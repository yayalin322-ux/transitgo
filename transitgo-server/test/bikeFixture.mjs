// Shared helpers for the YouBike tests. Everything here is REAL captured data except the two
// hand-built vehicles that stand in for services no local fixture has: a TRA train and a THSR
// train (real station coordinates from test/fixtures/rail_station_coords.json, invented timetable),
// and one bus route (real bike-adjacent coordinates, invented headway). No test here calls the network.
import { readFileSync } from "node:fs";
import { buildMrtDb } from "./mrtFixture.mjs";
import { buildGraph } from "../src/graph/builder.mjs";
import { TransitNode, TransitEdge, NodeType, Mode } from "../src/graph/model.mjs";
import { createBikeRealtime } from "../src/bike/realtime.mjs";
import { createRealtimeCache } from "../src/realtime/cache.mjs";

export const BIKE_REAL = JSON.parse(readFileSync(new URL("./fixtures/bike_real_taipei.json", import.meta.url), "utf8"));
export const RAIL_COORDS = JSON.parse(readFileSync(new URL("./fixtures/rail_station_coords.json", import.meta.url), "utf8"));
export const railStation = (kind, name) => RAIL_COORDS[kind].find((s) => s.name === name);

export const NOW = Date.parse("2026-09-21T09:00:00+08:00");   // Monday morning
export const WEEKDAY = "2026-09-21T09:00:00+08:00";

/** Bike station rows as the poller caches them, with `patch(row)` to force availability in a test. */
export function bikeRows(patch = (r) => r) {
  return BIKE_REAL.stations.map((r) => patch({ ...r }));
}
export const bikeRowByName = (name) => BIKE_REAL.stations.find((r) => r.name.includes(name));

export async function createBikeDb({ operators = ["TRTC"], stations = bikeRows() } = {}) {
  const { db } = await buildMrtDb(operators);
  db.exec(`CREATE TABLE IF NOT EXISTS bike_cache (city TEXT PRIMARY KEY, json TEXT NOT NULL, updated_at TEXT)`);
  db.prepare(`INSERT OR REPLACE INTO bike_cache (city, json, updated_at) VALUES ('Taipei', ?, datetime('now'))`).run(JSON.stringify(stations));
  return db;
}

/** A BikeRealtime over the given rows; `loadCaches` may be replaced to simulate failures. */
export function bikeRealtimeOver(rows, { loadCaches, now = () => NOW, cache = createRealtimeCache({ now }) } = {}) {
  const calls = { loads: 0 };
  const load = loadCaches ?? (async () => [{ city: "Taipei", stations: rows, updatedAt: new Date(NOW - 60_000).toISOString() }]);
  const rt = createBikeRealtime({ loadCaches: async () => { calls.loads++; return load(); }, now, cache, timeoutMs: 200 });
  rt.calls = calls;
  return rt;
}

let seq = 0;
/** A vehicle edge between two synthetic stops, used to stand in for TRA / THSR / bus in a real-coordinate graph. */
export function addTimetabled(graph, { feed, fromId, fromName, from, toId, toName, to, mode, routeId, dep, arr }) {
  for (const [id, name, p] of [[fromId, fromName, from], [toId, toName, to]]) {
    if (!graph.nodes.has(`${feed}:${id}`)) graph.addNode(new TransitNode({ id: `${feed}:${id}`, type: NodeType.STOP, name, lat: p.lat, lon: p.lon }));
  }
  graph.addEdge(new TransitEdge({
    id: `T_${feed}_${seq++}`, fromNodeId: `${feed}:${fromId}`, toNodeId: `${feed}:${toId}`, mode, routeId,
    departureSeconds: dep, arrivalSeconds: arr, travelSeconds: arr - dep, source: "test timetable",
  }));
}
export const addHeadway = (graph, { feed, fromId, fromName, from, toId, toName, to, routeId, headway = 600, travel = 900 }) => {
  for (const [id, name, p] of [[fromId, fromName, from], [toId, toName, to]]) {
    if (!graph.nodes.has(`${feed}:${id}`)) graph.addNode(new TransitNode({ id: `${feed}:${id}`, type: NodeType.STOP, name, lat: p.lat, lon: p.lon }));
  }
  graph.addEdge(new TransitEdge({
    id: `H_${feed}_${seq++}`, fromNodeId: `${feed}:${fromId}`, toNodeId: `${feed}:${toId}`, mode: Mode.BUS, routeId,
    headwaySeconds: headway, windowStartSeconds: 5 * 3600, windowEndSeconds: 23 * 3600, travelSeconds: travel, source: "test headway",
  }));
};

export const at = (seconds) => seconds;   // readability
export { buildGraph };
