/** Node/edge shapes for the Multimodal Graph — see the architecture doc section 3. */

export const NodeType = Object.freeze({
  STOP: "STOP",
  STATION: "STATION",
  ENTRANCE: "ENTRANCE",
  WALKING_POINT: "WALKING_POINT",
  VIRTUAL: "VIRTUAL",
});

export const Mode = Object.freeze({
  WALK: "WALK",
  BUS: "BUS",
  MRT: "MRT",
  TRA: "TRA",
  HSR: "HSR",
  BIKE: "BIKE",
  FERRY: "FERRY",
});

export class TransitNode {
  constructor({ id, type, mode = null, name = null, lat = null, lon = null, parentStationId = null }) {
    this.id = id;
    this.type = type;
    this.mode = mode;
    this.name = name;
    this.lat = lat;
    this.lon = lon;
    this.parentStationId = parentStationId;
  }
}

/**
 * One directed hop, already time-resolved for the specific departure it represents (a
 * time-dependent edge, not a flat "duration = 20 minutes" — see architecture doc
 * section 4/5). `headwaySeconds` is set instead of fixed departure/arrival times for a
 * route that only has real TDX headway data (see transit_route_frequency) — the Routing
 * Engine resolves an actual wait against the query time, it isn't baked in here.
 */
export class TransitEdge {
  constructor({
    id, fromNodeId, toNodeId, mode, routeId = null,
    departureSeconds = null, arrivalSeconds = null,
    headwaySeconds = null, travelSeconds = null,
    distanceMeters = null, fare = null, source,
  }) {
    this.id = id;
    this.fromNodeId = fromNodeId;
    this.toNodeId = toNodeId;
    this.mode = mode;
    this.routeId = routeId;
    this.departureSeconds = departureSeconds;
    this.arrivalSeconds = arrivalSeconds;
    this.headwaySeconds = headwaySeconds;
    this.travelSeconds = travelSeconds;
    this.distanceMeters = distanceMeters;
    this.fare = fare;
    this.source = source;   // e.g. "TDX real timetable", "TDX real headway", "walk estimate"
  }
  get isTimeDependent() { return this.departureSeconds != null; }
  get isHeadwayBased() { return this.headwaySeconds != null; }
}

/** "HH:MM" or "HH:MM:SS" (GTFS allows past 24:00:00 for a post-midnight trip) → seconds since midnight. */
export function parseGtfsTime(hhmmss) {
  if (!hhmmss) return null;
  const parts = hhmmss.split(":").map((n) => parseInt(n, 10));
  if (parts.length < 2 || parts.some(Number.isNaN)) return null;
  const [h, m, s = 0] = parts;
  return h * 3600 + m * 60 + s;
}

export class MultimodalGraph {
  constructor() {
    /** @type {Map<string, TransitNode>} */
    this.nodes = new Map();
    /** @type {Map<string, TransitEdge[]>} */
    this.edgesByFrom = new Map();
    this.builtAt = null;
    this.dataVersion = null;
  }

  addNode(node) {
    this.nodes.set(node.id, node);
  }

  addEdge(edge) {
    if (!this.edgesByFrom.has(edge.fromNodeId)) this.edgesByFrom.set(edge.fromNodeId, []);
    this.edgesByFrom.get(edge.fromNodeId).push(edge);
  }

  /** O(1) adjacency lookup — the whole point of building this in memory (architecture doc section 17). */
  neighbors(nodeId) {
    return this.edgesByFrom.get(nodeId) ?? [];
  }

  get nodeCount() { return this.nodes.size; }
  get edgeCount() {
    let n = 0;
    for (const list of this.edgesByFrom.values()) n += list.length;
    return n;
  }
}
