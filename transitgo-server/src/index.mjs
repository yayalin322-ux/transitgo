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
  createObservation,
  listObservations,
  getBikeCache,
  allBikeCaches,
} from "./db.mjs";
import { pushAnnouncement } from "./push.mjs";
import { startAlertPoller } from "./alerts.mjs";
import { startBikePoller, nearestFrom } from "./bikepoller.mjs";

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

app.get("/v1/admin/reports", requireAdmin, (req, res) => {
  res.json({ reports: listReports(parseInt(req.query.limit || "100", 10)) });
});

// ---- tiny admin page ----
app.get("/admin", (_req, res) => res.sendFile(join(__dirname, "..", "public", "admin.html")));

app.listen(PORT, () => {
  console.log(`[transitgo-server] listening on :${PORT}`);
  startBikePoller();
  if (!ADMIN_TOKEN) console.warn("[transitgo-server] WARNING: ADMIN_TOKEN not set — admin endpoints disabled");
  startAlertPoller();
});
