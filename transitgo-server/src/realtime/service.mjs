import { createRealtimeCache, withTimeout } from "./cache.mjs";
import { RealtimeReason } from "./errors.mjs";
import { RealtimeState } from "./model.mjs";
import { busRoutePath, busStopsPath, busArrivalsAtStop, busAlertsFor, mapBusRow } from "./sources/bus.mjs";
import { metroLiveBoardPath, metroAlertPath, mapMetroLiveBoard, mapMetroAlerts } from "./sources/metro.mjs";
import { traStationBoardPath, traAlertPath, mapTraTrain, mapTraAlerts, traTrainLiveBoardPath, traTimetablePath } from "./sources/tra.mjs";
import { parseTimetable, parseLiveRow, summarizeTrain } from "./trainProgress.mjs";
import { thsrAlertPath, mapThsrAlerts } from "./sources/hsr.mjs";

/**
 * Cache lifetimes, chosen from what each source really reports as its refresh rate
 * (live responses, 2026-09-19): TRA v3 boards say UpdateInterval 30 s; metro alerts 60 s,
 * TRA alerts 120 s; bus ETA rows show SrcUpdateTime -> UpdateTime within seconds and change
 * every 10-30 s; TDX's free key allows only ~5 requests/minute, so nothing here is cached
 * for less than 15 s.
 */
export const REALTIME_TTL_MS = Object.freeze({
  busEta: 15_000,
  busAlert: 120_000,
  metroLiveBoard: 20_000,
  metroAlert: 60_000,
  traBoard: 30_000,
  traLiveBoard: 20_000,      // one read covers every running train
  traTimetable: 6 * 3_600_000, // static for the day
  traAlert: 120_000,
  thsrAlert: 120_000,
});

/** What each mode really has, for GET /v1/realtime/capabilities — a statement of fact about the
 * sources this service reads, not a promise about any one response. */
export const REALTIME_CAPABILITIES = Object.freeze({
  BUS: {
    available: true,
    arrival: true, delay: false, alerts: true, vehicle: "plate number when TDX has one",
    endpoints: ["v2/Bus/EstimatedTimeOfArrival/{scope}/{route}", "v2/Bus/EstimatedTimeOfArrival/{scope}?$filter=StopUID…", "v2/Bus/Alert/{scope}"],
    ttlMs: { eta: REALTIME_TTL_MS.busEta, alerts: REALTIME_TTL_MS.busAlert },
    limits: ["TDX publishes no bus timetable in the ETA feed, so a bus has no scheduled time and no delay figure", "新竹 reports StopCountDown (stops away) instead of EstimateTime", "Alert Cause/Effect codes are undocumented and are not interpreted; only TDX's title/description are shown"],
  },
  MRT: {
    available: true,
    arrival: "桃園機場捷運: next trains (minutes). 台北捷運: only trains arriving right now", delay: false, alerts: true,
    endpoints: ["v2/Rail/Metro/LiveBoard/{operator}", "v2/Rail/Metro/Alert/{operator}"],
    ttlMs: { liveBoard: REALTIME_TTL_MS.metroLiveBoard, alerts: REALTIME_TTL_MS.metroAlert },
    limits: ["台北捷運 LiveBoard has no forward-looking ETA (only EstimateTime 0 rows), so an empty result is NOT 'no train coming'", "no per-train delay figure exists", "EstimateTime unit (minutes) is inferred from the 15-minute spacing matching TYMC's published headway"],
  },
  TRA: {
    available: true, arrival: true, delay: true, alerts: true,
    endpoints: ["v3/Rail/TRA/StationLiveBoard/Station/{stationId}", "v3/Rail/TRA/Alert"],
    ttlMs: { board: REALTIME_TTL_MS.traBoard, alerts: REALTIME_TTL_MS.traAlert },
    limits: ["needs the specific train number of the planned leg", "TDX documents RunningStatus 2 = cancelled but it has not appeared in live data yet"],
  },
  HSR: {
    available: false, arrival: false, delay: false, alerts: true,
    endpoints: ["v2/Rail/THSR/AlertInfo"],
    ttlMs: { alerts: REALTIME_TTL_MS.thsrAlert },
    limits: ["TDX has no per-train delay/arrival feed for 高鐵 (LiveBoard endpoint 404s); only network alerts and seat availability exist"],
  },
});

const RANK = { cancelled: 9, delayed: 8, notOperating: 7, lastServicePassed: 6, notDeparted: 5, notStopping: 5, unknown: 2, arriving: 1, approaching: 1, normal: 0 };

