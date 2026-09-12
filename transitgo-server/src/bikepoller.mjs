import cron from "node-cron";
import { tdxConfigured, bikeCity } from "./tdx.mjs";
import { setBikeCache } from "./db.mjs";

/**
 * Some cities publish their own YouBike snapshot directly — no auth, no rate limit at all
 * (unlike TDX's ~5 req/min budget shared with every other TDX call this server and every
 * app instance makes). Pulling these from source instead of TDX takes real pressure off
 * that shared budget, especially for the highest-traffic cities.
 */
async function fetchTaipeiDirect() {
  const res = await fetch("https://tcgbusfs.blob.core.windows.net/dotapp/youbike/v2/youbike_immediate.json", {
    signal: AbortSignal.timeout(15_000),
  });
  if (!res.ok) throw new Error(`HTTP ${res.status}`);
  const rows = await res.json();
  return rows
    .filter((r) => r.latitude != null && r.longitude != null)
    .map((r) => ({
      uid: r.sno,
      name: (r.sna || "").replace(/^YouBike\d\.\d_/, ""),
      city: "Taipei",
      lat: r.latitude, lon: r.longitude,
      address: r.ar || "",
      capacity: r.Quantity ?? null,
      rent: r.available_rent_bikes ?? 0,
      ret: r.available_return_bikes ?? 0,
      // This feed doesn't split rentable bikes into general/electric like TDX's detail
      // endpoint does — the app's "電輔車限定" filter just won't have anything to show
      // for Taipei stations. Total counts (rent/ret/capacity) are unaffected.
      general: null,
      electric: null,
      status: r.act === "1" ? 1 : 0,
      src: r.srcUpdateTime || null,
    }));
}

/** New Taipei's feed is CSV, not JSON, but does split general/electric bikes. */
async function fetchNewTaipeiDirect() {
  const res = await fetch("https://data.ntpc.gov.tw/api/datasets/010e5b15-3823-4b20-b401-b1cf000550c5/csv/file", {
    signal: AbortSignal.timeout(15_000),
  });
  if (!res.ok) throw new Error(`HTTP ${res.status}`);
  const text = await res.text();
  const rows = parseCsv(text);
  return rows
    .filter((r) => r.lat && r.lng)
    .map((r) => ({
      uid: r.sno,
      name: (r.sna || "").replace(/^YouBike\d\.\d_/, ""),
      city: "NewTaipei",
      lat: parseFloat(r.lat), lon: parseFloat(r.lng),
      address: r.ar || "",
      capacity: r.tot_quantity != null ? parseInt(r.tot_quantity, 10) : null,
      rent: parseInt(r.sbi_quantity, 10) || 0,
      ret: parseInt(r.bemp, 10) || 0,
      general: r.yb2_quantity != null ? parseInt(r.yb2_quantity, 10) : null,
      electric: r.eyb_quantity != null ? parseInt(r.eyb_quantity, 10) : null,
      status: r.act === "1" ? 1 : 0,
      src: r.mday || null,
    }));
}

/** Taichung's feed splits general/electric as a single "8,0" string field. */
async function fetchTaichungDirect() {
  const res = await fetch("https://newdatacenter.taichung.gov.tw/api/v1/no-auth/resource.download?rid=9468c0d0-e1ed-4ecc-a86f-ab5a9fd590ff", {
    signal: AbortSignal.timeout(15_000),
  });
  if (!res.ok) throw new Error(`HTTP ${res.status}`);
  const rows = await res.json();
  return rows
    .filter((r) => r.lat && r.lng)
    .map((r) => {
      const [general, electric] = String(r.sbi_detail || "").split(",").map((n) => parseInt(n, 10));
      return {
        uid: r.sno,
        name: (r.sna || "").replace(/^YouBike\d\.\d_/, ""),
        city: "Taichung",
        lat: parseFloat(r.lat), lon: parseFloat(r.lng),
        address: r.ar || "",
        capacity: r.tot != null ? parseInt(r.tot, 10) : null,
        rent: parseInt(r.sbi, 10) || 0,
        ret: parseInt(r.bemp, 10) || 0,
        general: Number.isFinite(general) ? general : null,
        electric: Number.isFinite(electric) ? electric : null,
        status: r.act === "1" ? 1 : 0,
        src: r.mday || null,
      };
    });
}

/** Minimal CSV parser — good enough for these government feeds (quoted fields, no embedded newlines). */
function parseCsv(text) {
  const lines = text.replace(/^﻿/, "").split(/\r?\n/).filter(Boolean);
  if (lines.length < 2) return [];
  const headers = splitCsvLine(lines[0]);
  return lines.slice(1).map((line) => {
    const cols = splitCsvLine(line);
    const row = {};
    headers.forEach((h, i) => { row[h] = cols[i]; });
    return row;
  });
}
function splitCsvLine(line) {
  const out = [];
  let cur = "", inQuotes = false;
  for (let i = 0; i < line.length; i++) {
    const ch = line[i];
    if (inQuotes) {
      if (ch === '"' && line[i + 1] === '"') { cur += '"'; i++; }
      else if (ch === '"') { inQuotes = false; }
      else { cur += ch; }
    } else if (ch === '"') { inQuotes = true; }
    else if (ch === ",") { out.push(cur); cur = ""; }
    else { cur += ch; }
  }
  out.push(cur);
  return out;
}

const DIRECT_FEEDS = {
  Taipei: fetchTaipeiDirect,
  NewTaipei: fetchNewTaipeiDirect,
  Taichung: fetchTaichungDirect,
};

/**
 * Periodically pulls YouBike availability for the configured cities and caches it, so
 * every app can read a fresh-ish shared snapshot without each device hitting TDX itself.
 * Cities in DIRECT_FEEDS go through their own no-auth feed; every other city still goes
 * through TDX.
 *
 * env:
 *   BIKE_CITIES        comma list of TDX city codes (default: Taipei,NewTaipei)
 *   BIKE_POLL_MINUTES  refresh interval (default: 2)
 */
export function startBikePoller() {
  const cities = (process.env.BIKE_CITIES || "Taipei,NewTaipei")
    .split(",").map((s) => s.trim()).filter(Boolean);
  if (!tdxConfigured() && !cities.some((c) => DIRECT_FEEDS[c])) {
    console.log("[bike] TDX not configured and no direct-feed city in BIKE_CITIES — shared YouBike cache disabled");
    return;
  }
  const minutes = Math.max(1, parseInt(process.env.BIKE_POLL_MINUTES || "2", 10));

  const run = async () => {
    for (const city of cities) {
      const direct = DIRECT_FEEDS[city];
      try {
        const rows = direct ? await direct() : await bikeCity(city);
        setBikeCache(city, rows);
        console.log(`[bike] cached ${city}: ${rows.length} stations${direct ? " (direct feed)" : ""}`);
      } catch (e) {
        console.warn(`[bike] ${city} failed: ${e.message}`);
        // A direct feed failing is unusual (not the TDX 429s this exists to dodge) — fall
        // back to TDX for this one cycle rather than serving a stale/empty cache.
        if (direct && tdxConfigured()) {
          try {
            const rows = await bikeCity(city);
            setBikeCache(city, rows);
            console.log(`[bike] cached ${city}: ${rows.length} stations (TDX fallback)`);
          } catch (e2) {
            console.warn(`[bike] ${city} TDX fallback also failed: ${e2.message}`);
          }
        }
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
