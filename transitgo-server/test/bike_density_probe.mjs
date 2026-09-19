// MANUAL density experiment (not part of npm test): how sparse can bike-to-bike edges be while
// still reaching real destinations? Uses the live government YouBike feeds the poller already reads.
//   node test/bike_density_probe.mjs
import { DIRECT_FEEDS } from "../src/bikepoller.mjs";
import { haversineMeters } from "../src/graph/virtual.mjs";
import { SpatialIndex } from "../src/graph/spatialIndex.mjs";

const all = [];
for (const [city, fn] of Object.entries(DIRECT_FEEDS)) {
  try { const rows = await fn(); for (const r of rows) all.push({ id: `${city}:${r.uid}`, lat: r.lat, lon: r.lon, city }); console.log(city, rows.length); }
  catch (e) { console.log(city, "ERR", e.message); }
}
console.log("total stations", all.length);
const index = new SpatialIndex(all.map((s) => ({ ...s, type: "STATION" })));
const q = (a) => (x) => a[Math.min(a.length - 1, Math.floor(a.length * x))];

// 1) density: neighbours within 500/800/1200 m and nearest-neighbour distance, per city
for (const city of Object.keys(DIRECT_FEEDS)) {
  const cs = all.filter((s) => s.city === city);
  const nn = [], c500 = [], c800 = [], c1200 = [];
  for (const s of cs.filter((_, i) => i % 5 === 0)) {
    const hits = index.near(s.lat, s.lon, 1200, haversineMeters).filter((h) => h.node.id !== s.id).map((h) => h.distanceMeters).sort((a, b) => a - b);
    nn.push(hits[0] ?? Infinity); c500.push(hits.filter((d) => d <= 500).length); c800.push(hits.filter((d) => d <= 800).length); c1200.push(hits.length);
  }
  const s = (a) => [...a].sort((x, y) => x - y);
  const P = (a, p) => Math.round(q(s(a))(p));
  console.log(`${city.padEnd(10)} nearest p50=${P(nn, 0.5)}m p90=${P(nn, 0.9)}m p99=${P(nn, 0.99)}m | within500 median=${P(c500, 0.5)} p90=${P(c500, 0.9)} | within800 median=${P(c800, 0.5)} | within1200 median=${P(c1200, 0.5)} p90=${P(c1200, 0.9)}`);
}

// 2) candidate strategies: fixed radius vs K-nearest (capped by radius)
const strategies = [
  { name: "radius 500", k: Infinity, r: 500 }, { name: "radius 800", k: Infinity, r: 800 }, { name: "radius 1200", k: Infinity, r: 1200 },
  { name: "K=4 r<=1500", k: 4, r: 1500 }, { name: "K=6 r<=1500", k: 6, r: 1500 }, { name: "K=8 r<=1500", k: 8, r: 1500 }, { name: "K=6 r<=2500", k: 6, r: 2500 },
];
const byId = new Map(all.map((s, i) => [s.id, i]));
function build({ k, r }) {
  const adj = all.map(() => new Map());   // symmetric union so a ride can go either way
  let directed = 0;
  for (let i = 0; i < all.length; i++) {
    const s = all[i];
    const near = index.near(s.lat, s.lon, r, haversineMeters).filter((h) => h.node.id !== s.id).sort((a, b) => a.distanceMeters - b.distanceMeters).slice(0, k);
    for (const h of near) { const j = byId.get(h.node.id); adj[i].set(j, h.distanceMeters); if (!adj[j].has(i)) adj[j].set(i, h.distanceMeters); }
    directed += near.length;
  }
  return adj;
}
function dijkstra(adj, src, maxDist) {
  const dist = new Map([[src, 0]]); const pq = [[0, src]];
  while (pq.length) {
    pq.sort((a, b) => a[0] - b[0]); const [d, u] = pq.shift();
    if (d > dist.get(u)) continue; if (d > maxDist) break;
    for (const [v, w] of adj[u]) { const nd = d + w; if (nd < (dist.get(v) ?? Infinity)) { dist.set(v, nd); pq.push([nd, v]); } }
  }
  return dist;
}
// sample origin stations; for target stations 1.5-4 km away (straight line) record reachability and chain/direct ratio
let seed = 42; const rnd = () => (seed = (seed * 1664525 + 1013904223) % 4294967296) / 4294967296;
const samples = Array.from({ length: 120 }, () => all[Math.floor(rnd() * all.length)]);
for (const st of strategies) {
  const adj = build(st);
  const edges = adj.reduce((a, m) => a + m.size, 0);
  const isolated = adj.filter((m) => m.size === 0).length;
  let pairs = 0, reach = 0; const ratios = [];
  for (const s of samples) {
    const src = byId.get(s.id); const dist = dijkstra(adj, src, 9000);
    for (const h of index.near(s.lat, s.lon, 4000, haversineMeters)) {
      if (h.distanceMeters < 1500) continue; pairs++;
      const d = dist.get(byId.get(h.node.id));
      if (d != null) { reach++; ratios.push(d / h.distanceMeters); }
    }
  }
  ratios.sort((a, b) => a - b);
  console.log(`${st.name.padEnd(14)} directed+sym edges=${edges} (per station ${(edges / all.length).toFixed(1)}) isolated=${isolated} (${(100 * isolated / all.length).toFixed(1)}%) | 1.5-4km pairs reachable=${(100 * reach / pairs).toFixed(1)}% chain/straight median=${ratios[Math.floor(ratios.length / 2)]?.toFixed(2)} p90=${ratios[Math.floor(ratios.length * 0.9)]?.toFixed(2)}`);
}
