import { randomBytes } from "node:crypto";

/**
 * Shareable trip links. A share holds ONLY what the realtime overlay needs to look a vehicle up —
 * mode, route, boarding/alighting stop ids and names, the boarded trip id and the planned times.
 * No coordinates, no device id, no user id, no IP: whoever opens the link learns which public
 * services the sharer planned to ride, never where the sharer is. Links expire.
 */
export const SHARE_MODES = Object.freeze(["BUS", "MRT", "TRA", "HSR", "WALK", "BIKE"]);
export const MAX_SEGMENTS = 8;
export const DEFAULT_TTL_HOURS = 6;
export const MAX_TTL_HOURS = 24;

const str = (v, max) => (typeof v === "string" && v.length > 0 ? v.slice(0, max) : null);
const isoTime = (v) => (typeof v === "string" && Number.isFinite(Date.parse(v)) ? new Date(Date.parse(v)).toISOString() : null);

/** Whitelist copy of the client's segments. Returns null when the trip has nothing worth sharing. */
export function sanitizeSegments(input) {
  if (!Array.isArray(input) || input.length === 0 || input.length > MAX_SEGMENTS) return null;
  const out = [];
  for (const s of input) {
    if (!s || typeof s !== "object" || !SHARE_MODES.includes(s.mode)) return null;
    const dep = isoTime(s.departureTime), arr = isoTime(s.arrivalTime);
    if (!dep || !arr) return null;
    out.push({
      mode: s.mode,
      routeId: str(s.routeId, 64), routeShortName: str(s.routeShortName, 32), scopePath: str(s.scopePath, 48),
      line: str(s.line, 32), towards: str(s.towards, 32),
      from: str(s.from, 64), to: str(s.to, 64), tripId: str(s.tripId, 96),
      fromName: str(s.fromName, 48), toName: str(s.toName, 48),
      departureTime: dep, arrivalTime: arr,
    });
  }
  // A walk-only trip has no vehicle to follow.
  return out.some((s) => s.mode !== "WALK" && s.mode !== "BIKE") ? out : null;
}

/** Control characters become spaces; empty → null. */
export function sanitizeTitle(v) {
  if (typeof v !== "string") return null;
  let t = "";
  for (const ch of v) t += ch.charCodeAt(0) < 32 ? " " : ch;
  return str(t.trim(), 60);
}

/** Modes the App's own in-car/on-foot navigation screen can share — deliberately just these
 * three; there is no vehicle to poll for a personal nav trip, only the sharer's own device. */
export const NAV_MODES = Object.freeze(["automobile", "scooter", "walking"]);

/** Whitelist copy of a 'nav' share's setup — what the destination IS, never where the sharer
 * currently is (that only ever comes from sanitizeNavProgress, as a distance/time, not a
 * coordinate). `null` when the input doesn't look like a real nav request. */
export function sanitizeNav(input) {
  if (!input || typeof input !== "object") return null;
  if (!NAV_MODES.includes(input.mode)) return null;
  const destinationName = str(input.destinationName, 60);
  if (!destinationName) return null;
  return { mode: input.mode, destinationName };
}

/** Whitelist copy of one progress update the sharer's own app pushes while navigating — never a
 * coordinate, only what's needed to show "how much further / how long" (the same idea as a
 * train's "3 stops left", not a live position on a map). */
export function sanitizeNavProgress(input) {
  if (!input || typeof input !== "object") return null;
  const remainingMeters = Number(input.remainingMeters);
  const etaSeconds = Number(input.etaSeconds);
  if (!Number.isFinite(remainingMeters) || remainingMeters < 0) return null;
  if (!Number.isFinite(etaSeconds) || etaSeconds < 0) return null;
  return {
    remainingMeters: Math.round(Math.min(2_000_000, remainingMeters)),
    etaSeconds: Math.round(Math.min(172_800, etaSeconds)),
    instruction: str(input.instruction, 120),
    arrived: input.arrived === true,
  };
}

/** A nav share is "live" only while the sharer's app is actually still pushing updates —
 * further apart than this and the link honestly says so instead of showing a frozen number. */
export const NAV_PROGRESS_STALE_MS = 45_000;

