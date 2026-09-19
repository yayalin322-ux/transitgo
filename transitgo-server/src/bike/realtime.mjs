import { createRealtimeCache, withTimeout } from "../realtime/cache.mjs";
import { RealtimeReason } from "../realtime/errors.mjs";
import { BIKE_CONFIG, bikeFeedOf } from "./config.mjs";

/**
 * BikeStationRealtime — what routing and the app both read, one shape:
 *   { stationId, availableBikes, availableDocks, isRentable, isReturnable, updatedAt, ... }
 *
 * Source: the poller's shared snapshot (bike_cache, refreshed every BIKE_POLL_MINUTES from the
 * government feeds / TDX). There is exactly one place availability is read from, so the "nearby"
 * list and route planning can never disagree. Nothing here is written into the routing graph.
 *
 * isRentable   = station in service AND at least one bike to take
 * isReturnable = station in service AND at least one free dock
 * A station the snapshot doesn't contain, or a snapshot that could not be read / is stale, is
 * UNKNOWN — never "available" and never "empty".
 */

/** "2026-09-19 17:15:52" (Taipei local, gov feeds) | ISO with offset (TDX) | sqlite "YYYY-MM-DD HH:MM:SS" (UTC) | Date. */
export function parseSnapshotTime(v, { assume = "+08:00" } = {}) {
  if (v instanceof Date) return v.getTime();
  if (typeof v !== "string" || !v) return NaN;
  if (/[zZ]$|[+-]\d{2}:?\d{2}$/.test(v)) return Date.parse(v);
  return Date.parse(v.replace(" ", "T") + assume);
}

/** One cached station row -> BikeStationRealtime. */
export function mapBikeStation(city, s, { fetchedAtMs }) {
  const inService = s.status === 1;
  const bikes = Number.isFinite(s.rent) ? s.rent : null;
  const docks = Number.isFinite(s.ret) ? s.ret : null;
  const srcMs = parseSnapshotTime(s.src);
  return {
    stationId: `${bikeFeedOf(city)}:${s.uid}`,
    availableBikes: bikes,
    availableDocks: docks,
    electricBikes: Number.isFinite(s.electric) ? s.electric : null,
    isRentable: inService && bikes != null && bikes > 0,
    isReturnable: inService && docks != null && docks > 0,
    inService,
    updatedAt: new Date(Number.isFinite(srcMs) ? srcMs : fetchedAtMs).toISOString(),
  };
}

export function createBikeRealtime({ loadCaches, cache = createRealtimeCache(), now = () => Date.now(), timeoutMs = 4000, ttlMs = BIKE_CONFIG.snapshotTtlMs, staleMs = BIKE_CONFIG.staleMs } = {}) {
  // The mapped snapshot is derived from the cached raw value once per refresh, not once per query:
  // ~12k stations would otherwise be re-mapped on every route request.
  let derived = null;   // { source, snap }

  /** One de-duplicated, cached read of the whole snapshot (every city). Always resolves. */
  async function snapshot() {
    const res = await cache.getOrLoad("bike:snapshot", () => withTimeout(loadCaches(), timeoutMs), { ttlMs });
    if (!res.ok) return { ok: false, reason: res.reason, stations: new Map(), cached: res.cached };
    if (derived && derived.source === res.value && now() - derived.builtAt < staleMs) return { ...derived.snap, cached: res.cached };
    const snap = deriveSnapshot(res);
    derived = { source: res.value, snap, builtAt: now() };
    return snap;
  }

  function deriveSnapshot(res) {
    const stations = new Map();
    let cities = 0;
    for (const c of res.value ?? []) {
      const fetchedAtMs = parseSnapshotTime(c.updatedAt, { assume: "Z" });   // DB timestamps are UTC
      if (Number.isFinite(fetchedAtMs) && now() - fetchedAtMs > staleMs) continue;   // poller stalled for this city: unknown, not "still true"
      cities++;
      for (const s of c.stations ?? []) {
        if (!s?.uid) continue;
        const m = mapBikeStation(c.city, s, { fetchedAtMs: Number.isFinite(fetchedAtMs) ? fetchedAtMs : now() });
        stations.set(m.stationId, m);
      }
    }
    if (stations.size === 0) return { ok: false, reason: RealtimeReason.NO_DATA, stations, cached: res.cached };
    return { ok: true, stations, cities, fetchedAt: res.fetchedAt, cached: res.cached };
  }

  /**
   * The search-time oracle: check(nodeId, "rent"|"return") -> "yes" | "no" | "unknown".
   * `unknownPolicy: "exclude"` turns unknown into "no" (never route through a station whose state
   * can't be confirmed); the default "allow" keeps it, flagged, so an outage never removes a route.
   */
  function oracleFor(snap, { unknownPolicy = "allow" } = {}) {
    return {
      available: snap.ok,
      reason: snap.ok ? null : snap.reason,
      check(nodeId, role) {
        const st = snap.stations.get(nodeId);
        if (!st) return unknownPolicy === "exclude" ? "no" : "unknown";
        return (role === "rent" ? st.isRentable : st.isReturnable) ? "yes" : "no";
      },
      status: (nodeId) => snap.stations.get(nodeId) ?? null,
    };
  }

  /** Availability for a list of station ids (the app's availability call). */
  async function availability(stationIds) {
    const snap = await snapshot();
    return {
      available: snap.ok, reason: snap.ok ? null : snap.reason, cached: snap.cached,
      stations: stationIds.map((id) => snap.stations.get(id) ?? null),
    };
  }

  return { snapshot, oracleFor, availability, cache };
}
