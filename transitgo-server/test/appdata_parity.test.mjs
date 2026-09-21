// The Firestore app-data layer must behave exactly like the SQL one. Both are driven through the SAME scenario
// (every function, edge cases included) and their outputs are compared. The SQL side is the real db.mjs on a
// temporary sqlite file; the document side is appdata.mjs over the in-memory adapter.
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { isDeepStrictEqual } from "node:util";

process.env.DB_PATH = join(mkdtempSync(join(tmpdir(), "parity-")), "p.db");
delete process.env.DATABASE_URL;
const sql = await import("../src/db.mjs");
const { createAppData } = await import("../src/firestore/appdata.mjs");
const { createMemoryAdapter } = await import("../src/firestore/memoryAdapter.mjs");

let failed = false;
function check(label, cond, detail) { console.log(`${cond ? "PASS" : "FAIL"} - ${label}`); if (!cond) { failed = true; if (detail) console.log("   ", detail); } }

// A clock that moves one second per call so ordering by created_at is decided by time, never by a tie.
let tick = 0;
const clock = () => new Date(Date.UTC(2026, 8, 21, 12, 0, 0) + 1000 * tick++);
const docs = createAppData(createMemoryAdapter(), { now: clock });

const TIME_KEYS = new Set(["created_at", "createdAt", "last_seen", "updated_at", "updatedAt", "lastSeen", "expiresAt", "expires_at"]);
/** Timestamps differ by design (SQL: second-resolution wall clock; documents: injected clock) — compare shape, not the instant. */
function norm(v) {
  if (Array.isArray(v)) return v.map(norm);
  if (v && typeof v === "object") return Object.fromEntries(Object.keys(v).sort().map((k) => [k, TIME_KEYS.has(k) ? (v[k] == null ? null : "<time>") : norm(v[k])]));
  return v;
}
const byId = (a) => [...a].sort((x, y) => (x.id ?? 0) - (y.id ?? 0));

