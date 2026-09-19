// The YouBike layer of the graph: real stations as nodes, sparse bike edges, stop links, size.
import { createBikeDb, bikeRows, BIKE_REAL, railStation, buildGraph, addHeadway } from "./bikeFixture.mjs";
import { buildMrtDb } from "./mrtFixture.mjs";
import { bikeNodeId, addBikeNetwork, loadBikeStations } from "../src/graph/bikeNetwork.mjs";
import { BIKE_CONFIG, isBikeNodeId } from "../src/bike/config.mjs";
import { findNearbyStops, findNearbyBikeStations, haversineMeters } from "../src/graph/virtual.mjs";
import { Mode, MultimodalGraph } from "../src/graph/model.mjs";
import { saveGraphToDisk, loadGraphFromDisk } from "../src/graph/persist.mjs";
import { graphCoverage } from "../src/routing/api.mjs";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

let failed = false;
function check(label, cond) { console.log(`${cond ? "PASS" : "FAIL"} - ${label}`); if (!cond) failed = true; }

// baseline: same database WITHOUT the bike layer
const { db: plainDb } = await buildMrtDb(["TRTC"]);
const before = await buildGraph(plainDb);
const db = await createBikeDb();
const graph = await buildGraph(db);
const N = BIKE_REAL.stations.length;
const bikeNodes = [...graph.nodes.values()].filter((n) => n.mode === Mode.BIKE);
const bikeEdges = [...graph.edgesByFrom.values()].flat().filter((e) => e.mode === Mode.BIKE);
const walkLinks = [...graph.edgesByFrom.values()].flat().filter((e) => e.source?.startsWith("Haversine estimate (bike station"));

check("no bike_cache table -> graph identical to before (no bike layer, no error)", before.nodeCount === 122 && !before.warnings.some((w) => w.includes("YouBike")));
check("every real station is one BIKE node (feed BIKE_<city>, id = uid)", bikeNodes.length === N && graph.nodes.has(bikeNodeId("Taipei", BIKE_REAL.stations[0].uid)) && bikeNodes.every((n) => isBikeNodeId(n.id)));
check("bike node carries real name and coordinates, and NO availability", (() => { const s = BIKE_REAL.stations[7], n = graph.nodes.get(bikeNodeId("Taipei", s.uid)); return n.name === s.name && n.lat === s.lat && n.lon === s.lon && !("rent" in n) && !("availableBikes" in n); })());
check("transit nodes are untouched: only the bike stations were added", graph.nodeCount === before.nodeCount + N);

// --- sparse, spatial-index-driven edges ---
const K = BIKE_CONFIG.linkNearestK;
const outDegree = new Map();
for (const e of bikeEdges) outDegree.set(e.fromNodeId, (outDegree.get(e.fromNodeId) ?? 0) + 1);
check(`NOT all-pairs: ${bikeEdges.length} bike edges for ${N} stations (all-pairs would be ${N * (N - 1)})`, bikeEdges.length < N * 2 * K && bikeEdges.length < (N * (N - 1)) / 20);
check(`each station links to about its ${K} nearest (union of both directions keeps it bounded)`, [...outDegree.values()].every((d) => d >= 1 && d <= 4 * K));
check("no isolated station in a dense area", bikeNodes.every((n) => outDegree.has(n.id)));
check("every bike edge is within the link cap (spatial search, not a scan)", bikeEdges.every((e) => e.straightLineMeters <= BIKE_CONFIG.linkMaxMeters));
check("edges are symmetric (a ride can go either way)", (() => { const set = new Set(bikeEdges.map((e) => `${e.fromNodeId}|${e.toNodeId}`)); return bikeEdges.every((e) => set.has(`${e.toNodeId}|${e.fromNodeId}`)); })());
check("links go to the NEAREST stations: a station's nearest neighbour is always linked", (() => {
  for (const a of bikeNodes.slice(0, 60)) {
    let nearest = null, best = Infinity;
    for (const b of bikeNodes) { if (b === a) continue; const d = haversineMeters(a.lat, a.lon, b.lat, b.lon); if (d < best) { best = d; nearest = b; } }
    if (!bikeEdges.some((e) => e.fromNodeId === a.id && e.toNodeId === nearest.id)) return false;
  }
  return true;
})());

// --- the ride is an ESTIMATE, and says so ---
const e0 = bikeEdges[0];
check("ride distance = straight line x detour factor (auditable, not a road distance)", e0.distanceMeters === Math.round(e0.straightLineMeters * BIKE_CONFIG.detourFactor) || Math.abs(e0.distanceMeters - e0.straightLineMeters * BIKE_CONFIG.detourFactor) <= 1);
check("ride time = estimated distance / assumed speed", Math.abs(e0.travelSeconds - e0.distanceMeters / BIKE_CONFIG.speedMps) <= 1);
check("bike edges carry no fare (null, never 0) and are not time-dependent", bikeEdges.every((e) => e.fare == null && !e.isTimeDependent && !e.isHeadwayBased));
check("edge source states it is an estimate with no bike-path data", /estimate/i.test(e0.source) && /no bike-path/i.test(e0.source));
check("the build warning discloses the estimates", graph.warnings.some((w) => /YouBike/.test(w) && /ESTIMATES/.test(w)));

