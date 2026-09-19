import { randomUUID } from "node:crypto";
import { attachVirtualOrigin, attachVirtualDestination, haversineMeters } from "../graph/virtual.mjs";
import { TransitEdge, Mode } from "../graph/model.mjs";
import { rankRoutes } from "./rank.mjs";
import { PROFILES } from "./profiles.mjs";
import { BIKE_CONFIG, BIKE_FEED_PREFIX, isBikeNodeId } from "../bike/config.mjs";

// Real TDX scope path for each feed this engine has ever ingested from — same
// scopePath value the ingest admin endpoints were actually called with (see
// ingest_master.mjs / the THB5900 ingest), not a guess. Extend this when a new feed
// gets ingested from a new scope. Was missing TYC/TPE/NTC (added once those cities were
// actually ingested) — every bus leg from those feeds was silently returning
// scopePath: null to the app, which needs a real scopePath to call TDX's live-position
// endpoints for that route.
const FEED_SCOPE_PATHS = {
  HSZ: "City/Hsinchu",
  HSQ: "City/HsinchuCounty",
  TYC: "City/Taoyuan",
  TPE: "City/Taipei",
  NTC: "City/NewTaipei",
  THB: "InterCity",
};

// Human-readable label for each feed, shared by /v1/routing/coverage below — so the app
// can show what's actually covered instead of a hand-typed sentence that silently goes
// stale every time a new feed is ingested (which already happened once: the UI kept
// saying "目前僅新竹市／縣" long after Taoyuan/Taipei/NewTaipei/TRA/THSR were added).
const FEED_LABELS = {
  HSZ: "新竹市公車", HSQ: "新竹縣公車", TYC: "桃園市公車", TPE: "臺北市公車", NTC: "新北市公車",
  THB: "跨區客運", TRA: "台鐵", THSR: "高鐵",
  // Metro operators (feed id = "MRT_" + TDX operator code, see ingestMetroOperator).
  MRT_TRTC: "台北捷運", MRT_TYMC: "桃園捷運", MRT_NTMC: "新北捷運", MRT_KRTC: "高雄捷運",
};
// YouBike stations are feed "BIKE_<TDX city>" (see graph/bikeNetwork.mjs) — reported as its own
// coverage entry, never mixed into the bus/rail lists.

const METRO_FEED_PREFIX = "MRT_";
function isMetroFeed(feedId) {
  return String(feedId).startsWith(METRO_FEED_PREFIX);
}

const ERROR_MESSAGES = {
  SAME_ORIGIN_DESTINATION: "起點與終點相同",
  NO_ORIGIN_NEARBY: "起點附近找不到可用的大眾運輸站點",
  NO_DESTINATION_NEARBY: "終點附近找不到可用的大眾運輸站點",
  UNKNOWN_DESTINATION: "終點不在目前的路網資料中",
  NO_ROUTE: "找不到符合條件的公共運輸路線",
  SEARCH_TOO_LARGE: "搜尋範圍過大，請稍後再試",
  INVALID_REQUEST: "請求格式錯誤",
};

function errorResponse(code) {
  return { status: code === "INVALID_REQUEST" ? 400 : 404, body: { error: { code, message: ERROR_MESSAGES[code] ?? code } } };
}

/** "2026-09-13T10:00:00+08:00" → { dateStr: "2026-09-13", secondsOfDay } in the given offset, defaulting to UTC+8 (Taiwan). */
function parseDepartureTime(iso) {
  const d = iso ? new Date(iso) : new Date();
  if (isNaN(d.getTime())) return null;
  // Render's `now` handling. +8 is Taiwan's fixed offset (no DST).
  const taipei = new Date(d.getTime() + 8 * 3600_000);
  const dateStr = taipei.toISOString().slice(0, 10);
  const secondsOfDay = taipei.getUTCHours() * 3600 + taipei.getUTCMinutes() * 60 + taipei.getUTCSeconds();
  return { dateStr, secondsOfDay, baseDate: new Date(`${dateStr}T00:00:00+08:00`) };
}

function secondsToIso(baseDate, seconds) {
  return new Date(baseDate.getTime() + seconds * 1000).toISOString();
}

