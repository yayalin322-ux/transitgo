import { MultimodalGraph, TransitNode, TransitEdge, NodeType, Mode, parseGtfsTime } from "./model.mjs";
import { haversineMeters } from "./virtual.mjs";
import { loadServiceCalendar } from "./calendar.mjs";
import { logMemory, resetMemoryTracking } from "./memlog.mjs";

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

// `source` is a debugging annotation, never actually read by routing (rankRoutes,
// planRoute) or serialized in an API response — checked, it's write-only. Interpolating
// each band's own min/max-headway and time-window numbers into a unique string PER EDGE
// used to cost real memory across ~270k headway edges (a meaningful share of the graph's
// ~300MB steady-state footprint on Render's 512MB instance) for detail nothing reads.
// One shared constant keeps the "this is estimated, not measured" disclosure the tests
// check for at effectively zero cost.
const HEADWAY_EDGE_SOURCE = `TDX real headway; travel time estimated from real distance at ${Math.round(ESTIMATED_BUS_SPEED_MPS * 3.6)} km/h`;

/** Node's single-threaded event loop otherwise gets starved for a long time by this
 * function's edge-building loops once there's enough ingested data — and on Render's
 * free tier (0.15 CPU, 512MB — confirmed from the dashboard, not assumed) that's not a
 * one-time hiccup: a build that blocks for a while on real hardware can block for
 * *minutes* here, long enough to fail Render's own health check and get the whole
 * process killed and restarted mid-build, forever. Called periodically (not every
 * iteration — that would slow the build itself down for no benefit) so other pending
 * work, health checks included, gets a turn. */
function yieldToEventLoop() {
  return new Promise((resolve) => setImmediate(resolve));
}

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
 *
 * Processes ONE FEED AT A TIME rather than one giant "every feed at once" query set —
 * on a normal machine that would just mean a few more (cheap) round trips, but on a
 * 512MB/0.15-CPU instance holding all ~1500 routes' worth of raw stop_times/route_stops
 * rows in memory simultaneously (on top of the graph objects being built from them) was
 * enough to risk tipping the process into an OOM kill. Scoping each pass to one feed
 * caps peak memory to roughly "one city's data" instead of "every ingested city's data
 * at once," and gives natural yield points between feeds for free.
 */
