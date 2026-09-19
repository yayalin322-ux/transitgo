import { TransitNode, TransitEdge, NodeType, Mode } from "./model.mjs";
import { haversineMeters } from "./virtual.mjs";
import { SpatialIndex } from "./spatialIndex.mjs";
import { BIKE_CONFIG, bikeFeedOf } from "../bike/config.mjs";

export const BIKE_LINK_SOURCE = "Bike estimate (nearest-station link): straight-line distance x detour factor at an assumed riding speed; no bike-path network data";
export const BIKE_STOP_LINK_SOURCE = "Haversine estimate (bike station to nearby stop)";

/** Node id of a bike station: "BIKE_Taipei:500101001" — same feed:stop shape as every other node. */
export const bikeNodeId = (city, uid) => `${bikeFeedOf(city)}:${uid}`;

/** Static station records from the poller's shared cache (city -> JSON blob). Static facts only —
 * position, name, capacity; availability is deliberately NOT read here (it is the realtime overlay). */
export async function loadBikeStations(db) {
  let rows;
  try {
    rows = await db.prepare(`SELECT city, json FROM bike_cache`).all();
  } catch {
    return [];   // no bike_cache table (e.g. a routing-only test database): no bike network, never an error
  }
  const out = [];
  for (const r of rows) {
    let list;
    try { list = JSON.parse(r.json); } catch { continue; }
    for (const s of Array.isArray(list) ? list : []) {
      if (!s?.uid || !Number.isFinite(s.lat) || !Number.isFinite(s.lon)) continue;
      out.push({ city: r.city, uid: String(s.uid), name: s.name || String(s.uid), lat: s.lat, lon: s.lon, capacity: s.capacity ?? null });
    }
  }
  return out;
}

/**
 * Adds the YouBike layer to a built graph: one STATION node per real dock station, sparse
 * bike-to-bike edges, and walking links between each station and the real stops next to it.
 *
 * Sparse on purpose (never all-pairs): each station links to its K nearest stations within a
 * distance cap, found through the spatial index (test/bike_density_probe.mjs picked K and the
 * cap from real station density). A stop link is made only when a stop really is within
 * `stopLinkMaxMeters` — no mode is assumed to have a bike station beside it.
 *
 * Ride distance/time on a bike edge are ESTIMATES (straight line x detour factor / assumed
 * speed) — there is no bike-path network in the data. `straightLineMeters` keeps the input.
 */
export function addBikeNetwork(graph, stations, config = BIKE_CONFIG) {
  const stats = { stations: 0, bikeEdges: 0, stopLinkEdges: 0, stationsWithStopLink: 0, isolated: 0 };
  if (stations.length === 0) return stats;

  const seen = new Set();
  const bikeNodes = [];
  for (const s of stations) {
    const id = bikeNodeId(s.city, s.uid);
    if (seen.has(id)) continue;
    seen.add(id);
    const node = new TransitNode({ id, type: NodeType.STATION, mode: Mode.BIKE, name: s.name, lat: s.lat, lon: s.lon });
    graph.addNode(node);
    bikeNodes.push(node);
  }
  stats.stations = bikeNodes.length;

  // Transit stops only (the default index excludes bike nodes) — built BEFORE any bike edge exists.
  const stopIndex = new SpatialIndex(graph.nodes.values());
  const bikeIndex = new SpatialIndex(bikeNodes, { bikeOnly: true });
  graph._spatialBikeIndex = bikeIndex;
  const feedOf = (id) => String(id).split(":")[0];

  // 1) bike <-> bike: K nearest within the cap, used both ways.
  const ladder = [600, 1200, config.linkMaxMeters].filter((r) => r <= config.linkMaxMeters);
  if (ladder.at(-1) !== config.linkMaxMeters) ladder.push(config.linkMaxMeters);
  const linked = new Set();
  const degree = new Map();
  for (const a of bikeNodes) {
    let near = [];
    for (const r of ladder) {   // smallest radius that already holds K stations: those ARE the K nearest overall
      near = bikeIndex.near(a.lat, a.lon, r, haversineMeters).filter((h) => h.node.id !== a.id);
      if (near.length >= config.linkNearestK) break;
    }
    near.sort((x, y) => x.distanceMeters - y.distanceMeters);
    for (const { node: b, distanceMeters } of near.slice(0, config.linkNearestK)) {
      const key = a.id < b.id ? `${a.id}|${b.id}` : `${b.id}|${a.id}`;
      if (linked.has(key)) continue;
      linked.add(key);
      const estimated = Math.round(distanceMeters * config.detourFactor);
      const travelSeconds = Math.max(1, Math.round(estimated / config.speedMps));
      for (const [from, to] of [[a.id, b.id], [b.id, a.id]]) {
        graph.addEdge(new TransitEdge({
          id: `BIKE_${from}_${to}`,
          fromNodeId: from, toNodeId: to, mode: Mode.BIKE,
          travelSeconds, distanceMeters: estimated, straightLineMeters: Math.round(distanceMeters),
          source: BIKE_LINK_SOURCE,
        }));
        stats.bikeEdges++;
        degree.set(from, (degree.get(from) ?? 0) + 1);
      }
    }
  }
  stats.isolated = bikeNodes.filter((n) => !degree.has(n.id)).length;

  // 2) bike <-> real stops: nearest stop of each feed within the radius, plus that stop's co-located
  //    siblings (a metro station's other line-node stands on the same spot). Foot pass-through at a
  //    dock is forbidden in the router, so linking siblings cannot create a walking shortcut.
  const COLOCATED_METERS = 40, MAX_PER_FEED = 4;
  for (const a of bikeNodes) {
    const nearby = stopIndex.near(a.lat, a.lon, config.stopLinkMaxMeters, haversineMeters);
    if (nearby.length === 0) continue;
    const byFeed = new Map();
    for (const h of nearby) {
      const f = feedOf(h.node.id);
      if (!byFeed.has(f)) byFeed.set(f, []);
      byFeed.get(f).push(h);
    }
    let any = false;
    for (const hits of byFeed.values()) {
      hits.sort((x, y) => x.distanceMeters - y.distanceMeters);
      const nearest = hits[0];
      const group = hits.filter((h) => h === nearest || haversineMeters(nearest.node.lat, nearest.node.lon, h.node.lat, h.node.lon) <= COLOCATED_METERS).slice(0, MAX_PER_FEED);
      for (const { node: stop, distanceMeters } of group) {
        const seconds = Math.max(1, Math.round(distanceMeters / config.walkingSpeedMps));
        for (const [from, to] of [[a.id, stop.id], [stop.id, a.id]]) {
          graph.addEdge(new TransitEdge({
            id: `BIKE_LINK_${from}_${to}`,
            fromNodeId: from, toNodeId: to, mode: Mode.WALK,
            travelSeconds: seconds, distanceMeters,
            source: BIKE_STOP_LINK_SOURCE,
          }));
          stats.stopLinkEdges++;
        }
        any = true;
      }
    }
    if (any) stats.stationsWithStopLink++;
  }
  return stats;
}