/**
 * "安全分享" (opt-in safety live-location). Off by default on every share — a sharer must
 * explicitly turn it on when creating the link (see shareLiveLocationEnabled on the create
 * request). Only then does the app push real coordinates here; a normal share never calls this
 * at all. Range-checked like any untrusted client input.
 */
export function sanitizeLiveLocation(input) {
  if (!input || typeof input !== "object") return null;
  const lat = Number(input.lat);
  const lon = Number(input.lon);
  if (!Number.isFinite(lat) || lat < -90 || lat > 90) return null;
  if (!Number.isFinite(lon) || lon < -180 || lon > 180) return null;
  return { lat, lon };
}

/** A shared live location older than this is too stale to show as "current" — the viewer sees
 * that sharing has paused/stopped instead of a frozen, possibly-misleading dot. */
export const LIVE_LOCATION_STALE_MS = 45_000;

/** How long the link lives, in ms. */
export function ttlMs(hours) {
  const h = Number.isFinite(hours) ? Math.min(MAX_TTL_HOURS, Math.max(1, hours)) : DEFAULT_TTL_HOURS;
  return h * 3_600_000;
}

/** 128 bits from the OS RNG, URL-safe: not guessable, not enumerable. */
export function newToken() { return randomBytes(16).toString("base64url"); }
export const isToken = (t) => typeof t === "string" && /^[A-Za-z0-9_-]{22}$/.test(t);

/**
 * share.html's Content-Security-Policy. Locked down (`default-src 'none'`), but with explicit
 * allowances for what the page actually loads — most importantly `img-src`, which must cover
 * wherever the page's own logo `<img>` is hosted (yayalin.com). Missed once already: the logo
 * was added to the page without updating this policy, so it silently never rendered (no img-src
 * meant `default-src 'none'` blocked every image outright) — a regression test pins this.
 * Same lesson applied here in advance for the Google Fonts stylesheet/font files the page loads
 * (style-src for the CSS, font-src for the actual font binary — missing either one silently
 * fails closed under default-src 'none', same as the logo did).
 */
export const SHARE_PAGE_CSP = "default-src 'none'; img-src 'self' https://yayalin.com; script-src 'unsafe-inline'; style-src 'unsafe-inline' https://fonts.googleapis.com; font-src https://fonts.gstatic.com; connect-src 'self'";

/** True when there is no such share or its time has run out — a viewer never sees the stored trip then. */
export function isExpired(row, nowMs = Date.now()) { return !row || Number(row.expires_at_ms) <= nowMs; }

export const isVehicle = (seg) => seg && seg.mode !== "WALK" && seg.mode !== "BIKE";

/** "TRA_152_2026-09-21" → { trainNo: "152", dateStr: "2026-09-21" } (the id the planner gives a boarded train). */
export function parseTrainTrip(tripId) {
  const m = /^TRA_([^_]+)_(\d{4}-\d{2}-\d{2})$/.exec(tripId ?? "");
  return m ? { trainNo: m[1], dateStr: m[2] } : null;
}

/**
 * May a viewer rate this leg yet? Only vehicle legs, and only once it has (about) arrived — a link opened before the
 * trip must not collect ratings for a ride that has not happened. Scheduled arrival minus a grace period, because a
 * train can be early and the page itself says "arrived" from the live position.
 */
export const RATING_GRACE_MS = 10 * 60_000;
export function canRate(segments, legIndex, nowMs) {
  const seg = Array.isArray(segments) ? segments[legIndex] : null;
  if (!isVehicle(seg)) return false;
  const arr = Date.parse(seg.arrivalTime);
  return Number.isFinite(arr) && nowMs >= arr - RATING_GRACE_MS;
}

/** One rating per viewer (IP) per leg per link, remembered for a day. In memory: a restart only forgets who rated. */
export function createRatingLedger({ ttlMs: ttl = 24 * 3_600_000 } = {}) {
  const seen = new Map();
  return {
    /** true = first time (recorded); false = already rated. */
    claim(token, legIndex, viewer, nowMs = Date.now()) {
      for (const [k, at] of seen) if (nowMs - at > ttl) seen.delete(k);
      const key = `${token}|${legIndex}|${viewer}`;
      if (seen.has(key)) return false;
      seen.set(key, nowMs);
      return true;
    },
  };
}
