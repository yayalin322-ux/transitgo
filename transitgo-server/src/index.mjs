import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import express from "express";
import { guardAsyncRoutes, errorResponder } from "./asyncGuard.mjs";
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
  reportPlaceReview,
  deletePlaceReview,
  listAllPlaceReviews,
  createUserLandmark,
  listApprovedLandmarksNear,
  listAllUserLandmarks,
  approveUserLandmark,
  verifyUserLandmarkBusiness,
  deleteUserLandmark,
  reportUserLandmark,
  listMyUserLandmarks,
  updateMyUserLandmark,
  createObservation,
  listObservations,
  getBikeCache,
  allBikeCaches,
  getSpeedcamCache,
  createShare,
  getShare,
  deleteShare,
} from "./appdata.mjs";
import { sanitizeSegments, sanitizeTitle, ttlMs, newToken, isToken, isExpired, isVehicle, parseTrainTrip, canRate, createRatingLedger } from "./shares.mjs";
import { pushAnnouncement } from "./push.mjs";
import { startAlertPoller } from "./alerts.mjs";
import { startBikePoller, nearestFrom, bikePollStatus } from "./bikepoller.mjs";
import { startSpeedcamPoller, nearestCams } from "./speedcampoller.mjs";
import { db } from "./db.mjs";
import { logMemorySummary, startMemorySampler } from "./graph/memlog.mjs";
import { RebuildLock } from "./graph/rebuildLock.mjs";
import { buildAndPublishGraph, downloadAndLoadGraph } from "./graph/graphPersistence.mjs";
import { storageConfigured } from "./graph/graphStorage.mjs";
import { planRoute, graphCoverage } from "./routing/api.mjs";
import { findNearbyBusStops } from "./graph/busStops.mjs";
import { createRealtimeService } from "./realtime/service.mjs";
import { getRouting } from "./tdx.mjs";
import { createBikeRealtime } from "./bike/realtime.mjs";
import { findNearbyBikeStations } from "./graph/virtual.mjs";
import { TDXProvider } from "./tdx/adapter.mjs";
import { ingestTRAStations, ingestTRAPair, ingestTHSRStations, ingestTHSRPair, ingestBusRouteSchedule, ingestMetroOperator } from "./tdx/ingest.mjs";

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

const app = guardAsyncRoutes(express());
// Raised from 64kb — place-review/landmark submissions can carry a base64-encoded photo.
app.use(express.json({ limit: "2mb" }));
app.use((req, _res, next) => {
  req.clientIp = (req.headers["x-forwarded-for"]?.split(",")[0] || req.socket.remoteAddress || "").trim();
  next();
});

function requireAdmin(req, res, next) {
  const tok = (req.headers.authorization || "").replace(/^Bearer\s+/i, "");
  if (!ADMIN_TOKEN || tok !== ADMIN_TOKEN) return res.status(401).json({ error: "unauthorized" });
  next();
}

// Every handler below is async and awaits its db.mjs calls — those are real network
// round trips now when DATABASE_URL (Supabase) is set, not synchronous local SQLite
// calls, so this isn't optional plumbing.

// ---- health ----
// GIT_COMMIT lets us confirm from the outside which build is actually live on Render —
// deploys have silently lagged behind pushes before, and "the fix is deployed" is
// otherwise unverifiable without dashboard access.
app.get("/v1/health", (_req, res) => {
  // Memory is reported here because Render's own memory chart is a paid feature and this service runs
  // near the 512 MB limit. `peakRssMB` is the highest resident memory since the process started (Node's
  // resourceUsage().maxRSS, kilobytes) — it includes the moment the routing graph is loaded at boot, which
  // is what once got the instance killed. Numbers only: nothing here is sensitive.
  const mb = (bytes) => Math.round((bytes / 1048576) * 10) / 10;
  const mem = process.memoryUsage();
  res.json({
    ok: true, time: new Date().toISOString(), commit: process.env.RENDER_GIT_COMMIT || null,
    uptimeSeconds: Math.round(process.uptime()),
    memory: { rssMB: mb(mem.rss), heapUsedMB: mb(mem.heapUsed), peakRssMB: mb(process.resourceUsage().maxRSS * 1024), limitMB: 512 },
    graph: { loaded: routingGraph !== null, nodeCount: routingGraph?.nodeCount ?? null, edgeCount: routingGraph?.edgeCount ?? null },
  });
});

// Which storage backend is actually active — never echoes the connection string itself,
// just whether DATABASE_URL was seen and a real query against it succeeds.
app.get("/v1/health/db", async (_req, res) => {
  const usingPg = !!process.env.DATABASE_URL;
  if (!usingPg) return res.json({ backend: "sqlite" });
  try {
    const row = await db.prepare(`SELECT current_database() AS db, now() AS t`).get();
    res.json({ backend: "postgres", database: row.db, serverTime: row.t });
  } catch (e) {
    res.status(500).json({ backend: "postgres", error: e.message });
  }
});

// ---- devices ----
app.post("/v1/devices", async (req, res) => {
  const { token, platform, appVersion } = req.body || {};
  if (!token || typeof token !== "string") return res.status(400).json({ error: "token required" });
  await upsertDevice({ token, platform, appVersion });
  res.json({ ok: true });
});

// ---- announcements (public read) ----
app.get("/v1/announcements", async (req, res) => {
  const since = typeof req.query.since === "string" && Number.isFinite(Date.parse(req.query.since)) ? req.query.since : null;   // a malformed timestamp would only make Postgres error
  res.json({ announcements: await listAnnouncements({ since }) });
});

// ---- reports (from app) ----
const reportBucket = new Map(); // ip -> [timestamps]
app.post("/v1/reports", async (req, res) => {
  const now = Date.now();
  const hist = (reportBucket.get(req.clientIp) || []).filter((t) => now - t < 60_000);
  if (hist.length >= 20) return res.status(429).json({ error: "rate limited" });
  hist.push(now);
  reportBucket.set(req.clientIp, hist);

  const { type, message, context, appVersion, os, device } = req.body || {};
  if (!type) return res.status(400).json({ error: "type required" });
  await createReport({ type, message, context, appVersion, os, device, ip: req.clientIp });
  res.json({ ok: true });
});

