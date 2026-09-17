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
} from "./db.mjs";
import { pushAnnouncement } from "./push.mjs";
import { startAlertPoller } from "./alerts.mjs";
import { startBikePoller, nearestFrom, bikePollStatus } from "./bikepoller.mjs";
import { startSpeedcamPoller, nearestCams } from "./speedcampoller.mjs";
import { db } from "./db.mjs";
import { buildGraph } from "./graph/builder.mjs";
import { saveGraphToDisk, loadGraphFromDisk, cacheFileInfo } from "./graph/persist.mjs";
import { logMemorySummary, startMemorySampler } from "./graph/memlog.mjs";
import { RebuildLock } from "./graph/rebuildLock.mjs";
import { planRoute, graphCoverage } from "./routing/api.mjs";
import { TDXProvider } from "./tdx/adapter.mjs";
import { ingestTRAStations, ingestTRAPair, ingestTHSRStations, ingestTHSRPair, ingestBusRouteSchedule } from "./tdx/ingest.mjs";

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
app.get("/v1/health", (_req, res) => res.json({ ok: true, time: new Date().toISOString(), commit: process.env.RENDER_GIT_COMMIT || null }));

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
  const since = typeof req.query.since === "string" ? req.query.since : null;
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
// GRAPH_CACHE_PATH: a from-scratch rebuild is real, non-trivial DB + CPU work (see
// graph/builder.mjs) — genuinely worth avoiding on every single restart, not just the
// first one. Render's disk doesn't survive a *deploy*, but it does survive a restart
// *within* one deploy's lifetime (a crash/OOM kill, Render's own health-check-triggered
// restart) — exactly the case that was causing repeat rebuilds under memory pressure.
// So: try loading a previously-persisted graph first (near-instant); only fall back to
// a real rebuild if there isn't one yet (first boot after a fresh deploy) or it's
// corrupt/incompatible. Either way, a fresh build gets persisted for the *next* restart.
const GRAPH_CACHE_PATH = process.env.GRAPH_CACHE_PATH || "/tmp/transitgo_routing_graph_cache.json";
let routingGraph = loadGraphFromDisk(GRAPH_CACHE_PATH);
if (routingGraph) {
  // A cache hit means this restart skips the DB rebuild entirely — Graph Build and
  // Route Query are now genuinely decoupled: building only happens on the very first
  // boot after a fresh deploy, or when explicitly requested via the rebuild endpoint
  // below (which every ingest batch script already calls when it finishes), never as a
  // side effect of a crash/OOM restart. That's the actual fix for rebuild-driven
  // restarts compounding each other.
  console.log(`[routing] graph loaded from disk cache: ${routingGraph.nodeCount} nodes, ${routingGraph.edgeCount} edges (built ${routingGraph.builtAt})`);
} else {
  // Deliberately NOT auto-building here, even in the background. Confirmed live (Render
  // logs + repeated 502s on /v1/health itself, not just the routing endpoints) that a
  // from-scratch build at the current data scale (~76k nodes, ~310k edges) can OOM-kill
  // the whole 512MB process during boot — and unlike a caught JS exception, a SIGKILL
  // takes the HTTP server down with it, so the "background build, health stays up"
  // design only holds for a build that *fails cleanly*, not one that kills the process.
  // On a fresh deploy with no cache yet, the graph simply starts empty (routes report
  // 503) until a human explicitly calls POST /v1/admin/routing/rebuild once the instance
  // has finished settling — every ingest batch script already does exactly that call
  // when it finishes, so this only actually matters right after a brand new deploy.
  console.log("[routing] no usable graph cache on disk — graph stays empty until POST /v1/admin/routing/rebuild is called explicitly");
}

app.post("/api/v1/routes", async (req, res) => {
  if (!routingGraph) return res.status(503).json({ ok: false, error: "routing graph still initializing, try again shortly" });
  const result = await planRoute(routingGraph, req.body, db);
  res.status(result.status).json(result.body);
});

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
  // Continuous sampler: checkpoint logging (inside buildGraph/saveGraphToDisk) only sees
  // RSS at the specific call sites those functions happen to report from — a spike that
  // rises and falls entirely between two checkpoints would never show up there. This
  // samples on a timer instead, independent of build control flow, for the whole rebuild
  // lifecycle (buildGraph -> saveGraphToDisk -> swap). One sampler per rebuild — the
  // RebuildLock this runs under already guarantees runRebuild itself never overlaps
  // itself, so startMemorySampler's own "already running" guard is a second, cheap
  // safety net, not the primary protection.
  let currentContext = { phase: "start", feed: null };
  const sampler = startMemorySampler({
    intervalMs: 100,
    getContext: () => currentContext,
  });

  try {
    const buildStart = Date.now();
    const g = await buildGraph(db, {
      onProgress: (info) => {
        currentContext = { phase: info.phase, feed: info.feed ?? null };
        onProgress?.(info);
      },
    });
    const buildDurationMs = Date.now() - buildStart;
    console.log(`[routing] graph built: ${g.nodeCount} nodes, ${g.edgeCount} edges`);
    if (g.warnings.length > 0) {
      for (const w of g.warnings) console.log(`[routing] warning: ${w}`);
    }

    currentContext = { phase: "persist", feed: null };
    const persistStart = Date.now();
    await saveGraphToDisk(g, GRAPH_CACHE_PATH);
    const persistDurationMs = Date.now() - persistStart;

    const continuousPeak = sampler.stop();
    logMemorySummary({ nodeCount: g.nodeCount, edgeCount: g.edgeCount, buildDurationMs, persistDurationMs, continuousPeak });
    // Only reassigned now that the new graph is fully built AND durably on disk —
    // routingGraph stays whatever it was (old graph, or null) for the entire build.
    routingGraph = g;
    return { nodeCount: g.nodeCount, edgeCount: g.edgeCount };
  } finally {
    // Runs on the success path too (sampler.stop() above is already idempotent), and —
    // the actual reason this exists — on any throw from buildGraph or saveGraphToDisk
    // (a real OOM, a DB error, a disk write failure): the sampler's setInterval must
    // never outlive the rebuild that started it, on either path.
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
  res.json({ ok: true, ...rebuildLock.state, cacheFile: cacheFileInfo(GRAPH_CACHE_PATH) });
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

app.listen(PORT, () => {
  console.log(`[transitgo-server] listening on :${PORT}`);
  startBikePoller();
  startSpeedcamPoller();
  if (!ADMIN_TOKEN) console.warn("[transitgo-server] WARNING: ADMIN_TOKEN not set — admin endpoints disabled");
  startAlertPoller();
});
