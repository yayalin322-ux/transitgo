import cron from "node-cron";
import { setSpeedcamCache } from "./db.mjs";

/**
 * Fixed traffic-camera locations (speed enforcement, intersection violations, etc.) from
 * public open-data feeds — no TDX, no auth, no rate limit. This data barely changes day to
 * day, so it's fetched once on boot and then re-pulled daily rather than polled like
 * YouBike. Used for the in-app-navigation "前方有測速照相" driving alert.
 *
 * Sources:
 *  - MOI (內政部) nationwide CSV — the base layer, already covers local roads AND national
 *    highways (國道) in one file.
 *  - County/city feeds that add cameras (or violation categories) the national file misses.
 */
const SOURCES = [
  {
    id: "moi",
    url: "https://opdadm.moi.gov.tw/api/v1/no-auth/resource/api/dataset/EA5E6FCD-B82D-43B7-A5CF-E9893253187E/resource/DFD07C94-3176-4946-9358-3A5D6ED25186/download",
    parse: parseMoiCsv,
  },
  {
    // 新竹縣 (Hsinchu COUNTY) — distinct jurisdiction/dataset from the hsinchu-city-* ones below.
    id: "hsinchu-county-speed",
    url: "https://ws.hsinchu.gov.tw/001/Upload/1/opendata/8774/2759/acf3a77d-470e-4420-90c0-64bf860fa875.json",
    parse: parseHsinchuSpeedJson,
  },
  {
    id: "hsinchu-county-violation",
    url: "https://ws.hsinchu.gov.tw/001/Upload/1/opendata/8774/2787/831b7670-51c6-4425-9ffc-5fe823fee5e8.json",
    parse: parseHsinchuViolationJson,
  },
  {
    // 新竹市 (Hsinchu CITY) — separate jurisdiction from the county feeds above.
    id: "hsinchu-city-speed",
    url: "https://opendata.hccg.gov.tw/OpenDataFileHit.ashx?ID=020951744099A4E1&u=77DFE16E459DFCE30371C36CCE30AFF2620C9FA93F99248767110C1E4071F137C5FBEE507EBE009F2A6AFAF641DA977AEA0E35A7C9DF57BF5A4DD5B9EAC96EAD7F1BB1AC17EC084A27252DB1880710E6EEB8305C28FEE0E287A511773A4E81F48AF474B63F314C5062CC5037480F4ADE6516AF833EC64D39",
    parse: (text) => parseHccgJson(text, "speed"),
  },
  {
    id: "hsinchu-city-violation",
    url: "https://opendata.hccg.gov.tw/OpenDataFileHit.ashx?ID=C2552DBD403D7B05&u=77DFE16E459DFCE30371C36CCE30AFF2620C9FA93F99248767110C1E4071F137C5FBEE507EBE009F2A6AFAF641DA977A944330C65FFE0B2ED6B4328E428C43A89E13294C2CE45AB10664CB583A17FB56022886144F312B0D588CBC6AFEDA8FF78FC768833FFE7872A71DA7B0D5D9EEC128F4692D7C77D856",
    parse: (text) => parseHccgJson(text, "intersection"),
  },
  {
    id: "kcg-intersection",
    url: "https://openapi.kcg.gov.tw/Api/Service/Get/671e6abd-37ff-4ec5-b3d2-e7179ff69801",
    parse: (text) => parseKcgJson(text, "intersection", "路口違規照相"),
  },
  {
    id: "kcg-pedestrian",
    url: "https://openapi.kcg.gov.tw/Api/Service/Get/6c5ed27d-0b48-44a5-9e06-b1dc7e558aed",
    parse: (text) => parseKcgJson(text, "pedestrian", "不停讓行人照相"),
  },
  {
    // 新竹縣「路口多功能科技執法」— a third, distinct Hsinchu County dataset (redirects
    // off www.hsinchu.gov.tw) from the county speed/violation ones above.
    id: "hsinchu-county-intersection",
    url: "https://ws.hsinchu.gov.tw/001/Upload/1/opendata/8774/297/f65385d7-f178-4cee-8ccc-053c14aadfdb.json",
    parse: parseHsinchuIntersectionJson,
  },
  {
    // 新北市 區間測速 (section/average-speed cameras) — a start+end coordinate PAIR
    // defining a road segment, not a single point like every other source here.
    id: "ntpc-section-speed",
    url: "https://data.ntpc.gov.tw/api/datasets/27b97ad9-9dba-4ca9-b0ed-14b29000ffec/csv/file",
    parse: parseNtpcSectionSpeedCsv,
  },
];