// ---- trip ratings (from app) ----
const ratingBucket = new Map();
app.post("/v1/ratings", async (req, res) => {
  const now = Date.now();
  const hist = (ratingBucket.get(req.clientIp) || []).filter((t) => now - t < 60_000);
  if (hist.length >= 30) return res.status(429).json({ error: "rate limited" });
  hist.push(now);
  ratingBucket.set(req.clientIp, hist);

  const { stars, kind, route, from, to, system, appVersion, device } = req.body || {};
  const n = parseInt(stars, 10);
  if (!(n >= 1 && n <= 5)) return res.status(400).json({ error: "stars 1-5 required" });
  await createRating({ stars: n, kind, route, from, to, system, appVersion, device, ip: req.clientIp });
  res.json({ ok: true });
});

// Public — the app shows this next to a route/train, Google-Maps style (★4.3 · 12 則評分).
app.get("/v1/ratings/route", async (req, res) => {
  const kind = req.query.kind === "rail" ? "rail" : "bus";
  const route = typeof req.query.route === "string" ? req.query.route : null;
  if (!route) return res.status(400).json({ error: "route required" });
  const system = typeof req.query.system === "string" ? req.query.system : null;
  res.json(await routeRatingStats(kind, route, system));
});

// A photo field must be a real data: URI (what the app's own JPEG-compress-then-encode
// step produces) and under ~1.5MB decoded — rejects garbage/oversized input without
// silently truncating it into a corrupt image.
function validPhoto(photo) {
  if (photo == null) return true;
  if (typeof photo !== "string" || !photo.startsWith("data:image/")) return false;
  return photo.length <= 2_000_000;
}

// ---- place reviews (real user-submitted content, no external Places API) ----
const placeReviewBucket = new Map();
app.post("/v1/places/reviews", async (req, res) => {
  const now = Date.now();
  const hist = (placeReviewBucket.get(req.clientIp) || []).filter((t) => now - t < 60_000);
  if (hist.length >= 10) return res.status(429).json({ error: "rate limited" });
  hist.push(now);
  placeReviewBucket.set(req.clientIp, hist);

  const { placeKey, placeName, lat, lon, stars, comment, photo, appVersion, device } = req.body || {};
  const n = parseInt(stars, 10);
  if (!placeKey || !placeName) return res.status(400).json({ error: "placeKey and placeName required" });
  if (!(n >= 1 && n <= 5)) return res.status(400).json({ error: "stars 1-5 required" });
  if (!validPhoto(photo)) return res.status(400).json({ error: "invalid photo" });
  await createPlaceReview({ placeKey, placeName, lat, lon, stars: n, comment, photo, appVersion, device, ip: req.clientIp });
  res.json({ ok: true });
});

app.get("/v1/places/reviews", async (req, res) => {
  const placeKey = typeof req.query.placeKey === "string" ? req.query.placeKey : null;
  if (!placeKey) return res.status(400).json({ error: "placeKey required" });
  res.json({ stats: await placeReviewStats(placeKey), reviews: await listPlaceReviews(placeKey) });
});

const placeReviewReportBucket = new Map();
app.post("/v1/places/reviews/:id/report", async (req, res) => {
  const now = Date.now();
  const hist = (placeReviewReportBucket.get(req.clientIp) || []).filter((t) => now - t < 60_000);
  if (hist.length >= 10) return res.status(429).json({ error: "rate limited" });
  hist.push(now);
  placeReviewReportBucket.set(req.clientIp, hist);

  const id = parseInt(req.params.id, 10);
  if (!Number.isInteger(id)) return res.status(400).json({ error: "invalid id" });
  const reason = typeof req.body?.reason === "string" ? req.body.reason : "other";
  const ok = await reportPlaceReview(id, reason, req.clientIp);
  if (!ok) return res.status(404).json({ error: "not found" });
  res.json({ ok: true });
});

app.get("/v1/admin/place-reviews", requireAdmin, async (_req, res) => {
  res.json({ reviews: await listAllPlaceReviews() });
});

// ---- user-submitted landmarks (real content, held for admin approval before showing) ----
const landmarkBucket = new Map();
app.post("/v1/landmarks", async (req, res) => {
  const now = Date.now();
  const hist = (landmarkBucket.get(req.clientIp) || []).filter((t) => now - t < 60_000);
  if (hist.length >= 5) return res.status(429).json({ error: "rate limited" });
  hist.push(now);
  landmarkBucket.set(req.clientIp, hist);

  const { name, description, category, lat, lon, photo, isBusinessClaim, businessHours, phone, appVersion, device } = req.body || {};
  if (!name || typeof name !== "string") return res.status(400).json({ error: "name required" });
  if (typeof lat !== "number" || typeof lon !== "number") return res.status(400).json({ error: "lat/lon required" });
  if (!validPhoto(photo)) return res.status(400).json({ error: "invalid photo" });
  await createUserLandmark({ name, description, category, lat, lon, photo, isBusinessClaim, businessHours, phone, appVersion, device, ip: req.clientIp });
  res.json({ ok: true });
});

/** Real approved landmarks near a point, to merge into the app's own nearby-landmarks list alongside Apple's POIs. */
app.get("/v1/landmarks", async (req, res) => {
  const lat = parseFloat(req.query.lat);
  const lon = parseFloat(req.query.lon);
  if (!Number.isFinite(lat) || !Number.isFinite(lon)) return res.status(400).json({ error: "lat/lon required" });
  const radius = Number.isFinite(parseFloat(req.query.radius)) ? parseFloat(req.query.radius) : 1000;
  res.json({ landmarks: await listApprovedLandmarksNear(lat, lon, radius) });
});

app.get("/v1/admin/landmarks", requireAdmin, async (_req, res) => {
  res.json({ landmarks: await listAllUserLandmarks() });
});