export function createRealtimeService({ tdxGet, db = null, cache = createRealtimeCache(), now = () => Date.now(), timeoutMs = 4000, ttl = REALTIME_TTL_MS } = {}) {
  /** One cached, de-duplicated, time-limited TDX read. Always resolves: { ok, value } or { ok:false, reason }. */
  const read = (key, path, ttlMs, opts = {}) => cache.getOrLoad(key, () => withTimeout(tdxGet(path), timeoutMs), { ttlMs, ...opts });

  const stopIdOf = (nodeId) => String(nodeId ?? "").slice(String(nodeId ?? "").indexOf(":") + 1);
  const feedOf = (nodeId) => String(nodeId ?? "").split(":")[0];
  const routeStopsCache = new Map();

  /** Ordered stop ids of one route from the static graph tables (never TDX). */
  async function routeStops(feedId, routeId) {
    if (!db || !routeId) return null;
    const key = `${feedId}|${routeId}`;
    if (routeStopsCache.has(key)) return routeStopsCache.get(key);
    const rows = await db.prepare(`SELECT direction, stop_sequence, stop_id FROM gtfs_route_stops WHERE feed_id = ? AND route_id = ? ORDER BY direction, stop_sequence`).all(feedId, routeId);
    const byDirection = new Map();
    for (const r of rows) {
      if (!byDirection.has(r.direction)) byDirection.set(r.direction, []);
      byDirection.get(r.direction).push(r.stop_id);
    }
    routeStopsCache.set(key, byDirection);
    return byDirection;
  }

  /** Which TDX bus direction(s) run from `fromStop` to `toStop` on this route, per the static stop order. */
  async function busDirection(feedId, routeId, fromStop, toStop) {
    const byDirection = await routeStops(feedId, routeId);
    if (!byDirection) return null;
    const matches = [...byDirection].filter(([, stops]) => {
      const a = stops.indexOf(fromStop), b = stops.indexOf(toStop);
      return a >= 0 && b > a;
    }).map(([d]) => d);
    return matches.length === 1 ? matches[0] : null;   // ambiguous or unknown -> don't filter
  }

  // ---- per-mode leg lookups: each resolves { available, reason, arrivals, alerts, alertsAvailable } ----

  async function busLeg(seg) {
    const scope = seg.scopePath, routeName = seg.routeShortName;
    if (!scope || !routeName || !seg.from) return { available: false, reason: RealtimeReason.NO_DATA, arrivals: [], alerts: [], alertsAvailable: false };
    const stopUID = stopIdOf(seg.from);
    const direction = await busDirection(feedOf(seg.from), seg.routeId, stopUID, stopIdOf(seg.to));
    const [eta, alertRes] = await Promise.all([
      read(`bus:route:${scope}:${routeName}`, busRoutePath(scope, routeName), ttl.busEta),
      read(`bus:alert:${scope}`, `v2/Bus/Alert/${scope}`, ttl.busAlert),
    ]);
    const alertsAvailable = alertRes.ok;
    const alerts = alertRes.ok ? busAlertsFor(alertRes.value, { routeName, stopIds: [stopUID, stopIdOf(seg.to)], nowMs: now() }) : [];
    if (!eta.ok) return { available: false, reason: eta.reason, arrivals: [], alerts, alertsAvailable, cached: eta.cached };
    const arrivals = busArrivalsAtStop(eta.value, stopUID, { direction, fetchedAtMs: eta.fetchedAt });
    return { available: arrivals.length > 0, reason: arrivals.length > 0 ? null : RealtimeReason.NO_DATA, arrivals, alerts, alertsAvailable, cached: eta.cached, fetchedAt: eta.fetchedAt };
  }

  async function metroLeg(seg) {
    const feed = feedOf(seg.from);
    const operator = feed.startsWith("MRT_") ? feed.slice(4) : null;
    if (!operator) return { available: false, reason: RealtimeReason.NO_DATA, arrivals: [], alerts: [], alertsAvailable: false };
    const stationId = stopIdOf(seg.from);
    const byDirection = await routeStops(feed, seg.routeId);
    const stops = byDirection ? [...byDirection.values()][0] : null;
    const ahead = stops ? stops.slice(stops.indexOf(stationId) + 1) : [];
    const [board, alertRes] = await Promise.all([
      read(`metro:board:${operator}`, metroLiveBoardPath(operator), ttl.metroLiveBoard),
      read(`metro:alert:${operator}`, metroAlertPath(operator), ttl.metroAlert),
    ]);
    const alerts = alertRes.ok ? mapMetroAlerts(alertRes.value) : [];
    if (!board.ok) return { available: false, reason: board.reason, arrivals: [], alerts, alertsAvailable: alertRes.ok, cached: board.cached };
    const arrivals = mapMetroLiveBoard(board.value, { stationId, aheadStopIds: ahead, fetchedAtMs: board.fetchedAt });
    return { available: arrivals.length > 0, reason: arrivals.length > 0 ? null : RealtimeReason.NO_DATA, arrivals, alerts, alertsAvailable: alertRes.ok, cached: board.cached, fetchedAt: board.fetchedAt };
  }

  async function traLeg(seg) {
    // tripId is "TRA_{trainNo}_{YYYY-MM-DD}" (see normalizeTRATimetable) — the specific train this leg boards.
    const m = /^TRA_([^_]+)_(\d{4}-\d{2}-\d{2})$/.exec(seg.tripId ?? "");
    const alertRes = await read("tra:alert", traAlertPath(), ttl.traAlert);
    const alerts = alertRes.ok ? mapTraAlerts(alertRes.value) : [];
    if (!m) return { available: false, reason: RealtimeReason.NO_DATA, arrivals: [], alerts, alertsAvailable: alertRes.ok };
    const stationId = stopIdOf(seg.from);
    const board = await read(`tra:board:${stationId}`, traStationBoardPath(stationId), ttl.traBoard);
    if (!board.ok) return { available: false, reason: board.reason, arrivals: [], alerts, alertsAvailable: alertRes.ok, cached: board.cached };
    const status = mapTraTrain(board.value, { stationId, trainNo: m[1], dateStr: m[2], fetchedAtMs: board.fetchedAt });
    return { available: !!status, reason: status ? null : RealtimeReason.NO_DATA, arrivals: status ? [status] : [], alerts, alertsAvailable: alertRes.ok, cached: board.cached, fetchedAt: board.fetchedAt };
  }

  async function hsrLeg() {
    const alertRes = await read("thsr:alert", thsrAlertPath(), ttl.thsrAlert);
    return { available: false, reason: RealtimeReason.NOT_SUPPORTED, arrivals: [], alerts: alertRes.ok ? mapThsrAlerts(alertRes.value) : [], alertsAvailable: alertRes.ok };
  }

  const LEGS = { BUS: busLeg, MRT: metroLeg, TRA: traLeg, HSR: hsrLeg };

  /**
   * The realtime overlay for a planned route. Input is the route's own segments as the
   * routing engine returned them (never re-derived); output only ever ADDS information —
   * `scheduledTime` stays exactly what the static plan said, `estimatedTime` and `etaSource`
   * sit beside it. A source that fails yields an `available:false` leg with its reason; the
   * overlay itself never throws and says nothing about whether the route exists.
   */
  async function routeOverlay({ segments = [], departureTime = null, arrivalTime = null } = {}) {
    const legs = await Promise.all(segments.map(async (seg, index) => {
      const lookup = LEGS[seg.mode];
      if (!lookup) return null;   // WALK and any mode with no realtime source: not part of the overlay
      let res;
      try { res = await lookup(seg); } catch { res = { available: false, reason: RealtimeReason.UNAVAILABLE, arrivals: [], alerts: [], alertsAvailable: false }; }
      const status = res.arrivals[0] ?? null;
      const scheduledTime = seg.departureTime ?? null;
      const estimatedTime = status?.estimatedTime ?? null;
      return {
        index, mode: seg.mode, routeName: seg.routeShortName ?? seg.line ?? null,
        available: res.available, reason: res.reason,
        status, arrivals: res.arrivals.slice(0, 3),
        alerts: res.alerts, alertsAvailable: res.alertsAvailable,
        scheduledTime, estimatedTime,
        // Where the departure time shown to the rider comes from — kept beside (never
        // instead of) the static time.
        etaSource: estimatedTime ? "realtime" : scheduledTime ? "scheduled" : "unknown",
      };
    }));
    const active = legs.filter(Boolean);

    // Route-level ETA: shift by the FIRST leg that has a real estimate. A vehicle the rider
    // cannot reach before it leaves is not "earlier" — boarding is never earlier than
    // arrival at the stop (the previous segment's arrival, or the route's departure).
    let eta = { etaSource: "scheduled", estimatedArrivalTime: null, shiftSeconds: null, basedOnLeg: null };
    const first = active.find((l) => l.estimatedTime && l.scheduledTime);
    if (first && arrivalTime) {
      const prev = segments[first.index - 1];
      const reachMs = Date.parse(prev?.arrivalTime ?? departureTime ?? "") || 0;
      const boardMs = Math.max(Date.parse(first.estimatedTime), reachMs);
      const shift = Math.round((boardMs - Date.parse(first.scheduledTime)) / 1000);
      if (Number.isFinite(shift) && Math.abs(shift) <= 3 * 3600) {
        eta = { etaSource: "realtime", estimatedArrivalTime: new Date(Date.parse(arrivalTime) + shift * 1000).toISOString(), shiftSeconds: shift, basedOnLeg: first.index };
      }
    } else if (!arrivalTime && !first) {
      eta.etaSource = "unknown";
    }

    const states = active.flatMap((l) => (l.status ? [l.status.state] : []));
    const worst = states.sort((a, b) => (RANK[b] ?? 0) - (RANK[a] ?? 0))[0] ?? null;
    const delays = active.map((l) => l.status?.delaySeconds).filter((d) => Number.isFinite(d));
    return {
      generatedAt: new Date(now()).toISOString(),
      legs: active,
      eta,
      summary: {
        anyRealtime: active.some((l) => l.available),
        state: worst,
        delaySeconds: delays.length ? Math.max(...delays) : null,
        alerts: active.flatMap((l) => l.alerts).filter((a, i, all) => all.findIndex((b) => b.id === a.id && b.source === a.source) === i),
        unavailableReasons: [...new Set(active.filter((l) => !l.available).map((l) => l.reason))],
      },
    };
  }

  /** Next arrivals at a set of physical bus stops (the "附近" list): one upstream call per
   * (scope, stop set), shared with every screen asking the same question. */
  async function busStopArrivals({ scopePath, stopUIDs }) {
    const uids = [...new Set(stopUIDs)].sort();
    const res = await read(`bus:stops:${scopePath}:${uids.join(",")}`, busStopsPath(scopePath, uids), ttl.busEta);
    if (!res.ok) return { available: false, reason: res.reason, stops: {}, cached: res.cached };
    const stops = {};
    for (const uid of uids) {
      stops[uid] = res.value.filter((r) => r.StopUID === uid).map((r) => mapBusRow(r, { fetchedAtMs: res.fetchedAt }))
        .sort((a, b) => (a.etaSeconds ?? 1e9) - (b.etaSeconds ?? 1e9));
    }
    const any = Object.values(stops).some((l) => l.length > 0);
    return { available: any, reason: any ? null : RealtimeReason.NO_DATA, stops, cached: res.cached, fetchedAt: res.fetchedAt };
  }

  /**
   * Where one 台鐵 train is, for the share page: the day's timetable + the live train board. Two reads at most, both
   * cached (the board is one call for all trains), so any number of viewers costs the same. Never throws.
   * The live position exists only for today's trains; another day gets the general timetable (schedule only).
   */
  async function trainStatus({ trainNo, dateStr, fromId = null, toId = null }) {
    const nowMs = now();
    const today = new Date(nowMs + 8 * 3_600_000).toISOString().slice(0, 10);   // Taipei calendar day
    const isToday = dateStr === today;
    const [tt, board] = await Promise.all([
      read(`tra:timetable:${trainNo}:${isToday ? "today" : "general"}`, traTimetablePath(trainNo, isToday), ttl.traTimetable),
      isToday ? read("tra:trainLiveBoard", traTrainLiveBoardPath(), ttl.traLiveBoard, { staleOnErrorMs: 3 * 60_000 }) : Promise.resolve({ ok: false, reason: RealtimeReason.NOT_SUPPORTED }),
    ]);
    const timetable = tt.ok ? parseTimetable(tt.value, dateStr) : null;
    const live = board.ok ? parseLiveRow(board.value, trainNo) : null;
    return {
      available: !!timetable || !!live,
      liveAvailable: board.ok,
      /** true = the position is the last successful read (a refresh just failed); liveAgeSeconds says how old it is. */
      liveStale: !!board.stale,
      liveAgeSeconds: board.ok && board.fetchedAt ? Math.max(0, Math.round((nowMs - board.fetchedAt) / 1000)) : null,
      scheduleSource: timetable ? (isToday ? "today" : "general") : null,
      reasons: { timetable: tt.ok ? null : tt.reason, live: board.ok ? null : board.reason },
      trainType: timetable?.trainType ?? null,
      towards: timetable?.towards ?? null,
      fetchedAt: Math.max(tt.fetchedAt ?? 0, board.fetchedAt ?? 0) || null,
      ...summarizeTrain({ timetable, live, fromId, toId, nowMs }),
    };
  }

  return { routeOverlay, busStopArrivals, trainStatus, capabilities: () => REALTIME_CAPABILITIES, cache };
}