/**
 * POST /api/v1/routes — architecture doc section 11/12. Pure function (no Express
 * req/res) so it's directly testable: takes the already-built in-memory graph and the
 * parsed request body, returns { status, body } for the caller to send as-is. `db` is
 * optional (tests can omit it) — only used to resolve each leg's real route_short_name
 * for the client to look up live vehicle positions with; omitted, those fields are null.
 */
export async function planRoute(graph, requestBody, db, { realtime = null, bikeRealtime = null } = {}) {
  const body = requestBody || {};
  const origin = body.origin;
  const destination = body.destination;
  if (!origin || typeof origin.lat !== "number" || typeof origin.lng !== "number") return errorResponse("INVALID_REQUEST");
  if (!destination || typeof destination.lat !== "number" || typeof destination.lng !== "number") return errorResponse("INVALID_REQUEST");

  const departure = parseDepartureTime(body.departureTime);
  if (!departure) return errorResponse("INVALID_REQUEST");

  const profileKey = typeof body.profile === "string" && PROFILES[body.profile] ? body.profile : null;
  const options = body.options || {};
  const maxWalkingSeconds = Number.isFinite(options.maxWalkingMinutes) ? options.maxWalkingMinutes * 60 : 20 * 60;
  const maxTransfers = Number.isFinite(options.maxTransfers) ? options.maxTransfers : 3;

  // Checked on the real coordinates, before any virtual-node wrapping — the virtual
  // origin/destination node IDs are always distinct strings (they embed a fresh
  // requestId), so findRoute's own originId===destinationId check can never catch this;
  // it has to happen here instead.
  const straightLineMeters = haversineMeters(origin.lat, origin.lng, destination.lat, destination.lng);
  if (straightLineMeters < 20) return errorResponse("SAME_ORIGIN_DESTINATION");

  // YouBike: on when the graph has a bike layer and the request doesn't opt out. Availability is read
  // ONCE here (a cached, de-duplicated snapshot) BEFORE the virtual nodes exist — the search itself
  // is synchronous and only asks the in-memory answer. A snapshot that can't be read is "unknown":
  // bike candidates stay (flagged) or are excluded per `bikeUnavailable`, and nothing else changes.
  const bikeEnabled = options.allowBike !== false && bikeStationCount(graph) > 0;
  let bikeSearch = null, bikeOracle = null;
  if (bikeEnabled) {
    let snap = { ok: false, reason: "not_configured", stations: new Map() };
    if (bikeRealtime) {
      try { snap = await bikeRealtime.snapshot(); } catch { snap = { ok: false, reason: "unavailable", stations: new Map() }; }
    }
    bikeOracle = bikeRealtime
      ? bikeRealtime.oracleFor(snap, { unknownPolicy: options.bikeUnavailable === "exclude" ? "exclude" : "allow" })
      : { available: false, reason: "not_configured", check: () => (options.bikeUnavailable === "exclude" ? "no" : "unknown"), status: () => null };
    bikeSearch = { check: bikeOracle.check, unlockSeconds: BIKE_CONFIG.unlockSeconds, returnSeconds: BIKE_CONFIG.returnSeconds };
  }

  const requestId = randomUUID();
  const originId = `virtual_origin_${requestId}`;
  const destinationId = `virtual_destination_${requestId}`;

  const originAttached = attachVirtualOrigin(graph, originId, origin.lat, origin.lng, { maxWalkingMeters: maxWalkingSeconds * 1.3, includeBike: bikeEnabled });
  if (!originAttached) return errorResponse("NO_ORIGIN_NEARBY");
  const destAttached = attachVirtualDestination(graph, destinationId, destination.lat, destination.lng, { maxWalkingMeters: maxWalkingSeconds * 1.3, includeBike: bikeEnabled });
  if (!destAttached) {
    cleanupVirtualNode(graph, originId);
    return errorResponse("NO_DESTINATION_NEARBY");
  }

  // Origin and destination close enough to just walk (doc's own Test 10: "起點與終點
  //距離 300m，應優先推薦步行，而不是搭車") — add that as a real candidate edge so
  // ranking/dominance naturally prefers it over any transit detour when it's actually
  // better, instead of forcing a transit route that doesn't make sense at this range.
  if (straightLineMeters <= maxWalkingSeconds * 1.3) {
    graph.addEdge(new TransitEdge({
      id: `direct_walk_${requestId}`,
      fromNodeId: originId, toNodeId: destinationId, mode: Mode.WALK,
      travelSeconds: Math.round(straightLineMeters / (1.3)),
      distanceMeters: straightLineMeters,
      source: "Haversine estimate (direct origin-to-destination)",
    }));
  }

  let result;
  try {
    result = rankRoutes(graph, originId, destinationId, departure.secondsOfDay, {
      maxResults: 5,
      searchOptions: { maxWalkingSeconds, maxTransfers, dateStr: departure.dateStr.replace(/-/g, ""), bike: bikeSearch },
    });
  } finally {
    cleanupVirtualNode(graph, originId);
    cleanupVirtualNode(graph, destinationId);
  }

  if (result.error) return errorResponse(result.error);
  // A specific profile was requested — narrow to just that one labeled result rather
  // than running a separate single-profile search (rankRoutes already computed every
  // profile's route to do the dedup/dominance pass, so the work isn't wasted either way).
  if (profileKey) {
    const wanted = PROFILES[profileKey].label;
    const match = result.routes.find((r) => r.label === wanted);
    result = { routes: match ? [match] : result.routes.slice(0, 1) };
  }

  const routeInfoCache = new Map();
  const routeInfo = async (fromNodeId, routeId) => {
    if (!db || !routeId) return { routeShortName: null, scopePath: null, towards: null };
    const feedId = String(fromNodeId).split(":")[0];
    const key = `${feedId}:${routeId}`;
    if (routeInfoCache.has(key)) return routeInfoCache.get(key);
    const row = await db.prepare(`SELECT route_short_name, route_long_name FROM gtfs_routes WHERE feed_id = ? AND route_id = ?`).get(feedId, routeId);
    const info = {
      routeShortName: row?.route_short_name ?? null,
      scopePath: FEED_SCOPE_PATHS[feedId] ?? null,
      // Metro only: "往{terminus}", derived at ingest from the route's own last real station.
      towards: isMetroFeed(feedId) ? (row?.route_long_name ?? null) : null,
    };
    routeInfoCache.set(key, info);
    return info;
  };

  const routes = [];
  for (const [i, r] of result.routes.entries()) {
    const legs = [];
    for (const l of r.route.legs) {
      const { routeShortName, scopePath, towards } = await routeInfo(l.fromNodeId, l.routeId);
      legs.push({
        mode: l.mode,
        routeId: l.routeId,
        routeShortName, scopePath, towards,
        from: l.fromNodeId,
        to: l.toNodeId,
        fromName: graph.nodes.get(l.fromNodeId)?.name ?? null,
        toName: graph.nodes.get(l.toNodeId)?.name ?? null,
        fromLat: graph.nodes.get(l.fromNodeId)?.lat ?? null,
        fromLng: graph.nodes.get(l.fromNodeId)?.lon ?? null,
        toLat: graph.nodes.get(l.toNodeId)?.lat ?? null,
        toLng: graph.nodes.get(l.toNodeId)?.lon ?? null,
        departureTime: secondsToIso(departure.baseDate, l.departureSeconds),
        arrivalTime: secondsToIso(departure.baseDate, l.arrivalSeconds),
        durationSeconds: l.arrivalSeconds - l.departureSeconds,
        isEstimated: l.isEstimated ?? false,
        distanceMeters: l.distanceMeters ?? null,
        // What kind of walk: a metro interchange (real TDX transfer minutes, no distance),
        // a metro-station-to-nearby-stop link, or an ordinary street walk (null).
        walkKind: walkKindOf(l.source),
        tripId: l.serviceKey ? l.serviceKey.slice(l.serviceKey.indexOf(":") + 1) : null,
        ...(l.mode === "BIKE" ? { straightLineMeters: l.straightLineMeters ?? null, handlingSeconds: l.handlingSeconds ?? 0 } : {}),
      });
    }
    routes.push({
      routeId: `R${String(i + 1).padStart(3, "0")}`,
      label: r.label,
      durationSeconds: r.route.durationSeconds,
      departureTime: secondsToIso(departure.baseDate, r.route.departureTime),
      arrivalTime: secondsToIso(departure.baseDate, r.route.arrivalTime),
      walkingSeconds: r.route.walkingSeconds,
      waitingSeconds: r.route.waitingSeconds,
      transitSeconds: r.route.transitSeconds,
      transfers: r.route.transfers,
      fare: r.route.fare,
      walkingDistanceMeters: r.route.walkingDistanceMeters,
      // YouBike totals (estimated distance/time — see `assumptions` on the response); null when no bike leg.
      bikeDistanceMeters: r.route.bikeSeconds > 0 ? r.route.bikeMeters : null,
      bikeSeconds: r.route.bikeSeconds > 0 ? r.route.bikeSeconds : null,
      // Best-effort live metro status (see routing/metroRealtime.mjs) — null when the trip
      // has no metro leg or no realtime provider is configured; { available: false } when
      // one was asked and couldn't answer. Never affects whether the route itself exists.
      realtimeStatus: null,
      legs,
      // One entry per real boarding, not per graph edge — the router's own edges are
      // one per stop-to-stop hop (so a 9-stop bus ride is 9 edges), which is correct for
      // routing but unreadable as a itinerary; this collapses consecutive same
      // mode+route edges into "board at X, ride N stops, alight at Y".
      segments: collapseToSegments(legs),
    });
  }

  if (realtime) await attachMetroRealtime(routes, realtime);

  const body2 = { requestId, routes };
  if (routes.some((r) => r.segments.some((sg) => sg.mode === "BIKE"))) {
    for (const route of routes) attachBikeDetails(route, bikeOracle);
    body2.assumptions = { bike: bikeAssumptions() };
    body2.bikeRealtime = { available: bikeOracle?.available ?? false, reason: bikeOracle?.reason ?? null };
  }
  return { status: 200, body: body2 };
}

