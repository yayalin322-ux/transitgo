import { TransitNode, TransitEdge, NodeType, Mode } from "./model.mjs";
import { SpatialIndex } from "./spatialIndex.mjs";
import { logMemory } from "./memlog.mjs";

const R = 6371000;
export function haversineMeters(lat1, lon1, lat2, lon2) {
  const p = Math.PI / 180;
  const x = 0.5 - Math.cos((lat2 - lat1) * p) / 2
    + (Math.cos(lat1 * p) * Math.cos(lat2 * p) * (1 - Math.cos((lon2 - lon1) * p))) / 2;
  return 2 * R * Math.asin(Math.sqrt(x));
}

/**
 * Default walking speed — architecture doc section 14: "把 walkingSpeed 做成設定值...
 * 未來可以替換成真正 Walking Routing". Haversine/speed is a deliberate first-pass
 * estimate, not a claim of real walking-route distance; callers can pass a different
 * speed (e.g. from WalkingSpeedLearner-style personalization) without touching this
 * module's logic.
 */
export const DEFAULT_WALKING_SPEED_MPS = 1.3;

/**
 * 500m → 800m → 1200m, capped at maxRadius — architecture doc section 13.
 *
 * Backed by a grid-bucket SpatialIndex (see graph/spatialIndex.mjs), built once per
 * graph and cached on the graph object itself (`graph._spatialStopIndex`) — a linear
 * scan over every node was fine at city/regional scale, but the graph is genuinely
 * national scale now (~76k nodes after the multi-city + TRA/THSR ingest), and this
 * function runs on every single route request. Real stop nodes never change after a
 * graph is built (a rebuild creates a whole new graph instance, never mutates stops in
 * place), so a cache built on first use stays correct for the graph's entire lifetime —
 * no invalidation logic needed. Falls back to the original full scan if anything about
 * the index looks wrong, so a bug here degrades to "slower," never "wrong answer."
 */
export function findNearbyStops(graph, lat, lon, { radii = [500, 800, 1200], maxRadius = 1200 } = {}) {
  // A caller passing a maxRadius below the smallest preset step (e.g. a short
  // maxWalkingMeters) used to make every preset radius fail the `radius > maxRadius`
  // check on the very first iteration, returning [] unconditionally — even for a stop
  // sitting at 0 meters. maxRadius itself must always be a real, tried step, not just an
  // upper bound the preset list happens to respect.
  const steps = [...new Set([...radii.filter((r) => r < maxRadius), maxRadius])];

  let index = graph._spatialStopIndex;
  if (!index) {
    // Lazy, first-use-only build (see doc comment above) — logged so a memory profile of
    // the process can attribute this one-time cost to the spatial index rather than
    // mistaking it for graph-build or routing-request growth.
    logMemory("before_spatial_index", { nodeCount: graph.nodeCount });
    try {
      index = new SpatialIndex(graph.nodes.values());
      graph._spatialStopIndex = index;
    } catch {
      index = null;   // fall through to the linear scan below
    }
    logMemory("after_spatial_index", { nodeCount: graph.nodeCount, indexBuilt: index !== null });
  }

  for (const radius of steps) {
    const hits = index
      ? index.near(lat, lon, radius, haversineMeters)
      : linearScanNearby(graph, lat, lon, radius);
    if (hits.length > 0) return hits.sort((a, b) => a.distanceMeters - b.distanceMeters);
  }
  return [];
}

function linearScanNearby(graph, lat, lon, radius) {
  const hits = [];
  for (const node of graph.nodes.values()) {
    if (node.type === NodeType.VIRTUAL || node.lat == null || node.lon == null) continue;
    const d = haversineMeters(lat, lon, node.lat, node.lon);
    if (d <= radius) hits.push({ node, distanceMeters: d });
  }
  return hits;
}

function walkSeconds(distanceMeters, walkingSpeedMps) {
  return Math.round(distanceMeters / walkingSpeedMps);
}

/**
 * Adds a VIRTUAL origin node at (lat, lon) plus a real WALK edge to every stop found
 * nearby (architecture doc section 2/6). Returns the virtual node's id, or null if
 * nothing is within maxWalkingDistance — callers must handle that as a real "no nearby
 * transit" error (section 18 #1), not retry silently forever.
 */
export function attachVirtualOrigin(graph, id, lat, lon, { walkingSpeedMps = DEFAULT_WALKING_SPEED_MPS, maxWalkingMeters = 1200 } = {}) {
  const nearby = findNearbyStops(graph, lat, lon, { maxRadius: maxWalkingMeters });
  if (nearby.length === 0) return null;

  graph.addNode(new TransitNode({ id, type: NodeType.VIRTUAL, lat, lon, name: "起點" }));
  for (const { node, distanceMeters } of nearby) {
    graph.addEdge(new TransitEdge({
      id: `walk_${id}_to_${node.id}`,
      fromNodeId: id, toNodeId: node.id, mode: Mode.WALK,
      travelSeconds: walkSeconds(distanceMeters, walkingSpeedMps),
      distanceMeters, source: "Haversine estimate",
    }));
  }
  return id;
}

/** Same idea, reversed — real stops get a WALK edge INTO the virtual destination. */
export function attachVirtualDestination(graph, id, lat, lon, { walkingSpeedMps = DEFAULT_WALKING_SPEED_MPS, maxWalkingMeters = 1200 } = {}) {
  const nearby = findNearbyStops(graph, lat, lon, { maxRadius: maxWalkingMeters });
  if (nearby.length === 0) return null;

  graph.addNode(new TransitNode({ id, type: NodeType.VIRTUAL, lat, lon, name: "目的地" }));
  for (const { node, distanceMeters } of nearby) {
    graph.addEdge(new TransitEdge({
      id: `walk_${node.id}_to_${id}`,
      fromNodeId: node.id, toNodeId: id, mode: Mode.WALK,
      travelSeconds: walkSeconds(distanceMeters, walkingSpeedMps),
      distanceMeters, source: "Haversine estimate",
    }));
  }
  return id;
}