export async function buildGraph(db, { feedIds = null, dataVersion = null, onProgress = null } = {}) {
  const report = (phase, extra = {}) => {
    const { rss } = logMemory(phase, extra);
    onProgress?.({ phase, memoryMB: rss, ...extra });
  };
  resetMemoryTracking();
  report("start");

  const graph = new MultimodalGraph();
  graph.builtAt = new Date().toISOString();
  graph.dataVersion = dataVersion;
  graph.warnings = [];
  graph.serviceCalendar = new Map();

  // Not every feed that matters has a gtfs_routes row — TRA/THSR ingest (ingestTRAPair)
  // never calls insertRoutes, only insertTrips/insertStopTimes/insertCalendarDates — so
  // the feed list has to come from a union of every table a feed could show up in, not
  // just gtfs_routes alone (that undercounted feeds and silently dropped TRA/THSR from
  // the graph the first time this was tried).
  const feeds = feedIds ?? (await db.prepare(`
    SELECT feed_id FROM gtfs_stops
    UNION SELECT feed_id FROM gtfs_trips
    UNION SELECT feed_id FROM transit_route_frequency
    UNION SELECT feed_id FROM gtfs_routes
  `).all()).map((r) => r.feed_id);
  report("feeds_listed", { feedCount: feeds.length });

  const routeType = new Map();  // "feedId:routeId" -> gtfs route_type
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

  let skippedForMissingStopId = 0;
  let headwayEdgesBuilt = 0, headwaySkippedNoStops = 0;
  let feedIndex = 0;

  for (const feedId of feeds) {
    feedIndex++;
    const feedClause = `WHERE feed_id = ?`;
    const feedArgs = [feedId];
    report("before_feed_query", { feed: feedId });

    // Kept on the graph itself (not baked into edges at build time) — findRoute checks
    // this against the actual query date, so a real 停駛/holiday/weekday-only service
    // works correctly for any date without needing the whole graph rebuilt.
    for (const [key, val] of await loadServiceCalendar(db, feedClause, feedArgs)) {
      graph.serviceCalendar.set(key, val);
    }

    for (const r of await db.prepare(`SELECT feed_id, route_id, route_type FROM gtfs_routes ${feedClause}`).all(...feedArgs)) {
      routeType.set(`${r.feed_id}:${r.route_id}`, r.route_type);
    }

    for (const s of await db.prepare(`SELECT feed_id, stop_id, stop_name, stop_lat, stop_lon, parent_station FROM gtfs_stops ${feedClause}`).all(...feedArgs)) {
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
    report("after_nodes", { feed: feedId, nodeCount: graph.nodeCount });

    const trips = await db.prepare(`SELECT feed_id, trip_id, route_id, service_id FROM gtfs_trips ${feedClause}`).all(...feedArgs);
    const tripByKey = new Map(trips.map((t) => [`${t.feed_id} ${t.trip_id}`, t]));

    // One query for every stop_times row in THIS feed, then group by trip in JS —
    // still one round trip for the whole feed rather than one per trip, just scoped to
    // a single feed at a time now instead of every feed's rows coexisting in memory.
    const stopTimesByTrip = new Map();
    {
      const allStopTimes = await db.prepare(`
        SELECT feed_id, trip_id, stop_id, arrival_time, departure_time, stop_sequence
        FROM gtfs_stop_times ${feedClause}
        ORDER BY feed_id, trip_id, stop_sequence
      `).all(...feedArgs);
      for (const row of allStopTimes) {
        const key = `${row.feed_id} ${row.trip_id}`;
        if (!tripByKey.has(key)) continue;   // stop_times for a trip outside this feed selection
        if (!stopTimesByTrip.has(key)) stopTimesByTrip.set(key, []);
        stopTimesByTrip.get(key).push(row);
      }
      // allStopTimes goes out of scope here — letting go of the reference explicitly
      // (rather than waiting for the enclosing block to end) gives the GC a chance to
      // reclaim it before the edge-building loop below allocates a comparable amount
      // of new TransitEdge objects.
    }
    report("after_feed_normalization", { feed: feedId, tripCount: trips.length });

    let tripIndex = 0;
    for (const trip of trips) {
      tripIndex++;
      if (tripIndex % 300 === 0) await yieldToEventLoop();
      const rows = stopTimesByTrip.get(`${trip.feed_id} ${trip.trip_id}`) ?? [];
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

    report("after_time_dependent_edges", { feed: feedId, edgeCount: graph.edgeCount });

    // Headway-based edges — one per consecutive real stop pair per route+direction that
    // has a real TDX headway band, active only during that band's own real time window.
    const freqRows = await db.prepare(`SELECT * FROM transit_route_frequency ${feedClause}`).all(...feedArgs);

    const allRouteStops = await db.prepare(`
      SELECT feed_id, route_id, direction, stop_sequence, stop_id FROM gtfs_route_stops ${feedClause}
      ORDER BY feed_id, route_id, direction, stop_sequence
    `).all(...feedArgs);
    const routeStopCache = new Map();
    for (const row of allRouteStops) {
      const key = `${row.feed_id}|${row.route_id}|${row.direction}`;
      if (!routeStopCache.has(key)) routeStopCache.set(key, []);
      routeStopCache.get(key).push(row.stop_id);
    }
    const stopCoords = new Map();
    for (const s of await db.prepare(`SELECT feed_id, stop_id, stop_lat, stop_lon FROM gtfs_stops ${feedClause}`).all(...feedArgs)) {
      stopCoords.set(`${s.feed_id}|${s.stop_id}`, s);
    }

    let freqIndex = 0;
    for (const f of freqRows) {
      freqIndex++;
      if (freqIndex % 300 === 0) await yieldToEventLoop();
      const stopIds = routeStopCache.get(`${f.feed_id}|${f.route_id}|${f.direction}`) ?? [];
      if (stopIds.length < 2) { headwaySkippedNoStops++; continue; }

      const startSeconds = parseGtfsTime(f.start_time);
      const endSeconds = parseGtfsTime(f.end_time);
      const avgHeadwaySeconds = f.min_headway_mins != null && f.max_headway_mins != null
        ? ((f.min_headway_mins + f.max_headway_mins) / 2) * 60
        : (f.min_headway_mins ?? f.max_headway_mins ?? null) * 60;
      if (avgHeadwaySeconds == null || startSeconds == null || endSeconds == null) continue;

      for (let i = 0; i < stopIds.length - 1; i++) {
        const a = stopCoords.get(`${f.feed_id}|${stopIds[i]}`);
        const b = stopCoords.get(`${f.feed_id}|${stopIds[i + 1]}`);
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
          source: HEADWAY_EDGE_SOURCE,
        }));
        headwayEdgesBuilt++;
      }
    }
    report("after_headway_edges", { feed: feedId, edgeCount: graph.edgeCount });

    // One more yield between feeds regardless of how many trips/freq rows it had —
    // keeps a feed with few routes from being lumped into the same event-loop turn as
    // the next feed's queries.
    await yieldToEventLoop();
    report("after_feed_cleanup", { feed: feedId });
    report("feed_done", {
      feedId,
      progress: Math.round((feedIndex / feeds.length) * 100),
      nodeCount: graph.nodeCount,
      edgeCount: graph.edgeCount,
    });
  }

  report("edges_complete", { nodeCount: graph.nodeCount, edgeCount: graph.edgeCount });

  if (skippedForMissingStopId > 0) {
    graph.warnings.push(`${skippedForMissingStopId} stop_times rows have no resolved stop_id yet (bus per-trip times not yet joined to StopOfRoute sequence) — excluded from edges, not guessed.`);
  }
  if (headwaySkippedNoStops > 0) {
    graph.warnings.push(`${headwaySkippedNoStops} headway band(s) skipped — no gtfs_route_stops sequence for that route+direction yet.`);
  }
  if (headwayEdgesBuilt > 0) {
    graph.warnings.push(`${headwayEdgesBuilt} headway-based edges built with an ESTIMATED travel time (real distance / assumed ${Math.round(ESTIMATED_BUS_SPEED_MPS * 3.6)} km/h) — no verified TDX stop-to-stop bus travel time source exists yet.`);
  }

  report("build_complete", { nodeCount: graph.nodeCount, edgeCount: graph.edgeCount });
  return graph;
}
