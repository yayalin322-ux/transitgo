// Email verification (borrowed from yayalin.com) for reviews and business-landmark claims,
// plus the self-service delete that lets a reviewer remove their own review.
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

process.env.DB_PATH = join(mkdtempSync(join(tmpdir(), "reviews-landmarks-")), "t.db");
delete process.env.DATABASE_URL;
const {
  createPlaceReview, listPlaceReviews, listMyPlaceReviews, deletePlaceReviewByDevice,
  createUserLandmark, listApprovedLandmarksNear, getApprovedLandmark, listAllUserLandmarks,
  listMyUserLandmarks, updateMyUserLandmark, searchApprovedLandmarks, claimUserLandmark,
  approveUserLandmark, LANDMARK_CATEGORIES,
} = await import("../src/db.mjs");
const { requestSiteEmailCode, verifySiteEmailCode } = await import("../src/siteEmailCode.mjs");

let failed = false;
function check(label, cond) { console.log(`${cond ? "PASS" : "FAIL"} - ${label}`); if (!cond) failed = true; }

// ---- siteEmailCode.mjs: talks to yayalin.com's Supabase RPCs, network mocked ----
function fakeFetch(responses) {
  let i = 0;
  return async (url, opts) => {
    const call = { url, body: JSON.parse(opts.body) };
    const r = responses[Math.min(i, responses.length - 1)];
    i++;
    return { ok: r.ok, json: async () => r.body, _call: call };
  };
}

{
  const calls = [];
  const fx = async (url, opts) => { calls.push({ url, body: JSON.parse(opts.body) }); return { ok: true, json: async () => true }; };
  const ok = await requestSiteEmailCode("a@b.com", fx);
  check("requestSiteEmailCode hits request_email_code with purpose=app", ok === true && calls[0].url.endsWith("/rpc/request_email_code") && calls[0].body.p_email === "a@b.com" && calls[0].body.p_purpose === "app");
}
{
  const ok = await requestSiteEmailCode("a@b.com", fakeFetch([{ ok: false, body: null }]));
  check("a non-200 from Supabase is a plain failure, not a throw", ok === false);
}
{
  const ok = await requestSiteEmailCode("a@b.com", async () => { throw new Error("network down"); });
  check("a network error is a plain failure too", ok === false);
}
{
  const calls = [];
  const fx = async (url, opts) => { calls.push({ url, body: JSON.parse(opts.body) }); return { ok: true, json: async () => true }; };
  const ok = await verifySiteEmailCode("A@B.com", "123456", fx);
  check("verifySiteEmailCode hits verify_email_code and returns true on a true body", ok === true && calls[0].url.endsWith("/rpc/verify_email_code") && calls[0].body.p_code === "123456");
}
{
  const ok = await verifySiteEmailCode("a@b.com", "000000", fakeFetch([{ ok: true, body: false }]));
  check("a false body (wrong/expired code) is rejected, not just 'ok'", ok === false);
}
{
  const ok = await verifySiteEmailCode("a@b.com", "000000", fakeFetch([{ ok: false, body: null }]));
  check("a non-200 from Supabase is rejected too", ok === false);
}

// ---- place reviews: email stored, self-delete is ownership-checked ----
await createPlaceReview({ placeKey: "cafe_1", placeName: "咖啡店", stars: 5, comment: "好喝", device: "dev-A", email: "a@b.com", ip: "1.1.1.1" });
{
  const mine = await listMyPlaceReviews("dev-A");
  check("the review is findable by its own device, with the place it belongs to", mine.length === 1 && mine[0].placeKey === "cafe_1" && mine[0].placeName === "咖啡店");
  check("a different device sees nothing under 'mine'", (await listMyPlaceReviews("dev-B")).length === 0);
  const id = mine[0].id;
  check("someone else's device cannot delete it", (await deletePlaceReviewByDevice(id, "dev-B")) === false);
  const stillThere = await listPlaceReviews("cafe_1");
  check("...and it's still there after the failed attempt", stillThere.length === 1 && stillThere[0].id === id);
  check("the owning device can delete it", (await deletePlaceReviewByDevice(id, "dev-A")) === true);
  check("it's gone", (await listPlaceReviews("cafe_1")).length === 0);
  check("deleting an id that no longer exists is a plain false, not a throw", (await deletePlaceReviewByDevice(id, "dev-A")) === false);
}
check("no device id at all is refused outright (never matches by coincidence)", (await deletePlaceReviewByDevice(999999, null)) === false);

