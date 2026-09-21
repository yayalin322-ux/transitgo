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

/** How long the link lives, in ms. */
export function ttlMs(hours) {
  const h = Number.isFinite(hours) ? Math.min(MAX_TTL_HOURS, Math.max(1, hours)) : DEFAULT_TTL_HOURS;
  return h * 3_600_000;
}

/** 128 bits from the OS RNG, URL-safe: not guessable, not enumerable. */
export function newToken() { return randomBytes(16).toString("base64url"); }
export const isToken = (t) => typeof t === "string" && /^[A-Za-z0-9_-]{22}$/.test(t);

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