/** Number of YouBike stations in the graph (counted once per graph instance — the layer never changes after a build). */
function bikeStationCount(graph) {
  if (graph._bikeStationCount == null) {
    let n = 0;
    for (const id of graph.nodes.keys()) if (isBikeNodeId(id)) n++;
    graph._bikeStationCount = n;
  }
  return graph._bikeStationCount;
}

/** The estimated-model numbers, disclosed on every response that contains a bike leg. */
function bikeAssumptions() {
  return {
    distanceBasis: "estimate",
    detourFactor: BIKE_CONFIG.detourFactor,
    speedMps: BIKE_CONFIG.speedMps,
    unlockSeconds: BIKE_CONFIG.unlockSeconds,
    returnSeconds: BIKE_CONFIG.returnSeconds,
    note: "騎乘距離＝直線距離 × 繞路係數、時間＝距離 ÷ 假設車速；目前沒有自行車道路網或票價資料，皆為估計值。",
  };
}

/**
 * Adds the bike detail to a route: per BIKE segment the rent/return station's realtime state (as of
 * THIS request's snapshot) and the estimate flags, and a route-level `bikeRides` summary with the
 * walk to the dock, the ride and the walk from the dock. Realtime missing => availability
 * "unknown" with a reason; the route and its times are never touched.
 */
