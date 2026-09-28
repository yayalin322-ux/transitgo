// Google-Maps-style business info end to end: photo gallery, structured hours (+ computed
// "open now"), feature tags — through the DB layer, both freshly created and later edited.
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

process.env.DB_PATH = join(mkdtempSync(join(tmpdir(), "landmark-business-info-")), "t.db");
delete process.env.DATABASE_URL;
const {
  createUserLandmark, listAllUserLandmarks, approveUserLandmark, getApprovedLandmark,
  listApprovedLandmarksNear, updateMyUserLandmark, listVerifiedBusinesses,
} = await import("../src/db.mjs");
const { WEEKDAYS } = await import("../src/landmarks.mjs");

let failed = false;
function check(label, cond) { console.log(`${cond ? "PASS" : "FAIL"} - ${label}`); if (!cond) failed = true; }

const fullWeek = (day) => Object.fromEntries(WEEKDAYS.map((d) => [d, day]));
const photoA = "data:image/jpeg;base64," + "A".repeat(50);
const photoB = "data:image/jpeg;base64," + "B".repeat(50);
const hours = { ...fullWeek({ open: "09:00", close: "21:00" }), sun: null };

// ---- a verified business created with the full gallery/hours/features up front ----
await createUserLandmark({
  name: "全功能小吃店", description: "", category: "restaurant", lat: 24.8, lon: 121.0,
  isBusinessClaim: true, businessVerified: true, businessHours: "自行填寫的舊版文字", phone: "03-1111111",
  device: "biz-phone-1", email: "biz@example.com", ip: "1.1.1.1",
  photos: [photoA, photoB], hours, features: ["parking", "wifi"],
});
const [fullBiz] = await listAllUserLandmarks(50).then((all) => all.filter((l) => l.name === "全功能小吃店"));
await approveUserLandmark(fullBiz.id);
{
  const seen = await getApprovedLandmark(fullBiz.id);
  check("the gallery reads back in order", JSON.stringify(seen.photos) === JSON.stringify([photoA, photoB]));
  check("structured hours read back exactly", JSON.stringify(seen.hours) === JSON.stringify(hours));
  check("feature tags read back exactly", JSON.stringify(seen.features) === JSON.stringify(["parking", "wifi"]));
  check("openNow is computed (not null) once structured hours exist", seen.openNow !== null && typeof seen.openNow.open === "boolean");
}
{
  const near = (await listApprovedLandmarksNear(24.8, 121.0, 500)).find((l) => l.id === fullBiz.id);
  check("the nearby-list view carries the same gallery/hours/features/openNow", JSON.stringify(near.photos) === JSON.stringify([photoA, photoB]) && near.openNow !== null);
}
{
  const { businesses } = await listVerifiedBusinesses();
  const row = businesses.find((b) => b.id === fullBiz.id);
  check("the directory shows a cover photo (the gallery's first photo)", row.coverPhoto === photoA);
  check("the directory shows openNow too", row.openNow !== null);
}

// ---- a plain landmark, never claimed as a business: legacy single `photo` still works ----
await createUserLandmark({ name: "普通地標", description: "", category: "other", lat: 24.81, lon: 121.01, photo: photoA, device: "x", ip: "1.1.1.1" });
const [plain] = await listAllUserLandmarks(50).then((all) => all.filter((l) => l.name === "普通地標"));
await approveUserLandmark(plain.id);
{
  const seen = await getApprovedLandmark(plain.id);
  check("an unverified landmark's gallery falls back to its single legacy photo, not empty", JSON.stringify(seen.photos) === JSON.stringify([photoA]));
  check("an unverified landmark has no structured hours and openNow is null", seen.hours === null && seen.openNow === null);
  check("an unverified landmark has no feature tags", JSON.stringify(seen.features) === JSON.stringify([]));
}

// ---- editing an existing verified business's gallery/hours/features ----
{
  const ok = await updateMyUserLandmark(fullBiz.id, { device: "biz-phone-1" }, {
    photos: [photoB],   // swap the gallery down to one photo
    hours: fullWeek(null),   // now closed every day
    features: ["petFriendly"],
  });
  check("the owner's own device can edit gallery/hours/features", ok === true);
  const seen = await getApprovedLandmark(fullBiz.id);
  check("...and the gallery actually changed", JSON.stringify(seen.photos) === JSON.stringify([photoB]));
  check("...and hours changed to always-closed", seen.openNow.open === false);
  check("...and feature tags changed", JSON.stringify(seen.features) === JSON.stringify(["petFriendly"]));
}
{
  // A field the caller didn't touch (photos) must survive an edit that only changes hours.
  const ok = await updateMyUserLandmark(fullBiz.id, { device: "biz-phone-1" }, { hours: fullWeek({ open: "00:00", close: "23:59" }) });
  check("editing only hours succeeds", ok === true);
  const seen = await getApprovedLandmark(fullBiz.id);
  check("...and the gallery from the previous edit is untouched", JSON.stringify(seen.photos) === JSON.stringify([photoB]));
}
{
  const ok = await updateMyUserLandmark(fullBiz.id, { device: "someone-elses-phone" }, { features: ["wifi"] });
  check("a different device can't edit these fields either (same ownership gate as everything else)", ok === false);
}

process.exit(failed ? 1 : 0);