app.post("/v1/admin/landmarks/:id/approve", requireAdmin, async (req, res) => {
  const id = parseInt(req.params.id, 10);
  if (!Number.isInteger(id)) return res.status(400).json({ error: "invalid id" });
  res.json({ ok: await approveUserLandmark(id) });
});

/** Admin has manually confirmed (outside the app) that this submitter really is the business owner. */
app.post("/v1/admin/landmarks/:id/verify-business", requireAdmin, async (req, res) => {
  const id = parseInt(req.params.id, 10);
  if (!Number.isInteger(id)) return res.status(400).json({ error: "invalid id" });
  res.json({ ok: await verifyUserLandmarkBusiness(id) });
});

app.delete("/v1/admin/landmarks/:id", requireAdmin, async (req, res) => {
  const id = parseInt(req.params.id, 10);
  if (!Number.isInteger(id)) return res.status(400).json({ error: "invalid id" });
  res.json({ ok: await deleteUserLandmark(id) });
});

const landmarkReportBucket = new Map();
app.post("/v1/landmarks/:id/report", async (req, res) => {
  const now = Date.now();
  const hist = (landmarkReportBucket.get(req.clientIp) || []).filter((t) => now - t < 60_000);
  if (hist.length >= 10) return res.status(429).json({ error: "rate limited" });
  hist.push(now);
  landmarkReportBucket.set(req.clientIp, hist);

  const id = parseInt(req.params.id, 10);
  if (!Number.isInteger(id)) return res.status(400).json({ error: "invalid id" });
  const reason = typeof req.body?.reason === "string" ? req.body.reason : "other";
  const ok = await reportUserLandmark(id, reason, req.clientIp);
  if (!ok) return res.status(404).json({ error: "not found" });
  res.json({ ok: true });
});

/** This device's own submitted landmarks, so the app can show status + let a verified owner edit. */
app.get("/v1/landmarks/mine", async (req, res) => {
  const device = typeof req.query.device === "string" ? req.query.device : null;
  if (!device) return res.status(400).json({ error: "device required" });
  res.json({ landmarks: await listMyUserLandmarks(device) });
});

/** A verified business owner editing their own real listing — see updateMyUserLandmark for the ownership+verification gate. */
app.put("/v1/landmarks/:id", async (req, res) => {
  const id = parseInt(req.params.id, 10);
  if (!Number.isInteger(id)) return res.status(400).json({ error: "invalid id" });
  const { device, description, businessHours, phone, photo, lat, lon } = req.body || {};
  if (!device) return res.status(400).json({ error: "device required" });
  if (photo !== undefined && !validPhoto(photo)) return res.status(400).json({ error: "invalid photo" });
  const ok = await updateMyUserLandmark(id, device, { description, businessHours, phone, photo, lat, lon });
  if (!ok) return res.status(403).json({ error: "not authorized to edit this listing" });
  res.json({ ok: true });
});

app.delete("/v1/admin/place-reviews/:id", requireAdmin, async (req, res) => {
  const id = parseInt(req.params.id, 10);
  if (!Number.isInteger(id)) return res.status(400).json({ error: "invalid id" });
  const ok = await deletePlaceReview(id);
  res.json({ ok });
});

// ---- crowd-sourced observations (from Live Activity board/alight buttons) ----
const obsBucket = new Map();
app.post("/v1/observations", async (req, res) => {
  const now = Date.now();
  const hist = (obsBucket.get(req.clientIp) || []).filter((t) => now - t < 60_000);
  if (hist.length >= 40) return res.status(429).json({ error: "rate limited" });
  hist.push(now);
  obsBucket.set(req.clientIp, hist);

  const { route, plate, stopUID, stopName, kind, system } = req.body || {};
  if (!route && !plate) return res.status(400).json({ error: "route or plate required" });
  await createObservation({ route, plate, stopUID, stopName, kind, system, ip: req.clientIp });
  res.json({ ok: true });
});
// Shared YouBike snapshot (refreshed by the poller). Public.
app.get("/v1/bike/nearby", async (req, res) => {
  const lat = parseFloat(req.query.lat);
  const lon = parseFloat(req.query.lon);
  if (Number.isNaN(lat) || Number.isNaN(lon)) return res.status(400).json({ error: "lat/lon required" });
  const radius = Math.min(12000, parseInt(req.query.radius, 10) || 900);
  const limit = Math.min(800, parseInt(req.query.limit, 10) || 200);

  let pool = [];
  let updatedAt = null;
  const cityCache = typeof req.query.city === "string" ? await getBikeCache(req.query.city) : null;
  if (cityCache) {
    pool = cityCache.stations;
    updatedAt = cityCache.updatedAt;
  } else {
    for (const c of await allBikeCaches()) {
      pool = pool.concat(c.stations);
      if (!updatedAt || c.updatedAt > updatedAt) updatedAt = c.updatedAt;
    }
  }
  if (pool.length === 0) return res.json({ stations: [], updatedAt: null });
  res.json({ stations: nearestFrom(pool, lat, lon, radius, limit), updatedAt });
});

// Nationwide YouBike name search over every cached city — lets the app jump to a
// station anywhere in Taiwan instead of only what's currently on screen.
app.get("/v1/bike/search", async (req, res) => {
  const q = (req.query.q || "").toString().trim();
  if (q.length < 1) return res.json({ stations: [] });
  const limit = Math.min(50, parseInt(req.query.limit, 10) || 20);
  const needle = q.toLowerCase();
  let pool = [];
  for (const c of await allBikeCaches()) pool = pool.concat(c.stations);
  const matches = pool
    .filter((s) => s.name && s.name.toLowerCase().includes(needle))
    .slice(0, limit);
  res.json({ stations: matches });
});