/** Runs the whole scenario against one implementation and returns everything it observed. */
async function scenario(api) {
  const r = {};
  // devices
  await api.upsertDevice({ token: "tok-a", platform: "ios", appVersion: "1.0" });
  await api.upsertDevice({ token: "tok-b", platform: "ios", appVersion: "1.0" });
  await api.upsertDevice({ token: "tok-a", platform: "ios", appVersion: "1.1" });   // upsert, not duplicate
  r.tokens = (await api.allDeviceTokens()).sort();
  await api.removeDevice("tok-b");
  r.tokensAfterRemove = await api.allDeviceTokens();

  // announcements
  const a1 = await api.createAnnouncement({ category: "metro", severity: "warning", title: "T1", body: "b1" });
  const a2 = await api.createAnnouncement({ category: "bus", title: "T2", expiresAt: "2099-01-01 00:00:00" });
  await api.createAnnouncement({ category: "rail", title: "expired", expiresAt: "2001-01-01 00:00:00" });
  r.ann = [a1, a2];
  r.annList = byId(await api.listAnnouncements());
  await api.deactivateAnnouncement(a1.id);
  r.annAfterDeactivate = byId(await api.listAnnouncements());
  r.annInactiveToo = byId(await api.listAnnouncements({ includeInactive: true }));
  r.annGet = await api.getAnnouncement(a2.id);
  r.annMissing = await api.getAnnouncement(9999);

  // reports / ratings / observations
  await api.createReport({ type: "bug", message: "m", context: { a: 1 }, appVersion: "1", os: "ios", device: "d", ip: "1.1.1.1" });
  await api.createReport({ type: "idea" });
  r.reports = byId(await api.listReports(10));
  for (const [stars, route] of [[5, "307"], [3, "307"], [4, "307"], [9, "20"], [0, "20"]]) {
    await api.createRating({ stars, kind: "bus", route, system: "TPE", from: "A", to: "B", appVersion: "1", device: "d" });
  }
  await api.createRating({ stars: 2, kind: "rail", route: "152", system: "TRA" });
  r.ratings = byId(await api.listRatings(50));
  r.routeStats = await api.routeRatingStats("bus", "307", "TPE");
  r.routeStatsNoSystem = await api.routeRatingStats("bus", "307", null);
  r.routeStatsNone = await api.routeRatingStats("bus", "nope", null);
  r.ratingStats = await api.ratingStats();
  await api.createObservation({ route: "307", plate: "ABC-123", stopUID: "S1", stopName: "台北", kind: "alight", system: "TPE", ip: "1" });
  await api.createObservation({ route: "20", kind: "weird" });
  r.obsAll = byId(await api.listObservations());
  r.obsRoute = byId(await api.listObservations({ route: "307" }));

  // caches (memory only on the document side; the SQL side stores them — observable behaviour must match)
  r.bikeBefore = await api.getBikeCache("Taipei");
  await api.setBikeCache("Taipei", [{ uid: "1" }]);
  r.bike = (await api.getBikeCache("Taipei"))?.stations;
  r.bikeAll = (await api.allBikeCaches()).map((c) => ({ city: c.city, n: c.stations.length }));
  r.camBefore = await api.getSpeedcamCache();
  await api.setSpeedcamCache([{ lat: 1, lon: 2 }]);
  r.cam = (await api.getSpeedcamCache())?.cams;

  // place reviews
  await api.createPlaceReview({ placeKey: "p1", placeName: "店", lat: 1, lon: 2, stars: 5, comment: "好", device: "dev1" });
  await api.createPlaceReview({ placeKey: "p1", placeName: "店", stars: 2, comment: "x".repeat(600), device: "dev2" });
  await api.createPlaceReview({ placeKey: "p1", placeName: "店", stars: 1, comment: "old client" });   // no device: insert-only
  await api.createPlaceReview({ placeKey: "p2", placeName: "別家", stars: 3, comment: "", device: "dev1" });
  // same device+place: update. (SQL's ON CONFLICT burns an auto-increment id, so it goes after every insert whose id is asserted.)
  await api.createPlaceReview({ placeKey: "p1", placeName: "店", stars: 4, comment: "改了", device: "dev1" });
  r.pr = byId(await api.listPlaceReviews("p1"));
  r.prStats = await api.placeReviewStats("p1");
  r.prStatsNone = await api.placeReviewStats("zzz");
  const firstReview = r.pr[0].id;
  r.reportOk = await api.reportPlaceReview(firstReview, "spam", "9.9.9.9");
  await api.reportPlaceReview(firstReview, "spam", "9.9.9.8");
  await api.reportPlaceReview(firstReview, "not-a-reason", "9.9.9.7");
  r.reportMissing = await api.reportPlaceReview(9999, "spam", "1");
  r.prAll = (await api.listAllPlaceReviews(50));
  r.prAllTopIsReported = r.prAll[0].reported;
  r.prAll = byId(r.prAll);
  await api.createPlaceReview({ placeKey: "p1", placeName: "店", stars: 5, comment: "again", device: "dev1" });   // resets reported to 0
  r.prAfterResubmit = byId(await api.listAllPlaceReviews(50)).find((x) => x.id === firstReview);
  r.deleteOk = await api.deletePlaceReview(r.pr[1].id);
  r.deleteMissing = await api.deletePlaceReview(9999);
  r.prAfterDelete = byId(await api.listPlaceReviews("p1")).map((x) => x.id);

  // landmarks
  await api.createUserLandmark({ name: "甲", description: "d", category: "foodDrink", lat: 24.84, lon: 121.01, isBusinessClaim: true, businessHours: "9-5", phone: "0900", device: "devA", photo: null });
  await api.createUserLandmark({ name: "乙", category: "not-a-category", lat: 24.841, lon: 121.011, device: "devB" });
  await api.createUserLandmark({ name: "遠", category: "other", lat: 25.5, lon: 121.5, device: "devA" });
  r.nearBeforeApprove = await api.listApprovedLandmarksNear(24.84, 121.01, 1000);
  const all0 = byId(await api.listAllUserLandmarks(50));
  r.lmAll0 = all0;
  r.approve = await api.approveUserLandmark(all0[0].id);
  r.approveMissing = await api.approveUserLandmark(9999);
  await api.approveUserLandmark(all0[1].id);
  await api.approveUserLandmark(all0[2].id);
  r.nearAfterApprove = byId(await api.listApprovedLandmarksNear(24.84, 121.01, 1000));   // 甲 unverified: no hours/phone shown
  r.nearWide = byId(await api.listApprovedLandmarksNear(24.84, 121.01, 200000)).map((x) => x.name);
  r.verify = await api.verifyUserLandmarkBusiness(all0[0].id);
  r.nearVerified = byId(await api.listApprovedLandmarksNear(24.84, 121.01, 1000)).find((x) => x.id === all0[0].id);
  r.lmReport = await api.reportUserLandmark(all0[1].id, "offensive", "1");
  await api.reportUserLandmark(all0[1].id, "offensive", "2");
  await api.reportUserLandmark(all0[1].id, "weird", "3");
  r.lmReportMissing = await api.reportUserLandmark(9999, "spam", "1");
  r.lmQueueOrder = (await api.listAllUserLandmarks(50)).length;
  r.lmAllAfterReports = byId(await api.listAllUserLandmarks(50));
  r.mine = byId(await api.listMyUserLandmarks("devA"));
  r.mineNone = await api.listMyUserLandmarks("nobody");
  r.editOk = await api.updateMyUserLandmark(all0[0].id, "devA", { description: "新描述", businessHours: "10-6", phone: "0911", lat: 24.842, lon: 121.012 });
  r.editWrongDevice = await api.updateMyUserLandmark(all0[0].id, "devB", { description: "hack" });
  r.editUnverified = await api.updateMyUserLandmark(all0[2].id, "devA", { description: "no" });
  r.editNothing = await api.updateMyUserLandmark(all0[0].id, "devA", {});
  r.editMissing = await api.updateMyUserLandmark(9999, "devA", { description: "x" });
  r.afterEdit = byId(await api.listMyUserLandmarks("devA")).find((x) => x.id === all0[0].id);
  r.nearAfterEdit = byId(await api.listApprovedLandmarksNear(24.842, 121.012, 100)).map((x) => x.name);
  r.lmDelete = await api.deleteUserLandmark(all0[1].id);
  r.lmDeleteMissing = await api.deleteUserLandmark(9999);
  r.lmAfterDelete = byId(await api.listAllUserLandmarks(50)).map((x) => x.id);

  // alert state
  r.alertNone = await api.getAlertState("tra");
  await api.setAlertState("tra", "sig1", true);
  r.alert1 = await api.getAlertState("tra");
  await api.setAlertState("tra", "sig2", false);
  r.alert2 = await api.getAlertState("tra");

  // shared trip links
  const t0 = 1_000_000;
  await api.createShare({ token: "tokenA", title: "去新竹", segments: [{ mode: "TRA" }], nowMs: t0, expiresAtMs: t0 + 5000 });
  r.share = await api.getShare("tokenA");
  r.shareMissing = await api.getShare("nope");
  await api.createShare({ token: "tokenB", title: null, segments: [{ mode: "BUS" }], nowMs: t0 + 10_000, expiresAtMs: t0 + 20_000 });   // sweeps tokenA (expired at t0+5000)
  r.shareSwept = await api.getShare("tokenA");
  r.shareB = await api.getShare("tokenB");
  await api.deleteShare("tokenB");
  r.shareDeleted = await api.getShare("tokenB");
  return r;
}

