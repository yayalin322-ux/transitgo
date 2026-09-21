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

const { db } = await import("../src/db.mjs");
const { createFirestoreClient } = await import("../src/firestore/firestoreClient.mjs");
const { createFirestoreAdapter } = await import("../src/firestore/firestoreAdapter.mjs");

const adapter = createFirestoreAdapter(createFirestoreClient(), { prefix });
console.log(`${apply ? "APPLY" : "DRY RUN (nothing is written)"} · source: ${process.env.DATABASE_URL ? "Postgres" : "sqlite"} · target collections prefix: "${prefix}"`);

const report = await migrate({
  readRows: (table) => db.prepare(`SELECT * FROM ${table}`).all(),
  adapter, apply,
  log: (e) => console.log(`${e.table.padEnd(24)} source ${String(e.source).padStart(6)} · target before ${String(e.targetBefore).padStart(5)}${apply ? ` · written ${e.written} · target after ${e.targetAfter} · ${e.ok ? "OK" : "MISMATCH"}` : ""}`),
});
if (apply && report.some((r) => !r.ok)) { console.error("MISMATCH — do not switch DATA_BACKEND"); process.exit(1); }
console.log(apply ? "done — counts match. Switch with DATA_BACKEND=firestore only after checking them yourself." : "dry run finished — re-run with --apply to write.");
process.exit(0);
