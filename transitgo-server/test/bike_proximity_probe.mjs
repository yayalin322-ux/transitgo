// MANUAL study (not part of npm test): how close is the nearest real YouBike station to each
// real TRA / THSR / metro station? Live YouBike feeds + TDX station lists (routing credential).
//   node --env-file=.env test/bike_proximity_probe.mjs
import { readFileSync, writeFileSync } from "node:fs";
import { DIRECT_FEEDS } from "../src/bikepoller.mjs";
import { getRouting } from "../src/tdx.mjs";
import { haversineMeters } from "../src/graph/virtual.mjs";
import { SpatialIndex } from "../src/graph/spatialIndex.mjs";

const bikes = [];
for (const [city, fn] of Object.entries(DIRECT_FEEDS)) for (const r of await fn()) bikes.push({ id: `${city}:${r.uid}`, lat: r.lat, lon: r.lon, city, type: "STATION" });
const index = new SpatialIndex(bikes);
const nearest = (lat, lon) => { for (const r of [100, 200, 300, 500, 800, 1200, 2000]) { const h = index.near(lat, lon, r, haversineMeters); if (h.length) return Math.min(...h.map((x) => x.distanceMeters)); } return null; };
const summarize = (label, pts) => {
  const d = pts.map((p) => nearest(p.lat, p.lon));
  const within = (m) => d.filter((x) => x != null && x <= m).length;
  const covered = d.filter((x) => x != null);
  console.log(`${label.padEnd(8)} stations=${pts.length}  nearestBike<=150m:${within(150)}  <=300m:${within(300)}  <=500m:${within(500)}  <=800m:${within(800)}  none within 2km:${d.length - covered.length}  median=${covered.length ? Math.round(covered.sort((a, b) => a - b)[Math.floor(covered.length / 2)]) : "-"}m`);
  return d;
};

// metro: real fixture (TRTC/TYMC/NTMC/KRTC)
const F = JSON.parse(readFileSync(new URL("./fixtures/mrt_real_tdx.json", import.meta.url), "utf8"));
for (const op of ["TRTC", "TYMC", "NTMC"]) summarize(op, F[op].Station.map((s) => ({ lat: s.StationPosition.PositionLat, lon: s.StationPosition.PositionLon })));

// TRA + THSR from TDX (2 calls, paced for the free key)
const tra = await getRouting("v3/Rail/TRA/Station"); await new Promise((r) => setTimeout(r, 15000));
const thsr = await getRouting("v2/Rail/THSR/Station");
const traPts = (tra.Stations ?? tra).map((s) => ({ name: s.StationName.Zh_tw, lat: s.StationPosition.PositionLat, lon: s.StationPosition.PositionLon }));
const thsrPts = thsr.map((s) => ({ name: s.StationName.Zh_tw, lat: s.StationPosition.PositionLat, lon: s.StationPosition.PositionLon }));
// TRA restricted to the 5 covered cities' bounding boxes would be fairer; report both
summarize("TRA(all)", traPts);
const inCovered = traPts.filter((p) => bikes.some((b) => Math.abs(b.lat - p.lat) < 0.05 && Math.abs(b.lon - p.lon) < 0.05));
summarize("TRA(cov)", inCovered);
const dT = summarize("THSR", thsrPts);
thsrPts.forEach((p, i) => console.log("  THSR", p.name, dT[i] == null ? "no YouBike within 2 km (in these 5 cities' feeds)" : `${Math.round(dT[i])} m`));
writeFileSync(new URL("./fixtures/rail_station_coords.json", import.meta.url), JSON.stringify({ capturedAt: new Date().toISOString(), tra: traPts, thsr: thsrPts }));