const a = norm(await scenario(sql));
const b = norm(await scenario(docs));

// The SQL side keeps the two caches in the database; the document side keeps them in process memory. Same observable
// behaviour for a running server, so those keys are compared like everything else.
function firstDifference(x, y) {
  if (Array.isArray(x) && Array.isArray(y)) {
    for (let i = 0; i < Math.max(x.length, y.length); i++) {
      if (!isDeepStrictEqual(x[i], y[i])) return `item ${i}:\n     SQL=${JSON.stringify(x[i])}\n     DOC=${JSON.stringify(y[i])}`;
    }
  }
  return `SQL=${JSON.stringify(x)}\n     DOC=${JSON.stringify(y)}`;
}
// Deliberate deviation: after a re-submit the SQL version resets the report COUNT to 0 but keeps showing the old
// report REASONS ("reported 0 times (spam ×2…)"). The document version clears both. Asserted explicitly, not hidden.
check("deviation (intended): a re-submitted review shows no stale report reasons",
  b.prAfterResubmit.reported === 0 && Object.keys(b.prAfterResubmit.reportReasons).length === 0 && a.prAfterResubmit.reported === 0 && Object.keys(a.prAfterResubmit.reportReasons).length > 0);
delete a.prAfterResubmit; delete b.prAfterResubmit;
const keys = [...new Set([...Object.keys(a), ...Object.keys(b)])];
let differing = 0;
for (const k of keys) {
  const same = isDeepStrictEqual(a[k], b[k]);
  if (!same) differing++;
  check(`parity: ${k}`, same, same ? null : firstDifference(a[k], b[k]));
}

