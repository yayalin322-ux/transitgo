import { FieldValue, AggregateField } from "@google-cloud/firestore";

/**
 * The real Firestore implementation of the document-store interface (see memoryAdapter.mjs for the contract).
 * Kept deliberately thin: every rule of the app lives in appdata.mjs, which is tested against the in-memory
 * adapter. `db` is a `Firestore` instance (Admin credentials come from the environment, see firestoreClient.mjs).
 *
 * Composite indexes the queries in appdata.mjs need are listed in firestore.indexes.json.
 */
export function createFirestoreAdapter(db, { prefix = "" } = {}) {
  const ref = (name) => db.collection(prefix + name);

  function applyQuery(name, { where = [], orderBy = [], limit } = {}) {
    let q = ref(name);
    for (const [f, op, v] of where) q = q.where(f, op, v);
    for (const [f, dir] of orderBy) q = q.orderBy(f, dir);
    if (limit) q = q.limit(limit);
    return q;
  }

  return {
    async get(name, id) {
      const s = await ref(name).doc(String(id)).get();
      return s.exists ? s.data() : null;
    },
    async set(name, id, data) { await ref(name).doc(String(id)).set(data); },
    async update(name, id, fields) {
      try { await ref(name).doc(String(id)).update(fields); return true; }
      catch (e) { if (e.code === 5 /* NOT_FOUND */) return false; throw e; }
    },
    async increment(name, id, field, n) {
      try { await ref(name).doc(String(id)).update({ [field]: FieldValue.increment(n) }); return true; }
      catch (e) { if (e.code === 5) return false; throw e; }
    },
    async remove(name, id) {
      const r = ref(name).doc(String(id));
      const s = await r.get();
      if (!s.exists) return false;
      await r.delete();
      return true;
    },
    async list(name, q) {
      const s = await applyQuery(name, q).get();
      return s.docs.map((d) => ({ _id: d.id, ...d.data() }));
    },
    async aggregate(name, where = [], avgField = null) {
      const q = applyQuery(name, { where });
      const spec = { count: AggregateField.count() };
      if (avgField) spec.avg = AggregateField.average(avgField);
      const s = await q.aggregate(spec).get();
      const d = s.data();
      return { count: d.count, avg: avgField ? (d.avg ?? null) : null };
    },
    /** Integer ids (the app and admin page address rows by number): a counter document, bumped in a transaction. */
    async nextId(name) {
      const c = db.collection(prefix + "_counters").doc(name);
      return db.runTransaction(async (tx) => {
        const s = await tx.get(c);
        const n = (s.exists ? s.data().n : 0) + 1;
        tx.set(c, { n });
        return n;
      });
    },
    async removeWhere(name, where, limit = 500) {
      const s = await applyQuery(name, { where, limit }).get();
      const batch = db.batch();
      s.docs.forEach((d) => batch.delete(d.ref));
      if (s.docs.length) await batch.commit();
      return s.docs.length;
    },
    async ensureCounterAtLeast(name, value) {
      const c = db.collection(prefix + "_counters").doc(name);
      await db.runTransaction(async (tx) => {
        const s = await tx.get(c);
        tx.set(c, { n: Math.max(s.exists ? s.data().n : 0, value) });
      });
    },
  };
}