export function startSpeedcamPoller() {
  const run = async () => {
    let merged = [];
    for (const src of SOURCES) {
      try {
        const res = await fetch(src.url, { signal: AbortSignal.timeout(20_000) });
        if (!res.ok) throw new Error(`HTTP ${res.status}`);
        const text = await res.text();
        const rows = src.parse(text);
        merged = merged.concat(rows);
        console.log(`[speedcam] ${src.id}: ${rows.length} cameras`);
      } catch (e) {
        console.warn(`[speedcam] ${src.id} failed: ${e.message}`);
      }
    }
    if (merged.length > 0) {
      setSpeedcamCache(merged);
      console.log(`[speedcam] cached ${merged.length} cameras total`);
    }
  };
  run();
  // Static-ish data — once a day is plenty, no point re-fetching like the live bike feed.
  cron.schedule("17 4 * * *", run);
  console.log("[speedcam] polling all sources once, then daily");
}

function num(v) {
  const n = parseFloat(v);
  return Number.isFinite(n) ? n : null;
}

function validPoint(lat, lon) {
  return lat != null && lon != null && lat > 15 && lat < 30 && lon > 115 && lon < 125;
}

/** MOI CSV: two header rows (English, then Chinese) then data. No quoted commas in practice — plain split is fine. */
function parseMoiCsv(text) {
  const lines = text.split(/\r?\n/).filter(Boolean);
  const out = [];
  for (let i = 2; i < lines.length; i++) {
    const cols = lines[i].split(",");
    if (cols.length < 9) continue;
    const [city, region, address, deptNm, branchNm, lon, lat, direct, limit] = cols;
    const la = num(lat), lo = num(lon);
    if (!validPoint(la, lo)) continue;
    out.push({
      lat: la, lon: lo, kind: "speed",
      address: address || null, city: city || null,
      direction: direct || null, speedLimit: num(limit),
      source: "moi",
    });
  }
  return out;
}

function parseHsinchuSpeedJson(text) {
  const rows = JSON.parse(text);
  return rows.map((r) => {
    const la = num(r["緯度"]), lo = num(r["經度"]);
    if (!validPoint(la, lo)) return null;
    return {
      lat: la, lon: lo, kind: "speed",
      address: r["設置地點"] || null, city: r["縣市"] || "新竹縣",
      direction: r["拍攝方向"] || null, speedLimit: num(r["速限"]),
      source: "hsinchu-speed",
    };
  }).filter(Boolean);
}

function parseHsinchuViolationJson(text) {
  const rows = JSON.parse(text);
  return rows.map((r) => {
    const la = num(r["緯度"]), lo = num(r["經度"]);
    if (!validPoint(la, lo)) return null;
    return {
      lat: la, lon: lo, kind: "violation",
      address: r["設置地點"] || null, city: "新竹",
      note: r["取締項目"] || null, source: "hsinchu-violation",
    };
  }).filter(Boolean);
}

/** Hsinchu City (hccg.gov.tw) feeds: 地點/經度/緯度 plus either 速限 (speed) or 違規取締項目 (intersection). */
function parseHccgJson(text, kind) {
  const rows = JSON.parse(text);
  return rows.map((r) => {
    const la = num(r["緯度"]), lo = num(r["經度"]);
    if (!validPoint(la, lo)) return null;
    return {
      lat: la, lon: lo, kind,
      address: r["地點"] || null, city: "新竹市",
      speedLimit: kind === "speed" ? num(r["速限"]) : null,
      note: r["違規取締項目"] || null,
      source: `hsinchu-city-${kind}`,
    };
  }).filter(Boolean);
}

/** Kaohsiung open API wraps rows in {data: [...]}. */
function parseKcgJson(text, kind, defaultNote) {
  const parsed = JSON.parse(text);
  const rows = Array.isArray(parsed) ? parsed : (parsed.data || []);
  return rows.map((r) => {
    const la = num(r["座標緯度"]), lo = num(r["座標經度"]);
    if (!validPoint(la, lo)) return null;
    return {
      lat: la, lon: lo, kind,
      address: r["設置位置"] || null, city: "高雄市",
      direction: r["測照行向"] || null, note: r["取締項目"] || defaultNote,
      source: `kcg-${kind}`,
    };
  }).filter(Boolean);
}