// ---- behaviours that only the document side must guarantee (ordering with distinct timestamps, caches)
{
  const fresh = createAppData(createMemoryAdapter(), { now: clock });
  await fresh.createReport({ type: "first" });
  await fresh.createReport({ type: "second" });
  await fresh.createReport({ type: "third" });
  check("lists are newest-first", (await fresh.listReports(10)).map((x) => x.type).join() === "third,second,first");
  check("limit is honoured", (await fresh.listReports(2)).length === 2);
  await fresh.createPlaceReview({ placeKey: "k", placeName: "n", stars: 3, comment: "a", device: "d1" });
  await fresh.createPlaceReview({ placeKey: "k", placeName: "n", stars: 5, comment: "b", device: "d2" });
  check("place reviews newest-first", (await fresh.listPlaceReviews("k")).map((x) => x.comment).join() === "b,a");
}
{
  // approved-landmark cache: served from memory for a minute, dropped by any landmark write
  let t = 0;
  const adapter = createMemoryAdapter();
  let reads = 0;
  const counting = { ...adapter, list: async (...args) => { if (args[0] === "user_landmarks") reads++; return adapter.list(...args); } };
  const d = createAppData(counting, { now: () => new Date(Date.UTC(2026, 8, 21) + t), landmarkCacheMs: 60_000 });
  await d.createUserLandmark({ name: "x", category: "other", lat: 24.8, lon: 121, device: "z" });
  await d.approveUserLandmark(1);
  await d.listApprovedLandmarksNear(24.8, 121); await d.listApprovedLandmarksNear(24.8, 121); await d.listApprovedLandmarksNear(24.8, 121);
  check("3 nearby requests cost 1 read of the landmark collection (cached)", reads === 1);
  t = 61_000; await d.listApprovedLandmarksNear(24.8, 121);
  check("the cache expires after a minute", reads === 2);
  await d.createUserLandmark({ name: "y", category: "other", lat: 24.8, lon: 121, device: "z" }); await d.approveUserLandmark(2);
  const near = await d.listApprovedLandmarksNear(24.8, 121);
  check("a landmark write drops the cache immediately (new approved landmark visible)", near.length === 2);
}

console.log(differing === 0 ? "all behaviours match" : `${differing} behaviour(s) differ`);
process.exit(failed ? 1 : 0);