// ---- business-landmark claims: verified-at-submission is a real, distinct path from the
// old admin-clicks-a-button one, and only a business claim gets hours/phone shown at all ----
await createUserLandmark({
  name: "阿明早餐店", description: "在地早餐", category: "foodDrink", lat: 24.83, lon: 121.0,
  isBusinessClaim: true, businessVerified: true, businessHours: "06:00-11:00", phone: "0912345678",
  device: "dev-shop", email: "shop@b.com", ip: "1.1.1.1",
});
await createUserLandmark({
  name: "隨手記的路邊小吃", description: "", category: "foodDrink", lat: 24.831, lon: 121.001,
  isBusinessClaim: false, businessVerified: false,
  device: "dev-passerby", ip: "1.1.1.1",
});
{
  const all = await listAllUserLandmarks();
  const shop = all.find((l) => l.name === "阿明早餐店");
  check("a business claim created already-verified stores the email and shows it to the admin", shop?.businessVerified === true && shop?.email === "shop@b.com");
  const passerby = all.find((l) => l.name === "隨手記的路邊小吃");
  check("a plain (non-business) landmark has no email at all — never asked for one", passerby?.isBusinessClaim === false && passerby?.email == null);

  // Neither is approved yet — verification alone never bypasses the moderation queue.
  check("neither shows up in the public 'approved near' list before an admin approves it", (await listApprovedLandmarksNear(24.83, 121.0, 500)).length === 0);
}

// ---- cross-device: the same verified email finds/deletes content a *different* device posted ----
await createPlaceReview({ placeKey: "cafe_2", placeName: "另一家咖啡", stars: 4, comment: "不錯", device: "phone-old", email: "person@b.com", ip: "1.1.1.1" });
{
  check("device-only lookup finds nothing for a device that never posted", (await listMyPlaceReviews("phone-new")).length === 0);
  const byEmail = await listMyPlaceReviews({ email: "person@b.com" });
  check("the same email finds it even from a 'different phone' (no device given)", byEmail.length === 1 && byEmail[0].placeKey === "cafe_2");
  check("a stranger's email finds nothing", (await listMyPlaceReviews({ email: "nobody@b.com" })).length === 0);
  const id = byEmail[0].id;
  check("the wrong device AND no email can't delete it", (await deletePlaceReviewByDevice(id, { device: "phone-new" })) === false);
  check("the verified email alone (no device) can delete it", (await deletePlaceReviewByDevice(id, { email: "person@b.com" })) === true);
  check("it's gone", (await listPlaceReviews("cafe_2")).length === 0);
}
check("neither device nor email at all is refused outright", (await deletePlaceReviewByDevice(123456, {})) === false);

// ---- landmarks: cross-device ownership, editing, and business status ----
await createUserLandmark({
  name: "小林牙醫", description: "", category: "dentist", lat: 24.85, lon: 121.02,
  isBusinessClaim: true, businessVerified: true, businessHours: "9-6", phone: "03-1234567",
  device: "shop-phone-1", email: "dentist@b.com", ip: "1.1.1.1",
});
{
  const mineByDevice = await listMyUserLandmarks("shop-phone-1");
  const id = mineByDevice[0].id;
  await approveUserLandmark(id);

  check("a different device can't edit it", (await updateMyUserLandmark(id, { device: "shop-phone-2" }, { businessHours: "0-0" })) === false);
  check("the verified email (no device — a new phone) CAN edit it", (await updateMyUserLandmark(id, { email: "dentist@b.com" }, { businessStatus: "temporarily_closed" })) === true);

  const mineByEmail = await listMyUserLandmarks({ email: "dentist@b.com" });
  check("the new phone finds the listing by email and sees the status change", mineByEmail.length === 1 && mineByEmail[0].businessStatus === "temporarily_closed");

  const near = (await listApprovedLandmarksNear(24.85, 121.02, 500))[0];
  check("a temporarily-closed place STAYS in the public listing (flagged, not hidden — Google-Maps style)", near?.id === id && near?.businessStatus === "temporarily_closed");

  check("an unrecognised businessStatus value is rejected, not silently stored", (await updateMyUserLandmark(id, { email: "dentist@b.com" }, { businessStatus: "on_fire" })) === false);
}

