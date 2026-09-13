import { MultimodalGraph, TransitNode, TransitEdge, NodeType, Mode, parseGtfsTime } from "./model.mjs";
import { haversineMeters } from "./virtual.mjs";
import { loadServiceCalendar } from "./calendar.mjs";

/**
 * No verified TDX endpoint gives real stop-to-stop bus travel time (S2STravelTime exists
 * for Metro only — checked the app's own MetroService.swift, nothing equivalent for
 * bus). Rather than leave headway routes edge-less forever, this uses the same honest
 * pattern the WALK edges already use: a real measured distance (from real stop
 * coordinates) divided by a clearly-labeled speed *estimate* — 15 km/h accounts for a
 * city bus's stops/traffic/signals, not free-flow speed. This is a genuine estimate, not
 * a real measurement — every such edge's `source` says so explicitly.
 */
const ESTIMATED_BUS_SPEED_MPS = 15 / 3.6;

export function nodeId(feedId, stopId) {
  return `${feedId}:${stopId}`;
}

/**
 * Builds the in-memory Multimodal Graph from the gtfs_* tables (architecture doc
 * section 3 + 17 — Database → Load Graph → RAM, Routing never queries SQL mid-search).
 *
 * Only builds TIME-DEPENDENT edges here (real trip/stop_times — TRA today, and any bus
 * route that has TDX's real `Timetables`, once ingested). Headway-based edges
 * (transit_route_frequency) need each route's ordered stop sequence to know which pairs
 * of stops a headway band even applies to, and that isn't persisted yet — Phase 1.5's
 * ingest only stored bus stops as a flat set, not per-route order. Rather than guess an
 * order, this is left as an explicit gap (see `graph.warnings`) for the next increment,
 * not silently faked.
 */
