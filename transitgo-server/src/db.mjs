// Uses Node's built-in SQLite (no native build). Node >= 22.5 (unflagged on 24).
import { DatabaseSync } from "node:sqlite";
import { mkdirSync } from "node:fs";
import { dirname } from "node:path";
import { ensureGtfsSchema } from "./gtfs/schema.mjs";

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

CREATE TABLE IF NOT EXISTS place_reviews (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  place_key   TEXT NOT NULL,
  place_name  TEXT NOT NULL,
  lat         REAL,
  lon         REAL,
  stars       INTEGER NOT NULL,
  comment     TEXT NOT NULL DEFAULT '',
  photo       TEXT,
  app_version TEXT,
  device      TEXT,
  ip          TEXT,
  reported    INTEGER NOT NULL DEFAULT 0,
  created_at  TEXT NOT NULL DEFAULT (datetime('now'))
);
CREATE INDEX IF NOT EXISTS idx_place_reviews_key ON place_reviews (place_key, created_at);

-- One row per report, with a reason — lets admins triage by category (廣告/不當言論/
-- 色情/其他) at a glance instead of just an opaque total count.
CREATE TABLE IF NOT EXISTS place_review_reports (
  id         INTEGER PRIMARY KEY AUTOINCREMENT,
  review_id  INTEGER NOT NULL,
  reason     TEXT NOT NULL DEFAULT 'other',
  device     TEXT,
  ip         TEXT,
  created_at TEXT NOT NULL DEFAULT (datetime('now'))
);
CREATE INDEX IF NOT EXISTS idx_place_review_reports_review ON place_review_reports (review_id);

