// Two backends: Postgres (Supabase) when DATABASE_URL is set — real persistent storage,
// survives a Render redeploy — or node:sqlite otherwise (local dev fallback). Every
// query below uses syntax valid on both (ON CONFLICT ... DO UPDATE SET x = excluded.x
// works the same way on both engines); only table creation/migration differs, since
// AUTOINCREMENT/PRAGMA are SQLite-specific and Postgres has its own equivalents.
import { mkdirSync } from "node:fs";
import { dirname } from "node:path";
import { ensureGtfsSchema } from "./gtfs/schema.mjs";

const usingPg = !!process.env.DATABASE_URL;
export let db;

if (usingPg) {
  const { PgDatabase } = await import("./pgdb.mjs");
  db = new PgDatabase(process.env.DATABASE_URL);
} else {
  const { DatabaseSync } = await import("node:sqlite");
  const DB_PATH = process.env.DB_PATH || "./data/transitgo.db";
  mkdirSync(dirname(DB_PATH), { recursive: true });
  db = new DatabaseSync(DB_PATH);
  await db.exec("PRAGMA journal_mode = WAL;");
}

if (usingPg) {
  await db.exec(`
    CREATE TABLE IF NOT EXISTS devices (
      token       TEXT PRIMARY KEY,
      platform    TEXT,
      app_version TEXT,
      created_at  TIMESTAMPTZ DEFAULT now(),
      last_seen   TIMESTAMPTZ DEFAULT now()
    );

    CREATE TABLE IF NOT EXISTS announcements (
      id         SERIAL PRIMARY KEY,
      category   TEXT NOT NULL,
      severity   TEXT NOT NULL DEFAULT 'info',
      title      TEXT NOT NULL,
      body       TEXT NOT NULL DEFAULT '',
      source     TEXT NOT NULL DEFAULT 'admin',
      active     INTEGER NOT NULL DEFAULT 1,
      created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
      expires_at TIMESTAMPTZ
    );
    CREATE INDEX IF NOT EXISTS idx_ann_created ON announcements (created_at);

    CREATE TABLE IF NOT EXISTS reports (
      id          SERIAL PRIMARY KEY,
      type        TEXT NOT NULL,
      message     TEXT NOT NULL DEFAULT '',
      context     TEXT,
      app_version TEXT,
      os          TEXT,
      device      TEXT,
      ip          TEXT,
      created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
    );
    CREATE INDEX IF NOT EXISTS idx_rep_created ON reports (created_at);

    CREATE TABLE IF NOT EXISTS alert_state (
      source     TEXT PRIMARY KEY,
      signature  TEXT,
      abnormal   INTEGER NOT NULL DEFAULT 0,
      updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
    );

    CREATE TABLE IF NOT EXISTS ratings (
      id          SERIAL PRIMARY KEY,
      stars       INTEGER NOT NULL,
      kind        TEXT NOT NULL DEFAULT 'bus',
      route       TEXT,
      from_stop   TEXT,
      to_stop     TEXT,
      system      TEXT,
      app_version TEXT,
      device      TEXT,
      ip          TEXT,
      created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
    );
    CREATE INDEX IF NOT EXISTS idx_rating_created ON ratings (created_at);

    CREATE TABLE IF NOT EXISTS observations (
      id         SERIAL PRIMARY KEY,
      route      TEXT,
      plate      TEXT,
      stop_uid   TEXT,
      stop_name  TEXT,
      kind       TEXT NOT NULL DEFAULT 'board',
      system     TEXT,
      ip         TEXT,
      created_at TIMESTAMPTZ NOT NULL DEFAULT now()
    );
    CREATE INDEX IF NOT EXISTS idx_obs_route ON observations (route, created_at);

    CREATE TABLE IF NOT EXISTS bike_cache (
      city       TEXT PRIMARY KEY,
      json       TEXT NOT NULL,
      updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
    );

    CREATE TABLE IF NOT EXISTS place_reviews (
      id          SERIAL PRIMARY KEY,
      place_key   TEXT NOT NULL,
      place_name  TEXT NOT NULL,
      lat         DOUBLE PRECISION,
      lon         DOUBLE PRECISION,
      stars       INTEGER NOT NULL,
      comment     TEXT NOT NULL DEFAULT '',
      photo       TEXT,
      app_version TEXT,
      device      TEXT,
      ip          TEXT,
      reported    INTEGER NOT NULL DEFAULT 0,
      created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
    );
    CREATE INDEX IF NOT EXISTS idx_place_reviews_key ON place_reviews (place_key, created_at);
    ALTER TABLE place_reviews ADD COLUMN IF NOT EXISTS reported INTEGER NOT NULL DEFAULT 0;
    ALTER TABLE place_reviews ADD COLUMN IF NOT EXISTS photo TEXT;
    DELETE FROM place_reviews WHERE device IS NOT NULL AND id NOT IN (
      SELECT MAX(id) FROM place_reviews WHERE device IS NOT NULL GROUP BY place_key, device
    );
    CREATE UNIQUE INDEX IF NOT EXISTS idx_place_reviews_one_per_device ON place_reviews (place_key, device);

    CREATE TABLE IF NOT EXISTS place_review_reports (
      id         SERIAL PRIMARY KEY,
      review_id  INTEGER NOT NULL,
      reason     TEXT NOT NULL DEFAULT 'other',
      device     TEXT,
      ip         TEXT,
      created_at TIMESTAMPTZ NOT NULL DEFAULT now()
    );
    CREATE INDEX IF NOT EXISTS idx_place_review_reports_review ON place_review_reports (review_id);

    CREATE TABLE IF NOT EXISTS user_landmarks (
      id                SERIAL PRIMARY KEY,
      name              TEXT NOT NULL,
      description       TEXT NOT NULL DEFAULT '',
      category          TEXT NOT NULL DEFAULT 'other',
      lat               DOUBLE PRECISION NOT NULL,
      lon               DOUBLE PRECISION NOT NULL,
      photo             TEXT,
      is_business_claim INTEGER NOT NULL DEFAULT 0,
      business_verified INTEGER NOT NULL DEFAULT 0,
      business_hours    TEXT,
      phone             TEXT,
      app_version       TEXT,
      device            TEXT,
      ip                TEXT,
      approved          INTEGER NOT NULL DEFAULT 0,
      reported          INTEGER NOT NULL DEFAULT 0,
      created_at        TIMESTAMPTZ NOT NULL DEFAULT now()
    );
    CREATE INDEX IF NOT EXISTS idx_user_landmarks_approved ON user_landmarks (approved, created_at);

    CREATE TABLE IF NOT EXISTS user_landmark_reports (
      id          SERIAL PRIMARY KEY,
      landmark_id INTEGER NOT NULL,
      reason      TEXT NOT NULL DEFAULT 'other',
      device      TEXT,
      ip          TEXT,
      created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
    );
    CREATE INDEX IF NOT EXISTS idx_user_landmark_reports_landmark ON user_landmark_reports (landmark_id);

    CREATE TABLE IF NOT EXISTS shares (
      token         TEXT PRIMARY KEY,
      title         TEXT,
      segments_json TEXT NOT NULL,
      created_at_ms BIGINT NOT NULL,
      expires_at_ms BIGINT NOT NULL
    );
    CREATE INDEX IF NOT EXISTS idx_shares_expires ON shares (expires_at_ms);

    CREATE TABLE IF NOT EXISTS speedcam_cache (
      id         TEXT PRIMARY KEY DEFAULT 'all',
      json       TEXT NOT NULL,
      updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
    );
  `);
} else {
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

    CREATE TABLE IF NOT EXISTS place_review_reports (
      id         INTEGER PRIMARY KEY AUTOINCREMENT,
      review_id  INTEGER NOT NULL,
      reason     TEXT NOT NULL DEFAULT 'other',
      device     TEXT,
      ip         TEXT,
      created_at TEXT NOT NULL DEFAULT (datetime('now'))
    );
    CREATE INDEX IF NOT EXISTS idx_place_review_reports_review ON place_review_reports (review_id);

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
      phone             TEXT,
      app_version       TEXT,
      device            TEXT,
      ip                TEXT,
      approved          INTEGER NOT NULL DEFAULT 0,
      reported          INTEGER NOT NULL DEFAULT 0,
      created_at        TEXT NOT NULL DEFAULT (datetime('now'))
    );
    CREATE INDEX IF NOT EXISTS idx_user_landmarks_approved ON user_landmarks (approved, created_at);

    CREATE TABLE IF NOT EXISTS user_landmark_reports (
      id          INTEGER PRIMARY KEY AUTOINCREMENT,
      landmark_id INTEGER NOT NULL,
      reason      TEXT NOT NULL DEFAULT 'other',
      device      TEXT,
      ip          TEXT,
      created_at  TEXT NOT NULL DEFAULT (datetime('now'))
    );
    CREATE INDEX IF NOT EXISTS idx_user_landmark_reports_landmark ON user_landmark_reports (landmark_id);

    CREATE TABLE IF NOT EXISTS shares (
      token         TEXT PRIMARY KEY,
      title         TEXT,
      segments_json TEXT NOT NULL,
      created_at_ms BIGINT NOT NULL,
      expires_at_ms BIGINT NOT NULL
    );
    CREATE INDEX IF NOT EXISTS idx_shares_expires ON shares (expires_at_ms);

    CREATE TABLE IF NOT EXISTS speedcam_cache (
      id         TEXT PRIMARY KEY DEFAULT 'all',
      json       TEXT NOT NULL,
      updated_at TEXT NOT NULL DEFAULT (datetime('now'))
    );
  `);

  await ensureGtfsSchema(db);

  // place_reviews existed before the `reported`/`photo` columns and the one-per-device
  // unique index — a plain CREATE TABLE IF NOT EXISTS won't add those to an
  // already-existing table, so check and migrate (SQLite only — Postgres's ADD COLUMN
  // IF NOT EXISTS above already handles this unconditionally).
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
  db.exec(`CREATE UNIQUE INDEX IF NOT EXISTS idx_place_reviews_one_per_device
    ON place_reviews (place_key, device)`);
}

if (usingPg) {
  // Idempotent (every statement is CREATE ... IF NOT EXISTS) — so if this boot loses a
  // lock-contention race against another connection mid-transaction on a gtfs_* table
  // (e.g. an in-flight ingest request) and Postgres's statement_timeout kills it, that's
  // safe to skip rather than fatal: the schema already exists from a prior successful
  // boot, and a later restart will pick up any genuinely new column/table once the
  // contention clears. Letting this crash the whole process was causing a boot
  // crash-loop that made the underlying contention worse, not better.
  try {
    await ensureGtfsSchema(db);
  } catch (e) {
    console.warn(`[db] ensureGtfsSchema skipped this boot: ${e.message}`);
  }
}

// ---- devices ----
export async function upsertDevice({ token, platform, appVersion }) {
  await db.prepare(`
    INSERT INTO devices (token, platform, app_version, last_seen)
    VALUES (:token, :platform, :appVersion, ${usingPg ? "now()" : "datetime('now')"})
    ON CONFLICT(token) DO UPDATE SET
      platform = excluded.platform,
      app_version = excluded.app_version,
      last_seen = ${usingPg ? "now()" : "datetime('now')"}
  `).run({ token, platform: platform ?? null, appVersion: appVersion ?? null });
}

export async function allDeviceTokens() {
  return (await db.prepare(`SELECT token FROM devices`).all()).map((r) => r.token);
}

export async function removeDevice(token) {
  await db.prepare(`DELETE FROM devices WHERE token = ?`).run(token);
}

// ---- announcements ----
export async function createAnnouncement(a) {
  const params = {
    category: a.category,
    severity: a.severity ?? "info",
    title: a.title,
    body: a.body ?? "",
    source: a.source ?? "admin",
    expires_at: a.expiresAt ?? null,
  };
  let id;
  if (usingPg) {
    const row = await db.prepare(`
      INSERT INTO announcements (category, severity, title, body, source, expires_at)
      VALUES (:category, :severity, :title, :body, :source, :expires_at)
      RETURNING id
    `).get(params);
    id = row.id;
  } else {
    const info = await db.prepare(`
      INSERT INTO announcements (category, severity, title, body, source, expires_at)
      VALUES (:category, :severity, :title, :body, :source, :expires_at)
    `).run(params);
    id = Number(info.lastInsertRowid);
  }
  return getAnnouncement(id);
}

export async function getAnnouncement(id) {
  return serializeAnnouncement(await db.prepare(`SELECT * FROM announcements WHERE id = ?`).get(id));
}

export async function listAnnouncements({ since, includeInactive = false } = {}) {
  const rows = await db.prepare(`
    SELECT * FROM announcements
    WHERE (:includeInactive = 1 OR active = 1)
      AND (expires_at IS NULL OR expires_at > ${usingPg ? "now()" : "datetime('now')"})
      AND (CAST(:since AS TEXT) IS NULL OR created_at > :since)
    ORDER BY created_at DESC
    LIMIT 200
  `).all({ since: since ?? null, includeInactive: includeInactive ? 1 : 0 });
  return rows.map(serializeAnnouncement);
}

export async function deactivateAnnouncement(id) {
  await db.prepare(`UPDATE announcements SET active = 0 WHERE id = ?`).run(id);
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
export async function createReport(r) {
  await db.prepare(`
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

