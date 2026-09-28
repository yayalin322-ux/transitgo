// Google-Maps-style business info: categorized photo gallery, structured weekly hours (+ "open
// now"), fixed-vocabulary feature tags, external links, and self-reported price range. Pure
// functions, no DB.
import {
  sanitizePhotos, normalizePhotos, PHOTO_CATEGORIES, sanitizeHours, sanitizeFeatures, isOpenNow,
  sanitizeLinks, sanitizePriceRange, LANDMARK_FEATURES, WEEKDAYS, MAX_PHOTOS, MAX_PRICE_RANGE,
} from "../src/landmarks.mjs";

let failed = false;
function check(label, cond) { console.log(`${cond ? "PASS" : "FAIL"} - ${label}`); if (!cond) failed = true; }

// ---- sanitizePhotos ----
const dataPhoto = (n = 100) => "data:image/jpeg;base64," + "A".repeat(n);
check("null (no gallery submitted) is accepted as null, not an error", sanitizePhotos(null) === null);
check("a plain string is normalized to {url, category: 'other'}", JSON.stringify(sanitizePhotos([dataPhoto()])) === JSON.stringify([{ url: dataPhoto(), category: "other" }]));
check("an object with a real category is kept as-is", JSON.stringify(sanitizePhotos([{ url: dataPhoto(), category: "menu" }])) === JSON.stringify([{ url: dataPhoto(), category: "menu" }]));
check("an object with no/unknown category defaults to 'other'", sanitizePhotos([{ url: dataPhoto(), category: "not-a-real-category" }])?.[0].category === "other");
check("an already-uploaded https URL is accepted too", sanitizePhotos(["https://cdn.example.com/a.jpg"])?.length === 1);
check("an empty array is rejected, not stored as 'no photos'", sanitizePhotos([]) === null);
check(`more than ${MAX_PHOTOS} photos is rejected`, sanitizePhotos(Array.from({ length: MAX_PHOTOS + 1 }, () => dataPhoto())) === null);
check("a non-image data: URI is rejected", sanitizePhotos(["data:text/plain;base64,AAAA"]) === null);
check("an oversized photo is rejected", sanitizePhotos([dataPhoto(2_000_000)]) === null);
check("an http:// (not https) URL is rejected", sanitizePhotos(["http://cdn.example.com/a.jpg"]) === null);
check("one bad photo rejects the whole gallery, not a silently shorter one", sanitizePhotos([dataPhoto(), "not a photo"]) === null);
check("a non-array is rejected", sanitizePhotos("x") === null);
check("every real category is accepted as-is", PHOTO_CATEGORIES.every((c) => sanitizePhotos([{ url: dataPhoto(), category: c }])?.[0].category === c));

// ---- normalizePhotos: reading back whatever shape ended up stored ----
check("the current {url, category} shape reads back untouched", JSON.stringify(normalizePhotos([{ url: "https://x/a.jpg", category: "food" }])) === JSON.stringify([{ url: "https://x/a.jpg", category: "food" }]));
check("the older plain-string array (from before categories existed) upgrades to 'other'", JSON.stringify(normalizePhotos(["https://x/a.jpg"])) === JSON.stringify([{ url: "https://x/a.jpg", category: "other" }]));
check("nothing stored at all → an empty gallery, not an error", JSON.stringify(normalizePhotos(undefined)) === "[]" && JSON.stringify(normalizePhotos(null)) === "[]");

// ---- sanitizeLinks ----
check("null (no links submitted) is accepted as null", sanitizeLinks(null) === null);
check("a real set of links is accepted as-is", JSON.stringify(sanitizeLinks({ menu: "https://x/menu", website: "https://x" })) === JSON.stringify({ menu: "https://x/menu", website: "https://x" }));
check("every known kind is individually accepted", ["menu", "order", "website", "delivery"].every((k) => sanitizeLinks({ [k]: "https://x" })?.[k] === "https://x"));
check("an unknown link kind is rejected outright, not dropped", sanitizeLinks({ menu: "https://x/menu", instagram: "https://x" }) === null);
check("a non-https URL is rejected", sanitizeLinks({ menu: "http://x/menu" }) === null);
check("an empty object is rejected (nothing worth storing)", sanitizeLinks({}) === null);
check("not an object is rejected", sanitizeLinks("x") === null && sanitizeLinks([]) === null);

// ---- sanitizePriceRange ----
check("null (not set) is accepted as null", sanitizePriceRange(null) === null);
check(`every value 1..${MAX_PRICE_RANGE} is accepted`, [1, 2, 3, 4].every((n) => sanitizePriceRange(n) === n));
check("0 is rejected (the scale starts at 1)", sanitizePriceRange(0) === null);
check(`${MAX_PRICE_RANGE + 1} is rejected`, sanitizePriceRange(MAX_PRICE_RANGE + 1) === null);
check("a non-integer is rejected", sanitizePriceRange(2.5) === null && sanitizePriceRange("2") === null);