function attachBikeDetails(route, oracle) {
  const rides = [];
  route.segments.forEach((seg, i) => {
    if (seg.mode !== "BIKE") return;
    const rentStatus = oracle?.status(seg.from) ?? null;
    const returnStatus = oracle?.status(seg.to) ?? null;
    const known = !!(rentStatus && returnStatus);
    const prev = route.segments[i - 1], next = route.segments[i + 1];
    const rideSeconds = Math.max(0, seg.durationSeconds - (seg.handlingSeconds ?? 0));
    seg.bike = {
      rentStationId: seg.from, rentStationName: seg.fromName,
      returnStationId: seg.to, returnStationName: seg.toName,
      bikeDistanceMeters: seg.distanceMeters, straightLineMeters: seg.straightLineMeters,
      bikeDurationSeconds: rideSeconds, handlingSeconds: seg.handlingSeconds ?? 0,
      isEstimated: true,
      availability: {
        status: known ? "known" : "unknown",
        reason: known ? null : (oracle?.reason ?? (oracle?.available ? "station_not_in_snapshot" : "unavailable")),
        rent: rentStatus, return: returnStatus,
      },
    };
    seg.isEstimated = true;
    rides.push({
      segmentIndex: i,
      walkingToBikeMeters: prev?.mode === "WALK" ? (route.legs.find((l) => l.to === seg.from && l.mode === "WALK")?.distanceMeters ?? null) : 0,
      bikeDistanceMeters: seg.distanceMeters,
      walkingFromBikeMeters: next?.mode === "WALK" ? (route.legs.find((l) => l.from === seg.to && l.mode === "WALK")?.distanceMeters ?? null) : 0,
      bikeDurationSeconds: rideSeconds,
    });
  });
  route.bikeRides = rides;
  route.bikeAvailability = route.segments.filter((s) => s.mode === "BIKE").every((s) => s.bike.availability.status === "known") ? "known" : "unknown";
}

