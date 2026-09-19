import { NodeType, Mode } from "./model.mjs";
import { SpatialIndex } from "./spatialIndex.mjs";
import { haversineMeters } from "./virtual.mjs";

/**
 * Nearest bus stops straight from the loaded routing graph — no TDX call. Bus stop positions are
 * static data the graph already holds, and the graph's stop id IS the TDX StopUID (see
 * realtime/service.mjs stopIdOf), so the app can ask for arrivals with these ids directly.
 *
 * Bus feed id → the TDX scope its arrivals must be requested under. THB is the InterCity feed
 * (公路客運 / 快捷); it is not any city's. Rail and metro feeds are deliberately absent.
 */
export const BUS_FEED_SCOPE = Object.freeze({
  HSZ: "City/Hsinchu",
  HSQ: "City/HsinchuCounty",
  TYC: "City/Taoyuan",
  TPE: "City/Taipei",
  NTC: "City/NewTaipei",
  THB: "InterCity",
});

/** "婦幼館" and "婦幼館站" are the same pole — same rule the app used for its own grouping. */
export function normalizedStopName(name) {
  const s = String(name ?? "");
  return s.endsWith("站") && s.length > 2 ? s.slice(0, -1) : s;
}

const feedOf = (id) => String(id).split(":")[0];
const stopUidOf = (id) => String(id).slice(String(id).indexOf(":") + 1);

function stopIndex(graph) {
  if (!graph._spatialStopIndex) graph._spatialStopIndex = new SpatialIndex(graph.nodes.values());
  return graph._spatialStopIndex;
}

/**
 * Physical stops within `radiusMeters`, nearest first. Entries that share a (normalized) name, or
 * sit within `mergeMeters` of one already kept, are one physical stop carrying every scope+UID
 * under which TDX knows it. `covered` says whether the graph has ANY bus stop within
 * `coverageMeters` of the point — false means "the graph has no bus data here", which the caller
 * must not present as "no bus stops nearby".
 */
export function findNearbyBusStops(graph, lat, lon, { radiusMeters = 500, limit = 6, mergeMeters = 40, coverageMeters = 5000 } = {}) {
  const index = stopIndex(graph);
  const busHits = (radius) => index.near(lat, lon, radius, haversineMeters)
    .filter(({ node }) => node.type === NodeType.STOP && node.mode !== Mode.BIKE && BUS_FEED_SCOPE[feedOf(node.id)])
    .sort((a, b) => a.distanceMeters - b.distanceMeters);

  const hits = busHits(radiusMeters);
  const covered = hits.length > 0 || busHits(coverageMeters).length > 0;

  const groups = [];
  const byName = new Map();
  for (const { node, distanceMeters } of hits) {
    const ref = { scope: BUS_FEED_SCOPE[feedOf(node.id)], stopUID: stopUidOf(node.id) };
    const key = normalizedStopName(node.name);
    let g = byName.get(key);
    if (!g) g = groups.find((x) => haversineMeters(x.lat, x.lon, node.lat, node.lon) < mergeMeters);
    if (g) {
      if (!g.stops.some((s) => s.scope === ref.scope && s.stopUID === ref.stopUID)) g.stops.push(ref);
      byName.set(key, g);
      continue;
    }
    g = { name: node.name, lat: node.lat, lon: node.lon, distanceMeters: Math.round(distanceMeters), stops: [ref] };
    groups.push(g);
    byName.set(key, g);
  }
  // shortest name wins ("婦幼館" over "婦幼館站"), like the app's own merge
  return { covered, stops: groups.slice(0, limit) };
}
