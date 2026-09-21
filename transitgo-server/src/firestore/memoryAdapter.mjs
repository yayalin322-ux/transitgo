/**
 * In-memory implementation of the small document-store interface the app-data layer is written against
 * (see appdata.mjs). It exists so all of that logic can be tested without a Firestore project or emulator; the
 * real adapter (firestoreAdapter.mjs) implements exactly the same methods.
 *
 * Interface — every method is async:
 *   get(col, id)                     → data | null
 *   set(col, id, data)               replace the document
 *   update(col, id, fields)          merge fields into an existing document → boolean (false when missing)
 *   increment(col, id, field, n)     atomic add → boolean
 *   remove(col, id)                  → boolean (existed)
 *   list(col, {where, orderBy, limit}) → [{ _id, ...data }]
 *   aggregate(col, where, avgField)  → { count, avg }
 *   nextId(col)                      → a new integer id, never reused
 *   removeWhere(col, where, limit)   → number removed
 * where = [[field, op, value]] with op in "==", "<=", ">"; orderBy = [[field, "asc" | "desc"]].
 */
export function createMemoryAdapter() {
  const cols = new Map();
  const counters = new Map();
  const col = (name) => { if (!cols.has(name)) cols.set(name, new Map()); return cols.get(name); };
  const clone = (v) => (v == null ? v : structuredClone(v));

  const test = (v, op, x) => (op === "==" ? v === x : op === "<=" ? v != null && v <= x : op === ">" ? v != null && v > x : false);
  const matches = (doc, where) => where.every(([f, op, x]) => test(doc[f], op, x));
  const cmp = (a, b) => (a === b ? 0 : a == null ? -1 : b == null ? 1 : a < b ? -1 : 1);

  function select(name, { where = [], orderBy = [], limit } = {}) {
    let rows = [...col(name).entries()].map(([id, d]) => ({ _id: id, ...clone(d) })).filter((d) => matches(d, where));
    if (orderBy.length) {
      rows.sort((a, b) => {
        for (const [f, dir] of orderBy) {
          const c = cmp(a[f], b[f]);
          if (c !== 0) return dir === "desc" ? -c : c;
        }
        return 0;
      });
    }
    return limit ? rows.slice(0, limit) : rows;
  }

  return {
    async get(name, id) { const d = col(name).get(String(id)); return d ? clone(d) : null; },
    async set(name, id, data) { col(name).set(String(id), clone(data)); },
    async update(name, id, fields) {
      const d = col(name).get(String(id));
      if (!d) return false;
      col(name).set(String(id), { ...d, ...clone(fields) });
      return true;
    },
    async increment(name, id, field, n) {
      const d = col(name).get(String(id));
      if (!d) return false;
      d[field] = (d[field] ?? 0) + n;
      return true;
    },
    async remove(name, id) { return col(name).delete(String(id)); },
    async list(name, q) { return select(name, q); },
    async aggregate(name, where = [], avgField = null) {
      const rows = select(name, { where });
      const vals = avgField ? rows.map((r) => r[avgField]).filter((v) => Number.isFinite(v)) : [];
      return { count: rows.length, avg: vals.length ? vals.reduce((a, b) => a + b, 0) / vals.length : null };
    },
    async nextId(name) { const n = (counters.get(name) ?? 0) + 1; counters.set(name, n); return n; },
    async removeWhere(name, where, limit = 500) {
      let n = 0;
      for (const r of select(name, { where, limit })) { col(name).delete(r._id); n++; }
      return n;
    },
    /** Test/migration helper: make sure future nextId(name) is above an id that was imported. */
    async ensureCounterAtLeast(name, value) { counters.set(name, Math.max(counters.get(name) ?? 0, value)); },
    _dump: (name) => select(name),
  };
}
