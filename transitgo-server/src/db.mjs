// Uses Node's built-in SQLite (no native build). Node >= 22.5 (unflagged on 24).
import { DatabaseSync } from "node:sqlite";
import { mkdirSync } from "node:fs";
import { dirname } from "node:path";

const DB_PATH = process.env.DB_PATH || "./data/transitgo.db";
mkdirSync(dirname(DB_PATH), { recursive: true });

export const db = new DatabaseSync(DB_PATH);
db.exec("PRAGMA journal_mode = WAL;");

db.exec(`
CREATE TABLE IF NOT EXISTS devices (
  token       TEXT PRIMARY KEY,
  platform    TEXT,
  app_version TEXT,
  created_at  TEXT DEFAULT (datetime('now')),
  last_seen   TEXT DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS announcements (
  id         INTEGER PRIMARY KEY AUTOINCREMENT,
  category   TEXT NOT NULL,
  severity   TEXT NOT NULL DEFAULT 'info',
  title      TEXT NOT NULL,
  body       TEXT NOT NULL DEFAULT '',
  source     TEXT NOT NULL DEFAULT 'admin',
  active     INTEGER NOT NULL DEFAULT 1,
  created_at TEXT NOT NULL DEFAULT (datetime('now')),
  expires_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_ann_created ON announcements (created_at);

CREATE TABLE IF NOT EXISTS reports (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  type        TEXT NOT NULL,
  message     TEXT NOT NULL DEFAULT '',
  context     TEXT,
  app_version TEXT,
  os          TEXT,
  device      TEXT,
  ip          TEXT,
  created_at  TEXT NOT NULL DEFAULT (datetime('now'))
);
CREATE INDEX IF NOT EXISTS idx_rep_created ON reports (created_at);

CREATE TABLE IF NOT EXISTS alert_state (
  source     TEXT PRIMARY KEY,
  signature  TEXT,
  abnormal   INTEGER NOT NULL DEFAULT 0,
  updated_at TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS ratings (
  id         INTEGER PRIMARY KEY AUTOINCREMENT,
  stars      INTEGER NOT NULL,
  kind       TEXT NOT NULL DEFAULT 'bus',
  route      TEXT,
  from_stop  TEXT,
  to_stop    TEXT,
  system     TEXT,
  app_version TEXT,
  device     TEXT,
  ip         TEXT,
  created_at TEXT NOT NULL DEFAULT (datetime('now'))
);
CREATE INDEX IF NOT EXISTS idx_rating_created ON ratings (created_at);

CREATE TABLE IF NOT EXISTS observations (
  id         INTEGER PRIMARY KEY AUTOINCREMENT,
  route      TEXT,
  plate      TEXT,
  stop_uid   TEXT,
  stop_name  TEXT,
  kind       TEXT NOT NULL DEFAULT 'board',
  system     TEXT,
  ip         TEXT,
  created_at TEXT NOT NULL DEFAULT (datetime('now'))
);
CREATE INDEX IF NOT EXISTS idx_obs_route ON observations (route, created_at);

CREATE TABLE IF NOT EXISTS bike_cache (
  city       TEXT PRIMARY KEY,
  json       TEXT NOT NULL,
  updated_at TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS speedcam_cache (
  id         TEXT PRIMARY KEY DEFAULT 'all',
  json       TEXT NOT NULL,
  updated_at TEXT NOT NULL DEFAULT (datetime('now'))
);
`);

// ---- devices ----
export function upsertDevice({ token, platform, appVersion }) {
  db.prepare(`
    INSERT INTO devices (token, platform, app_version, last_seen)
    VALUES (:token, :platform, :appVersion, datetime('now'))
    ON CONFLICT(token) DO UPDATE SET
      platform = excluded.platform,
      app_version = excluded.app_version,
      last_seen = datetime('now')
  `).run({ token, platform: platform ?? null, appVersion: appVersion ?? null });
}

export function allDeviceTokens() {
  return db.prepare(`SELECT token FROM devices`).all().map((r) => r.token);
}

export function removeDevice(token) {
  db.prepare(`DELETE FROM devices WHERE token = ?`).run(token);
}

// ---- announcements ----
export function createAnnouncement(a) {
  const info = db.prepare(`
    INSERT INTO announcements (category, severity, title, body, source, expires_at)
    VALUES (:category, :severity, :title, :body, :source, :expires_at)
  `).run({
    category: a.category,
    severity: a.severity ?? "info",
    title: a.title,
    body: a.body ?? "",
    source: a.source ?? "admin",
    expires_at: a.expiresAt ?? null,
  });
  return getAnnouncement(Number(info.lastInsertRowid));
}

export function getAnnouncement(id) {
  return serializeAnnouncement(db.prepare(`SELECT * FROM announcements WHERE id = ?`).get(id));
}

export function listAnnouncements({ since, includeInactive = false } = {}) {
  return db.prepare(`
    SELECT * FROM announcements
    WHERE (:includeInactive = 1 OR active = 1)
      AND (expires_at IS NULL OR expires_at > datetime('now'))
      AND (:since IS NULL OR created_at > :since)
    ORDER BY created_at DESC
    LIMIT 200
  `).all({ since: since ?? null, includeInactive: includeInactive ? 1 : 0 })
    .map(serializeAnnouncement);
}

export function deactivateAnnouncement(id) {
  db.prepare(`UPDATE announcements SET active = 0 WHERE id = ?`).run(id);
}

function serializeAnnouncement(r) {
  if (!r) return null;
  return {
    id: r.id,
    category: r.category,
    severity: r.severity,
    title: r.title,
    body: r.body,
    source: r.source,
    active: !!r.active,
    createdAt: isoZ(r.created_at),
    expiresAt: r.expires_at ? isoZ(r.expires_at) : null,
  };
}