export function buildGraph(db, { feedIds = null, dataVersion = null } = {}) {
  const graph = new MultimodalGraph();
  graph.builtAt = new Date().toISOString();
  graph.dataVersion = dataVersion;
  graph.warnings = [];

  const feedClause = feedIds ? `WHERE feed_id IN (${feedIds.map(() => "?").join(",")})` : "";
  const feedArgs = feedIds ?? [];

  // Kept on the graph itself (not baked into edges at build time) — findRoute checks
  // this against the actual query date, so a real 停駛/holiday/weekday-only service
  // works correctly for any date without needing the whole graph rebuilt.
  graph.serviceCalendar = loadServiceCalendar(db, feedClause, feedArgs);

  const routeType = new Map();  // "feedId:routeId" -> gtfs route_type
  for (const r of db.prepare(`SELECT feed_id, route_id, route_type FROM gtfs_routes ${feedClause}`).all(...feedArgs)) {
    routeType.set(`${r.feed_id}:${r.route_id}`, r.route_type);
  }

  function modeFor(feedId, routeId) {
    if (routeId === "TRA") return Mode.TRA;
    if (routeId === "THSR") return Mode.HSR;
    const t = routeType.get(`${feedId}:${routeId}`);
    switch (t) {
      case 0: case 1: return Mode.MRT;
      case 2: return Mode.TRA;
      case 4: return Mode.FERRY;
      default: return Mode.BUS;
    }
  }

  for (const s of db.prepare(`SELECT * FROM gtfs_stops ${feedClause}`).all(...feedArgs)) {
    graph.addNode(new TransitNode({
      id: nodeId(s.feed_id, s.stop_id),
      type: NodeType.STOP,
      mode: null,   // a stop can serve more than one mode; edges carry the mode, not the node
      name: s.stop_name,
      lat: s.stop_lat,
      lon: s.stop_lon,
      parentStationId: s.parent_station ? nodeId(s.feed_id, s.parent_station) : null,
    }));
  }

  const trips = db.prepare(`SELECT feed_id, trip_id, route_id, service_id FROM gtfs_trips ${feedClause}`).all(...feedArgs);
  const stopTimesStmt = db.prepare(`
    SELECT stop_id, arrival_time, departure_time, stop_sequence
    FROM gtfs_stop_times WHERE feed_id = ? AND trip_id = ? ORDER BY stop_sequence
  `);

  let skippedForMissingStopId = 0;
  for (const trip of trips) {
    const rows = stopTimesStmt.all(trip.feed_id, trip.trip_id);
    const resolved = rows.filter((r) => r.stop_id != null);
    skippedForMissingStopId += rows.length - resolved.length;

    for (let i = 0; i < resolved.length - 1; i++) {
      const a = resolved[i], b = resolved[i + 1];
      const dep = parseGtfsTime(a.departure_time ?? a.arrival_time);
      const arr = parseGtfsTime(b.arrival_time ?? b.departure_time);
      if (dep == null || arr == null) continue;
      const travelSeconds = arr >= dep ? arr - dep : arr + 86400 - dep;   // past-midnight rollover
      graph.addEdge(new TransitEdge({
        id: `${trip.feed_id}_${trip.trip_id}_${a.stop_sequence}`,
        fromNodeId: nodeId(trip.feed_id, a.stop_id),
        toNodeId: nodeId(trip.feed_id, b.stop_id),
        mode: modeFor(trip.feed_id, trip.route_id),
        routeId: trip.route_id,
        departureSeconds: dep,
        arrivalSeconds: arr,
        travelSeconds,
        serviceKey: trip.service_id ? `${trip.feed_id}:${trip.service_id}` : null,
        source: "TDX real timetable",
      }));
    }
  }
  if (skippedForMissingStopId > 0) {
    graph.warnings.push(`${skippedForMissingStopId} stop_times rows have no resolved stop_id yet (bus per-trip times not yet joined to StopOfRoute sequence) — excluded from edges, not guessed.`);
  }

  // Headway-based edges — one per consecutive real stop pair per route+direction that
  // has a real TDX headway band, active only during that band's own real time window.
  const freqRows = db.prepare(`SELECT * FROM transit_route_frequency ${feedClause}`).all(...feedArgs);
  const routeStopStmt = db.prepare(`
    SELECT stop_id FROM gtfs_route_stops
    WHERE feed_id = ? AND route_id = ? AND direction = ? ORDER BY stop_sequence
  `);
  const stopCoordStmt = db.prepare(`SELECT stop_lat, stop_lon FROM gtfs_stops WHERE feed_id = ? AND stop_id = ?`);
  const routeStopCache = new Map();
  let headwayEdgesBuilt = 0, headwaySkippedNoStops = 0;

  for (const f of freqRows) {
    const cacheKey = `${f.feed_id}|${f.route_id}|${f.direction}`;
    if (!routeStopCache.has(cacheKey)) {
      routeStopCache.set(cacheKey, routeStopStmt.all(f.feed_id, f.route_id, f.direction).map((r) => r.stop_id));
    }
    const stopIds = routeStopCache.get(cacheKey);
    if (stopIds.length < 2) { headwaySkippedNoStops++; continue; }

    const startSeconds = parseGtfsTime(f.start_time);
    const endSeconds = parseGtfsTime(f.end_time);
    const avgHeadwaySeconds = f.min_headway_mins != null && f.max_headway_mins != null
      ? ((f.min_headway_mins + f.max_headway_mins) / 2) * 60
      : (f.min_headway_mins ?? f.max_headway_mins ?? null) * 60;
    if (avgHeadwaySeconds == null || startSeconds == null || endSeconds == null) continue;

    for (let i = 0; i < stopIds.length - 1; i++) {
      const a = stopCoordStmt.get(f.feed_id, stopIds[i]);
      const b = stopCoordStmt.get(f.feed_id, stopIds[i + 1]);
      if (!a?.stop_lat || !b?.stop_lat) continue;
      const distanceMeters = haversineMeters(a.stop_lat, a.stop_lon, b.stop_lat, b.stop_lon);
      graph.addEdge(new TransitEdge({
        id: `HW_${f.feed_id}_${f.route_id}_${f.direction}_${i}_${f.start_time}`,
        fromNodeId: nodeId(f.feed_id, stopIds[i]),
        toNodeId: nodeId(f.feed_id, stopIds[i + 1]),
        mode: modeFor(f.feed_id, f.route_id),
        routeId: f.route_id,
        headwaySeconds: avgHeadwaySeconds,
        windowStartSeconds: startSeconds,
        windowEndSeconds: endSeconds,
        travelSeconds: Math.max(30, Math.round(distanceMeters / ESTIMATED_BUS_SPEED_MPS)),
        distanceMeters,
        source: `TDX real headway (${f.min_headway_mins ?? "?"}-${f.max_headway_mins ?? "?"} min, ${f.start_time}-${f.end_time}); travel time estimated from real distance at ${Math.round(ESTIMATED_BUS_SPEED_MPS * 3.6)} km/h`,
      }));
      headwayEdgesBuilt++;
    }
  }
  if (headwaySkippedNoStops > 0) {
    graph.warnings.push(`${headwaySkippedNoStops} headway band(s) skipped — no gtfs_route_stops sequence for that route+direction yet.`);
  }
  if (headwayEdgesBuilt > 0) {
    graph.warnings.push(`${headwayEdgesBuilt} headway-based edges built with an ESTIMATED travel time (real distance / assumed ${Math.round(ESTIMATED_BUS_SPEED_MPS * 3.6)} km/h) — no verified TDX stop-to-stop bus travel time source exists yet.`);
  }

  return graph;
}
