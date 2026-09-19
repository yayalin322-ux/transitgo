// MANUAL real-data check + performance (not part of npm test):
//   node --expose-gc test/live_bike_routing.mjs
// Live government YouBike feeds (Taipei, New Taipei, Taichung, Kaohsiung, Taoyuan = 7,4xx real stations,
// real availability) + the REAL TDX metro fixture (TRTC/TYMC/NTMC/KRTC) + real TRA/THSR station coordinates.
// The TRA and THSR trains are hand-built (this machine has no TRA/THSR timetable data) — flagged below.
import { DIRECT_FEEDS } from "../src/bikepoller.mjs";
import { buildMrtDb, realResponse } from "./mrtFixture.mjs";
import { railStation } from "./bikeFixture.mjs";
import { buildGraph } from "../src/graph/builder.mjs";
import { addBikeNetwork } from "../src/graph/bikeNetwork.mjs";
import { planRoute } from "../src/routing/api.mjs";
import { createBikeRealtime } from "../src/bike/realtime.mjs";
import { addTimetabled } from "./bikeFixture.mjs";
import { Mode } from "../src/graph/model.mjs";
import { haversineMeters } from "../src/graph/virtual.mjs";

const gc = () => { global.gc?.(); global.gc?.(); return process.memoryUsage().heapUsed / 1048576; };
const cpu = async (fn) => { const c = process.cpuUsage(); const t = performance.now(); const r = await fn(); const u = process.cpuUsage(c); return [r, Math.round((u.user + u.system) / 1000), Math.round(performance.now() - t)]; };

// ---- live data ----
const caches = [];
for (const [city, fn] of Object.entries(DIRECT_FEEDS)) { const stations = await fn(); caches.push({ city, stations, updatedAt: new Date().toISOString() }); }
const all = caches.flatMap((c) => c.stations.map((s) => ({ city: c.city, uid: s.uid, name: s.name, lat: s.lat, lon: s.lon })));
const bikes = caches.flatMap((c) => c.stations), sum = (k) => bikes.reduce((a, s) => a + (s[k] || 0), 0);
console.log(`\n## YouBike live: stations=${bikes.length} (${caches.map((c) => `${c.city} ${c.stations.length}`).join(", ")})  inService=${bikes.filter((s) => s.status === 1).length}  availableBikes=${sum("rent")}  availableDocks=${sum("ret")}  stationsWithNoBike=${bikes.filter((s) => s.status === 1 && s.rent === 0).length}  noDock=${bikes.filter((s) => s.status === 1 && s.ret === 0).length}`);

// ---- graph: real metro + hand-built TRA/THSR ----
const { db } = await buildMrtDb(["TRTC", "TYMC", "NTMC", "KRTC"]);
const graph = await buildGraph(db);
const traTp = railStation("tra", "臺北"), traHc = railStation("tra", "新竹"), hsrTp = railStation("thsr", "台北"), hsrTc = railStation("thsr", "台中");
const D = (h, m) => h * 3600 + m * 60;
for (const [from, to, fn, tn, fp, tp2, mode, rid, a, b] of [
  ["1000", "3300", "臺北", "新竹", traTp, traHc, Mode.TRA, "TRA", D(10, 0), D(10, 54)], ["3300", "1000", "新竹", "臺北", traHc, traTp, Mode.TRA, "TRA", D(10, 0), D(10, 54)],
  ["1000", "1040", "台北", "台中", hsrTp, hsrTc, Mode.HSR, "THSR", D(10, 0), D(10, 50)], ["1040", "1000", "台中", "台北", hsrTc, hsrTp, Mode.HSR, "THSR", D(10, 0), D(10, 50)],
]) addTimetabled(graph, { feed: mode === Mode.TRA ? "TRA" : "THSR", fromId: from, fromName: fn, from: fp, toId: to, toName: tn, to: tp2, mode, routeId: rid, dep: a, arr: b });
const before = { nodes: graph.nodeCount, edges: graph.edgeCount };

// ---- graph size / build cost of the bike layer ----
const heap0 = gc();
const [stats, bikeBuildCpuMs, bikeBuildWallMs] = await cpu(async () => addBikeNetwork(graph, all));
const heap1 = gc();
const after = { nodes: graph.nodeCount, edges: graph.edgeCount };
console.log(`\n## Graph (local: real metro + TRA/THSR stops; NO bus feeds on this machine)\n before: nodes=${before.nodes} edges=${before.edges}\n after : nodes=${after.nodes} edges=${after.edges}   (+${after.nodes - before.nodes} nodes, +${after.edges - before.edges} edges)\n bike layer: stations=${stats.stations} bikeEdges=${stats.bikeEdges} (${(stats.bikeEdges / stats.stations).toFixed(1)}/station) stopLinkEdges=${stats.stopLinkEdges} isolated=${stats.isolated}\n build cost of the layer: cpu=${bikeBuildCpuMs} ms wall=${bikeBuildWallMs} ms   heap retained=${(heap1 - heap0).toFixed(1)} MB  (${((heap1 - heap0) * 1024 / stats.stations).toFixed(2)} KB/station)`);
console.log(` all-pairs would have been ${stats.stations * (stats.stations - 1)} edges; actual bike edges are ${(100 * stats.bikeEdges / (stats.stations * (stats.stations - 1))).toFixed(2)}% of that`);

