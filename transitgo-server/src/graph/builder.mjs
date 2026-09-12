import { MultimodalGraph, TransitNode, TransitEdge, NodeType, Mode, parseGtfsTime } from "./model.mjs";

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

  const trips = db.prepare(`SELECT feed_id, trip_id, route_id FROM gtfs_trips ${feedClause}`).all(...feedArgs);
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
        source: "TDX real timetable",
      }));
    }
  }
  if (skippedForMissingStopId > 0) {
    graph.warnings.push(`${skippedForMissingStopId} stop_times rows have no resolved stop_id yet (bus per-trip times not yet joined to StopOfRoute sequence) — excluded from edges, not guessed.`);
  }

  const freqCount = db.prepare(`SELECT COUNT(*) c FROM transit_route_frequency ${feedClause}`).get(...feedArgs).c;
  if (freqCount > 0) {
    graph.warnings.push(`${freqCount} real TDX headway bands in transit_route_frequency have no edges built yet — needs each route's ordered stop sequence (see module doc comment); tracked as the next increment, not fabricated as edges.`);
  }

  return graph;
}