// Fixed traffic-camera locations (speed / intersection / pedestrian-yield), nationwide —
// see speedcampoller.mjs for sources. No TDX involved, so no rate limit either.
app.get("/v1/speedcams/nearby", async (req, res) => {
  const lat = parseFloat(req.query.lat);
  const lon = parseFloat(req.query.lon);
  if (Number.isNaN(lat) || Number.isNaN(lon)) return res.status(400).json({ error: "lat/lon required" });
  const radius = Math.min(20000, parseInt(req.query.radius, 10) || 2000);
  const limit = Math.min(200, parseInt(req.query.limit, 10) || 50);

  const cache = await getSpeedcamCache();
  if (!cache) return res.json({ cams: [], updatedAt: null });
  res.json({ cams: nearestCams(cache.cams, lat, lon, radius, limit), updatedAt: cache.updatedAt });
});

// Public read so the app can fall back to crowd data when TDX is stale.
app.get("/v1/observations", async (req, res) => {
  const route = typeof req.query.route === "string" ? req.query.route : null;
  res.json({ observations: await listObservations({ route, limit: 50 }) });
});

// ---- admin ----
app.get("/v1/admin/ratings", requireAdmin, async (_req, res) => {
  res.json({ stats: await ratingStats(), ratings: await listRatings(200) });
});
app.get("/v1/admin/observations", requireAdmin, async (_req, res) => {
  res.json({ observations: await listObservations({ limit: 200 }) });
});

app.get("/v1/admin/announcements", requireAdmin, async (_req, res) => {
  res.json({ announcements: await listAnnouncements({ includeInactive: true }) });
});

app.post("/v1/admin/announcements", requireAdmin, async (req, res) => {
  const { category, severity, title, body, expiresInMinutes } = req.body || {};
  if (!title || !category) return res.status(400).json({ error: "title and category required" });
  const expiresAt = expiresInMinutes
    ? new Date(Date.now() + expiresInMinutes * 60_000).toISOString().replace("T", " ").slice(0, 19)
    : null;
  const ann = await createAnnouncement({ category, severity, title, body, source: "admin", expiresAt });
  const push = await pushAnnouncement(ann);
  res.json({ announcement: ann, push });
});

app.delete("/v1/admin/announcements/:id", requireAdmin, async (req, res) => {
  await deactivateAnnouncement(parseInt(req.params.id, 10));
  res.json({ ok: true });
});

// Last poll result per bike city — direct feed vs TDX, ok/error, station count, timestamp.
// No way to see Render's own server logs from here, so this is how "why is city X empty"
// gets debugged without dashboard access.
app.get("/v1/admin/bike-status", requireAdmin, (_req, res) => {
  res.json({ status: bikePollStatus() });
});

app.get("/v1/admin/reports", requireAdmin, async (req, res) => {
  res.json({ reports: await listReports(parseInt(req.query.limit || "100", 10)) });
});

// ---- tiny admin page ----
app.get("/admin", (_req, res) => res.sendFile(join(__dirname, "..", "public", "admin.html")));

// ---- Multimodal Routing Engine (architecture doc section 11) ----
// Graph is built once from the DB and kept in memory (section 17 — Routing never
// queries SQL mid-search); rebuilt on demand via the admin endpoint below once new
// GTFS/TDX data has actually been ingested.
//
// Deliberately NOT awaited here — with enough ingested data (multi-city GTFS) this can
// now take minutes, and awaiting it at module scope used to block app.listen() below
// until it finished. That meant /v1/health couldn't respond during a slow build either,
// so Render's own health check would time out, conclude the instance was unhealthy, and
// restart it — which then had to build the exact same graph from scratch before it could
// pass a health check either, an unrecoverable boot crash-loop. The server now starts
// listening immediately with an empty graph; requests that need it (below) report 503
// until the graph is ready.
//
// Graph persistence used to mean "a local file at GRAPH_CACHE_PATH (/tmp/...)" — a real
// production restart test proved that assumption wrong: Render's /tmp does NOT survive
// a restart, so every restart (crash, OOM, manual, or Render's own health-check-
// triggered restart) was silently forcing a full rebuild, exactly the risky operation
// this was supposed to make rare. Graph artifacts now live in Supabase Storage
// (graph/graphStorage.mjs, graph/graphPersistence.mjs); /tmp is only ever a transient
// relay for one download/upload, never the thing that makes the graph durable.
//
// Deliberately NOT awaited here, same reasoning as the old cache-load and the rebuild
// endpoint below: awaiting a network download at module scope would block app.listen(),
// which is exactly the boot-crash-loop shape this codebase has already been bitten by
// once (see the commit history). The server starts listening immediately with an empty
// graph; routes that need it report 503 until this recovery (or an explicit rebuild)
// finishes. downloadAndLoadGraph() never throws — any failure (Storage not configured,
// no artifact published yet, network failure after its own bounded retries, a corrupt/
// truncated download) just leaves the graph empty, never crashes the process.
let routingGraph = null;
let activeArtifactId = null;
if (!storageConfigured()) {
  console.log("[routing] Supabase Storage not configured (SUPABASE_S3_*/SUPABASE_STORAGE_BUCKET) — graph stays empty until POST /v1/admin/routing/rebuild is called explicitly");
} else {
  downloadAndLoadGraph()
    .then((result) => {
      if (result) {
        routingGraph = result.graph;
        activeArtifactId = result.artifactId;
      }
    })
    .catch((e) => console.error(`[routing] unexpected error during boot graph recovery: ${e.message}`));
}

// Realtime is a separate overlay service, never part of route planning: the route response
// above is fully static and returns immediately; clients ask /v1/realtime/* afterwards.
// TDX calls use the routing engine's own credentials (the iOS app's embedded TDX key is
// currently rejected by TDX, so realtime cannot go app -> TDX directly anyway).
const realtime = createRealtimeService({ tdxGet: getRouting, db });
const railBoardBucket = new Map();
// YouBike availability: ONE snapshot (the poller's shared cache), cached + de-duplicated, read by
// route planning and by the app's availability/candidates calls alike.
const bikeRealtime = createBikeRealtime({ loadCaches: allBikeCaches });

