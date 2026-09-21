// Copies the app-data tables from Supabase/sqlite to Firestore.
//
//   node scripts/migrate_to_firestore.mjs                 dry run: counts only, writes NOTHING
//   node scripts/migrate_to_firestore.mjs --apply         writes (refuses if a target collection is not empty)
//   --prefix dev_                                         namespace the collections (rehearse on the real project safely)
//
// Reads with plain SELECTs. Credentials come from the environment (DATABASE_URL for the source;
// FIREBASE_SERVICE_ACCOUNT_JSON or GOOGLE_APPLICATION_CREDENTIALS for the target). Nothing is printed except counts.
import { migrate } from "../src/firestore/migrate.mjs";

const args = process.argv.slice(2);
const apply = args.includes("--apply");
const prefix = args.includes("--prefix") ? args[args.indexOf("--prefix") + 1] : (process.env.FIRESTORE_PREFIX || "");

// The source is read with its own READ-ONLY connection. (Importing src/db.mjs would run its CREATE TABLE IF NOT EXISTS
// statements against the database — a write, which a migration's source must never receive.)
async function openSource() {
  if (process.env.DATABASE_URL) {
    const { default: pg } = await import("pg");
    const url = process.env.DATABASE_URL;
    const pool = new pg.Pool({ connectionString: url, max: 1, ssl: /localhost|127\.0\.0\.1/.test(url) ? false : { rejectUnauthorized: false } });
    const client = await pool.connect();
    // Every read runs inside a READ ONLY transaction: the server itself refuses any write, even through a pooler.
    const rows = async (t) => {
      await client.query("BEGIN READ ONLY");
      try { return (await client.query(`SELECT * FROM ${t}`)).rows; } finally { await client.query("ROLLBACK"); }
    };
    return { rows, close: async () => { client.release(); await pool.end(); }, label: "Postgres (read-only)" };
  }
  const { DatabaseSync } = await import("node:sqlite");
  const file = process.env.DB_PATH || "./data/transitgo.db";
  const d = new DatabaseSync(file, { readOnly: true });
  return { rows: async (t) => d.prepare(`SELECT * FROM ${t}`).all(), close: async () => d.close(), label: "sqlite (read-only)" };
}
const source = await openSource();
const { createFirestoreClient } = await import("../src/firestore/firestoreClient.mjs");
const { createFirestoreAdapter } = await import("../src/firestore/firestoreAdapter.mjs");

const adapter = createFirestoreAdapter(createFirestoreClient(), { prefix });
console.log(`${apply ? "APPLY" : "DRY RUN (nothing is written)"} · source: ${source.label} · target collections prefix: "${prefix}"`);

const report = await migrate({
  readRows: (table) => source.rows(table),
  adapter, apply,
  log: (e) => console.log(`${e.table.padEnd(24)} source ${String(e.source).padStart(6)} · target before ${String(e.targetBefore).padStart(5)}${apply ? ` · written ${e.written} · target after ${e.targetAfter} · ${e.ok ? "OK" : "MISMATCH"}` : ""}`),
});
await source.close();
if (apply && report.some((r) => !r.ok)) { console.error("MISMATCH — do not switch DATA_BACKEND"); process.exit(1); }
console.log(apply ? "done — counts match. Switch with DATA_BACKEND=firestore only after checking them yourself." : "dry run finished — re-run with --apply to write.");
process.exit(0);
