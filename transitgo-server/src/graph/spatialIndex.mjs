import { NodeType } from "./model.mjs";

/**
 * A grid-bucket spatial index over a graph's real (non-virtual) stop nodes — swaps out
 * findNearbyStops()'s linear scan (see virtual.mjs's own comment: "fine at city/regional
 * graph scale; a graph spanning all of Taiwan would want a spatial index here instead")
 * now that the graph genuinely is national scale (~76k nodes as of the multi-city +
 * TRA/THSR ingest). A grid is the simplest structure that actually fixes the problem —
 * not an R-tree/KD-tree, but O(cells near the query) instead of O(every node in Taiwan)
 * for every single route request. Exposed as its own small class (not inlined into
 * virtual.mjs) specifically so a future R-tree/KD-tree swap only touches this file.
 *
 * Cell size ≈1.1km at the equator (0.01°) — small enough that even the tightest walking
 * radius this app uses only ever touches a handful of cells, big enough that a normal
 * stop density doesn't blow up the bucket count.
 */
const CELL_DEGREES = 0.01;

function cellKey(lat, lon) {
  return `${Math.floor(lat / CELL_DEGREES)}:${Math.floor(lon / CELL_DEGREES)}`;
}

export class SpatialIndex {
  constructor(nodes) {
    /** @type {Map<string, object[]>} */
    this.cells = new Map();
    for (const node of nodes) {
      if (node.type === NodeType.VIRTUAL || node.lat == null || node.lon == null) continue;
      const key = cellKey(node.lat, node.lon);
      if (!this.cells.has(key)) this.cells.set(key, []);
      this.cells.get(key).push(node);
    }
  }

  /** Every indexed node within `radiusMeters` of (lat, lon) — same real nodes a linear
   * scan over the whole graph would find, just without touching every node to find them.
   * Real haversine distance is still computed per candidate (the grid only narrows which
   * nodes are worth measuring, it never approximates the distance itself). */
  near(lat, lon, radiusMeters, haversineMeters) {
    // A degree of longitude shrinks toward the poles; latitude doesn't. Using latitude's
    // fixed ~111km/degree for both keeps this a safe (if slightly generous at higher
    // latitudes) radius-to-cell-count conversion without a per-latitude cosine
    // correction that would just add complexity for a country as latitude-narrow as
    // Taiwan (~22-25°N).
    const cellSpanMeters = CELL_DEGREES * 111_000;
    const cellRadius = Math.max(1, Math.ceil(radiusMeters / cellSpanMeters));
    const centerCellLat = Math.floor(lat / CELL_DEGREES);
    const centerCellLon = Math.floor(lon / CELL_DEGREES);

    const hits = [];
    for (let dLat = -cellRadius; dLat <= cellRadius; dLat++) {
      for (let dLon = -cellRadius; dLon <= cellRadius; dLon++) {
        const bucket = this.cells.get(`${centerCellLat + dLat}:${centerCellLon + dLon}`);
        if (!bucket) continue;
        for (const node of bucket) {
          const d = haversineMeters(lat, lon, node.lat, node.lon);
          if (d <= radiusMeters) hits.push({ node, distanceMeters: d });
        }
      }
    }
    return hits;
  }
}