export async function listReports(limit = 100) {
  return db.prepare(`SELECT * FROM reports ORDER BY created_at DESC LIMIT ?`).all(limit);
}

// ---- ratings ----
export async function createRating(r) {
  await db.prepare(`
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

export async function listRatings(limit = 100) {
  return db.prepare(`SELECT * FROM ratings ORDER BY created_at DESC LIMIT ?`).all(limit);
}

/** Public per-route average — what the app shows next to a route, Google-Maps style. */
export async function routeRatingStats(kind, route, system) {
  const row = await db.prepare(`
    SELECT COUNT(*) n, AVG(stars) avg FROM ratings
    WHERE kind = ? AND route = ? AND (CAST(? AS TEXT) IS NULL OR system = ?)
  `).get(kind, route, system ?? null, system ?? null);
  return { count: Number(row.n), avg: row.avg ? Number(Number(row.avg).toFixed(1)) : null };
}

// ---- observations (crowd-sourced board / alight events) ----
export async function createObservation(o) {
  await db.prepare(`
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
export async function listObservations({ route = null, limit = 100 } = {}) {
  if (route) {
    return db.prepare(
      `SELECT * FROM observations WHERE route = ? ORDER BY created_at DESC LIMIT ?`
    ).all(route, limit);
  }
  return db.prepare(`SELECT * FROM observations ORDER BY created_at DESC LIMIT ?`).all(limit);
}

// ---- bike cache (shared, refreshed by the poller) ----
export async function setBikeCache(city, stations) {
  await db.prepare(`
    INSERT INTO bike_cache (city, json, updated_at) VALUES (:city, :json, ${usingPg ? "now()" : "datetime('now')"})
    ON CONFLICT(city) DO UPDATE SET json = excluded.json, updated_at = ${usingPg ? "now()" : "datetime('now')"}
  `).run({ city, json: JSON.stringify(stations) });
}
export async function getBikeCache(city) {
  const r = await db.prepare(`SELECT json, updated_at FROM bike_cache WHERE city = ?`).get(city);
  if (!r) return null;
  return { stations: JSON.parse(r.json), updatedAt: isoZ(r.updated_at) };
}
export async function allBikeCaches() {
  const rows = await db.prepare(`SELECT city, json, updated_at FROM bike_cache`).all();
  return rows.map((r) => ({
    city: r.city, stations: JSON.parse(r.json), updatedAt: isoZ(r.updated_at),
  }));
}

// ---- speed/traffic-camera cache (shared, refreshed by the poller) ----
export async function setSpeedcamCache(cams) {
  await db.prepare(`
    INSERT INTO speedcam_cache (id, json, updated_at) VALUES ('all', :json, ${usingPg ? "now()" : "datetime('now')"})
    ON CONFLICT(id) DO UPDATE SET json = excluded.json, updated_at = ${usingPg ? "now()" : "datetime('now')"}
  `).run({ json: JSON.stringify(cams) });
}
export async function getSpeedcamCache() {
  const r = await db.prepare(`SELECT json, updated_at FROM speedcam_cache WHERE id = 'all'`).get();
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
export async function createPlaceReview(r) {
  const stars = Math.max(1, Math.min(5, parseInt(r.stars, 10) || 0));
  const comment = (r.comment ?? "").slice(0, 500);
  const now = usingPg ? "now()" : "datetime('now')";
  if (r.device) {
    await db.prepare(`
      INSERT INTO place_reviews (place_key, place_name, lat, lon, stars, comment, photo, app_version, device, ip)
      VALUES (:place_key, :place_name, :lat, :lon, :stars, :comment, :photo, :app_version, :device, :ip)
      ON CONFLICT(place_key, device) DO UPDATE SET
        stars = excluded.stars, comment = excluded.comment, photo = excluded.photo,
        app_version = excluded.app_version, ip = excluded.ip,
        reported = 0, created_at = ${now}
    `).run({
      place_key: r.placeKey, place_name: r.placeName, lat: r.lat ?? null, lon: r.lon ?? null,
      stars, comment, photo: r.photo ?? null, app_version: r.appVersion ?? null,
      device: r.device, ip: r.ip ?? null,
    });
  } else {
    await db.prepare(`
      INSERT INTO place_reviews (place_key, place_name, lat, lon, stars, comment, photo, app_version, device, ip)
      VALUES (:place_key, :place_name, :lat, :lon, :stars, :comment, :photo, :app_version, NULL, :ip)
    `).run({
      place_key: r.placeKey, place_name: r.placeName, lat: r.lat ?? null, lon: r.lon ?? null,
      stars, comment, photo: r.photo ?? null, app_version: r.appVersion ?? null, ip: r.ip ?? null,
    });
  }
}

export async function listPlaceReviews(placeKey, limit = 50) {
  const rows = await db.prepare(`
    SELECT id, stars, comment, photo, created_at FROM place_reviews
    WHERE place_key = ? ORDER BY created_at DESC LIMIT ?
  `).all(placeKey, limit);
  return rows.map((row) => ({
    id: row.id, stars: row.stars, comment: row.comment, photo: row.photo, createdAt: isoZ(row.created_at),
  }));
}

// Fixed reason taxonomy — keep in sync with Swift's ReportReason.
export const REPORT_REASONS = ["spam", "offensive", "sexual", "harassment", "other"];

/** Logs a real reported reason (not just a bare +1) so admins can triage by category. */
export async function reportPlaceReview(id, reason, ip) {
  const info = await db.prepare(`UPDATE place_reviews SET reported = reported + 1 WHERE id = ?`).run(id);
  if (info.changes === 0) return false;
  await db.prepare(`INSERT INTO place_review_reports (review_id, reason, ip) VALUES (?, ?, ?)`)
    .run(id, REPORT_REASONS.includes(reason) ? reason : "other", ip ?? null);
  return true;
}

export async function deletePlaceReview(id) {
  const info = await db.prepare(`DELETE FROM place_reviews WHERE id = ?`).run(id);
  await db.prepare(`DELETE FROM place_review_reports WHERE review_id = ?`).run(id);
  return info.changes > 0;
}

/** Admin moderation view — most-reported first, each with a real reason breakdown
 * (e.g. {spam: 3, other: 1}) so a report count isn't just an opaque number. */
export async function listAllPlaceReviews(limit = 200) {
  const rows = await db.prepare(`
    SELECT * FROM place_reviews ORDER BY reported DESC, created_at DESC LIMIT ?
  `).all(limit);
  const reasonRows = await db.prepare(`SELECT review_id, reason, COUNT(*) n FROM place_review_reports GROUP BY review_id, reason`).all();
  const reasonsByReview = new Map();
  for (const r of reasonRows) {
    if (!reasonsByReview.has(r.review_id)) reasonsByReview.set(r.review_id, {});
    reasonsByReview.get(r.review_id)[r.reason] = Number(r.n);
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

export async function createUserLandmark(r) {
  const category = LANDMARK_CATEGORIES.includes(r.category) ? r.category : "other";
  await db.prepare(`
    INSERT INTO user_landmarks (name, description, category, lat, lon, photo, is_business_claim, business_hours, phone, app_version, device, ip)
    VALUES (:name, :description, :category, :lat, :lon, :photo, :is_business_claim, :business_hours, :phone, :app_version, :device, :ip)
  `).run({
    name: r.name,
    description: (r.description ?? "").slice(0, 500),
    category,
    lat: r.lat,
    lon: r.lon,
    photo: r.photo ?? null,
    is_business_claim: r.isBusinessClaim ? 1 : 0,
    business_hours: (r.businessHours ?? "").slice(0, 500) || null,
    phone: (r.phone ?? "").slice(0, 50) || null,
    app_version: r.appVersion ?? null,
    device: r.device ?? null,
    ip: r.ip ?? null,
  });
}

/** Real approved landmarks near a point — Haversine done in JS since this table stays small. */
export async function listApprovedLandmarksNear(lat, lon, radiusMeters = 1000) {
  const rows = await db.prepare(`SELECT * FROM user_landmarks WHERE approved = 1`).all();
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
    phone: r.business_verified ? r.phone : null,
    businessVerified: !!r.business_verified,
  }));
}

/** Admin moderation queue — pending ones first, since those need a decision. */
export async function listAllUserLandmarks(limit = 200) {
  const rows = await db.prepare(`
    SELECT * FROM user_landmarks ORDER BY approved ASC, created_at DESC LIMIT ?
  `).all(limit);
  const reasonRows = await db.prepare(`SELECT landmark_id, reason, COUNT(*) n FROM user_landmark_reports GROUP BY landmark_id, reason`).all();
  const reasonsByLandmark = new Map();
  for (const r of reasonRows) {
    if (!reasonsByLandmark.has(r.landmark_id)) reasonsByLandmark.set(r.landmark_id, {});
    reasonsByLandmark.get(r.landmark_id)[r.reason] = Number(r.n);
  }
  return rows.map((r) => ({
    id: r.id, name: r.name, description: r.description, category: r.category, lat: r.lat, lon: r.lon, photo: r.photo,
    isBusinessClaim: !!r.is_business_claim, businessVerified: !!r.business_verified, businessHours: r.business_hours, phone: r.phone,
    approved: !!r.approved, reported: r.reported, reportReasons: reasonsByLandmark.get(r.id) ?? {},
    appVersion: r.app_version, createdAt: isoZ(r.created_at),
  }));
}

export async function approveUserLandmark(id) {
  const info = await db.prepare(`UPDATE user_landmarks SET approved = 1 WHERE id = ?`).run(id);
  return info.changes > 0;
}

/** Admin manually confirmed this really is the business owner — e.g. checked a business
 * registration or matching contact info outside the app. There's no automated identity
 * verification here; this is a human decision the admin panel just records. */
export async function verifyUserLandmarkBusiness(id) {
  const info = await db.prepare(`UPDATE user_landmarks SET business_verified = 1 WHERE id = ?`).run(id);
  return info.changes > 0;
}

export async function deleteUserLandmark(id) {
  const info = await db.prepare(`DELETE FROM user_landmarks WHERE id = ?`).run(id);
  await db.prepare(`DELETE FROM user_landmark_reports WHERE landmark_id = ?`).run(id);
  return info.changes > 0;
}

/** Logs a real report reason for a landmark, same pattern as place reviews. */
export async function reportUserLandmark(id, reason, ip) {
  const info = await db.prepare(`UPDATE user_landmarks SET reported = reported + 1 WHERE id = ?`).run(id);
  if (info.changes === 0) return false;
  await db.prepare(`INSERT INTO user_landmark_reports (landmark_id, reason, ip) VALUES (?, ?, ?)`)
    .run(id, REPORT_REASONS.includes(reason) ? reason : "other", ip ?? null);
  return true;
}

/** This device's own submitted landmarks (any status) — so a submitter can see
 * "pending"/"approved"/"verified" and, once verified, actually edit their listing. */
export async function listMyUserLandmarks(device) {
  const rows = await db.prepare(`
    SELECT * FROM user_landmarks WHERE device = ? ORDER BY created_at DESC
  `).all(device);
  return rows.map((r) => ({
    id: r.id, name: r.name, description: r.description, category: r.category, lat: r.lat, lon: r.lon, photo: r.photo,
    isBusinessClaim: !!r.is_business_claim, businessVerified: !!r.business_verified, businessHours: r.business_hours, phone: r.phone,
    approved: !!r.approved, createdAt: isoZ(r.created_at),
  }));
}

/**
 * A verified business owner editing their own real listing — the ONLY identity check
 * available without a real account system is "does the device id match the one that
 * originally submitted this", so that's what gates it, on top of requiring
 * business_verified (an admin's real, manual confirmation) — an unverified claimant
 * can't use this to rewrite their listing into something an admin never actually
 * checked. Only the provided fields are changed.
 */
export async function updateMyUserLandmark(id, device, fields) {
  const row = await db.prepare(`SELECT device, business_verified FROM user_landmarks WHERE id = ?`).get(id);
  if (!row || row.device !== device || !row.business_verified) return false;
  const sets = [];
  const params = { id };
  if (typeof fields.description === "string") { sets.push("description = :description"); params.description = fields.description.slice(0, 500); }
  if (typeof fields.businessHours === "string") { sets.push("business_hours = :business_hours"); params.business_hours = fields.businessHours.slice(0, 500); }
  if (typeof fields.photo === "string") { sets.push("photo = :photo"); params.photo = fields.photo; }
  if (typeof fields.phone === "string") { sets.push("phone = :phone"); params.phone = fields.phone.slice(0, 50); }
  if (typeof fields.lat === "number" && typeof fields.lon === "number") {
    sets.push("lat = :lat", "lon = :lon");
    params.lat = fields.lat; params.lon = fields.lon;
  }
  if (sets.length === 0) return false;
  await db.prepare(`UPDATE user_landmarks SET ${sets.join(", ")} WHERE id = :id`).run(params);
  return true;
}

export async function placeReviewStats(placeKey) {
  const row = await db.prepare(`SELECT COUNT(*) n, AVG(stars) avg FROM place_reviews WHERE place_key = ?`).get(placeKey);
  return { count: Number(row.n), avg: row.avg ? Number(Number(row.avg).toFixed(1)) : null };
}

export async function ratingStats() {
  const row = await db.prepare(`SELECT COUNT(*) n, AVG(stars) avg FROM ratings`).get();
  const hist = await db.prepare(`SELECT stars, COUNT(*) c FROM ratings GROUP BY stars`).all();
  const byStar = { 1: 0, 2: 0, 3: 0, 4: 0, 5: 0 };
  for (const h of hist) byStar[h.stars] = Number(h.c);
  return { count: Number(row.n), avg: row.avg ? Number(Number(row.avg).toFixed(2)) : null, byStar };
}

// ---- alert state ----
export async function getAlertState(source) {
  return db.prepare(`SELECT * FROM alert_state WHERE source = ?`).get(source);
}
export async function setAlertState(source, signature, abnormal) {
  const now = usingPg ? "now()" : "datetime('now')";
  await db.prepare(`
    INSERT INTO alert_state (source, signature, abnormal, updated_at)
    VALUES (:source, :signature, :abnormal, ${now})
    ON CONFLICT(source) DO UPDATE SET
      signature = excluded.signature, abnormal = excluded.abnormal, updated_at = ${now}
  `).run({ source, signature, abnormal: abnormal ? 1 : 0 });
}

function isoZ(value) {
  if (value == null) return value;
  if (value instanceof Date) return value.toISOString();
  return String(value).replace(" ", "T") + "Z";
}


// ---- Shared trip links (see shares.mjs) -------------------------------------------------------

export async function createShare({ token, title, segments, nowMs, expiresAtMs }) {
  // Expired links are useless and hold nothing we need: sweep them on every create.
  await db.prepare(`DELETE FROM shares WHERE expires_at_ms <= :now`).run({ now: nowMs });
  await db.prepare(`
    INSERT INTO shares (token, title, segments_json, created_at_ms, expires_at_ms)
    VALUES (:token, :title, :segments_json, :created, :expires)
  `).run({ token, title: title ?? null, segments_json: JSON.stringify(segments), created: nowMs, expires: expiresAtMs });
}

/** The stored share, or null. Expiry is the caller's decision (shares.mjs isExpired). */
export async function getShare(token) {
  const r = await db.prepare(`SELECT token, title, segments_json, created_at_ms, expires_at_ms FROM shares WHERE token = :token`).get({ token });
  if (!r) return null;
  return { token: r.token, title: r.title, segments: JSON.parse(r.segments_json), created_at_ms: Number(r.created_at_ms), expires_at_ms: Number(r.expires_at_ms) };
}

export async function deleteShare(token) {
  await db.prepare(`DELETE FROM shares WHERE token = :token`).run({ token });
}