app.post("/api/v1/routes", async (req, res) => {
  if (!routingGraph) return res.status(503).json({ ok: false, error: "routing graph still initializing, try again shortly" });
  const result = await planRoute(routingGraph, req.body, db, { bikeRealtime });
  res.status(result.status).json(result.body);
});

/** Realtime overlay for a planned route. Body: { segments, departureTime, arrivalTime } exactly as
 * returned by POST /api/v1/routes. Always 200 with per-leg availability — a realtime failure is
 * data ("即時資料暫時無法取得"), never an error status, and says nothing about the route itself. */
app.post("/v1/realtime/route", async (req, res) => {
  const { segments, departureTime, arrivalTime } = req.body || {};
  if (!Array.isArray(segments) || segments.length > 16) return res.status(400).json({ ok: false, error: "segments must be an array (max 16)" });
  try {
    res.json({ ok: true, ...(await realtime.routeOverlay({ segments, departureTime, arrivalTime })) });
  } catch (e) {
    res.json({ ok: true, legs: [], eta: { etaSource: "scheduled", estimatedArrivalTime: null, shiftSeconds: null, basedOnLeg: null }, summary: { anyRealtime: false, state: null, delaySeconds: null, alerts: [], unavailableReasons: ["unavailable"] } });
  }
});

// ---- Shared trip links --------------------------------------------------------------------------
// A link lets family and friends follow the public vehicles someone plans to ride. It stores no location
// and no identity (see shares.mjs); the live status is the same realtime overlay the app uses, served
// through the shared cache, so any number of viewers costs one upstream read per refresh window.
const shareCreateBucket = new Map();
const shareViewBucket = new Map();
function limited(bucket, ip, perMinute) {
  const now = Date.now();
  const hist = (bucket.get(ip) || []).filter((t) => now - t < 60_000);
  if (hist.length >= perMinute) return true;
  hist.push(now);
  bucket.set(ip, hist);
  return false;
}

/** Shared by POST (server picks the token) and PUT (the app picked it, so it can hand out the link at once). */
async function storeShare(req, res, token) {
  if (limited(shareCreateBucket, req.clientIp, 10)) return res.status(429).json({ ok: false, error: "rate limited" });
  const segments = sanitizeSegments(req.body?.segments);
  if (!segments) return res.status(400).json({ ok: false, error: "need 1-8 valid segments including at least one vehicle leg" });
  const nowMs = Date.now();
  const expiresAtMs = nowMs + ttlMs(req.body?.ttlHours);
  try {
    await createShare({ token, title: sanitizeTitle(req.body?.title), segments, nowMs, expiresAtMs });
  } catch (e) {
    return res.status(500).json({ ok: false, error: "could not create link" });
  }
  const origin = `${req.headers["x-forwarded-proto"]?.split(",")[0] || req.protocol}://${req.get("host")}`;
  res.json({ ok: true, token, url: `${origin}/s/${token}`, expiresAt: new Date(expiresAtMs).toISOString() });
}

app.post("/v1/shares", (req, res) => storeShare(req, res, newToken()));

/**
 * The app makes up the token itself (128 random bits) so the share sheet can open the instant the button is pressed and
 * the upload happens in the background. Idempotent: a retry after a dropped reply, for a token that already exists,
 * answers ok instead of failing — only the app that made the token knows it.
 */
app.put("/v1/shares/:token", async (req, res) => {
  if (!isToken(req.params.token)) return res.status(400).json({ ok: false, error: "token must be 22 url-safe characters" });
  if (await getShare(req.params.token)) return res.json({ ok: true, existed: true });
  return storeShare(req, res, req.params.token);
});

/** The stored trip (what was planned), for the share page. */
app.get("/v1/shares/:token", async (req, res) => {
  res.set("Cache-Control", "no-store");
  if (!isToken(req.params.token) || limited(shareViewBucket, req.clientIp, 90)) return res.status(404).json({ ok: false, error: "not found" });
  const row = await getShare(req.params.token);
  if (isExpired(row)) return res.status(404).json({ ok: false, error: "expired or unknown" });
  res.json({ ok: true, title: row.title, segments: row.segments, expiresAt: new Date(row.expires_at_ms).toISOString() });
});

/** Live status of the shared trip's vehicles. 台鐵 legs get the train's real position (last station, next station,
 * stops left, delay) from two cached reads; every other mode goes through the ordinary realtime overlay. */
/**
 * A TRA station's departure board split 北上 / 南下 (see realtime/railBoard.mjs). One cached upstream read serves every
 * device asking about the same station, so widgets on several phones cost TDX one call per 30 s, not one each.
 */
app.get("/v1/rail/board", async (req, res) => {
  res.set("Cache-Control", "no-store");
  const stationId = String(req.query.station ?? "");
  if (!/^\d{4}$/.test(stationId)) return res.status(400).json({ ok: false, error: "station must be a 4-digit TRA station id" });
  if (limited(railBoardBucket, req.clientIp, 120)) return res.status(429).json({ ok: false, error: "rate limited" });
  res.json({ ok: true, ...(await realtime.railBoard({ stationId })) });
});

app.get("/v1/rail/stations", async (_req, res) => {
  res.set("Cache-Control", "public, max-age=3600");
  res.json({ ok: true, ...(await realtime.railStations()) });
});

