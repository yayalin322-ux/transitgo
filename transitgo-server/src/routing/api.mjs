import { randomUUID } from "node:crypto";
import { attachVirtualOrigin, attachVirtualDestination, haversineMeters } from "../graph/virtual.mjs";
import { TransitEdge, Mode } from "../graph/model.mjs";
import { rankRoutes } from "./rank.mjs";
import { PROFILES } from "./profiles.mjs";

// Real TDX scope path for each feed this engine has ever ingested from — same
// scopePath value the ingest admin endpoints were actually called with (see
// hsinchu_routes.json / the THB5900 ingest), not a guess. Extend this when a new feed
// gets ingested from a new scope.
const FEED_SCOPE_PATHS = {
  HSZ: "City/Hsinchu",
  HSQ: "City/HsinchuCounty",
  THB: "InterCity",
};

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
export function planRoute(graph, requestBody, db) {
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

  const requestId = randomUUID();
  const originId = `virtual_origin_${requestId}`;
  const destinationId = `virtual_destination_${requestId}`;

  const originAttached = attachVirtualOrigin(graph, originId, origin.lat, origin.lng, { maxWalkingMeters: maxWalkingSeconds * 1.3 });
  if (!originAttached) return errorResponse("NO_ORIGIN_NEARBY");
  const destAttached = attachVirtualDestination(graph, destinationId, destination.lat, destination.lng, { maxWalkingMeters: maxWalkingSeconds * 1.3 });
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
      searchOptions: { maxWalkingSeconds, maxTransfers, dateStr: departure.dateStr.replace(/-/g, "") },
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
  const routeInfo = (fromNodeId, routeId) => {
    if (!db || !routeId) return { routeShortName: null, scopePath: null };
    const feedId = String(fromNodeId).split(":")[0];
    const key = `${feedId}:${routeId}`;
    if (routeInfoCache.has(key)) return routeInfoCache.get(key);
    const row = db.prepare(`SELECT route_short_name FROM gtfs_routes WHERE feed_id = ? AND route_id = ?`).get(feedId, routeId);
    const info = { routeShortName: row?.route_short_name ?? null, scopePath: FEED_SCOPE_PATHS[feedId] ?? null };
    routeInfoCache.set(key, info);
    return info;
  };

  const routes = result.routes.map((r, i) => {
    const legs = r.route.legs.map((l) => {
      const { routeShortName, scopePath } = routeInfo(l.fromNodeId, l.routeId);
      return {
        mode: l.mode,
        routeId: l.routeId,
        routeShortName, scopePath,
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
      };
    });
    return {
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
      legs,
      // One entry per real boarding, not per graph edge — the router's own edges are
      // one per stop-to-stop hop (so a 9-stop bus ride is 9 edges), which is correct for
      // routing but unreadable as a itinerary; this collapses consecutive same
      // mode+route edges into "board at X, ride N stops, alight at Y".
      segments: collapseToSegments(legs),
    };
  });

  return { status: 200, body: { requestId, routes } };
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
      });
    }
  }
  return segments;
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
