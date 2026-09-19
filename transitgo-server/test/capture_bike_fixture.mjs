// One-off capture (not part of npm test): real YouBike station rows (as the poller stores them)
// within 3.5 km of 台北車站, from the live Taipei government feed. Written to test/fixtures/.
import { writeFileSync } from "node:fs";
import { DIRECT_FEEDS } from "../src/bikepoller.mjs";
import { haversineMeters } from "../src/graph/virtual.mjs";
const rows = await DIRECT_FEEDS.Taipei();
const near = rows.filter((r) => haversineMeters(25.0478, 121.517, r.lat, r.lon) <= 3500);
writeFileSync(new URL("./fixtures/bike_real_taipei.json", import.meta.url), JSON.stringify({ capturedAt: new Date().toISOString(), source: "tcgbusfs.blob.core.windows.net youbike_immediate.json via bikepoller", city: "Taipei", stations: near }));
console.log("stations", near.length, "bikes", near.reduce((a, r) => a + r.rent, 0), "docks", near.reduce((a, r) => a + r.ret, 0));