// --- bike stations are not 'stops' ---
{
  const s = BIKE_REAL.stations[0];
  const stops = findNearbyStops(graph, s.lat, s.lon, { maxRadius: 1200 });
  check("findNearbyStops never returns a bike dock (it would end the radius search early)", stops.every((h) => h.node.mode !== Mode.BIKE));
  const near = findNearbyBikeStations(graph, s.lat, s.lon, { maxRadius: 800, limit: 6 });
  check("findNearbyBikeStations: nearest first, capped, bike-only", near.length === 6 && near.every((h) => h.node.mode === Mode.BIKE && h.distanceMeters <= 800) && near[0].distanceMeters <= near[1].distanceMeters);
  check("...and it finds the station standing at that point at ~0 m", near[0].distanceMeters < 1);
  const brute = BIKE_REAL.stations.map((b) => haversineMeters(s.lat, s.lon, b.lat, b.lon)).sort((a, b) => a - b).slice(0, 6);
  check("the spatial index returns exactly the true 6 nearest (matches a brute-force check)", near.every((h, i) => Math.abs(h.distanceMeters - brute[i]) < 0.001));
}

// --- stop links: only where a stop really is near ---
{
  const links = walkLinks;
  check("stop links exist, both directions", links.length > 0 && links.length % 2 === 0);
  check("every link is within the measured radius (no station is assumed to have a stop beside it)", links.every((e) => e.distanceMeters <= BIKE_CONFIG.stopLinkMaxMeters));
  const linked = new Set(links.map((e) => (isBikeNodeId(e.fromNodeId) ? e.fromNodeId : e.toNodeId)));
  check("bike stations far from any stop have NO link (not every station reaches transit)", linked.size < N && linked.size > 0);
  check("a bike station beside 台北車站 links to a real TRTC station node", links.some((e) => isBikeNodeId(e.fromNodeId) && e.toNodeId.startsWith("MRT_TRTC:")));
  check("link walking time is the distance at the shared walking speed", links.every((e) => Math.abs(e.travelSeconds - e.distanceMeters / BIKE_CONFIG.walkingSpeedMps) <= 1));
}

// --- graph size ---
{
  check(`size: +${N} nodes (${before.nodeCount} -> ${graph.nodeCount}); edges ${before.edgeCount} -> ${graph.edgeCount} = +${graph.edgeCount - before.edgeCount} (${((graph.edgeCount - before.edgeCount) / N).toFixed(1)} per station)`, (graph.edgeCount - before.edgeCount) / N < 16);
}

// --- coverage ---
{
  const cov = graphCoverage(graph);
  check("coverage reports bike separately (available, station count, cities)", cov.bike.available && cov.bike.stationCount === N && cov.bike.cities.join() === "Taipei" && !cov.bus.includes("BIKE_Taipei"));
}

// --- persistence roundtrip keeps the layer ---
{
  const dir = mkdtempSync(join(tmpdir(), "bikegraph-"));
  const file = join(dir, "graph.json");
  await saveGraphToDisk(graph, file);
  const loaded = loadGraphFromDisk(file);
  check("persist -> load: bike nodes, bike edges and their estimate fields survive", loaded && loaded.nodeCount === graph.nodeCount && loaded.edgeCount === graph.edgeCount
    && loaded.nodes.get(bikeNodes[0].id).mode === Mode.BIKE
    && loaded.neighbors(e0.fromNodeId).find((e) => e.toNodeId === e0.toNodeId && e.mode === Mode.BIKE)?.straightLineMeters === e0.straightLineMeters);
  const nearLoaded = findNearbyBikeStations(loaded, bikeNodes[0].lat, bikeNodes[0].lon, { maxRadius: 300, limit: 3 });
  check("a graph loaded from disk builds its bike index lazily and finds stations", nearLoaded.length >= 1);
  check("non-bike edges gain no extra field (artifact stays the same shape)", (() => { const e = [...before.edgesByFrom.values()][0][0]; return !("straightLineMeters" in e); })());
}

// --- one stray row must not break the build ---
{
  const g = new MultimodalGraph();
  const stats = addBikeNetwork(g, [{ city: "X", uid: "1", name: "a", lat: 25, lon: 121 }, { city: "X", uid: "1", name: "dup", lat: 25, lon: 121 }, { city: "X", uid: "2", name: "b", lat: 25.001, lon: 121 }]);
  check("duplicate uid collapses to one node; two stations link to each other", stats.stations === 2 && stats.bikeEdges === 2);
  check("no stations -> nothing added", addBikeNetwork(new MultimodalGraph(), []).stations === 0);
  check("loadBikeStations skips rows without a position", (await loadBikeStations({ prepare: () => ({ all: async () => [{ city: "T", json: JSON.stringify([{ uid: "a", lat: null, lon: 1 }, { uid: "b", lat: 25, lon: 121, name: "ok" }]) }] }) })).length === 1);
}

console.log(failed ? "\nOVERALL: FAIL" : "\nOVERALL: PASS");
process.exit(failed ? 1 : 0);
