import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import express from "express";
import {
  upsertDevice,
  createAnnouncement,
  listAnnouncements,
  deactivateAnnouncement,
  createReport,
  listReports,
  createRating,
  listRatings,
  ratingStats,
  routeRatingStats,
  createPlaceReview,
  listPlaceReviews,
  placeReviewStats,
  createObservation,
  listObservations,
  getBikeCache,
  allBikeCaches,
  getSpeedcamCache,
} from "./db.mjs";
import { pushAnnouncement } from "./push.mjs";
import { startAlertPoller } from "./alerts.mjs";
import { startBikePoller, nearestFrom, bikePollStatus } from "./bikepoller.mjs";
import { startSpeedcamPoller, nearestCams } from "./speedcampoller.mjs";
import { db } from "./db.mjs";
import { buildGraph } from "./graph/builder.mjs";
import { planRoute } from "./routing/api.mjs";
import { TDXProvider } from "./tdx/adapter.mjs";
import { ingestTRAStations, ingestBusRouteSchedule } from "./tdx/ingest.mjs";

// load .env (no dependency)
try {
  for (const line of readFileSync(".env", "utf8").split("\n")) {
    const m = line.match(/^\s*([\w.]+)\s*=\s*(.*)\s*$/);
    if (m && !process.env[m[1]]) process.env[m[1]] = m[2].replace(/^["']|["']$/g, "");
  }
} catch {}

const __dirname = dirname(fileURLToPath(import.meta.url));
const PORT = parseInt(process.env.PORT || "8787", 10);
const ADMIN_TOKEN = process.env.ADMIN_TOKEN || "";

const app = express();
app.use(express.json({ limit: "64kb" }));
app.use((req, _res, next) => {
  req.clientIp = (req.headers["x-forwarded-for"]?.split(",")[0] || req.socket.remoteAddress || "").trim();
  next();
});

function requireAdmin(req, res, next) {
  const tok = (req.headers.authorization || "").replace(/^Bearer\s+/i, "");
  if (!ADMIN_TOKEN || tok !== ADMIN_TOKEN) return res.status(401).json({ error: "unauthorized" });
  next();
}

// ---- health ----
app.get("/v1/health", (_req, res) => res.json({ ok: true, time: new Date().toISOString() }));

// ---- devices ----
app.post("/v1/devices", (req, res) => {
  const { token, platform, appVersion } = req.body || {};
  if (!token || typeof token !== "string") return res.status(400).json({ error: "token required" });
  upsertDevice({ token, platform, appVersion });
  res.json({ ok: true });
});

// ---- announcements (public read) ----
app.get("/v1/announcements", (req, res) => {
  const since = typeof req.query.since === "string" ? req.query.since : null;
  res.json({ announcements: listAnnouncements({ since }) });
});

// ---- reports (from app) ----
const reportBucket = new Map(); // ip -> [timestamps]
app.post("/v1/reports", (req, res) => {
  const now = Date.now();
  const hist = (reportBucket.get(req.clientIp) || []).filter((t) => now - t < 60_000);
  if (hist.length >= 20) return res.status(429).json({ error: "rate limited" });
  hist.push(now);
  reportBucket.set(req.clientIp, hist);

  const { type, message, context, appVersion, os, device } = req.body || {};
  if (!type) return res.status(400).json({ error: "type required" });
  createReport({ type, message, context, appVersion, os, device, ip: req.clientIp });
  res.json({ ok: true });
});

// ---- trip ratings (from app) ----
const ratingBucket = new Map();
app.post("/v1/ratings", (req, res) => {
  const now = Date.now();
  const hist = (ratingBucket.get(req.clientIp) || []).filter((t) => now - t < 60_000);
  if (hist.length >= 30) return res.status(429).json({ error: "rate limited" });
  hist.push(now);
  ratingBucket.set(req.clientIp, hist);

  const { stars, kind, route, from, to, system, appVersion, device } = req.body || {};
  const n = parseInt(stars, 10);
  if (!(n >= 1 && n <= 5)) return res.status(400).json({ error: "stars 1-5 required" });
  createRating({ stars: n, kind, route, from, to, system, appVersion, device, ip: req.clientIp });
  res.json({ ok: true });
});

// Public — the app shows this next to a route/train, Google-Maps style (★4.3 · 12 則評分).
app.get("/v1/ratings/route", (req, res) => {
  const kind = req.query.kind === "rail" ? "rail" : "bus";
  const route = typeof req.query.route === "string" ? req.query.route : null;
  if (!route) return res.status(400).json({ error: "route required" });
  const system = typeof req.query.system === "string" ? req.query.system : null;
  res.json(routeRatingStats(kind, route, system));
});

// ---- place reviews (real user-submitted content, no external Places API) ----
const placeReviewBucket = new Map();
app.post("/v1/places/reviews", (req, res) => {
  const now = Date.now();
  const hist = (placeReviewBucket.get(req.clientIp) || []).filter((t) => now - t < 60_000);
  if (hist.length >= 10) return res.status(429).json({ error: "rate limited" });
  hist.push(now);
  placeReviewBucket.set(req.clientIp, hist);

  const { placeKey, placeName, lat, lon, stars, comment, appVersion, device } = req.body || {};
  const n = parseInt(stars, 10);
  if (!placeKey || !placeName) return res.status(400).json({ error: "placeKey and placeName required" });
  if (!(n >= 1 && n <= 5)) return res.status(400).json({ error: "stars 1-5 required" });
  createPlaceReview({ placeKey, placeName, lat, lon, stars: n, comment, appVersion, device, ip: req.clientIp });
  res.json({ ok: true });
});

app.get("/v1/places/reviews", (req, res) => {
  const placeKey = typeof req.query.placeKey === "string" ? req.query.placeKey : null;
  if (!placeKey) return res.status(400).json({ error: "placeKey required" });
  res.json({ stats: placeReviewStats(placeKey), reviews: listPlaceReviews(placeKey) });
});

// ---- crowd-sourced observations (from Live Activity board/alight buttons) ----
const obsBucket = new Map();
app.post("/v1/observations", (req, res) => {
  const now = Date.now();
  const hist = (obsBucket.get(req.clientIp) || []).filter((t) => now - t < 60_000);
  if (hist.length >= 40) return res.status(429).json({ error: "rate limited" });
  hist.push(now);
  obsBucket.set(req.clientIp, hist);

  const { route, plate, stopUID, stopName, kind, system } = req.body || {};
  if (!route && !plate) return res.status(400).json({ error: "route or plate required" });
  createObservation({ route, plate, stopUID, stopName, kind, system, ip: req.clientIp });
  res.json({ ok: true });
});
// Shared YouBike snapshot (refreshed by the poller). Public.
app.get("/v1/bike/nearby", (req, res) => {
  const lat = parseFloat(req.query.lat);
  const lon = parseFloat(req.query.lon);
  if (Number.isNaN(lat) || Number.isNaN(lon)) return res.status(400).json({ error: "lat/lon required" });
  const radius = Math.min(12000, parseInt(req.query.radius, 10) || 900);
  const limit = Math.min(800, parseInt(req.query.limit, 10) || 200);

  let pool = [];
  let updatedAt = null;
  if (typeof req.query.city === "string" && getBikeCache(req.query.city)) {
    const c = getBikeCache(req.query.city);
    pool = c.stations;
    updatedAt = c.updatedAt;
  } else {
    for (const c of allBikeCaches()) {
      pool = pool.concat(c.stations);
      if (!updatedAt || c.updatedAt > updatedAt) updatedAt = c.updatedAt;
    }
  }
  if (pool.length === 0) return res.json({ stations: [], updatedAt: null });
  res.json({ stations: nearestFrom(pool, lat, lon, radius, limit), updatedAt });
});

// Nationwide YouBike name search over every cached city — lets the app jump to a
// station anywhere in Taiwan instead of only what's currently on screen.
app.get("/v1/bike/search", (req, res) => {
  const q = (req.query.q || "").toString().trim();
  if (q.length < 1) return res.json({ stations: [] });
  const limit = Math.min(50, parseInt(req.query.limit, 10) || 20);
  const needle = q.toLowerCase();
  let pool = [];
  for (const c of allBikeCaches()) pool = pool.concat(c.stations);
  const matches = pool
    .filter((s) => s.name && s.name.toLowerCase().includes(needle))
    .slice(0, limit);
  res.json({ stations: matches });
});

// Fixed traffic-camera locations (speed / intersection / pedestrian-yield), nationwide —
// see speedcampoller.mjs for sources. No TDX involved, so no rate limit either.
app.get("/v1/speedcams/nearby", (req, res) => {
  const lat = parseFloat(req.query.lat);
  const lon = parseFloat(req.query.lon);
  if (Number.isNaN(lat) || Number.isNaN(lon)) return res.status(400).json({ error: "lat/lon required" });
  const radius = Math.min(20000, parseInt(req.query.radius, 10) || 2000);
  const limit = Math.min(200, parseInt(req.query.limit, 10) || 50);

  const cache = getSpeedcamCache();
  if (!cache) return res.json({ cams: [], updatedAt: null });
  res.json({ cams: nearestCams(cache.cams, lat, lon, radius, limit), updatedAt: cache.updatedAt });
});

// Public read so the app can fall back to crowd data when TDX is stale.
app.get("/v1/observations", (req, res) => {
  const route = typeof req.query.route === "string" ? req.query.route : null;
  res.json({ observations: listObservations({ route, limit: 50 }) });
});

// ---- admin ----
app.get("/v1/admin/ratings", requireAdmin, (_req, res) => {
  res.json({ stats: ratingStats(), ratings: listRatings(200) });
});
app.get("/v1/admin/observations", requireAdmin, (_req, res) => {
  res.json({ observations: listObservations({ limit: 200 }) });
});

app.get("/v1/admin/announcements", requireAdmin, (_req, res) => {
  res.json({ announcements: listAnnouncements({ includeInactive: true }) });
});

app.post("/v1/admin/announcements", requireAdmin, async (req, res) => {
  const { category, severity, title, body, expiresInMinutes } = req.body || {};
  if (!title || !category) return res.status(400).json({ error: "title and category required" });
  const expiresAt = expiresInMinutes
    ? new Date(Date.now() + expiresInMinutes * 60_000).toISOString().replace("T", " ").slice(0, 19)
    : null;
  const ann = createAnnouncement({ category, severity, title, body, source: "admin", expiresAt });
  const push = await pushAnnouncement(ann);
  res.json({ announcement: ann, push });
});

app.delete("/v1/admin/announcements/:id", requireAdmin, (req, res) => {
  deactivateAnnouncement(parseInt(req.params.id, 10));
  res.json({ ok: true });
});

// Last poll result per bike city — direct feed vs TDX, ok/error, station count, timestamp.
// No way to see Render's own server logs from here, so this is how "why is city X empty"
// gets debugged without dashboard access.
app.get("/v1/admin/bike-status", requireAdmin, (_req, res) => {
  res.json({ status: bikePollStatus() });
});

app.get("/v1/admin/reports", requireAdmin, (req, res) => {
  res.json({ reports: listReports(parseInt(req.query.limit || "100", 10)) });
});

// ---- tiny admin page ----
app.get("/admin", (_req, res) => res.sendFile(join(__dirname, "..", "public", "admin.html")));

// ---- Multimodal Routing Engine (architecture doc section 11) ----
// Graph is built once from the DB and kept in memory (section 17 — Routing never
// queries SQL mid-search); rebuilt on demand via the admin endpoint below once new
// GTFS/TDX data has actually been ingested. Right now (pre-live-TDX-verification) this
// graph is empty or test-only, so every /api/v1/routes call will correctly return
// NO_ORIGIN_NEARBY/NO_DESTINATION_NEARBY until real ingestion runs — that's honest
// behavior, not a bug: there's no real route data in it yet.
let routingGraph = buildGraph(db);
console.log(`[routing] graph built: ${routingGraph.nodeCount} nodes, ${routingGraph.edgeCount} edges`);
if (routingGraph.warnings.length > 0) {
  for (const w of routingGraph.warnings) console.log(`[routing] warning: ${w}`);
}

app.post("/api/v1/routes", (req, res) => {
  const result = planRoute(routingGraph, req.body, db);
  res.status(result.status).json(result.body);
});

/** Debug: nearest real ingested stops to a point, with real distances — for diagnosing NO_ORIGIN_NEARBY. */
app.get("/v1/admin/routing/debug/nearby-stops", requireAdmin, async (req, res) => {
  const lat = parseFloat(req.query.lat);
  const lng = parseFloat(req.query.lng);
  if (!Number.isFinite(lat) || !Number.isFinite(lng)) return res.status(400).json({ ok: false, error: "need ?lat=&lng=" });
  const { haversineMeters } = await import("./graph/virtual.mjs");
  const hits = [];
  for (const node of routingGraph.nodes.values()) {
    if (node.lat == null || node.lon == null) continue;
    hits.push({ id: node.id, name: node.name, lat: node.lat, lon: node.lon, distanceMeters: Math.round(haversineMeters(lat, lng, node.lat, node.lon)) });
  }
  hits.sort((a, b) => a.distanceMeters - b.distanceMeters);
  res.json({ ok: true, nearest: hits.slice(0, 10) });
});

app.post("/v1/admin/routing/rebuild", requireAdmin, (_req, res) => {
  routingGraph = buildGraph(db);
  res.json({ ok: true, nodeCount: routingGraph.nodeCount, edgeCount: routingGraph.edgeCount, warnings: routingGraph.warnings });
});

/** Confirms the routing engine's TDX credentials actually work — never echoes the credentials themselves. */
app.get("/v1/admin/routing/tdx-check", requireAdmin, async (_req, res) => {
  try {
    const { getRouting, tdxRoutingConfigured } = await import("./tdx.mjs");
    const d = await getRouting("v3/Rail/TRA/Station");
    res.json({ ok: true, usingRoutingCredentials: tdxRoutingConfigured(), stationCount: d?.Stations?.length ?? 0 });
  } catch (e) {
    res.status(502).json({ ok: false, error: e.message });
  }
});

const routingProvider = new TDXProvider();

/** Lists TDX's real bus routes for one scope (e.g. "City/Hsinchu") — used to pick real routeIds to ingest. */
app.get("/v1/admin/routing/tdx/bus-routes", requireAdmin, async (req, res) => {
  const scopePath = req.query.scope;
  if (!scopePath) return res.status(400).json({ ok: false, error: "missing ?scope=City/Hsinchu" });
  try {
    const raw = await routingProvider.getBusRoutes(scopePath);
    const routes = (raw ?? []).map((r) => ({ routeId: r.RouteUID ?? r.RouteID, routeNameZh: r.RouteName?.Zh_tw ?? null }));
    res.json({ ok: true, count: routes.length, routes });
  } catch (e) {
    res.status(502).json({ ok: false, error: e.message });
  }
});

/** Ingests one real bus route's real stops + schedule/headway for one date. Body: {feedId, scopePath, routeId, routeNameZh, date}. */
app.post("/v1/admin/routing/ingest/bus-route", requireAdmin, async (req, res) => {
  const { feedId, scopePath, routeId, routeNameZh, date } = req.body || {};
  if (!feedId || !scopePath || !routeId || !routeNameZh || !date) {
    return res.status(400).json({ ok: false, error: "need feedId, scopePath, routeId, routeNameZh, date" });
  }
  try {
    const result = await ingestBusRouteSchedule(db, feedId, scopePath, routeId, routeNameZh, date);
    res.json({ ok: true, ...result });
  } catch (e) {
    res.status(502).json({ ok: false, error: e.message });
  }
});

/** Ingests the real nationwide TRA station list (stops only, no schedule — cheap, one TDX call). */
app.post("/v1/admin/routing/ingest/tra-stations", requireAdmin, async (_req, res) => {
  try {
    const result = await ingestTRAStations(db, "TRA");
    res.json({ ok: true, ...result });
  } catch (e) {
    res.status(502).json({ ok: false, error: e.message });
  }
});

app.listen(PORT, () => {
  console.log(`[transitgo-server] listening on :${PORT}`);
  startBikePoller();
  startSpeedcamPoller();
  if (!ADMIN_TOKEN) console.warn("[transitgo-server] WARNING: ADMIN_TOKEN not set — admin endpoints disabled");
  startAlertPoller();
});