// ---- reports ----
export function createReport(r) {
  db.prepare(`
    INSERT INTO reports (type, message, context, app_version, os, device, ip)
    VALUES (:type, :message, :context, :app_version, :os, :device, :ip)
  `).run({
    type: r.type,
    message: r.message ?? "",
    context: r.context ? JSON.stringify(r.context) : null,
    app_version: r.appVersion ?? null,
    os: r.os ?? null,
    device: r.device ?? null,
    ip: r.ip ?? null,
  });
}

export function listReports(limit = 100) {
  return db.prepare(`SELECT * FROM reports ORDER BY created_at DESC LIMIT ?`).all(limit);
}

// ---- ratings ----
export function createRating(r) {
  db.prepare(`
    INSERT INTO ratings (stars, kind, route, from_stop, to_stop, system, app_version, device, ip)
    VALUES (:stars, :kind, :route, :from_stop, :to_stop, :system, :app_version, :device, :ip)
  `).run({
    stars: Math.max(1, Math.min(5, parseInt(r.stars, 10) || 0)),
    kind: r.kind ?? "bus",
    route: r.route ?? null,
    from_stop: r.from ?? null,
    to_stop: r.to ?? null,
    system: r.system ?? null,
    app_version: r.appVersion ?? null,
    device: r.device ?? null,
    ip: r.ip ?? null,
  });
}

export function listRatings(limit = 100) {
  return db.prepare(`SELECT * FROM ratings ORDER BY created_at DESC LIMIT ?`).all(limit);
}

/** Public per-route average — what the app shows next to a route, Google-Maps style. */
export function routeRatingStats(kind, route, system) {
  const row = db.prepare(`
    SELECT COUNT(*) n, AVG(stars) avg FROM ratings
    WHERE kind = ? AND route = ? AND (? IS NULL OR system = ?)
  `).get(kind, route, system ?? null, system ?? null);
  return { count: row.n, avg: row.avg ? Number(row.avg.toFixed(1)) : null };
}

// ---- observations (crowd-sourced board / alight events) ----
export function createObservation(o) {
  db.prepare(`
    INSERT INTO observations (route, plate, stop_uid, stop_name, kind, system, ip)
    VALUES (:route, :plate, :stop_uid, :stop_name, :kind, :system, :ip)
  `).run({
    route: o.route ?? null,
    plate: o.plate ?? null,
    stop_uid: o.stopUID ?? null,
    stop_name: o.stopName ?? null,
    kind: o.kind === "alight" ? "alight" : "board",
    system: o.system ?? null,
    ip: o.ip ?? null,
  });
}
export function listObservations({ route = null, limit = 100 } = {}) {
  if (route) {
    return db.prepare(
      `SELECT * FROM observations WHERE route = ? ORDER BY created_at DESC LIMIT ?`
    ).all(route, limit);
  }
  return db.prepare(`SELECT * FROM observations ORDER BY created_at DESC LIMIT ?`).all(limit);
}

// ---- bike cache (shared, refreshed by the poller) ----
export function setBikeCache(city, stations) {
  db.prepare(`
    INSERT INTO bike_cache (city, json, updated_at) VALUES (:city, :json, datetime('now'))
    ON CONFLICT(city) DO UPDATE SET json = excluded.json, updated_at = datetime('now')
  `).run({ city, json: JSON.stringify(stations) });
}
export function getBikeCache(city) {
  const r = db.prepare(`SELECT json, updated_at FROM bike_cache WHERE city = ?`).get(city);
  if (!r) return null;
  return { stations: JSON.parse(r.json), updatedAt: isoZ(r.updated_at) };
}
export function allBikeCaches() {
  return db.prepare(`SELECT city, json, updated_at FROM bike_cache`).all().map((r) => ({
    city: r.city, stations: JSON.parse(r.json), updatedAt: isoZ(r.updated_at),
  }));
}

// ---- speed/traffic-camera cache (shared, refreshed by the poller) ----
export function setSpeedcamCache(cams) {
  db.prepare(`
    INSERT INTO speedcam_cache (id, json, updated_at) VALUES ('all', :json, datetime('now'))
    ON CONFLICT(id) DO UPDATE SET json = excluded.json, updated_at = datetime('now')
  `).run({ json: JSON.stringify(cams) });
}
export function getSpeedcamCache() {
  const r = db.prepare(`SELECT json, updated_at FROM speedcam_cache WHERE id = 'all'`).get();
  if (!r) return null;
  return { cams: JSON.parse(r.json), updatedAt: isoZ(r.updated_at) };
}

export function ratingStats() {
  const row = db.prepare(`SELECT COUNT(*) n, AVG(stars) avg FROM ratings`).get();
  const hist = db.prepare(`SELECT stars, COUNT(*) c FROM ratings GROUP BY stars`).all();
  const byStar = { 1: 0, 2: 0, 3: 0, 4: 0, 5: 0 };
  for (const h of hist) byStar[h.stars] = h.c;
  return { count: row.n, avg: row.avg ? Number(row.avg.toFixed(2)) : null, byStar };
}

// ---- alert state ----
export function getAlertState(source) {
  return db.prepare(`SELECT * FROM alert_state WHERE source = ?`).get(source);
}
export function setAlertState(source, signature, abnormal) {
  db.prepare(`
    INSERT INTO alert_state (source, signature, abnormal, updated_at)
    VALUES (:source, :signature, :abnormal, datetime('now'))
    ON CONFLICT(source) DO UPDATE SET
      signature = excluded.signature, abnormal = excluded.abnormal, updated_at = datetime('now')
  `).run({ source, signature, abnormal: abnormal ? 1 : 0 });
}

function isoZ(sqliteDatetime) {
  return sqliteDatetime.replace(" ", "T") + "Z";
}