// ---- realtime: N route queries, how many source reads? ----
let reads = 0;
const rt = createBikeRealtime({ loadCaches: async () => { reads++; return caches; } });
const G10 = { maxWalkingMinutes: 10 };
const plan = (o, d, options = {}) => planRoute(graph, { origin: { lat: o.lat, lng: o.lon ?? o.lng }, destination: { lat: d.lat, lng: d.lon ?? d.lng }, departureTime: "2026-09-21T09:00:00+08:00", options }, db, { bikeRealtime: rt });
const byName = (frag) => bikes.find((s) => s.name.includes(frag));
const metro = (op, id) => { const s = realResponse(op, "Station").find((x) => x.StationID === id); return { name: s.StationName.Zh_tw, lat: s.StationPosition.PositionLat, lon: s.StationPosition.PositionLon }; };
const desc = (r) => `${r.label} ${Math.round(r.durationSeconds / 60)}min transfers=${r.transfers} walk=${Math.round(r.walkingSeconds / 60)}min` + (r.bikeSeconds ? ` bike=${Math.round(r.bikeSeconds / 60)}min/${Math.round(r.bikeDistanceMeters)}m(est)` : "") + `  ${r.segments.map((s) => s.mode === "BIKE" ? `BIKE[${s.fromName}→${s.toName}; ${s.bike.availability.status}${s.bike.availability.rent ? ` bikes=${s.bike.availability.rent.availableBikes} docks@end=${s.bike.availability.return.availableDocks}` : ""}]` : s.mode === "MRT" ? `MRT[${s.line}]` : s.mode === "WALK" ? "WALK" : s.mode).join(" > ")}`;
async function show(title, o, d, options = {}) {
  const [res, cpuMs, wallMs] = await cpu(() => plan(o, d, options));
  console.log(`\n### ${title}\n    origin=${o.name ?? "?"} (${(o.lat).toFixed(4)},${(o.lon ?? o.lng).toFixed(4)}) destination=${d.name ?? "?"}  status=${res.status} cpu=${cpuMs}ms wall=${wallMs}ms`);
  if (res.body.routes) for (const r of res.body.routes) console.log("    " + desc(r));
  else console.log("    " + JSON.stringify(res.body.error));
  return res;
}

// three real YouBike stations
const yb = [byName("捷運中山國中站"), byName("青年公園3號出口"), byName("承德鄭州路口")].map((s) => ({ ...s, lon: s.lon }));
console.log("\n## Real-data routes (live availability; TRA/THSR trains hand-built)");
await show("station -> station: 青年公園3號出口 → 捷運中山國中站 (YouBike to YouBike)", yb[1], yb[0]);
await show("station -> station: 承德鄭州路口 → 青年公園3號出口", yb[2], yb[1]);
await show("station -> station: 捷運中山國中站 → 承德鄭州路口", yb[0], yb[2]);
const nanjing = metro("TRTC", "BL15") ?? metro("TRTC", "G16");
const zhongshanGuozhong = metro("TRTC", "BR10");
await show("origin -> YouBike -> MRT: 青年公園 (walk<=10min) → 南京復興", yb[1], { ...metro("TRTC", "BR11") }, G10);
await show("MRT -> YouBike -> destination: 南京復興 → 青年公園 (walk<=10min)", { ...metro("TRTC", "BR11") }, yb[1], G10);
await show("TRA -> YouBike: 新竹(TRA, hand-built train) → 青年公園", { name: "新竹(TRA)", lat: traHc.lat, lon: traHc.lon }, yb[1], G10);
await show("YouBike -> TRA: 青年公園 → 新竹(TRA)", yb[1], { name: "新竹(TRA)", lat: traHc.lat, lon: traHc.lon }, G10);
await show("HSR -> YouBike: 台中(THSR, hand-built train) → 青年公園", { name: "台中(HSR)", lat: hsrTc.lat, lon: hsrTc.lon }, yb[1], G10);
await show("YouBike -> HSR: 青年公園 → 台中(HSR)", yb[1], { name: "台中(HSR)", lat: hsrTc.lat, lon: hsrTc.lon }, G10);
await show("MRT station -> MRT station (TYMC) with bike on: 台北車站(A1) → 機場第一航廈", { ...metro("TYMC", "A1") }, { ...metro("TYMC", "A12") ?? metro("TYMC", "A13") });

// ---- performance ----
console.log("\n## Performance");
const O = { lat: 25.0478, lon: 121.517 }, Dd = { lat: 25.042, lon: 121.5326 };   // 台北車站 -> 忠孝新生: metro exists with or without the bike
const N = 30;
const noBike = [], withBike = [];
for (let i = 0; i < 5; i++) { await plan(O, Dd); await plan(O, Dd, { allowBike: false }); }   // warm up (lazy spatial indexes)
for (let i = 0; i < N; i++) { const [, c] = await cpu(() => plan(O, Dd, { allowBike: false })); noBike.push(c); }
reads = 0;
for (let i = 0; i < N; i++) { const [, c] = await cpu(() => plan(O, Dd)); withBike.push(c); }
const probe = await plan(O, Dd);
const med = (a) => [...a].sort((x, y) => x - y)[Math.floor(a.length / 2)], p95 = (a) => [...a].sort((x, y) => x - y)[Math.floor(a.length * 0.95)];
console.log(` routing CPU time, ${N} queries, machine is shared/loaded so CPU ms (not wall):  bike off median=${med(noBike)} p95=${p95(noBike)}   bike on median=${med(withBike)} p95=${p95(withBike)}  (result: ${probe.body.routes.length} candidates, ${probe.body.routes.filter((r) => r.bikeSeconds).length} with a bike)`);
console.log(` realtime source reads during ${N} bike-on route queries: ${reads}   (upstream government-feed fetches this run: ${caches.length}, one per city, made by the poller not by queries)`);
const [, coldCpu] = await cpu(async () => { const rt2 = createBikeRealtime({ loadCaches: async () => caches }); await rt2.snapshot(); });
console.log(` first snapshot (derive ${bikes.length} stations) cpu=${coldCpu} ms; cached snapshot afterwards ~0 ms`);
