// Postgres-backed drop-in replacement for node:sqlite's DatabaseSync, used when
// DATABASE_URL (Supabase's connection string) is set. Real motivation: Render's disk is
// ephemeral — every deploy wiped the SQLite file, taking real user data (reviews,
// landmarks, ratings) with it. Supabase's Postgres is a separate persistent service, so
// deploys stop wiping anything.
//
// The rest of the codebase (db.mjs, gtfs/schema.mjs, graph/builder.mjs, tdx/ingest.mjs,
// graph/calendar.mjs) was written against node:sqlite's synchronous `.prepare(sql).run()
// /.get()/.all()` shape. Every call site there is now `await`-ed — awaiting a plain
// (non-Promise) value is a no-op in JS, so those same call sites work unchanged whether
// the object underneath is real sqlite (tests, which construct their own in-memory
// DatabaseSync directly) or this Postgres shim (production). This module is what makes
// the *production* half of that true.
import pg from "pg";

const { Pool } = pg;

/**
 * Translates SQLite-style placeholders (`?` positional, `:name` named) into Postgres's
 * `$1, $2, ...`, and reorders/dereferences the caller's args (a single object for named,
 * a flat arg list for positional) to match. This is the one piece of real "SQL dialect"
 * translation this shim does — everything else in the queries below is already
 * standard/portable SQL (both engines accept it as-is).
 */
function translate(sql, args) {
  let n = 0;
  const values = [];
  const named = args.length === 1 && args[0] !== null && typeof args[0] === "object" && !Array.isArray(args[0]);
  const namedObj = named ? args[0] : null;
  const text = sql.replace(/:(\w+)|\?/g, (match, name) => {
    n += 1;
    values.push(name ? namedObj[name] : args[values.length]);
    return `$${n}`;
  });
  return { text, values };
}

class PgStatement {
  constructor(db, sql) {
    this.db = db;
    this.sql = sql;
  }

  // BEGIN/COMMIT/ROLLBACK pin a single checked-out client on the PgDatabase (see
  // exec() below); every statement run while that's set must go through the SAME
  // client, or a multi-statement transaction can land its inserts on a different
  // pooled connection than its own BEGIN/COMMIT — silently breaking atomicity and,
  // worse, leaving connections stuck "idle in transaction" until the pool is
  // exhausted and unrelated requests start timing out (surfaced as 502s upstream).
  get conn() {
    return this.db.txClient || this.db.pool;
  }

  async run(...args) {
    const { text, values } = translate(this.sql, args);
    const result = await this.conn.query(text, values);
    return {
      changes: result.rowCount ?? 0,
      // Only meaningful for an INSERT ... RETURNING id — every INSERT in this codebase
      // that needs the new row's id back has that clause added explicitly (see below).
      lastInsertRowid: result.rows?.[0]?.id ?? null,
    };
  }

  async get(...args) {
    const { text, values } = translate(this.sql, args);
    const result = await this.conn.query(text, values);
    return result.rows[0];
  }

  async all(...args) {
    const { text, values } = translate(this.sql, args);
    const result = await this.conn.query(text, values);
    return result.rows;
  }
}

export class PgDatabase {
  constructor(connectionString) {
    // connectionTimeoutMillis caps how long pool.connect() waits for a free client —
    // pg's own default is 0 (wait forever), which turns any real leak/exhaustion into
    // a silent permanent hang instead of a clear, fast error.
    this.pool = new Pool({ connectionString, ssl: { rejectUnauthorized: false }, connectionTimeoutMillis: 15_000 });
    // If the process holding a transaction open dies uncleanly (container restart
    // mid-request, OOM kill, etc.) the client-side release() in exec() above never
    // runs — Postgres has no way to know the other end is gone until it notices the
    // dead TCP connection, which can take a long time. Left unbounded, that "idle in
    // transaction" session holds its locks indefinitely and blocks schema DDL on
    // every later boot. This makes Postgres itself kill any transaction that's been
    // idle (not actively running a query) for more than 30s, so a crashed process
    // can no longer wedge the database for longer than that.
    this.pool.on("connect", (client) => {
      client.query("SET idle_in_transaction_session_timeout = 30000").catch(() => {});
    });
    // Set between BEGIN and COMMIT/ROLLBACK to pin every query in an explicit
    // transaction to one physical connection. Null outside a transaction, when
    // each statement can use whichever connection the pool hands back.
    this.txClient = null;
    // db.mjs shares ONE PgDatabase across every request and background poller, so
    // without this lock two BEGINs that overlap in time (e.g. an admin ingest call
    // running long while another comes in) would stomp each other's this.txClient —
    // the first transaction's connection gets orphaned mid-transaction (never
    // committed/rolled back/released) since COMMIT ends up firing on whichever
    // client is current by then. That's exactly how a connection ends up stuck
    // "idle in transaction" forever, eventually exhausting the pool so that every
    // later request hangs on pool.connect() with no error and no trace in
    // pg_stat_activity. This chain of promises serializes BEGIN...COMMIT/ROLLBACK
    // blocks so only one is ever in flight against this.txClient at a time.
    this._txLock = Promise.resolve();
  }

  /** Multi-statement DDL/raw SQL — pg's simple query protocol runs every ';'-separated
   * statement in one round trip as long as there are no bound parameters, same as
   * sqlite's db.exec(). Also where BEGIN/COMMIT/ROLLBACK are intercepted to pin/release
   * a single connection for the duration of an explicit transaction. */
  async exec(sql) {
    const trimmed = sql.trim().toUpperCase();
    if (trimmed === "BEGIN") {
      // Queue behind any transaction already in progress, then hold the lock open
      // (release() is handed to the COMMIT/ROLLBACK branch below, not called here)
      // until this transaction ends — that's what actually serializes them.
      let release;
      const prev = this._txLock;
      this._txLock = new Promise((resolve) => { release = resolve; });
      await prev;
      const client = await this.pool.connect();
      try {
        await client.query(sql);
      } catch (e) {
        client.release();
        release();
        throw e;
      }
      this.txClient = client;
      this._releaseTxLock = release;
      return;
    }
    if (trimmed === "COMMIT" || trimmed === "ROLLBACK") {
      const client = this.txClient;
      const releaseLock = this._releaseTxLock;
      this.txClient = null;
      this._releaseTxLock = null;
      if (!client) return;
      try {
        await client.query(sql);
      } finally {
        client.release();
        if (releaseLock) releaseLock();
      }
      return;
    }
    await (this.txClient || this.pool).query(sql);
  }

  prepare(sql) {
    return new PgStatement(this, sql);
  }
}
