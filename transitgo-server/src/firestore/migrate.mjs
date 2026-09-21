/**
 * SQL → Firestore copy of the app-data tables. Pure with respect to where the rows come from and go to:
 *   readRows(table) → rows            (SELECT * — read only)
 *   adapter                           (the document-store interface)
 * Row ids are kept (the app and the admin page address rows by number) and each collection's id counter is moved past
 * the largest imported id, so the next new row can never collide with an old one.
 */
export const TABLES = [
  { table: "devices", key: (r) => r.token },
  { table: "announcements", key: (r) => r.id, counter: true },
  { table: "reports", key: (r) => r.id, counter: true },
  { table: "ratings", key: (r) => r.id, counter: true },
  { table: "observations", key: (r) => r.id, counter: true },
  { table: "place_reviews", key: (r) => r.id, counter: true },
  { table: "place_review_reports", key: (r) => r.id, counter: true },
  { table: "user_landmarks", key: (r) => r.id, counter: true },
  { table: "user_landmark_reports", key: (r) => r.id, counter: true },
  { table: "alert_state", key: (r) => r.source },
];

const TIME_COLUMNS = new Set(["created_at", "last_seen", "updated_at", "expires_at"]);

function toIso(v) {
  if (v == null || v === "") return null;
  if (v instanceof Date) return v.toISOString();
  const s = String(v);
  const d = new Date(/^\d{4}-\d{2}-\d{2} /.test(s) ? s.replace(" ", "T") + "Z" : s);
  return Number.isNaN(d.getTime()) ? null : d.toISOString();
}

/** A SQL row as a document: same column names, timestamps as ISO strings, undefined dropped. */
export function toDocument(row) {
  const doc = {};
  for (const [k, v] of Object.entries(row)) {
    if (v === undefined) continue;
    doc[k] = TIME_COLUMNS.has(k) ? toIso(v) : typeof v === "bigint" ? Number(v) : v;
  }
  return doc;
}

export async function migrate({ readRows, adapter, apply = false, log = () => {}, tables = TABLES }) {
  const report = [];
  for (const t of tables) {
    const rows = await readRows(t.table);
    const already = await adapter.aggregate(t.table, []);
    const entry = { table: t.table, source: rows.length, targetBefore: already.count, written: 0 };
    if (apply && already.count > 0) throw new Error(`refusing to write: collection "${t.table}" already holds ${already.count} documents`);
    if (apply) {
      let maxId = 0;
      for (const r of rows) {
        const key = t.key(r);
        if (key == null) continue;
        await adapter.set(t.table, key, toDocument(r));
        entry.written++;
        if (t.counter) maxId = Math.max(maxId, Number(r.id) || 0);
      }
      if (t.counter && maxId > 0) await adapter.ensureCounterAtLeast(t.table, maxId);
      entry.targetAfter = (await adapter.aggregate(t.table, [])).count;
      entry.ok = entry.targetAfter === entry.source;
    }
    log(entry);
    report.push(entry);
  }
  return report;
}
