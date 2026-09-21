// SQL → document migration: what is written, id safety, refusal to overwrite, and — the real check — that data
// migrated from SQL reads back through the document layer exactly as the SQL layer served it.
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { isDeepStrictEqual } from "node:util";

process.env.DB_PATH = join(mkdtempSync(join(tmpdir(), "mig-")), "m.db");
delete process.env.DATABASE_URL;
const sql = await import("../src/db.mjs");
const { db } = sql;
const { createAppData } = await import("../src/firestore/appdata.mjs");
const { createMemoryAdapter } = await import("../src/firestore/memoryAdapter.mjs");
const { migrate, toDocument, TABLES } = await import("../src/firestore/migrate.mjs");

let failed = false;
function check(label, cond, detail) { console.log(`${cond ? "PASS" : "FAIL"} - ${label}`); if (!cond) { failed = true; if (detail) console.log("   ", detail); } }

// ---- seed the SQL side with realistic data
await sql.upsertDevice({ token: "tok-a", platform: "ios", appVersion: "1.0" });
await sql.createAnnouncement({ category: "metro", severity: "warning", title: "公告一", body: "內文", expiresAt: "2099-01-01 00:00:00" });
await sql.createAnnouncement({ category: "bus", title: "公告二" });
await sql.createReport({ type: "bug", message: "m", context: { a: 1 }, os: "ios" });
await sql.createRating({ stars: 5, kind: "bus", route: "307", system: "TPE" });
await sql.createRating({ stars: 3, kind: "bus", route: "307", system: "TPE" });
await sql.createObservation({ route: "307", plate: "ABC", kind: "alight" });
await sql.createPlaceReview({ placeKey: "p1", placeName: "店", stars: 5, comment: "好", device: "d1" });
await sql.createPlaceReview({ placeKey: "p1", placeName: "店", stars: 2, comment: "普通", device: "d2" });
await sql.reportPlaceReview(1, "spam", "1.1.1.1");
await sql.createUserLandmark({ name: "甲", category: "foodDrink", lat: 24.84, lon: 121.01, isBusinessClaim: true, businessHours: "9-5", phone: "0900", device: "devA" });
await sql.createUserLandmark({ name: "乙", category: "other", lat: 24.85, lon: 121.02, device: "devB" });
await sql.approveUserLandmark(1); await sql.verifyUserLandmarkBusiness(1);
await sql.reportUserLandmark(2, "offensive", "2.2.2.2");
await sql.setAlertState("tra", "sig", true);

const readRows = (t) => db.prepare(`SELECT * FROM ${t}`).all();

// ---- dry run writes nothing
const adapter = createMemoryAdapter();
const dry = await migrate({ readRows, adapter, apply: false });
check("dry run reports the source counts", dry.find((r) => r.table === "ratings").source === 2 && dry.find((r) => r.table === "user_landmarks").source === 2);
check("dry run writes nothing", (await adapter.aggregate("ratings", [])).count === 0 && (await adapter.aggregate("devices", [])).count === 0);

// ---- apply
const applied = await migrate({ readRows, adapter, apply: true });
check("every table's target count equals its source count", applied.every((r) => r.ok), JSON.stringify(applied.filter((r) => !r.ok)));
check("all 10 tables were considered", applied.length === TABLES.length && TABLES.length === 10);

// ---- refuses to write over existing data
let refused = false;
try { await migrate({ readRows, adapter, apply: true }); } catch (e) { refused = /refusing to write/.test(e.message); }
check("a second --apply refuses instead of overwriting", refused);

// ---- reads back identically
const docs = createAppData(adapter);
const same = async (label, a, b) => check(`read-back matches the SQL layer: ${label}`, isDeepStrictEqual(a, b), `SQL=${JSON.stringify(a)?.slice(0, 200)}\n    DOC=${JSON.stringify(b)?.slice(0, 200)}`);
const drop = (v) => JSON.parse(JSON.stringify(v, (k, x) => (["createdAt", "created_at", "last_seen", "updated_at", "expiresAt"].includes(k) ? "<t>" : x)));
await same("device tokens", await sql.allDeviceTokens(), await docs.allDeviceTokens());
await same("announcements", drop(await sql.listAnnouncements()).sort((a, b) => a.id - b.id), drop(await docs.listAnnouncements()).sort((a, b) => a.id - b.id));
await same("ratings stats", await sql.ratingStats(), await docs.ratingStats());
await same("route rating stats", await sql.routeRatingStats("bus", "307", "TPE"), await docs.routeRatingStats("bus", "307", "TPE"));
await same("place reviews (with report reasons)", drop(await sql.listAllPlaceReviews()).sort((a, b) => a.id - b.id), drop(await docs.listAllPlaceReviews()).sort((a, b) => a.id - b.id));
await same("place review stats", await sql.placeReviewStats("p1"), await docs.placeReviewStats("p1"));
await same("landmark moderation queue", drop(await sql.listAllUserLandmarks()).sort((a, b) => a.id - b.id), drop(await docs.listAllUserLandmarks()).sort((a, b) => a.id - b.id));
await same("approved landmarks near a point (verified business shows its hours)", drop(await sql.listApprovedLandmarksNear(24.84, 121.01, 2000)), drop(await docs.listApprovedLandmarksNear(24.84, 121.01, 2000)));
await same("alert state", drop(await sql.getAlertState("tra")), drop(await docs.getAlertState("tra")));
await same("a device's own landmarks", drop(await sql.listMyUserLandmarks("devA")), drop(await docs.listMyUserLandmarks("devA")));

// ---- id safety: a new row after migration must not reuse an imported id
await docs.createUserLandmark({ name: "新", category: "other", lat: 24.9, lon: 121, device: "devC" });
const ids = (await docs.listAllUserLandmarks(50)).map((x) => x.id).sort();
check("the next landmark gets a fresh id (3), never 1 or 2", isDeepStrictEqual(ids, [1, 2, 3]));
await docs.createAnnouncement({ category: "rail", title: "新公告" });
check("the next announcement continues the sequence (3)", (await docs.listAnnouncements()).some((a) => a.id === 3));

// ---- document conversion
const doc = toDocument({ id: 1, created_at: new Date("2026-09-21T01:02:03Z"), last_seen: "2026-09-21 01:02:03", expires_at: null, big: 12n, gone: undefined, name: "甲" });
check("timestamps become ISO strings, bigint a number, undefined is dropped",
  doc.created_at === "2026-09-21T01:02:03.000Z" && doc.last_seen === "2026-09-21T01:02:03.000Z" && doc.expires_at === null && doc.big === 12 && !("gone" in doc) && doc.name === "甲");

process.exit(failed ? 1 : 0);