app.get("/v1/shares/:token/live", async (req, res) => {
  res.set("Cache-Control", "no-store");
  if (!isToken(req.params.token) || limited(shareViewBucket, req.clientIp, 90)) return res.status(404).json({ ok: false, error: "not found" });
  const row = await getShare(req.params.token);
  if (isExpired(row)) return res.status(404).json({ ok: false, error: "expired or unknown" });
  const segs = row.segments;
  const first = segs[0], last = segs[segs.length - 1];
  const stopId = (n) => String(n ?? "").slice(String(n ?? "").indexOf(":") + 1) || null;

  // 台鐵 legs: the train's own status. Not sent to the overlay too — its station-board read would spend TDX quota on
  // a delay figure the train board already gives.
  const trains = (await Promise.all(segs.map(async (seg, index) => {
    if (seg.mode !== "TRA") return null;
    const trip = parseTrainTrip(seg.tripId);
    if (!trip) return null;
    try { return { index, ...(await realtime.trainStatus({ ...trip, fromId: stopId(seg.from), toId: stopId(seg.to) })) }; }
    catch { return null; }
  }))).filter(Boolean);
  const handled = new Set(trains.map((t) => t.index));

  // everything else: the overlay, with indexes mapped back to the shared trip's own
  const rest = segs.map((seg, index) => ({ seg, index })).filter((x) => !handled.has(x.index));
  let legs = [], summary = { anyRealtime: false, state: null, delaySeconds: null, alerts: [], unavailableReasons: [] };
  if (rest.some((x) => isVehicle(x.seg))) {
    try {
      const o = await realtime.routeOverlay({ segments: rest.map((x) => x.seg), departureTime: first.departureTime, arrivalTime: last.arrivalTime });
      legs = (o.legs ?? []).map((l) => ({ ...l, index: rest[l.index]?.index ?? l.index }));
      summary = o.summary ?? summary;
    } catch { summary.unavailableReasons = ["unavailable"]; }
  }
  res.json({ ok: true, generatedAt: new Date().toISOString(), legs, trains, summary });
});

/** A viewer rates a leg once it has arrived. Stars only (no free text from an anonymous page). */
const shareRatings = createRatingLedger();
app.post("/v1/shares/:token/rating", async (req, res) => {
  if (!isToken(req.params.token) || limited(shareViewBucket, req.clientIp, 30)) return res.status(404).json({ ok: false, error: "not found" });
  const row = await getShare(req.params.token);
  if (isExpired(row)) return res.status(404).json({ ok: false, error: "expired or unknown" });
  const legIndex = Number.isInteger(req.body?.legIndex) ? req.body.legIndex : -1;
  const stars = Number.isInteger(req.body?.stars) ? req.body.stars : 0;
  if (stars < 1 || stars > 5) return res.status(400).json({ ok: false, error: "stars must be 1-5" });
  if (!canRate(row.segments, legIndex, Date.now())) return res.status(409).json({ ok: false, error: "this ride has not arrived yet" });
  if (!shareRatings.claim(req.params.token, legIndex, req.clientIp)) return res.status(409).json({ ok: false, error: "already rated" });
  const seg = row.segments[legIndex];
  await createRating({
    stars, kind: seg.mode === "TRA" || seg.mode === "HSR" || seg.mode === "MRT" ? "rail" : "bus",
    route: seg.line || seg.routeShortName || null, from: seg.fromName, to: seg.toName, system: `share-${seg.mode}`, appVersion: "web-share", device: "web-share",
  });
  res.json({ ok: true });
});

/** The creator can revoke early. Knowing the token is the authority (128-bit, unguessable). */
app.delete("/v1/shares/:token", async (req, res) => {
  if (!isToken(req.params.token)) return res.status(404).json({ ok: false });
  await deleteShare(req.params.token);
  res.json({ ok: true });
});

app.get("/s/:token", (req, res) => {
  res.set({
    "Cache-Control": "no-store",
    "X-Robots-Tag": "noindex, nofollow",
    "Referrer-Policy": "no-referrer",
    "Content-Security-Policy": "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'self'",
  });
  res.sendFile(join(__dirname, "..", "public", "share.html"));
});

/** Next bus arrivals at a set of stops (the nearby list). ?scope=City/Taipei&stops=UID1,UID2 */
app.get("/v1/realtime/bus/stops", async (req, res) => {
  const scope = typeof req.query.scope === "string" ? req.query.scope : "";
  const stops = typeof req.query.stops === "string" ? req.query.stops.split(",").filter(Boolean) : [];
  if (!/^(City\/[A-Za-z]+|InterCity)$/.test(scope) || stops.length === 0 || stops.length > 12) return res.status(400).json({ ok: false, error: "need scope=City/<City>|InterCity and 1-12 stops" });
  res.json({ ok: true, ...(await realtime.busStopArrivals({ scopePath: scope, stopUIDs: stops })) });
});

/**
 * Nearest bus stops from the routing graph — replaces the app querying TDX for stop lists (static
 * data, and TDX quotas are tiny). `covered:false` means the graph has no bus data near the point:
 * the app must treat that as "unknown" and fall back, never as "no stops here".
 * Each physical stop lists every {scope, stopUID} to request arrivals with (scope InterCity = 公路客運/快捷).
 */
app.get("/v1/bus/nearby", (req, res) => {
  const lat = parseFloat(req.query.lat), lon = parseFloat(req.query.lon);
  if (!Number.isFinite(lat) || !Number.isFinite(lon)) return res.status(400).json({ ok: false, error: "lat/lon required" });
  const radius = Math.min(1000, Math.max(50, parseInt(req.query.radius, 10) || 500));
  const limit = Math.min(20, Math.max(1, parseInt(req.query.limit, 10) || 6));
  if (!routingGraph) return res.status(503).json({ ok: false, error: "routing graph still initializing, try again shortly" });
  res.json({ ok: true, radiusMeters: radius, ...findNearbyBusStops(routingGraph, lat, lon, { radiusMeters: radius, limit }) });
});

/** Realtime availability for specific YouBike stations (ids as routing returns them, "BIKE_Taipei:500101001"). */
app.get("/v1/bike/availability", async (req, res) => {
  const ids = typeof req.query.stations === "string" ? req.query.stations.split(",").filter(Boolean) : [];
  if (ids.length === 0 || ids.length > 50 || ids.some((i) => !/^BIKE_[A-Za-z]+:[\w.-]+$/.test(i))) return res.status(400).json({ ok: false, error: "need 1-50 station ids like BIKE_Taipei:500101001" });
  res.json({ ok: true, ...(await bikeRealtime.availability(ids)) });
});

/** Routing candidates: the nearest stations that can actually be used right now for `role`
 * ("rent" = has a bike, "return" = has a free dock). Same graph index and same availability
 * snapshot the router uses. Stations whose state can't be confirmed are returned flagged, not dropped. */