/** "MRT_TRTC:BL12" -> "TRTC" (the TDX operator code a realtime lookup needs). */
function metroOperatorOfNode(nodeId) {
  const feedId = String(nodeId).split(":")[0];
  return isMetroFeed(feedId) ? feedId.slice(METRO_FEED_PREFIX.length) : null;
}

function walkKindOf(source) {
  if (typeof source !== "string") return null;
  if (source.startsWith("TDX LineTransfer")) return "MRT_TRANSFER_WALK";
  if (source.startsWith("Haversine estimate (metro station")) return "MRT_STATION_LINK";
  return null;
}

/**
 * Adds `realtimeStatus` to every route that rides a metro operator. A realtime lookup that
 * throws, times out or returns nothing yields `{ available: false }` for that operator —
 * the route, its times and its legs are already fully built and are never touched here, so
 * a realtime outage cannot turn a found route into a failed one.
 */
async function attachMetroRealtime(routes, realtime) {
  for (const route of routes) {
    const operators = [...new Set(route.legs.filter((l) => l.mode === "MRT").map((l) => metroOperatorOfNode(l.from)).filter(Boolean))];
    if (operators.length === 0) continue;
    const results = await Promise.all(operators.map(async (op) => {
      try {
        return { operator: op, status: await realtime.metroStatus(op) };
      } catch {
        return { operator: op, status: null };
      }
    }));
    const unavailable = results.some((r) => !r.status);
    const alerts = results.flatMap((r) => r.status?.alerts ?? []);
    route.realtimeStatus = {
      available: !unavailable,
      summary: unavailable ? "即時資料暫時無法取得" : (alerts.length > 0 ? `捷運營運通阻：${alerts.map((a) => a.title).join("、")}` : "捷運營運正常"),
      alerts,
    };
  }
}

/**
 * Collapses per-edge legs into one entry per real boarding: consecutive legs with the
 * same (mode, routeId) merge into a single "board at the first one's origin, alight at
 * the last one's destination" segment. A WALK leg is always its own segment (there's no
 * "route" to merge it with). `stopsPassed` is the real number of intermediate hops —
 * useful context ("經過6站"), not the real per-stop names (those stay in `legs` for
 * anyone who wants the detail).
 */
