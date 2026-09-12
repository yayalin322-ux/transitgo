// TransitGo backend, ported to Firebase Functions v2 (HTTPS + Firestore + Scheduler).
// Endpoint shapes match transitgo-server 1:1 — the app doesn't need to change beyond
// pointing BACKEND_HOST at this deployment's URL.
import { setGlobalOptions } from "firebase-functions/v2";
import { onRequest } from "firebase-functions/v2/https";
import { onSchedule } from "firebase-functions/v2/scheduler";
import express from "express";
import {
  upsertDevice,
  createAnnouncement, listAnnouncements, deactivateAnnouncement,
  createReport, listReports,
  createRating, listRatings, ratingStats, routeRatingStats,
  createObservation, listObservations,
  getBikeCache, allBikeCaches,
} from "./lib/db.js";
import { pushAnnouncement } from "./lib/push.js";
import { runAlertPoll } from "./lib/alerts.js";
import { runBikePoll, nearestFrom } from "./lib/bikepoller.js";

setGlobalOptions({ region: "asia-east1", maxInstances: 10 });

const ADMIN_TOKEN = process.env.ADMIN_TOKEN || "";

const app = express();
app.use(express.json({ limit: "64kb" }));
app.use((req, _res, next) => {
  req.clientIp = (req.headers["x-forwarded-for"]?.split(",")[0] || req.ip || "").trim();
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
const reportBucket = new Map();
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
app.get("/v1/observations", async (req, res) => {
  const route = typeof req.query.route === "string" ? req.query.route : null;
  res.json({ observations: await listObservations({ route, limit: 50 }) });
});

// ---- shared YouBike snapshot (refreshed by the scheduled poller). Public. ----
app.get("/v1/bike/nearby", async (req, res) => {
  const lat = parseFloat(req.query.lat);
  const lon = parseFloat(req.query.lon);
  if (Number.isNaN(lat) || Number.isNaN(lon)) return res.status(400).json({ error: "lat/lon required" });
  const radius = Math.min(12000, parseInt(req.query.radius, 10) || 900);
  const limit = Math.min(800, parseInt(req.query.limit, 10) || 200);

  let pool = [];
  let updatedAt = null;
  if (typeof req.query.city === "string") {
    const c = await getBikeCache(req.query.city);
    if (c) { pool = c.stations; updatedAt = c.updatedAt; }
  } else {
    for (const c of await allBikeCaches()) {
      pool = pool.concat(c.stations);
      if (!updatedAt || c.updatedAt > updatedAt) updatedAt = c.updatedAt;
    }
  }
  if (pool.length === 0) return res.json({ stations: [], updatedAt: null });
  res.json({ stations: nearestFrom(pool, lat, lon, radius, limit), updatedAt });
});

// Nationwide YouBike name search over every cached city.
app.get("/v1/bike/search", async (req, res) => {
  const q = (req.query.q || "").toString().trim();
  if (q.length < 1) return res.json({ stations: [] });
  const limit = Math.min(50, parseInt(req.query.limit, 10) || 20);
  const needle = q.toLowerCase();
  let pool = [];
  for (const c of await allBikeCaches()) pool = pool.concat(c.stations);
  const matches = pool.filter((s) => s.name && s.name.toLowerCase().includes(needle)).slice(0, limit);
  res.json({ stations: matches });
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
  const expiresAt = expiresInMinutes ? new Date(Date.now() + expiresInMinutes * 60_000).toISOString() : null;
  const ann = await createAnnouncement({ category, severity, title, body, source: "admin", expiresAt });
  const push = await pushAnnouncement(ann);
  res.json({ announcement: ann, push });
});
app.delete("/v1/admin/announcements/:id", requireAdmin, async (req, res) => {
  await deactivateAnnouncement(req.params.id);   // Firestore doc id — a string, not an int
  res.json({ ok: true });
});
app.get("/v1/admin/reports", requireAdmin, async (req, res) => {
  res.json({ reports: await listReports(parseInt(req.query.limit || "100", 10)) });
});

// The static admin.html is served by Firebase Hosting directly (see firebase.json) —
// this route is just a fallback for the emulator / calling the function directly.
app.get("/admin", (_req, res) => {
  res.redirect(302, "/admin.html");
});

export const api = onRequest(app);

// ---- scheduled jobs (replace the Node server's node-cron loops) ----

/** Shared YouBike cache. Default: every 2 minutes (adjust via the schedule below). */
export const bikePoll = onSchedule("every 2 minutes", async () => {
  await runBikePoll();
});

/** TRA/THSR service-alert → announcement + push, deduped by content signature. */
export const alertPoll = onSchedule("every 3 minutes", async () => {
  await runAlertPoll();
});