-- User-submitted custom landmarks (not from Apple's POI index) — held for admin
-- approval before appearing to anyone else, same "never show unmoderated content as if
-- it were verified" principle as the rest of this app's real-data-only approach.
CREATE TABLE IF NOT EXISTS user_landmarks (
  id                INTEGER PRIMARY KEY AUTOINCREMENT,
  name              TEXT NOT NULL,
  description       TEXT NOT NULL DEFAULT '',
  category          TEXT NOT NULL DEFAULT 'other',
  lat               REAL NOT NULL,
  lon               REAL NOT NULL,
  photo             TEXT,
  is_business_claim INTEGER NOT NULL DEFAULT 0,
  business_verified INTEGER NOT NULL DEFAULT 0,
  business_hours    TEXT,
  app_version       TEXT,
  device            TEXT,
  ip                TEXT,
  approved          INTEGER NOT NULL DEFAULT 0,
  created_at        TEXT NOT NULL DEFAULT (datetime('now'))
);
CREATE INDEX IF NOT EXISTS idx_user_landmarks_approved ON user_landmarks (approved, created_at);

CREATE TABLE IF NOT EXISTS speedcam_cache (
  id         TEXT PRIMARY KEY DEFAULT 'all',
  json       TEXT NOT NULL,
  updated_at TEXT NOT NULL DEFAULT (datetime('now'))
);
`);

ensureGtfsSchema(db);

// place_reviews existed before the `reported` column — a plain CREATE TABLE IF NOT
// EXISTS above won't add it to an already-existing table, so check and migrate.
{
  const cols = db.prepare(`PRAGMA table_info(place_reviews)`).all().map((c) => c.name);
  if (!cols.includes("reported")) {
    db.exec(`ALTER TABLE place_reviews ADD COLUMN reported INTEGER NOT NULL DEFAULT 0`);
  }
  if (!cols.includes("photo")) {
    db.exec(`ALTER TABLE place_reviews ADD COLUMN photo TEXT`);
  }
  // One review per (place, device) — without this, a single phone could post an
  // unlimited number of 5-star reviews for the same place. Existing duplicates (from
  // before this was enforced) keep only the most recent one so the unique index below
  // can actually be created.
  db.exec(`
    DELETE FROM place_reviews WHERE device IS NOT NULL AND id NOT IN (
      SELECT MAX(id) FROM place_reviews WHERE device IS NOT NULL GROUP BY place_key, device
    )
  `);
  // Not partial (node:sqlite's ON CONFLICT matching doesn't resolve to a partial
  // index) — fine because NULL device rows never collide under a UNIQUE index anyway
  // (SQLite treats every NULL as distinct), so this only ever actually constrains rows
  // that do have a device id, same effect as a WHERE device IS NOT NULL index would give.
  db.exec(`CREATE UNIQUE INDEX IF NOT EXISTS idx_place_reviews_one_per_device
    ON place_reviews (place_key, device)`);
}

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

// ---- place reviews (real user-submitted, no external API) ----
/**
 * Re-submitting from the same device for the same place UPDATES that device's existing
 * review instead of adding a new one — the `idx_place_reviews_one_per_device` unique
 * index is what makes this a real constraint and not just app-side politeness. A
 * `device` of null (very old client) falls back to insert-only, since there's nothing
 * to key an upsert on.
 */
export function createPlaceReview(r) {
  const stars = Math.max(1, Math.min(5, parseInt(r.stars, 10) || 0));
  const comment = (r.comment ?? "").slice(0, 500);
  if (r.device) {
    db.prepare(`
      INSERT INTO place_reviews (place_key, place_name, lat, lon, stars, comment, photo, app_version, device, ip)
      VALUES (:place_key, :place_name, :lat, :lon, :stars, :comment, :photo, :app_version, :device, :ip)
      ON CONFLICT(place_key, device) DO UPDATE SET
        stars = excluded.stars, comment = excluded.comment, photo = excluded.photo,
        app_version = excluded.app_version, ip = excluded.ip,
        reported = 0, created_at = datetime('now')
    `).run({
      place_key: r.placeKey, place_name: r.placeName, lat: r.lat ?? null, lon: r.lon ?? null,
      stars, comment, photo: r.photo ?? null, app_version: r.appVersion ?? null,
      device: r.device, ip: r.ip ?? null,
    });
  } else {
    db.prepare(`
      INSERT INTO place_reviews (place_key, place_name, lat, lon, stars, comment, photo, app_version, device, ip)
      VALUES (:place_key, :place_name, :lat, :lon, :stars, :comment, :photo, :app_version, NULL, :ip)
    `).run({
      place_key: r.placeKey, place_name: r.placeName, lat: r.lat ?? null, lon: r.lon ?? null,
      stars, comment, photo: r.photo ?? null, app_version: r.appVersion ?? null, ip: r.ip ?? null,
    });
  }
}

export function listPlaceReviews(placeKey, limit = 50) {
  return db.prepare(`
    SELECT id, stars, comment, photo, created_at FROM place_reviews
    WHERE place_key = ? ORDER BY created_at DESC LIMIT ?
  `).all(placeKey, limit).map((row) => ({
    id: row.id, stars: row.stars, comment: row.comment, photo: row.photo, createdAt: isoZ(row.created_at),
  }));
}

/** A user flagged a review as inappropriate/spam — bumps a visible-to-admin counter, doesn't hide it automatically. */
// Fixed reason taxonomy — keep in sync with Swift's ReportReason.
export const REPORT_REASONS = ["spam", "offensive", "sexual", "harassment", "other"];

/** Logs a real reported reason (not just a bare +1) so admins can triage by category. */
export function reportPlaceReview(id, reason, ip) {
  const info = db.prepare(`UPDATE place_reviews SET reported = reported + 1 WHERE id = ?`).run(id);
  if (info.changes === 0) return false;
  db.prepare(`INSERT INTO place_review_reports (review_id, reason, ip) VALUES (?, ?, ?)`)
    .run(id, REPORT_REASONS.includes(reason) ? reason : "other", ip ?? null);
  return true;
}

export function deletePlaceReview(id) {
  const info = db.prepare(`DELETE FROM place_reviews WHERE id = ?`).run(id);
  db.prepare(`DELETE FROM place_review_reports WHERE review_id = ?`).run(id);
  return info.changes > 0;
}

/** Admin moderation view — most-reported first, each with a real reason breakdown
 * (e.g. {spam: 3, other: 1}) so a report count isn't just an opaque number. */
export function listAllPlaceReviews(limit = 200) {
  const rows = db.prepare(`
    SELECT * FROM place_reviews ORDER BY reported DESC, created_at DESC LIMIT ?
  `).all(limit);
  const reasonRows = db.prepare(`SELECT review_id, reason, COUNT(*) n FROM place_review_reports GROUP BY review_id, reason`).all();
  const reasonsByReview = new Map();
  for (const r of reasonRows) {
    if (!reasonsByReview.has(r.review_id)) reasonsByReview.set(r.review_id, {});
    reasonsByReview.get(r.review_id)[r.reason] = r.n;
  }
  return rows.map((r) => ({
    id: r.id, placeKey: r.place_key, placeName: r.place_name,
    stars: r.stars, comment: r.comment, reported: r.reported,
    reportReasons: reasonsByReview.get(r.id) ?? {},
    appVersion: r.app_version, createdAt: isoZ(r.created_at),
  }));
}

// ---- user-submitted landmarks (real user content, held for admin approval) ----
// Fixed taxonomy the app's picker uses — keep in sync with Swift's LandmarkCategory.
export const LANDMARK_CATEGORIES = [
  "foodDrink", "medical", "shopping", "transportation", "education", "finance",
  "government", "recreation", "sports", "lodging", "religion", "personalServices", "other",
];

export function createUserLandmark(r) {
  const category = LANDMARK_CATEGORIES.includes(r.category) ? r.category : "other";
  db.prepare(`
    INSERT INTO user_landmarks (name, description, category, lat, lon, photo, is_business_claim, business_hours, app_version, device, ip)
    VALUES (:name, :description, :category, :lat, :lon, :photo, :is_business_claim, :business_hours, :app_version, :device, :ip)
  `).run({
    name: r.name,
    description: (r.description ?? "").slice(0, 500),
    category,
    lat: r.lat,
    lon: r.lon,
    photo: r.photo ?? null,
    is_business_claim: r.isBusinessClaim ? 1 : 0,
    business_hours: (r.businessHours ?? "").slice(0, 500) || null,
    app_version: r.appVersion ?? null,
    device: r.device ?? null,
    ip: r.ip ?? null,
  });
}

/** Real approved landmarks near a point — Haversine done in JS since this table stays small. */
export function listApprovedLandmarksNear(lat, lon, radiusMeters = 1000) {
  const rows = db.prepare(`SELECT * FROM user_landmarks WHERE approved = 1`).all();
  const R = 6371000, p = Math.PI / 180;
  return rows.filter((r) => {
    const x = 0.5 - Math.cos((r.lat - lat) * p) / 2
      + (Math.cos(lat * p) * Math.cos(r.lat * p) * (1 - Math.cos((r.lon - lon) * p))) / 2;
    return 2 * R * Math.asin(Math.sqrt(x)) <= radiusMeters;
  }).map((r) => ({
    id: r.id, name: r.name, description: r.description, category: r.category, lat: r.lat, lon: r.lon, photo: r.photo,
    // Business hours/menu only shown once an admin has actually verified the claim —
    // an unverified "isBusinessClaim" submitter could type anything, so it can't be
    // presented to other users as real until checked.
    businessHours: r.business_verified ? r.business_hours : null,
    businessVerified: !!r.business_verified,
  }));
}

/** Admin moderation queue — pending ones first, since those need a decision. */
export function listAllUserLandmarks(limit = 200) {
  return db.prepare(`
    SELECT * FROM user_landmarks ORDER BY approved ASC, created_at DESC LIMIT ?
  `).all(limit).map((r) => ({
    id: r.id, name: r.name, description: r.description, category: r.category, lat: r.lat, lon: r.lon, photo: r.photo,
    isBusinessClaim: !!r.is_business_claim, businessVerified: !!r.business_verified, businessHours: r.business_hours,
    approved: !!r.approved, appVersion: r.app_version, createdAt: isoZ(r.created_at),
  }));
}

export function approveUserLandmark(id) {
  const info = db.prepare(`UPDATE user_landmarks SET approved = 1 WHERE id = ?`).run(id);
  return info.changes > 0;
}

/** Admin manually confirmed this really is the business owner — e.g. checked a business
 * registration or matching contact info outside the app. There's no automated identity
 * verification here; this is a human decision the admin panel just records. */
export function verifyUserLandmarkBusiness(id) {
  const info = db.prepare(`UPDATE user_landmarks SET business_verified = 1 WHERE id = ?`).run(id);
  return info.changes > 0;
}

export function deleteUserLandmark(id) {
  const info = db.prepare(`DELETE FROM user_landmarks WHERE id = ?`).run(id);
  return info.changes > 0;
}

export function placeReviewStats(placeKey) {
  const row = db.prepare(`SELECT COUNT(*) n, AVG(stars) avg FROM place_reviews WHERE place_key = ?`).get(placeKey);
  return { count: row.n, avg: row.avg ? Number(row.avg.toFixed(1)) : null };
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
