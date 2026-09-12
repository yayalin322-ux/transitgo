import { TransitNode, TransitEdge, NodeType, Mode } from "./model.mjs";

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
 * 500m → 800m → 1200m, capped at maxRadius — architecture doc section 13. Linear scan
 * over graph.nodes is fine at city/regional graph scale; a graph spanning all of Taiwan
 * would want a spatial index here instead (grid bucket / R-tree), not a rewrite of the
 * calling contract — swap this function's internals only.
 */
export function findNearbyStops(graph, lat, lon, { radii = [500, 800, 1200], maxRadius = 1200 } = {}) {
  for (const radius of radii) {
    if (radius > maxRadius) break;
    const hits = [];
    for (const node of graph.nodes.values()) {
      if (node.type === NodeType.VIRTUAL || node.lat == null || node.lon == null) continue;
      const d = haversineMeters(lat, lon, node.lat, node.lon);
      if (d <= radius) hits.push({ node, distanceMeters: d });
    }
    if (hits.length > 0) return hits.sort((a, b) => a.distanceMeters - b.distanceMeters);
  }
  return [];
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
