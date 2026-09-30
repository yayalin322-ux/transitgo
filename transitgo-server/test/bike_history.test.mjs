// Hourly YouBike station-history logging (see bikepoller.mjs's startBikeHistoryLogger) — this
// is what will eventually let a page show a real usage-over-time trend for Hsinchu County
// (there's no long-term historical dataset published for the COUNTY, only Hsinchu CITY, so this
// starts genuinely recording from whenever a server with this code first runs).
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

process.env.DB_PATH = join(mkdtempSync(join(tmpdir(), "bike-history-")), "t.db");
delete process.env.DATABASE_URL;
const { logBikeStationSnapshot, getBikeStationHistory } = await import("../src/db.mjs");

let failed = false;
function check(label, cond, detail) { console.log(`${cond ? "PASS" : "FAIL"} - ${label}`); if (!cond) { failed = true; if (detail) console.log("   ", detail); } }

const stationA = { uid: "A1", name: "站A", lat: 24.8, lon: 121.0, capacity: 20, rent: 5, ret: 15 };
const stationB = { uid: "B1", name: "站B", lat: 24.81, lon: 121.01, capacity: 10, rent: 0, ret: 10 };

await logBikeStationSnapshot("HsinchuCounty", [stationA, stationB]);
{
  const rows = await getBikeStationHistory("HsinchuCounty", Date.now() - 60_000);
  check("both stations from the same snapshot are logged", rows.length === 2);
  check("station fields round-trip", rows.some((r) => r.stationUID === "A1" && r.name === "站A" && r.rent === 5 && r.ret === 15 && r.capacity === 20));
  check("recordedAt is a real timestamp", rows.every((r) => !Number.isNaN(Date.parse(r.recordedAt))));
}
{
  // A different city's history never leaks into this one's query.
  await logBikeStationSnapshot("Taipei", [stationA]);
  const rows = await getBikeStationHistory("HsinchuCounty", Date.now() - 60_000);
  check("a different city's snapshot doesn't show up", rows.every((r) => true) && rows.length === 2);
}
{
  // A window that starts after everything was logged sees nothing.
  const rows = await getBikeStationHistory("HsinchuCounty", Date.now() + 60_000);
  check("a future 'since' cutoff returns nothing yet", rows.length === 0);
}
{
  const ok = await logBikeStationSnapshot("HsinchuCounty", []);
  check("logging an empty station list is a harmless no-op", ok === undefined);
  const rows = await getBikeStationHistory("HsinchuCounty", Date.now() - 60_000);
  check("...and doesn't add any rows", rows.length === 2);
}

process.exit(failed ? 1 : 0);