function parseHsinchuIntersectionJson(text) {
  const rows = JSON.parse(text);
  return rows.map((r) => {
    const la = num(r["緯度"]), lo = num(r["經度"]);
    if (!validPoint(la, lo)) return null;
    return {
      lat: la, lon: lo, kind: "intersection",
      address: r["設置地點"] || null, city: "新竹縣",
      direction: r["拍攝方向"] || null,   // "路口" here — omnidirectional, the app's direction parser treats unrecognized text as "always applies"
      note: r["取締項目"] || null,
      source: "hsinchu-county-intersection",
    };
  }).filter(Boolean);
}

/** First numeric token in a space-separated cell like "24.9569297 24.953133". */
function firstNumber(v) {
  if (!v) return null;
  const token = String(v).trim().split(/\s+/)[0];
  return num(token);
}

/** Minimal quote-aware CSV parser — MOI's parser above skips this since its fields never
 * contain a comma inside quotes, but NTPC's does (Chinese full-width commas aside, the
 * quoted "往新店方向：... 往宜蘭方向：..." cells are quoted specifically because of the
 * space, and to be safe this doesn't assume otherwise). */
function parseGenericCsv(text) {
  const lines = text.replace(/^﻿/, "").split(/\r?\n/).filter(Boolean);
  if (lines.length < 2) return [];
  const split = (line) => {
    const out = []; let cur = "", inQuotes = false;
    for (let i = 0; i < line.length; i++) {
      const ch = line[i];
      if (inQuotes) {
        if (ch === '"' && line[i + 1] === '"') { cur += '"'; i++; }
        else if (ch === '"') { inQuotes = false; }
        else cur += ch;
      } else if (ch === '"') { inQuotes = true; }
      else if (ch === ",") { out.push(cur); cur = ""; }
      else cur += ch;
    }
    out.push(cur);
    return out;
  };
  const headers = split(lines[0]);
  return lines.slice(1).map((line) => {
    const cols = split(line);
    const row = {};
    headers.forEach((h, i) => { row[h] = cols[i]; });
    return row;
  });
}

/** 新北市 區間測速 — a start+end coordinate PAIR per row (a road segment), not one point.
 * Each cell can hold more than one number space-separated (multiple sub-directions on the
 * same segment) — this takes the first as a representative point for that end. */
function parseNtpcSectionSpeedCsv(text) {
  const rows = parseGenericCsv(text);
  const out = [];
  for (const r of rows) {
    const startLat = firstNumber(r["start latitude"]);
    const startLon = firstNumber(r["start longitude"]);
    const endLat = firstNumber(r["end latitude"]);
    const endLon = firstNumber(r["end longitude"]);
    const limitDigits = (r.limit || "").match(/\d+/);
    const common = {
      kind: "speed",
      address: r.location || null,
      city: r.cityname || null,
      direction: r.direct || null,
      speedLimit: limitDigits ? parseInt(limitDigits[0], 10) : null,
      note: `區間測速（${r.deptnm || ""}${r.branchnm || ""}）`,
      source: "ntpc-section-speed",
    };
    if (validPoint(startLat, startLon)) out.push({ lat: startLat, lon: startLon, ...common });
    if (validPoint(endLat, endLon) && (endLat !== startLat || endLon !== startLon)) out.push({ lat: endLat, lon: endLon, ...common });
  }
  return out;
}

const R = 6371000;
function haversine(a, b, c, d) {
  const p = Math.PI / 180;
  const x =
    0.5 - Math.cos((c - a) * p) / 2 +
    (Math.cos(a * p) * Math.cos(c * p) * (1 - Math.cos((d - b) * p))) / 2;
  return 2 * R * Math.asin(Math.sqrt(x));
}
export function nearestCams(cams, lat, lon, radius, limit) {
  return cams
    .map((c) => ({ ...c, distance: Math.round(haversine(lat, lon, c.lat, c.lon)) }))
    .filter((c) => c.distance <= radius)
    .sort((a, b) => a.distance - b.distance)
    .slice(0, limit);
}