// ---- sanitizeHours ----
const fullWeek = (day) => Object.fromEntries(WEEKDAYS.map((d) => [d, day]));
check("null (no structured hours submitted) is accepted as null", sanitizeHours(null) === null);
check("a real full week is accepted", sanitizeHours(fullWeek({ open: "09:00", close: "18:00" }))?.mon?.open === "09:00");
check("a day can be explicitly closed (null)", sanitizeHours({ ...fullWeek({ open: "09:00", close: "18:00" }), sun: null })?.sun === null);
check("a missing day is rejected (never silently defaults the rest of the week)", sanitizeHours({ mon: { open: "09:00", close: "18:00" } }) === null);
check("an extra/unknown key is rejected", sanitizeHours({ ...fullWeek(null), someday: null }) === null);
check("a malformed time is rejected", sanitizeHours(fullWeek({ open: "9:00", close: "18:00" })) === null);
check("open === close is rejected (that's not a real open window)", sanitizeHours(fullWeek({ open: "09:00", close: "09:00" })) === null);
check("overnight hours (close < open) are accepted — a real case, not a mistake", sanitizeHours(fullWeek({ open: "18:00", close: "02:00" }))?.mon?.close === "02:00");
check("not an object is rejected", sanitizeHours("x") === null && sanitizeHours([]) === null);

// ---- sanitizeFeatures ----
check("null (no tags submitted) is accepted as null", sanitizeFeatures(null) === null);
check("real tags are accepted as-is", JSON.stringify(sanitizeFeatures(["parking", "wifi"])) === JSON.stringify(["parking", "wifi"]));
check("an unknown tag is rejected outright, not dropped", sanitizeFeatures(["parking", "not-a-real-tag"]) === null);
check("a duplicate tag is rejected", sanitizeFeatures(["wifi", "wifi"]) === null);
check("an empty array is rejected", sanitizeFeatures([]) === null);
check("every tag in the vocabulary is individually valid", LANDMARK_FEATURES.every((f) => sanitizeFeatures([f])?.[0] === f));

// ---- isOpenNow ----
const taipei = (y, m, d, h, min) => Date.UTC(y, m - 1, d, h - 8, min);   // Asia/Taipei is UTC+8
check("no structured hours → null (caller falls back to free-text business_hours)", isOpenNow(null) === null);
{
  const hours = fullWeek({ open: "09:00", close: "18:00" });
  const midday = taipei(2026, 9, 28, 12, 0);   // a Monday, well inside 09:00-18:00
  const r = isOpenNow(hours, midday);
  check("inside today's hours → open, with today's closing time", r.open === true && r.changesAt === "18:00");
  const beforeOpen = taipei(2026, 9, 28, 7, 0);
  const r2 = isOpenNow(hours, beforeOpen);
  check("before today's opening → closed, with today's opening time", r2.open === false && r2.changesAt === "09:00" && r2.changesLabel.includes("今天"));
  const afterClose = taipei(2026, 9, 28, 19, 0);
  const r3 = isOpenNow(hours, afterClose);
  check("after today's closing → closed, with tomorrow's opening time", r3.open === false && r3.changesLabel.includes("週二"));
}
{
  // A bar open 18:00 Mon – 02:00 Tue.
  const hours = { ...fullWeek(null), mon: { open: "18:00", close: "02:00" } };
  const lateMonday = taipei(2026, 9, 28, 23, 0);   // Monday 23:00 — still open (crosses midnight)
  const r = isOpenNow(hours, lateMonday);
  check("late at night, before the overnight close → still open", r.open === true && r.changesAt === "02:00");
  const earlyTuesday = taipei(2026, 9, 29, 1, 0);   // Tuesday 01:00 — still the Monday-night window
  const r2 = isOpenNow(hours, earlyTuesday);
  check("just after midnight, still inside the overnight window from the day before → open", r2.open === true && r2.changesAt === "02:00");
  const afterOvernightClose = taipei(2026, 9, 29, 3, 0);   // Tuesday 03:00 — window has closed
  const r3 = isOpenNow(hours, afterOvernightClose);
  check("after the overnight window finally closes → closed", r3.open === false);
}
{
  const alwaysClosed = fullWeek(null);
  const r = isOpenNow(alwaysClosed, taipei(2026, 9, 28, 12, 0));
  check("a week with no open hours at all → closed, with an honest message instead of a bogus time", r.open === false && r.changesAt === null);
}

process.exit(failed ? 1 : 0);
