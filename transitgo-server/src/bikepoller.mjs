import cron from "node-cron";
import { tdxConfigured, bikeCity } from "./tdx.mjs";
import { setBikeCache } from "./db.mjs";

/**
 * Periodically pulls YouBike availability for the configured cities from TDX and
 * caches it, so every app can read a fresh-ish shared snapshot without each device
 * hitting TDX itself.
 *
 * env:
 *   BIKE_CITIES        comma list of TDX city codes (default: Taipei,NewTaipei)
 *   BIKE_POLL_MINUTES  refresh interval (default: 2)
 */
export function startBikePoller() {
  if (!tdxConfigured()) {
    console.log("[bike] TDX not configured — shared YouBike cache disabled");
    return;
  }
  const cities = (process.env.BIKE_CITIES || "Taipei,NewTaipei")
    .split(",").map((s) => s.trim()).filter(Boolean);
  const minutes = Math.max(1, parseInt(process.env.BIKE_POLL_MINUTES || "2", 10));

  const run = async () => {
    for (const city of cities) {
      try {
        const rows = await bikeCity(city);
        setBikeCache(city, rows);
        console.log(`[bike] cached ${city}: ${rows.length} stations`);
      } catch (e) {
        console.warn(`[bike] ${city} failed: ${e.message}`);
      }
    }
  };
  run();
  cron.schedule(`*/${minutes} * * * *`, run);
  console.log(`[bike] polling ${cities.join(", ")} every ${minutes} min`);
}

const R = 6371000;
function haversine(a, b, c, d) {
  const p = Math.PI / 180;
  const x =
    0.5 - Math.cos((c - a) * p) / 2 +
    (Math.cos(a * p) * Math.cos(c * p) * (1 - Math.cos((d - b) * p))) / 2;
  return 2 * R * Math.asin(Math.sqrt(x));
}
export function nearestFrom(stations, lat, lon, radius, limit) {
  return stations
    .map((s) => ({ ...s, distance: Math.round(haversine(lat, lon, s.lat, s.lon)) }))
    .filter((s) => s.distance <= radius)
    .sort((a, b) => a.distance - b.distance)
    .slice(0, limit);
}
