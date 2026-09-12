import { tdxConfigured, bikeCity } from "./tdx.js";
import { setBikeCache } from "./db.js";

/** One pass: pulls YouBike availability for every configured city and caches it in
 * Firestore, so every app reads a fresh-ish shared snapshot without hitting TDX itself.
 * Called from the scheduled function in index.js.
 *
 * env:
 *   BIKE_CITIES  comma list of TDX city codes (default: Taipei,NewTaipei)
 */
export async function runBikePoll() {
  if (!tdxConfigured()) {
    console.log("[bike] TDX not configured — shared YouBike cache disabled");
    return;
  }
  const cities = (process.env.BIKE_CITIES || "Taipei,NewTaipei").split(",").map((s) => s.trim()).filter(Boolean);
  for (const city of cities) {
    try {
      const rows = await bikeCity(city);
      await setBikeCache(city, rows);
      console.log(`[bike] cached ${city}: ${rows.length} stations`);
    } catch (e) {
      console.warn(`[bike] ${city} failed: ${e.message}`);
    }
  }
}

const R = 6371000;
function haversine(a, b, c, d) {
  const p = Math.PI / 180;
  const x = 0.5 - Math.cos((c - a) * p) / 2 + (Math.cos(a * p) * Math.cos(c * p) * (1 - Math.cos((d - b) * p))) / 2;
  return 2 * R * Math.asin(Math.sqrt(x));
}
export function nearestFrom(stations, lat, lon, radius, limit) {
  return stations
    .map((s) => ({ ...s, distance: Math.round(haversine(lat, lon, s.lat, s.lon)) }))
    .filter((s) => s.distance <= radius)
    .sort((a, b) => a.distance - b.distance)
    .slice(0, limit);
}
