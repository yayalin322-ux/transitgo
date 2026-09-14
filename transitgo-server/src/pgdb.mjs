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
    this.pool = new Pool({ connectionString, ssl: { rejectUnauthorized: false } });
    // Set between BEGIN and COMMIT/ROLLBACK to pin every query in an explicit
    // transaction to one physical connection. Null outside a transaction, when
    // each statement can use whichever connection the pool hands back.
    this.txClient = null;
  }

  /** Multi-statement DDL/raw SQL — pg's simple query protocol runs every ';'-separated
   * statement in one round trip as long as there are no bound parameters, same as
   * sqlite's db.exec(). Also where BEGIN/COMMIT/ROLLBACK are intercepted to pin/release
   * a single connection for the duration of an explicit transaction. */
  async exec(sql) {
    const trimmed = sql.trim().toUpperCase();
    if (trimmed === "BEGIN") {
      const client = await this.pool.connect();
      try {
        await client.query(sql);
      } catch (e) {
        client.release();
        throw e;
      }
      this.txClient = client;
      return;
    }
    if (trimmed === "COMMIT" || trimmed === "ROLLBACK") {
      const client = this.txClient;
      this.txClient = null;
      if (!client) return;
      try {
        await client.query(sql);
      } finally {
        client.release();
      }
      return;
    }
    await (this.txClient || this.pool).query(sql);
  }

  prepare(sql) {
    return new PgStatement(this, sql);
  }
}