// ---- claiming an EXISTING (plain, unverified) landmark ----
await createUserLandmark({ name: "巷口五金行", description: "", category: "other", lat: 24.86, lon: 121.03, device: "passerby-phone", ip: "1.1.1.1" });
{
  const [unclaimed] = await listAllUserLandmarks().then((all) => all.filter((l) => l.name === "巷口五金行"));
  check("a plain landmark starts with no business claim at all", unclaimed.isBusinessClaim === false && unclaimed.businessVerified === false);

  check("claiming it (email already verified by the caller) succeeds", (await claimUserLandmark(unclaimed.id, { email: "owner@b.com", businessHours: "8-8", phone: "03-9999999" })) === true);
  const [claimed] = await listAllUserLandmarks().then((all) => all.filter((l) => l.id === unclaimed.id));
  check("it's now a verified business claim with the claimant's email and details", claimed.isBusinessClaim === true && claimed.businessVerified === true && claimed.email === "owner@b.com" && claimed.businessHours === "8-8");

  check("a SECOND claim attempt is refused — already verified, no silent takeover", (await claimUserLandmark(unclaimed.id, { email: "someone-else@b.com" })) === false);
  check("claiming a landmark that doesn't exist is a plain false", (await claimUserLandmark(999999, { email: "x@b.com" })) === false);
  await approveUserLandmark(unclaimed.id);   // search only ever covers approved landmarks
}

// ---- name search (the web business dashboard's "find my business" flow) ----
await createUserLandmark({ name: "另一家五金行（還沒審核）", description: "", category: "other", lat: 24.861, lon: 121.031, device: "x", ip: "1.1.1.1" });
{
  const hits = await searchApprovedLandmarks("五金");
  check("name search finds the approved landmark by a substring of its name", hits.some((l) => l.name === "巷口五金行"));
  check("name search never returns an unapproved landmark, even with a matching name", !hits.some((l) => l.name === "另一家五金行（還沒審核）"));
}

// ---- category taxonomy: fine-grained, and the old coarse strings never end up stored again ----
check("the taxonomy is the new fine-grained one, not the old 13-group one", LANDMARK_CATEGORIES.includes("restaurant") && !LANDMARK_CATEGORIES.includes("foodDrink"));
await createUserLandmark({ name: "測試舊分類", description: "", category: "foodDrink", lat: 24.87, lon: 121.04, device: "x", ip: "1.1.1.1" });
{
  const [row] = await listAllUserLandmarks().then((all) => all.filter((l) => l.name === "測試舊分類"));
  check("an old, no-longer-recognised category falls back to 'other' on a fresh insert (not silently accepted)", row.category === "other");
}

// ---- a single landmark, public — the yayalin.com/shop/:id page's data source ----
await createUserLandmark({
  name: "老王牛肉麵", description: "在地老店", category: "restaurant", lat: 24.88, lon: 121.05,
  isBusinessClaim: true, businessVerified: true, businessHours: "11-14, 17-20", phone: "03-5551234",
  device: "wang-phone", email: "wang@b.com", ip: "1.1.1.1",
});
await createUserLandmark({ name: "還沒審核的攤位", description: "", category: "other", lat: 24.881, lon: 121.051, device: "x", ip: "1.1.1.1" });
{
  const [shop] = await listAllUserLandmarks().then((all) => all.filter((l) => l.name === "老王牛肉麵"));
  check("not approved yet: the public single-landmark lookup returns nothing", (await getApprovedLandmark(shop.id)) === null);
  await approveUserLandmark(shop.id);
  const page = await getApprovedLandmark(shop.id);
  check("once approved: shows the verified business's hours and phone", page?.name === "老王牛肉麵" && page?.businessHours === "11-14, 17-20" && page?.phone === "03-5551234");
  check("a made-up id returns null, not a crash", (await getApprovedLandmark(999999)) === null);

  const [unapproved] = await listAllUserLandmarks().then((all) => all.filter((l) => l.name === "還沒審核的攤位"));
  check("an unapproved landmark's id is never resolvable this way either", (await getApprovedLandmark(unapproved.id)) === null);
}

process.exit(failed ? 1 : 0);
