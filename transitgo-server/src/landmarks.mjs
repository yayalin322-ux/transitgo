// Google-Maps-style business info: a photo gallery, structured weekly hours (so "open now" can
// be computed instead of just showing whatever free-text the owner typed), and a fixed set of
// feature tags. Kept separate from db.mjs (pure, no DB connection) the same way shares.mjs is —
// easy to unit test, and reusable from both the SQL and Firestore backends without either one
// importing the other's setup.

/** A photo field must be a real data: URI (what the app's own JPEG-compress-then-encode step
 * produces) or a plain https URL (what an already-uploaded photo becomes), and small enough that
 * a handful of them together still fit in one request. */
function validPhoto(photo) {
  if (typeof photo !== "string") return false;
  if (photo.startsWith("data:image/")) return photo.length <= 1_200_000;   // ~900KB decoded
  return /^https:\/\//.test(photo) && photo.length <= 2000;
}

export const MAX_PHOTOS = 6;

/** Whitelist copy of a photo gallery — `null` (not an array, too many, or any one photo invalid)
 * means "reject the whole write", same as every other sanitizer here: never silently drop a bad
 * entry and save a shorter gallery than what was actually submitted. */
export function sanitizePhotos(input) {
  if (input == null) return null;
  if (!Array.isArray(input) || input.length === 0 || input.length > MAX_PHOTOS) return null;
  if (!input.every(validPhoto)) return null;
  return input;
}

export const WEEKDAYS = Object.freeze(["mon", "tue", "wed", "thu", "fri", "sat", "sun"]);
const TIME_RE = /^([01]\d|2[0-3]):([0-5]\d)$/;

/** One day's hours: `null` (closed all day) or `{ open, close }` in "HH:MM" 24h — `close` may be
 * earlier than `open` for a place that crosses midnight (e.g. a bar open 18:00–02:00): that's a
 * real, common case, not a mistake, so it's accepted rather than rejected. */
function validDay(v) {
  if (v === null) return true;
  if (!v || typeof v !== "object") return false;
  return TIME_RE.test(v.open) && TIME_RE.test(v.close) && v.open !== v.close;
}

/** Whitelist copy of structured weekly hours — an object with exactly the 7 WEEKDAYS keys.
 * `null` if the shape is wrong; missing/extra keys are rejected rather than silently patched,
 * since a partial week would make `isOpenNow` wrong for whichever day it left out. */
export function sanitizeHours(input) {
  if (input == null) return null;
  if (typeof input !== "object" || Array.isArray(input)) return null;
  const keys = Object.keys(input);
  if (keys.length !== WEEKDAYS.length || !WEEKDAYS.every((d) => keys.includes(d))) return null;
  const out = {};
  for (const d of WEEKDAYS) {
    if (!validDay(input[d])) return null;
    out[d] = input[d];
  }
  return out;
}

/** Fixed vocabulary, Google-Maps-style small feature chips — a fixed list (not free text) so the
 * shop page/App can render them as recognisable icons instead of arbitrary strings. */
export const LANDMARK_FEATURES = Object.freeze([
  "reservations", "parking", "petFriendly", "outdoorSeating", "wifi", "creditCard",
  "delivery", "takeout", "wheelchairAccessible", "kidsFriendly", "airConditioning",
  "groupFriendly",
]);

export const MAX_FEATURES = LANDMARK_FEATURES.length;

/** Whitelist copy of a feature-tag selection — `null` for anything not a plain array of known,
 * unique tags. Unknown tags are rejected outright rather than dropped, so a client sending a stale
 * tag id finds out immediately instead of silently losing it. */
export function sanitizeFeatures(input) {
  if (input == null) return null;
  if (!Array.isArray(input) || input.length === 0 || input.length > MAX_FEATURES) return null;
  const unique = [...new Set(input)];
  if (unique.length !== input.length) return null;
  if (!unique.every((f) => LANDMARK_FEATURES.includes(f))) return null;
  return unique;
}

const DAY_LABEL = { mon: "週一", tue: "週二", wed: "週三", thu: "週四", fri: "週五", sat: "週六", sun: "週日" };

/**
 * "Is this place open right now?", from structured hours alone (the caller applies
 * business_status — temporarily/permanently closed — on top of this; that always wins over the
 * schedule). Handles a day's hours crossing midnight into the next day. Returns `null` when there
 * are no structured hours to compute from (the caller falls back to the free-text business_hours,
 * same as before this feature existed).
 */
export function isOpenNow(hours, nowMs = Date.now(), timeZone = "Asia/Taipei") {
  if (!hours) return null;
  const parts = new Intl.DateTimeFormat("en-US", {
    timeZone, weekday: "short", hour: "2-digit", minute: "2-digit", hourCycle: "h23",
  }).formatToParts(new Date(nowMs));
  const get = (t) => parts.find((p) => p.type === t)?.value;
  const weekdayMap = { Mon: "mon", Tue: "tue", Wed: "wed", Thu: "thu", Fri: "fri", Sat: "sat", Sun: "sun" };
  const today = weekdayMap[get("weekday")];
  const nowMin = Number(get("hour")) * 60 + Number(get("minute"));
  const toMin = (hhmm) => { const [h, m] = hhmm.split(":").map(Number); return h * 60 + m; };
  const todayIdx = WEEKDAYS.indexOf(today);
  const yesterday = WEEKDAYS[(todayIdx + 6) % 7];

  const spansTonight = hours[today] && toMin(hours[today].close) <= toMin(hours[today].open);
  if (spansTonight && nowMin >= toMin(hours[today].open)) {
    return { open: true, changesAt: hours[today].close, changesLabel: `${DAY_LABEL[today]} ${hours[today].close} 打烊` };
  }
  const yEntry = hours[yesterday];
  const ySpansTonight = yEntry && toMin(yEntry.close) <= toMin(yEntry.open);
  if (ySpansTonight && nowMin < toMin(yEntry.close)) {
    return { open: true, changesAt: yEntry.close, changesLabel: `今天 ${yEntry.close} 打烊` };
  }
  const t = hours[today];
  if (t && nowMin >= toMin(t.open) && nowMin < toMin(t.close)) {
    return { open: true, changesAt: t.close, changesLabel: `今天 ${t.close} 打烊` };
  }
  // Closed right now — find the next day (today included, later than now) that opens.
  for (let i = 0; i < 7; i++) {
    const d = WEEKDAYS[(todayIdx + i) % 7];
    const entry = hours[d];
    if (!entry) continue;
    if (i === 0 && toMin(entry.open) <= nowMin) continue;   // today's opening already passed
    const label = i === 0 ? `今天 ${entry.open} 開始營業` : `${DAY_LABEL[d]} ${entry.open} 開始營業`;
    return { open: false, changesAt: entry.open, changesLabel: label };
  }
  return { open: false, changesAt: null, changesLabel: "本週沒有營業時間" };
}