app.get("/v1/bike/candidates", async (req, res) => {
  const lat = parseFloat(req.query.lat), lon = parseFloat(req.query.lon);
  const role = req.query.role === "return" ? "return" : "rent";
  const radius = Math.min(2000, parseInt(req.query.radius, 10) || 800);
  if (Number.isNaN(lat) || Number.isNaN(lon)) return res.status(400).json({ ok: false, error: "lat/lon required" });
  if (!routingGraph) return res.status(503).json({ ok: false, error: "routing graph still initializing, try again shortly" });
  const snap = await bikeRealtime.snapshot();
  const near = findNearbyBikeStations(routingGraph, lat, lon, { maxRadius: radius, limit: 40 });
  const out = [];
  for (const { node, distanceMeters } of near) {
    const st = snap.stations.get(node.id) ?? null;
    const usable = st ? (role === "rent" ? st.isRentable : st.isReturnable) : null;   // null = unknown
    if (usable === false) continue;
    out.push({ stationId: node.id, name: node.name, lat: node.lat, lon: node.lon, distanceMeters: Math.round(distanceMeters), availability: st, availabilityKnown: st !== null });
    if (out.length >= 8) break;
  }
  res.json({ ok: true, role, realtimeAvailable: snap.ok, reason: snap.ok ? null : snap.reason, stations: out });
});

/** What realtime each mode really has, its sources, refresh/TTL and known limits. */
app.get("/v1/realtime/capabilities", (_req, res) => res.json({ ok: true, capabilities: realtime.capabilities() }));

/** What the multimodal engine actually has real data for right now — see graphCoverage()
 * in routing/api.mjs. The app should use this instead of a hardcoded coverage sentence. */
app.get("/v1/routing/coverage", (_req, res) => {
  if (!routingGraph) return res.status(503).json({ ok: false, error: "routing graph still initializing, try again shortly" });
  res.json({ ok: true, ...graphCoverage(routingGraph) });
});

/** Debug: nearest real ingested stops to a point, with real distances — for diagnosing NO_ORIGIN_NEARBY. */
app.get("/v1/admin/routing/debug/nearby-stops", requireAdmin, async (req, res) => {
  const lat = parseFloat(req.query.lat);
  const lng = parseFloat(req.query.lng);
  if (!Number.isFinite(lat) || !Number.isFinite(lng)) return res.status(400).json({ ok: false, error: "need ?lat=&lng=" });
  if (!routingGraph) return res.status(503).json({ ok: false, error: "routing graph still initializing, try again shortly" });
  const { haversineMeters } = await import("./graph/virtual.mjs");
  const hits = [];
  for (const node of routingGraph.nodes.values()) {
    if (node.lat == null || node.lon == null) continue;
    hits.push({ id: node.id, name: node.name, lat: node.lat, lon: node.lon, distanceMeters: Math.round(haversineMeters(lat, lng, node.lat, node.lon)) });
  }
  hits.sort((a, b) => a.distanceMeters - b.distanceMeters);
  res.json({ ok: true, nearest: hits.slice(0, 10) });
});

// Keeps two rebuilds from ever running at once — a concurrent second build would double
// every array/Map buildGraph() allocates on top of the graph the first build is already
// holding, on an instance where a single build alone has been observed to approach the
// 512MB limit. See graph/rebuildLock.mjs.
const rebuildLock = new RebuildLock();

/** Real graph swap happens here — the currently-active `routingGraph` is only ever
 * reassigned after a build has fully completed AND been persisted, so a build that
 * crashes or OOMs mid-way never replaces a working graph with a half-built one, and a
 * request arriving mid-rebuild is still served by the old graph. */
async function runRebuild(onProgress) {
  // Continuous sampler: checkpoint logging (inside buildGraph/saveGraphToDisk/the
  // Storage upload) only sees RSS at the specific call sites those functions happen to
  // report from — a spike that rises and falls entirely between two checkpoints would
  // never show up there. This samples on a timer instead, independent of control flow,
  // for the whole rebuild-and-publish lifecycle. One sampler per rebuild — the
  // RebuildLock this runs under already guarantees runRebuild itself never overlaps
  // itself, so startMemorySampler's own "already running" guard is a second, cheap
  // safety net, not the primary protection.
  let currentContext = { phase: "start", feed: null };
  const sampler = startMemorySampler({
    intervalMs: 100,
    getContext: () => currentContext,
  });

  // Memory: the old graph used to stay resident for the whole rebuild so requests kept being served — but
  // on a 512 MB instance "old graph (~130 MB) + a graph being built (peak 300+ MB) + the server" does not
  // fit, and the instance was OOM-killed mid-rebuild. So the old graph is released first (route requests
  // answer 503 "still initializing" for the ~2 minutes a rebuild takes). If the rebuild fails, the graph
  // that is still published in Storage is loaded back. Set REBUILD_KEEP_OLD_GRAPH=true on an instance
  // with plenty of memory to keep the old behavior.
  const releasedOldGraph = process.env.REBUILD_KEEP_OLD_GRAPH !== "true" && routingGraph !== null;
  if (releasedOldGraph) {
    routingGraph = null;
    activeArtifactId = null;
    if (global.gc) global.gc();
  }

  try {
    const rebuildStart = Date.now();
    const result = await buildAndPublishGraph(db, {
      onProgress: (info) => {
        currentContext = { phase: info.phase, feed: info.feed ?? null };
        onProgress?.(info);
      },
    });
    const rebuildDurationMs = Date.now() - rebuildStart;
    console.log(`[routing] graph built and published: ${result.nodeCount} nodes, ${result.edgeCount} edges (artifact ${result.artifactId})`);
    if (result.graph.warnings.length > 0) {
      for (const w of result.graph.warnings) console.log(`[routing] warning: ${w}`);
    }

    const continuousPeak = sampler.stop();
    logMemorySummary({ nodeCount: result.nodeCount, edgeCount: result.edgeCount, buildDurationMs: rebuildDurationMs, continuousPeak });
    // Only reassigned now that the new graph is fully built, uploaded to Storage,
    // verified, AND activated (setCurrentArtifactId) — routingGraph stays whatever it
    // was (old graph, or null) for the entire build+publish. See graphPersistence.mjs:
    // nothing before activation can affect what's currently live.
    routingGraph = result.graph;
    activeArtifactId = result.artifactId;
    return { nodeCount: result.nodeCount, edgeCount: result.edgeCount };
  } catch (e) {
    // A failed rebuild never activates a new artifact, so the previously published graph is still the
    // current one in Storage: bring it back instead of leaving routing down until the next restart.
    if (releasedOldGraph && routingGraph === null) {
      downloadAndLoadGraph()
        .then((restored) => {
          if (restored && routingGraph === null) {
            routingGraph = restored.graph;
            activeArtifactId = restored.artifactId;
            console.log(`[routing] rebuild failed; restored the published graph (artifact ${restored.artifactId})`);
          }
        })
        .catch((err) => console.error(`[routing] could not restore the graph after a failed rebuild: ${err.message}`));
    }
    throw e;
  } finally {
    // Runs on the success path too (sampler.stop() above is already idempotent), and —
    // the actual reason this exists — on any throw anywhere in build/persist/upload (a
    // real OOM, a DB error, a disk write failure, a Storage outage): the sampler's
    // setInterval must never outlive the rebuild that started it, on either path.
    sampler.stop();
  }
}

