// Email verification (borrowed from yayalin.com) for reviews and business-landmark claims,
// plus the self-service delete that lets a reviewer remove their own review.
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

process.env.DB_PATH = join(mkdtempSync(join(tmpdir(), "reviews-landmarks-")), "t.db");
delete process.env.DATABASE_URL;
const {
  createPlaceReview, listPlaceReviews, listMyPlaceReviews, deletePlaceReviewByDevice,
  createUserLandmark, listApprovedLandmarksNear, listAllUserLandmarks,
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

process.exit(failed ? 1 : 0);
