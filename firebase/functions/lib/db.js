// Firestore-backed equivalent of transitgo-server's src/db.mjs. Same function names
// and shapes so index.js reads almost identically to the Node/Express version.
import { initializeApp, getApps } from "firebase-admin/app";
import { getFirestore, Timestamp, FieldValue } from "firebase-admin/firestore";

if (!getApps().length) initializeApp();
export const db = getFirestore();

const toISO = (ts) => (ts instanceof Timestamp ? ts.toDate().toISOString() : ts ?? null);

// ---- devices ----
export async function upsertDevice({ token, platform, appVersion }) {
  await db.collection("devices").doc(token).set(
    { platform: platform ?? null, appVersion: appVersion ?? null, lastSeen: FieldValue.serverTimestamp(),
      createdAt: FieldValue.serverTimestamp() },
    { merge: true }
  );
}
export async function allDeviceTokens() {
  const snap = await db.collection("devices").get();
  return snap.docs.map((d) => d.id);
}
export async function removeDevice(token) {
  await db.collection("devices").doc(token).delete();
}

// ---- announcements ----
export async function createAnnouncement(a) {
  const ref = await db.collection("announcements").add({
    category: a.category,
    severity: a.severity ?? "info",
    title: a.title,
    body: a.body ?? "",
    source: a.source ?? "admin",
    active: true,
    createdAt: FieldValue.serverTimestamp(),
    expiresAt: a.expiresAt ?? null,   // ISO string or null
  });
  const doc = await ref.get();
  return serializeAnnouncement(doc);
}

/**
 * Firestore can't combine an `active == true` filter with an `expiresAt` range filter
 * and a `since` range filter on a *different* field in one query — so we filter on
 * `active` + order by `createdAt` server-side, then post-filter `since`/`expiresAt` in
 * memory. Fine at this scale; revisit with a composite index if the collection gets huge.
 */
export async function listAnnouncements({ since, includeInactive = false } = {}) {
  let q = db.collection("announcements").orderBy("createdAt", "desc").limit(200);
  if (!includeInactive) q = q.where("active", "==", true);
  const snap = await q.get();
  const now = Date.now();
  return snap.docs
    .map(serializeAnnouncement)
    .filter((a) => !a.expiresAt || new Date(a.expiresAt).getTime() > now)
    .filter((a) => !since || new Date(a.createdAt).getTime() > new Date(since).getTime());
}

export async function deactivateAnnouncement(id) {
  await db.collection("announcements").doc(id).update({ active: false });
}

function serializeAnnouncement(doc) {
  const r = doc.data();
  if (!r) return null;
  return {
    id: doc.id,
    category: r.category,
    severity: r.severity,
    title: r.title,
    body: r.body,
    source: r.source,
    active: !!r.active,
    createdAt: toISO(r.createdAt),
    expiresAt: r.expiresAt ? toISO(r.expiresAt) : null,
  };
}

// ---- reports ----
export async function createReport(r) {
  await db.collection("reports").add({
    type: r.type,
    message: r.message ?? "",
    context: r.context ?? null,
    appVersion: r.appVersion ?? null,
    os: r.os ?? null,
    device: r.device ?? null,
    ip: r.ip ?? null,
    createdAt: FieldValue.serverTimestamp(),
  });
}
export async function listReports(limit = 100) {
  const snap = await db.collection("reports").orderBy("createdAt", "desc").limit(limit).get();
  return snap.docs.map((d) => ({ id: d.id, ...d.data(), createdAt: toISO(d.data().createdAt) }));
}

// ---- ratings ----
export async function createRating(r) {
  await db.collection("ratings").add({
    stars: Math.max(1, Math.min(5, parseInt(r.stars, 10) || 0)),
    kind: r.kind ?? "bus",
    route: r.route ?? null,
    fromStop: r.from ?? null,
    toStop: r.to ?? null,
    system: r.system ?? null,
    appVersion: r.appVersion ?? null,
    device: r.device ?? null,
    ip: r.ip ?? null,
    createdAt: FieldValue.serverTimestamp(),
  });
}
export async function listRatings(limit = 100) {
  const snap = await db.collection("ratings").orderBy("createdAt", "desc").limit(limit).get();
  return snap.docs.map((d) => ({ id: d.id, ...d.data(), createdAt: toISO(d.data().createdAt) }));
}

/** Public per-route average — what the app shows next to a route, Google-Maps style. */
export async function routeRatingStats(kind, route, system) {
  let q = db.collection("ratings").where("kind", "==", kind).where("route", "==", route);
  if (system) q = q.where("system", "==", system);
  const snap = await q.limit(2000).get();
  const stars = snap.docs.map((d) => d.data().stars).filter((n) => typeof n === "number");
  if (stars.length === 0) return { count: 0, avg: null };
  const avg = stars.reduce((a, b) => a + b, 0) / stars.length;
  return { count: stars.length, avg: Number(avg.toFixed(1)) };
}

/** Overall stats for the admin page. Reads up to 5000 most-recent ratings — fine at
 * bootstrap scale; move to running counters if this collection grows large. */
export async function ratingStats() {
  const snap = await db.collection("ratings").orderBy("createdAt", "desc").limit(5000).get();
  const byStar = { 1: 0, 2: 0, 3: 0, 4: 0, 5: 0 };
  let sum = 0;
  snap.docs.forEach((d) => {
    const s = d.data().stars;
    if (byStar[s] !== undefined) { byStar[s]++; sum += s; }
  });
  const n = snap.size;
  return { count: n, avg: n ? Number((sum / n).toFixed(2)) : null, byStar };
}

// ---- observations (crowd-sourced board / alight events) ----
export async function createObservation(o) {
  await db.collection("observations").add({
    route: o.route ?? null,
    plate: o.plate ?? null,
    stopUID: o.stopUID ?? null,
    stopName: o.stopName ?? null,
    kind: o.kind === "alight" ? "alight" : "board",
    system: o.system ?? null,
    ip: o.ip ?? null,
    createdAt: FieldValue.serverTimestamp(),
  });
}
export async function listObservations({ route = null, limit = 100 } = {}) {
  let q = db.collection("observations").orderBy("createdAt", "desc").limit(limit);
  if (route) q = db.collection("observations").where("route", "==", route).orderBy("createdAt", "desc").limit(limit);
  const snap = await q.get();
  return snap.docs.map((d) => ({ id: d.id, ...d.data(), createdAt: toISO(d.data().createdAt) }));
}

// ---- bike cache (shared, refreshed by the scheduled poller) ----
export async function setBikeCache(city, stations) {
  await db.collection("bikeCache").doc(city).set({ stations, updatedAt: FieldValue.serverTimestamp() });
}
export async function getBikeCache(city) {
  const doc = await db.collection("bikeCache").doc(city).get();
  if (!doc.exists) return null;
  const r = doc.data();
  return { stations: r.stations, updatedAt: toISO(r.updatedAt) };
}
export async function allBikeCaches() {
  const snap = await db.collection("bikeCache").get();
  return snap.docs.map((d) => ({ city: d.id, stations: d.data().stations, updatedAt: toISO(d.data().updatedAt) }));
}

// ---- alert state (dedup for the scheduled TRA/THSR alert poller) ----
export async function getAlertState(source) {
  const doc = await db.collection("alertState").doc(source).get();
  return doc.exists ? doc.data() : null;
}
export async function setAlertState(source, signature, abnormal) {
  await db.collection("alertState").doc(source).set({
    signature, abnormal: !!abnormal, updatedAt: FieldValue.serverTimestamp(),
  });
}