// Responds immediately and rebuilds in the background — awaiting the full build here
// (as this used to) held the HTTP response open for minutes with enough ingested data,
// which is exactly the kind of long-blocked request that made Render's proxy return an
// empty "non-JSON http 502" to the caller even though the server was still working.
// Poll GET /v1/admin/routing/rebuild/status to see live progress.
app.post("/v1/admin/routing/rebuild", requireAdmin, async (_req, res) => {
  const { started, state, promise } = rebuildLock.start(runRebuild);
  if (!started) return res.status(409).json({ ok: false, error: "rebuild already in progress", state });
  res.json({ ok: true, started: true });
  // Failure is already recorded on rebuildLock.state (and logged inside runRebuild) —
  // this only stops it from surfacing as an unhandled promise rejection.
  promise.catch((e) => console.error(`[routing] rebuild failed: ${e.message}`));
});

/** Live progress for a running/just-finished rebuild — phase/progress/memoryMB while
 * building, final counts on success, `error: "out_of_memory"` (or another message) on
 * failure. Lets an operator confirm a rebuild isn't "stuck" without needing Render's own
 * log stream, and gives real peak-memory numbers straight from the process that's doing
 * the allocating. */
app.get("/v1/admin/routing/rebuild/status", requireAdmin, (_req, res) => {
  res.json({
    ok: true,
    ...rebuildLock.state,
    storageConfigured: storageConfigured(),
    activeArtifactId,
  });
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

/** Ingests one real TRA O-D pair's timetable for one date. Body: {fromStationID, toStationID, date}. */
app.post("/v1/admin/routing/ingest/tra-pair", requireAdmin, async (req, res) => {
  const { fromStationID, toStationID, date } = req.body || {};
  if (!fromStationID || !toStationID || !date) {
    return res.status(400).json({ ok: false, error: "need fromStationID, toStationID, date" });
  }
  try {
    const result = await ingestTRAPair(db, "TRA", fromStationID, toStationID, date);
    res.json({ ok: true, ...result });
  } catch (e) {
    res.status(502).json({ ok: false, error: e.message });
  }
});

/** Ingests the real nationwide THSR station list (stops only, one TDX call). */
app.post("/v1/admin/routing/ingest/thsr-stations", requireAdmin, async (_req, res) => {
  try {
    const result = await ingestTHSRStations(db, "THSR");
    res.json({ ok: true, ...result });
  } catch (e) {
    res.status(502).json({ ok: false, error: e.message });
  }
});

/** Ingests one real THSR O-D pair's timetable for one date. Body: {fromStationID, toStationID, date}. */
app.post("/v1/admin/routing/ingest/thsr-pair", requireAdmin, async (req, res) => {
  const { fromStationID, toStationID, date } = req.body || {};
  if (!fromStationID || !toStationID || !date) {
    return res.status(400).json({ ok: false, error: "need fromStationID, toStationID, date" });
  }
  try {
    const result = await ingestTHSRPair(db, "THSR", fromStationID, toStationID, date);
    res.json({ ok: true, ...result });
  } catch (e) {
    res.status(502).json({ ok: false, error: e.message });
  }
});

/**
 * Ingests one real metro operator's routing data (stations, per-hop run times, headway
 * bands, interchange times) from TDX. Body: {operator: "TRTC"}. Sequential and
 * rate-limit-paced (TDX allows ~5 requests/minute) — takes a minute or two per operator;
 * an operator TDX publishes no usable run times for returns `ingested: false` and adds
 * nothing to the graph.
 */
app.post("/v1/admin/routing/ingest/metro-operator", requireAdmin, async (req, res) => {
  const { operator } = req.body || {};
  if (!operator || !/^[A-Z]{2,10}$/.test(operator)) return res.status(400).json({ ok: false, error: "need operator (TDX code, e.g. TRTC)" });
  try {
    const result = await ingestMetroOperator(db, operator, { pauseMs: 6000 });
    res.json({ ok: true, ...result });
  } catch (e) {
    res.status(502).json({ ok: false, error: e.message });
  }
});

app.use(errorResponder());

// A stray rejection from a background poller must not take the whole server down; log it and carry on.
process.on("unhandledRejection", (e) => console.error("[transitgo-server] unhandled rejection:", e?.message ?? e));

app.listen(PORT, () => {
  console.log(`[transitgo-server] listening on :${PORT}`);
  startBikePoller();
  startSpeedcamPoller();
  if (!ADMIN_TOKEN) console.warn("[transitgo-server] WARNING: ADMIN_TOKEN not set — admin endpoints disabled");
  startAlertPoller();
});