function collapseToSegments(legs) {
  const segments = [];
  for (const leg of legs) {
    const last = segments[segments.length - 1];
    if (last && leg.mode !== "WALK" && last.mode === leg.mode && last.routeId === leg.routeId) {
      last.to = leg.to;
      last.toName = leg.toName;
      last.toLat = leg.toLat;
      last.toLng = leg.toLng;
      last.arrivalTime = leg.arrivalTime;
      last.durationSeconds = (Date.parse(leg.arrivalTime) - Date.parse(last.departureTime)) / 1000;
      last.stopsPassed += 1;
      last.isEstimated = last.isEstimated || leg.isEstimated;
      if (leg.mode === "BIKE") {   // consecutive bike hops are ONE ride: sum the estimated distance
        last.distanceMeters = (last.distanceMeters ?? 0) + (leg.distanceMeters ?? 0);
        last.straightLineMeters = (last.straightLineMeters ?? 0) + (leg.straightLineMeters ?? 0);
        last.handlingSeconds = (last.handlingSeconds ?? 0) + (leg.handlingSeconds ?? 0);
      }
      if (last.stops) { last.stops.push(leg.toName); last.alightingStation = leg.toName; }
    } else {
      segments.push({
        mode: leg.mode,
        routeId: leg.routeId,
        routeShortName: leg.routeShortName, scopePath: leg.scopePath,
        from: leg.from, fromName: leg.fromName, fromLat: leg.fromLat, fromLng: leg.fromLng,
        to: leg.to, toName: leg.toName, toLat: leg.toLat, toLng: leg.toLng,
        departureTime: leg.departureTime,
        arrivalTime: leg.arrivalTime,
        durationSeconds: leg.durationSeconds,
        stopsPassed: 1,
        isEstimated: leg.isEstimated,
        walkKind: leg.walkKind ?? null,
        tripId: leg.tripId ?? null,
        ...(leg.mode === "BIKE" ? { distanceMeters: leg.distanceMeters ?? null, straightLineMeters: leg.straightLineMeters ?? null, handlingSeconds: leg.handlingSeconds ?? 0 } : {}),
        // Metro rides carry the fields an itinerary needs: which line, which direction,
        // where you board/alight and every station in between (real station names).
        ...(leg.mode === "MRT" ? {
          line: leg.routeShortName ?? null,
          towards: leg.towards ?? null,
          boardingStation: leg.fromName,
          alightingStation: leg.toName,
          stops: [leg.fromName, leg.toName],
        } : {}),
      });
    }
  }
  return segments;
}

/**
 * What real data is actually in the given graph right now — computed from the graph
 * itself (which feeds it actually has nodes for), not a hand-maintained list that has
 * to be remembered every time a new city/feed gets ingested. The in-app footer that
 * used to say "測試中，目前僅新竹市／縣有真實資料" stayed that way long after Taoyuan,
 * Taipei, New Taipei, TRA and THSR were all ingested — this is what replaces it.
 */
export function graphCoverage(graph) {
  const feedIds = new Set();
  for (const id of graph.nodes.keys()) {
    const feedId = String(id).split(":")[0];
    feedIds.add(feedId);
  }
  const bus = [], rail = [], metro = [];
  for (const feedId of feedIds) {
    const label = FEED_LABELS[feedId];
    if (!label) continue;   // an internal feed id nothing here recognizes yet — omit rather than show a raw code
    if (isMetroFeed(feedId)) metro.push(label);
    else (feedId === "TRA" || feedId === "THSR" ? rail : bus).push(label);
  }
  let metroStations = 0;
  for (const id of graph.nodes.keys()) if (isMetroFeed(String(id).split(":")[0])) metroStations++;
  const bikeCities = new Set();
  let bikeStations = 0;
  for (const id of graph.nodes.keys()) {
    if (!isBikeNodeId(id)) continue;
    bikeStations++;
    bikeCities.add(id.slice(BIKE_FEED_PREFIX.length, id.indexOf(":")));
  }
  return {
    bus: bus.sort(),
    rail: rail.sort(),
    bike: { available: bikeStations > 0, stationCount: bikeStations, cities: [...bikeCities].sort() },
    // Metro operators that actually have real stations + run times in the live graph —
    // computed from the graph itself, so an operator whose ingest was skipped (no real
    // run times) never shows up here.
    mrt: { available: metro.length > 0, operators: metro.sort(), stationCount: metroStations },
    nodeCount: graph.nodeCount,
    edgeCount: graph.edgeCount,
    builtAt: graph.builtAt,
  };
}

/** Virtual nodes/edges are per-request — never let them leak into the shared graph past this call. */
function cleanupVirtualNode(graph, nodeId) {
  graph.nodes.delete(nodeId);
  graph.edgesByFrom.delete(nodeId);
  for (const [from, edges] of graph.edgesByFrom) {
    const filtered = edges.filter((e) => e.toNodeId !== nodeId);
    if (filtered.length !== edges.length) graph.edgesByFrom.set(from, filtered);
  }
}
