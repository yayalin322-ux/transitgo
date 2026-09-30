// Two backends: Postgres (Supabase) when DATABASE_URL is set — real persistent storage,
// survives a Render redeploy — or node:sqlite otherwise (local dev fallback). Every
// query below uses syntax valid on both (ON CONFLICT ... DO UPDATE SET x = excluded.x
// works the same way on both engines); only table creation/migration differs, since
// AUTOINCREMENT/PRAGMA are SQLite-specific and Postgres has its own equivalents.
import { mkdirSync } from "node:fs";
import { dirname } from "node:path";
import { ensureGtfsSchema } from "./gtfs/schema.mjs";
import { isOpenNow, normalizePhotos } from "./landmarks.mjs";

const usingPg = !!process.env.DATABASE_URL;
export let db;

// One-time remap for landmarks saved under the old, coarser 13-category taxonomy (used by the
// schema-migration blocks below) — a representative fine category per old group, so existing
// listings get *something specific* rather than every old row silently bucketing into "other".
// Safe to run every boot: once a row's category is no longer one of these old keys, its WHERE
// clause never matches again.
const OLD_CATEGORY_REMAP = {
  foodDrink: "restaurant", medical: "clinic", shopping: "marketplace", transportation: "parkingLot",
  education: "school", finance: "bank", government: "cityHall", recreation: "park",
  sports: "gym", lodging: "hotel", religion: "temple", personalServices: "repairShop",
};

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

    -- One row per station per hourly snapshot, for cities in BIKE_HISTORY_CITIES (see
    -- bikepoller.mjs) — the live bike_cache above only ever holds the CURRENT state, this is
    -- what lets a page later show a real usage-over-time trend instead of just "right now".
    -- recorded_at_ms (epoch ms, set from JS) rather than a DB-side now()/datetime('now') — a
    -- text TIMESTAMPTZ column compared against a JS-built ISO string breaks across backends
    -- (Postgres's own format vs SQLite's space-separated datetime('now') don't string-compare
    -- the same way); a plain BIGINT sidesteps that entirely, same as shares.expires_at_ms.
    CREATE TABLE IF NOT EXISTS bike_station_history (
      id             SERIAL PRIMARY KEY,
      city           TEXT NOT NULL,
      station_uid    TEXT NOT NULL,
      name           TEXT,
      lat            DOUBLE PRECISION,
      lon            DOUBLE PRECISION,
      capacity       INTEGER,
      rent           INTEGER,
      ret            INTEGER,
      recorded_at_ms BIGINT NOT NULL
    );
    CREATE INDEX IF NOT EXISTS idx_bike_history_city_time ON bike_station_history (city, recorded_at_ms);

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
      email       TEXT,
      ip          TEXT,
      reported    INTEGER NOT NULL DEFAULT 0,
      created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
    );
    CREATE INDEX IF NOT EXISTS idx_place_reviews_key ON place_reviews (place_key, created_at);
    ALTER TABLE place_reviews ADD COLUMN IF NOT EXISTS reported INTEGER NOT NULL DEFAULT 0;
    ALTER TABLE place_reviews ADD COLUMN IF NOT EXISTS photo TEXT;
    -- Email 驗證改成留言的必要條件（防止匿名亂留言）；既有的舊留言沒有這欄，NULL 保留原樣，不會被回溯要求驗證。
    ALTER TABLE place_reviews ADD COLUMN IF NOT EXISTS email TEXT;
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
      business_status   TEXT NOT NULL DEFAULT 'open',
      app_version       TEXT,
      device            TEXT,
      email             TEXT,
      ip                TEXT,
      approved          INTEGER NOT NULL DEFAULT 0,
      reported          INTEGER NOT NULL DEFAULT 0,
      created_at        TIMESTAMPTZ NOT NULL DEFAULT now()
    );
    CREATE INDEX IF NOT EXISTS idx_user_landmarks_approved ON user_landmarks (approved, created_at);
    -- 店家自己驗證信箱後留下的信箱（跟手動驗證並存：兩條路都能讓 business_verified 變 true）。
    ALTER TABLE user_landmarks ADD COLUMN IF NOT EXISTS email TEXT;
    -- 'open' | 'temporarily_closed' | 'permanently_closed' —— 只有已驗證店家自己能改（見 updateMyUserLandmark）。
    ALTER TABLE user_landmarks ADD COLUMN IF NOT EXISTS business_status TEXT NOT NULL DEFAULT 'open';
    -- Google 地圖風格的店家詳情：相簿（JSON 陣列，取代單張 photo——photo 仍保留當作第一張的舊資料相容）、
    -- 結構化營業時間（JSON：{mon:{open,close}|null, ...}，用來算「現在有沒有開」，跟舊的自由文字
    -- business_hours 並存——沒填結構化時就照舊顯示那段文字）、特色標籤（JSON 字串陣列，見 shares.mjs 之外
    -- 的 LANDMARK_FEATURES 固定清單）。
    ALTER TABLE user_landmarks ADD COLUMN IF NOT EXISTS photos_json TEXT;
    ALTER TABLE user_landmarks ADD COLUMN IF NOT EXISTS hours_json TEXT;
    ALTER TABLE user_landmarks ADD COLUMN IF NOT EXISTS features_json TEXT;
    -- 外部連結（菜單/線上點餐/官網/外送，見 landmarks.mjs 的 LANDMARK_LINK_KINDS）跟自報的價位
    -- （1~4，Google 地圖式的 $ ~ $$$$）。
    ALTER TABLE user_landmarks ADD COLUMN IF NOT EXISTS links_json TEXT;
    ALTER TABLE user_landmarks ADD COLUMN IF NOT EXISTS price_range INTEGER;
    -- 舊的粗分類（這個功能改成 Google 地圖那樣細分類之前）換成細分類裡的代表值，
    -- 不然舊地標全部會被 App 端當成無法辨識、退回顯示成「其他」。
    UPDATE user_landmarks SET category = 'restaurant' WHERE category = 'foodDrink';
    UPDATE user_landmarks SET category = 'clinic' WHERE category = 'medical';
    UPDATE user_landmarks SET category = 'marketplace' WHERE category = 'shopping';
    UPDATE user_landmarks SET category = 'parkingLot' WHERE category = 'transportation';
    UPDATE user_landmarks SET category = 'school' WHERE category = 'education';
    UPDATE user_landmarks SET category = 'bank' WHERE category = 'finance';
    UPDATE user_landmarks SET category = 'cityHall' WHERE category = 'government';
    UPDATE user_landmarks SET category = 'park' WHERE category = 'recreation';
    UPDATE user_landmarks SET category = 'gym' WHERE category = 'sports';
    UPDATE user_landmarks SET category = 'hotel' WHERE category = 'lodging';
    UPDATE user_landmarks SET category = 'temple' WHERE category = 'religion';
    UPDATE user_landmarks SET category = 'repairShop' WHERE category = 'personalServices';

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
    -- 'trip'（公車/台鐵/高鐵…查 TDX）或 'nav'（App 內開車/走路導航，靠 App 自己回報進度）。
    -- nav 沒有 segments，segments_json 存 '[]' 當佔位（欄位維持 NOT NULL，不改欄位定義）。
    ALTER TABLE shares ADD COLUMN IF NOT EXISTS kind TEXT NOT NULL DEFAULT 'trip';
    ALTER TABLE shares ADD COLUMN IF NOT EXISTS nav_json TEXT;
    ALTER TABLE shares ADD COLUMN IF NOT EXISTS nav_progress_json TEXT;
    ALTER TABLE shares ADD COLUMN IF NOT EXISTS nav_progress_at_ms BIGINT;
    -- 安全分享（選用，預設關閉）：分享者建立連結時自己決定要不要「順便」傳即時座標——
    -- 一般分享連結完全不含座標；只有這個欄位是 true 的連結，App 才會開始回報座標。
    ALTER TABLE shares ADD COLUMN IF NOT EXISTS live_location_enabled INTEGER NOT NULL DEFAULT 0;
    ALTER TABLE shares ADD COLUMN IF NOT EXISTS live_lat DOUBLE PRECISION;
    ALTER TABLE shares ADD COLUMN IF NOT EXISTS live_lon DOUBLE PRECISION;
    ALTER TABLE shares ADD COLUMN IF NOT EXISTS live_location_at_ms BIGINT;

    CREATE TABLE IF NOT EXISTS speedcam_cache (
      id         TEXT PRIMARY KEY DEFAULT 'all',
      json       TEXT NOT NULL,
      updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
    );

    -- 新竹縣交通地圖（縣市公車＋公路客運＋尖峰班距）——TDX 一天只重新抓一次（見
    -- hsinchuTransit.mjs／index.mjs 的排程），這裡存的是抓完、算完班距之後的成品 JSON。
    CREATE TABLE IF NOT EXISTS hsinchu_transit_cache (
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

    CREATE TABLE IF NOT EXISTS bike_station_history (
      id             INTEGER PRIMARY KEY AUTOINCREMENT,
      city           TEXT NOT NULL,
      station_uid    TEXT NOT NULL,
      name           TEXT,
      lat            REAL,
      lon            REAL,
      capacity       INTEGER,
      rent           INTEGER,
      ret            INTEGER,
      recorded_at_ms INTEGER NOT NULL
    );
    CREATE INDEX IF NOT EXISTS idx_bike_history_city_time ON bike_station_history (city, recorded_at_ms);

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
      email       TEXT,
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
      business_status   TEXT NOT NULL DEFAULT 'open',
      photos_json       TEXT,
      hours_json        TEXT,
      features_json     TEXT,
      links_json        TEXT,
      price_range       INTEGER,
      app_version       TEXT,
      device            TEXT,
      email             TEXT,
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
      token                TEXT PRIMARY KEY,
      title                TEXT,
      kind                 TEXT NOT NULL DEFAULT 'trip',
      segments_json        TEXT NOT NULL,
      nav_json             TEXT,
      nav_progress_json    TEXT,
      nav_progress_at_ms   INTEGER,
      live_location_enabled INTEGER NOT NULL DEFAULT 0,
      live_lat             REAL,
      live_lon             REAL,
      live_location_at_ms  INTEGER,
      created_at_ms        BIGINT NOT NULL,
      expires_at_ms        BIGINT NOT NULL
    );
    CREATE INDEX IF NOT EXISTS idx_shares_expires ON shares (expires_at_ms);

    CREATE TABLE IF NOT EXISTS speedcam_cache (
      id         TEXT PRIMARY KEY DEFAULT 'all',
      json       TEXT NOT NULL,
      updated_at TEXT NOT NULL DEFAULT (datetime('now'))
    );

    CREATE TABLE IF NOT EXISTS hsinchu_transit_cache (
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
  if (!cols.includes("email")) {
    db.exec(`ALTER TABLE place_reviews ADD COLUMN email TEXT`);
  }
  const landmarkCols = db.prepare(`PRAGMA table_info(user_landmarks)`).all().map((c) => c.name);
  if (!landmarkCols.includes("email")) {
    db.exec(`ALTER TABLE user_landmarks ADD COLUMN email TEXT`);
  }
  if (!landmarkCols.includes("business_status")) {
    db.exec(`ALTER TABLE user_landmarks ADD COLUMN business_status TEXT NOT NULL DEFAULT 'open'`);
  }
  if (!landmarkCols.includes("photos_json")) db.exec(`ALTER TABLE user_landmarks ADD COLUMN photos_json TEXT`);
  if (!landmarkCols.includes("hours_json")) db.exec(`ALTER TABLE user_landmarks ADD COLUMN hours_json TEXT`);
  if (!landmarkCols.includes("features_json")) db.exec(`ALTER TABLE user_landmarks ADD COLUMN features_json TEXT`);
  if (!landmarkCols.includes("links_json")) db.exec(`ALTER TABLE user_landmarks ADD COLUMN links_json TEXT`);
  if (!landmarkCols.includes("price_range")) db.exec(`ALTER TABLE user_landmarks ADD COLUMN price_range INTEGER`);
  for (const [oldCat, newCat] of Object.entries(OLD_CATEGORY_REMAP)) {
    db.exec(`UPDATE user_landmarks SET category = '${newCat}' WHERE category = '${oldCat}'`);
  }
  const shareCols = db.prepare(`PRAGMA table_info(shares)`).all().map((c) => c.name);
  if (!shareCols.includes("kind")) db.exec(`ALTER TABLE shares ADD COLUMN kind TEXT NOT NULL DEFAULT 'trip'`);
  if (!shareCols.includes("nav_json")) db.exec(`ALTER TABLE shares ADD COLUMN nav_json TEXT`);
  if (!shareCols.includes("nav_progress_json")) db.exec(`ALTER TABLE shares ADD COLUMN nav_progress_json TEXT`);
  if (!shareCols.includes("nav_progress_at_ms")) db.exec(`ALTER TABLE shares ADD COLUMN nav_progress_at_ms INTEGER`);
  if (!shareCols.includes("live_location_enabled")) db.exec(`ALTER TABLE shares ADD COLUMN live_location_enabled INTEGER NOT NULL DEFAULT 0`);
  if (!shareCols.includes("live_lat")) db.exec(`ALTER TABLE shares ADD COLUMN live_lat REAL`);
  if (!shareCols.includes("live_lon")) db.exec(`ALTER TABLE shares ADD COLUMN live_lon REAL`);
  if (!shareCols.includes("live_location_at_ms")) db.exec(`ALTER TABLE shares ADD COLUMN live_location_at_ms INTEGER`);
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

// ---- bike station history (hourly snapshots, for cities in BIKE_HISTORY_CITIES) ----
/** One row per station, all sharing the same recorded_at_ms — see bikepoller.mjs's hourly hook. */
export async function logBikeStationSnapshot(city, stations) {
  if (!stations.length) return;
  const recordedAtMs = Date.now();   // one shared moment for the whole snapshot batch
  const stmt = db.prepare(`
    INSERT INTO bike_station_history (city, station_uid, name, lat, lon, capacity, rent, ret, recorded_at_ms)
    VALUES (:city, :station_uid, :name, :lat, :lon, :capacity, :rent, :ret, :recorded_at_ms)
  `);
  for (const s of stations) {
    await stmt.run({
      city, station_uid: s.uid, name: s.name ?? null, lat: s.lat ?? null, lon: s.lon ?? null,
      capacity: s.capacity ?? null, rent: s.rent ?? null, ret: s.ret ?? null, recorded_at_ms: recordedAtMs,
    });
  }
}

/** Everything logged for a city since `sinceMs` — a simple time-series a later page can bucket
 * by hour-of-day/weekday itself; no aggregation done here so the caller keeps full control. */
export async function getBikeStationHistory(city, sinceMs) {
  const rows = await db.prepare(`
    SELECT station_uid, name, lat, lon, capacity, rent, ret, recorded_at_ms
    FROM bike_station_history WHERE city = ? AND recorded_at_ms >= ?
    ORDER BY recorded_at_ms ASC
  `).all(city, sinceMs);
  return rows.map((r) => ({
    stationUID: r.station_uid, name: r.name, lat: r.lat, lon: r.lon,
    capacity: r.capacity, rent: r.rent, ret: r.ret, recordedAt: new Date(Number(r.recorded_at_ms)).toISOString(),
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

// ---- Hsinchu County transit overview cache (refreshed daily, see hsinchuTransit.mjs) ----
export async function setHsinchuTransitCache(overview) {
  await db.prepare(`
    INSERT INTO hsinchu_transit_cache (id, json, updated_at) VALUES ('all', :json, ${usingPg ? "now()" : "datetime('now')"})
    ON CONFLICT(id) DO UPDATE SET json = excluded.json, updated_at = ${usingPg ? "now()" : "datetime('now')"}
  `).run({ json: JSON.stringify(overview) });
}
export async function getHsinchuTransitCache() {
  const r = await db.prepare(`SELECT json, updated_at FROM hsinchu_transit_cache WHERE id = 'all'`).get();
  if (!r) return null;
  return { ...JSON.parse(r.json), cachedAt: isoZ(r.updated_at) };
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
      INSERT INTO place_reviews (place_key, place_name, lat, lon, stars, comment, photo, app_version, device, email, ip)
      VALUES (:place_key, :place_name, :lat, :lon, :stars, :comment, :photo, :app_version, :device, :email, :ip)
      ON CONFLICT(place_key, device) DO UPDATE SET
        stars = excluded.stars, comment = excluded.comment, photo = excluded.photo,
        app_version = excluded.app_version, email = excluded.email, ip = excluded.ip,
        reported = 0, created_at = ${now}
    `).run({
      place_key: r.placeKey, place_name: r.placeName, lat: r.lat ?? null, lon: r.lon ?? null,
      stars, comment, photo: r.photo ?? null, app_version: r.appVersion ?? null,
      device: r.device, email: r.email ?? null, ip: r.ip ?? null,
    });
  } else {
    await db.prepare(`
      INSERT INTO place_reviews (place_key, place_name, lat, lon, stars, comment, photo, app_version, device, email, ip)
      VALUES (:place_key, :place_name, :lat, :lon, :stars, :comment, :photo, :app_version, NULL, :email, :ip)
    `).run({
      place_key: r.placeKey, place_name: r.placeName, lat: r.lat ?? null, lon: r.lon ?? null,
      stars, comment, photo: r.photo ?? null, app_version: r.appVersion ?? null, email: r.email ?? null, ip: r.ip ?? null,
    });
  }
}

/** Self-service delete: the device that posted a review, OR the same verified email
 * re-proven with a fresh code (the /v1/places/reviews/:id route re-verifies before calling
 * this with `email` set) — same two-path ownership as "my landmarks", so switching phones
 * doesn't strand you. `owner` can be a bare device string (old call shape) or `{device, email}`. */
export async function deletePlaceReviewByDevice(id, owner) {
  const { device = null, email = null } = typeof owner === "string" ? { device: owner } : (owner || {});
  if (!device && !email) return false;
  const row = await db.prepare(`SELECT device, email FROM place_reviews WHERE id = ?`).get(id);
  if (!row) return false;
  const isOwner = (device && row.device === device) || (email && row.email === email);
  if (!isOwner) return false;
  const info = await db.prepare(`DELETE FROM place_reviews WHERE id = ?`).run(id);
  if (info.changes === 0) return false;
  await db.prepare(`DELETE FROM place_review_reports WHERE review_id = ?`).run(id);
  return true;
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

/** This device's own reviews (any place), OR — once re-verified with a fresh code — the ones
 * tied to a given Email, so a switch to a new phone doesn't lose access to your own reviews.
 * The public listing never exposes whose device/email posted what; this is the only path in. */
export async function listMyPlaceReviews(owner) {
  const { device = null, email = null } = typeof owner === "string" ? { device: owner } : (owner || {});
  if (!device && !email) return [];
  const byId = new Map();
  if (device) {
    for (const row of await db.prepare(`SELECT id, place_key, place_name, stars, comment, photo, created_at FROM place_reviews WHERE device = ? ORDER BY created_at DESC LIMIT 200`).all(device)) byId.set(row.id, row);
  }
  if (email) {
    for (const row of await db.prepare(`SELECT id, place_key, place_name, stars, comment, photo, created_at FROM place_reviews WHERE email = ? ORDER BY created_at DESC LIMIT 200`).all(email)) byId.set(row.id, row);
  }
  return [...byId.values()].sort((a, b) => (a.created_at < b.created_at ? 1 : -1)).map((row) => ({
    id: row.id, placeKey: row.place_key, placeName: row.place_name,
    stars: row.stars, comment: row.comment, photo: row.photo, createdAt: isoZ(row.created_at),
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
    reportReasons: reasonsByReview.get(r.id) ?? {}, email: r.email,
    appVersion: r.app_version, createdAt: isoZ(r.created_at),
  }));
}

// ---- user-submitted landmarks (real user content, held for admin approval) ----
// Google-Maps-style fine-grained taxonomy — keep in sync with Swift's LandmarkCategory
// (same raw values; LandmarkCategoryGroup there is the old 13-case list, used for icon/color).
export const LANDMARK_CATEGORIES = [
  "restaurant", "cafe", "teaShop", "bakery", "dessertShop", "bar", "breakfastShop", "nightMarketStall", "buffet", "fastFood",
  "groceryStore", "convenienceStore", "supermarket", "clothingStore", "bookstore", "electronicsStore", "giftShop", "marketplace",
  "hospital", "clinic", "dentist", "pharmacy", "veterinary",
  "gasStation", "evCharging", "parkingLot", "carRepair", "bikeShop",
  "school", "kindergarten", "cramSchool", "library",
  "bank", "atm", "insurance",
  "policeStation", "fireStation", "postOffice", "cityHall",
  "park", "cinema", "museum", "artGallery", "karaoke", "arcade",
  "gym", "swimmingPool", "sportsField", "yogaStudio",
  "hotel", "hostel", "bnb", "campground",
  "temple", "church",
  "hairSalon", "laundry", "petGrooming", "repairShop",
  "other",
];
/** photos_json/hours_json/features_json/links_json/price_range, parsed and normalised: `photos`
 * falls back to the legacy single `photo` column (or the older plain-string gallery shape, before
 * photo categories existed — see normalizePhotos) so an old row still shows something instead of
 * an empty gallery. `openNow` is computed fresh on every read (see isOpenNow) rather than stored,
 * so it's never stale. */
function landmarkExtras(r) {
  const photos = r.photos_json ? normalizePhotos(JSON.parse(r.photos_json)) : (r.photo ? [{ url: r.photo, category: "other" }] : []);
  const hours = r.hours_json ? JSON.parse(r.hours_json) : null;
  const features = r.features_json ? JSON.parse(r.features_json) : [];
  const links = r.links_json ? JSON.parse(r.links_json) : null;
  return { photos, hours, features, links, priceRange: r.price_range ?? null, openNow: isOpenNow(hours) };
}

export async function createUserLandmark(r) {
  const category = LANDMARK_CATEGORIES.includes(r.category) ? r.category : "other";
  await db.prepare(`
    INSERT INTO user_landmarks (name, description, category, lat, lon, photo, is_business_claim, business_verified, business_hours, phone, app_version, device, email, ip, photos_json, hours_json, features_json, links_json, price_range)
    VALUES (:name, :description, :category, :lat, :lon, :photo, :is_business_claim, :business_verified, :business_hours, :phone, :app_version, :device, :email, :ip, :photos_json, :hours_json, :features_json, :links_json, :price_range)
  `).run({
    name: r.name,
    description: (r.description ?? "").slice(0, 500),
    category,
    lat: r.lat,
    lon: r.lon,
    photo: r.photo ?? null,
    is_business_claim: r.isBusinessClaim ? 1 : 0,
    // Verified by Email at submission time (see POST /v1/landmarks) — not the old
    // admin-clicks-a-button path, though that manual override still exists too.
    business_verified: r.businessVerified ? 1 : 0,
    business_hours: (r.businessHours ?? "").slice(0, 500) || null,
    phone: (r.phone ?? "").slice(0, 50) || null,
    app_version: r.appVersion ?? null,
    device: r.device ?? null,
    email: r.email ?? null,
    ip: r.ip ?? null,
    photos_json: r.photos ? JSON.stringify(r.photos) : null,
    hours_json: r.hours ? JSON.stringify(r.hours) : null,
    features_json: r.features ? JSON.stringify(r.features) : null,
    links_json: r.links ? JSON.stringify(r.links) : null,
    price_range: r.priceRange ?? null,
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
    // Google-Maps-style: a closed place stays visible (with the status flagged) rather than
    // vanishing — vanishing reads as "this data is broken", a flag reads as "closed today".
    businessStatus: r.business_verified ? r.business_status : "open",
    ...(r.business_verified ? landmarkExtras(r) : { photos: r.photo ? [{ url: r.photo, category: "other" }] : [], hours: null, features: [], links: null, priceRange: null, openNow: null }),
  }));
}

/** A single approved landmark, public-facing — the yayalin.com/shop/:id page. `null` for
 * anything not approved (never leak an unapproved submission's existence this way) or
 * missing. Same field-hiding rule as listApprovedLandmarksNear: hours/phone only once verified. */
export async function getApprovedLandmark(id) {
  const r = await db.prepare(`SELECT * FROM user_landmarks WHERE id = ? AND approved = 1`).get(id);
  if (!r) return null;
  return {
    id: r.id, name: r.name, description: r.description, category: r.category, lat: r.lat, lon: r.lon, photo: r.photo,
    businessHours: r.business_verified ? r.business_hours : null,
    phone: r.business_verified ? r.phone : null,
    businessVerified: !!r.business_verified,
    businessStatus: r.business_verified ? r.business_status : "open",
    ...(r.business_verified ? landmarkExtras(r) : { photos: r.photo ? [{ url: r.photo, category: "other" }] : [], hours: null, features: [], links: null, priceRange: null, openNow: null }),
  };
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
    businessStatus: r.business_status, email: r.email, approved: !!r.approved, reported: r.reported, reportReasons: reasonsByLandmark.get(r.id) ?? {},
    appVersion: r.app_version, createdAt: isoZ(r.created_at),
    ...landmarkExtras(r),
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

const BUSINESS_STATUSES = ["open", "temporarily_closed", "permanently_closed"];

function mapMyLandmarkRow(r) {
  return {
    id: r.id, name: r.name, description: r.description, category: r.category, lat: r.lat, lon: r.lon, photo: r.photo,
    isBusinessClaim: !!r.is_business_claim, businessVerified: !!r.business_verified, businessHours: r.business_hours, phone: r.phone,
    businessStatus: r.business_status, approved: !!r.approved, createdAt: isoZ(r.created_at),
    ...landmarkExtras(r),
  };
}

/** This device's own submitted landmarks (any status) — so a submitter can see
 * "pending"/"approved"/"verified" and, once verified, actually edit their listing.
 * `owner` can be a bare device string (old call shape) or `{device, email}` — email
 * matters for a verified business owner checking from a *different* phone than the one
 * that originally submitted the claim (see /v1/landmarks/mine, which re-verifies the
 * email with a fresh code before ever calling this). */
export async function listMyUserLandmarks(owner) {
  const { device = null, email = null } = typeof owner === "string" ? { device: owner } : (owner || {});
  const byId = new Map();
  if (device) {
    for (const r of await db.prepare(`SELECT * FROM user_landmarks WHERE device = ?`).all(device)) byId.set(r.id, r);
  }
  if (email) {
    for (const r of await db.prepare(`SELECT * FROM user_landmarks WHERE email = ?`).all(email)) byId.set(r.id, r);
  }
  return [...byId.values()].sort((a, b) => (a.created_at < b.created_at ? 1 : -1)).map(mapMyLandmarkRow);
}

/**
 * A verified business owner editing their own real listing. Ownership is "the device that
 * originally submitted it" OR "the same verified email, re-proven with a fresh code" — the
 * second path is what makes this work after switching phones, since there's no real account
 * system otherwise to carry that identity across devices. Either way `business_verified`
 * (an admin's real confirmation, or the Email-verified-at-submission path) must already be
 * true — an unverified claimant can't use this to rewrite a listing an admin never checked.
 * Only the provided fields are changed.
 */
export async function updateMyUserLandmark(id, owner, fields) {
  const { device = null, email = null } = typeof owner === "string" ? { device: owner } : (owner || {});
  const row = await db.prepare(`SELECT device, email, business_verified FROM user_landmarks WHERE id = ?`).get(id);
  if (!row || !row.business_verified) return false;
  const isOwner = (device && row.device === device) || (email && row.email === email);
  if (!isOwner) return false;
  const sets = [];
  const params = { id };
  if (typeof fields.description === "string") { sets.push("description = :description"); params.description = fields.description.slice(0, 500); }
  if (typeof fields.businessHours === "string") { sets.push("business_hours = :business_hours"); params.business_hours = fields.businessHours.slice(0, 500); }
  if (typeof fields.photo === "string") { sets.push("photo = :photo"); params.photo = fields.photo; }
  if (typeof fields.phone === "string") { sets.push("phone = :phone"); params.phone = fields.phone.slice(0, 50); }
  if (typeof fields.businessStatus === "string" && BUSINESS_STATUSES.includes(fields.businessStatus)) {
    sets.push("business_status = :business_status"); params.business_status = fields.businessStatus;
  }
  if (typeof fields.category === "string" && LANDMARK_CATEGORIES.includes(fields.category)) {
    sets.push("category = :category"); params.category = fields.category;
  }
  if (typeof fields.lat === "number" && typeof fields.lon === "number") {
    sets.push("lat = :lat", "lon = :lon");
    params.lat = fields.lat; params.lon = fields.lon;
  }
  // photos/hours/features are already sanitized by the caller (see index.mjs) before reaching
  // here — this just stores whatever whitelisted shape it was handed, same trust boundary as
  // every other field on this row.
  if (fields.photos !== undefined) { sets.push("photos_json = :photos_json"); params.photos_json = fields.photos ? JSON.stringify(fields.photos) : null; }
  if (fields.hours !== undefined) { sets.push("hours_json = :hours_json"); params.hours_json = fields.hours ? JSON.stringify(fields.hours) : null; }
  if (fields.features !== undefined) { sets.push("features_json = :features_json"); params.features_json = fields.features ? JSON.stringify(fields.features) : null; }
  if (fields.links !== undefined) { sets.push("links_json = :links_json"); params.links_json = fields.links ? JSON.stringify(fields.links) : null; }
  if (fields.priceRange !== undefined) { sets.push("price_range = :price_range"); params.price_range = fields.priceRange; }
  if (sets.length === 0) return false;
  await db.prepare(`UPDATE user_landmarks SET ${sets.join(", ")} WHERE id = :id`).run(params);
  return true;
}

/** Name search over already-approved landmarks — for the web business dashboard's "find my
 * business to claim it" flow, and anything else that wants to search by name rather than by
 * a radius (the app's own map search already has that). Substring match, case-insensitive;
 * this table is small (see listApprovedLandmarksNear's own comment), so no FTS needed. */
export async function searchApprovedLandmarks(query, limit = 20) {
  const q = `%${query.replace(/[%_]/g, (c) => `\\${c}`)}%`;
  const rows = await db.prepare(`
    SELECT * FROM user_landmarks WHERE approved = 1 AND name ${usingPg ? "ILIKE" : "LIKE"} ? ESCAPE '\\'
    ORDER BY name LIMIT ?
  `).all(q, limit);
  return rows.map((r) => ({
    id: r.id, name: r.name, description: r.description, category: r.category, lat: r.lat, lon: r.lon,
    isBusinessClaim: !!r.is_business_claim, businessVerified: !!r.business_verified,
  }));
}

/**
 * Verified businesses, browsable — yayalin.com/shop's directory page (as opposed to
 * yayalin.com/shop/:id, which needs the id already). Only `business_verified` landmarks: an
 * unclaimed community-added landmark has no business info to show and shouldn't read as "here
 * are our businesses" alongside real ones.
 */
export async function listVerifiedBusinesses({ category, limit = 60, offset = 0 } = {}) {
  const cappedLimit = Math.min(200, Math.max(1, limit));
  const params = [];
  let where = "approved = 1 AND business_verified = 1";
  if (category) { where += ` AND category = ?`; params.push(category); }
  const rows = await db.prepare(`
    SELECT * FROM user_landmarks WHERE ${where} ORDER BY name LIMIT ? OFFSET ?
  `).all(...params, cappedLimit, offset);
  const total = (await db.prepare(`SELECT COUNT(*) c FROM user_landmarks WHERE ${where}`).get(...params))?.c ?? 0;
  return {
    businesses: rows.map((r) => {
      const { photos, openNow } = landmarkExtras(r);
      return {
        id: r.id, name: r.name, description: r.description, category: r.category,
        businessHours: r.business_hours, businessStatus: r.business_status ?? "open",
        coverPhoto: photos[0]?.url ?? null, openNow,
      };
    }),
    total: Number(total),
  };
}

/**
 * A business owner claiming an EXISTING landmark (already approved, community-added or
 * otherwise) that nobody has verified yet — as opposed to submitting a brand new one (see
 * createUserLandmark). The Email is already verified by the caller (POST
 * /v1/landmarks/:id/claim) before this runs. Refuses outright if someone else already holds
 * a verified claim on it — this never lets a second claimant silently take over a real
 * business's listing.
 */
export async function claimUserLandmark(id, { email, businessHours, phone }) {
  const row = await db.prepare(`SELECT business_verified FROM user_landmarks WHERE id = ?`).get(id);
  if (!row) return false;
  if (row.business_verified) return false;
  const info = await db.prepare(`
    UPDATE user_landmarks
    SET is_business_claim = 1, business_verified = 1, email = :email,
        business_hours = COALESCE(:business_hours, business_hours), phone = COALESCE(:phone, phone)
    WHERE id = :id AND business_verified = 0
  `).run({ id, email, business_hours: businessHours || null, phone: phone || null });
  return info.changes > 0;
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

/** `kind: 'trip'` (default) needs `segments`; `kind: 'nav'` needs `nav` instead (an in-app
 * driving/walking navigation share — see shares.mjs's sanitizeNav) and no segments at all. */
export async function createShare({ token, title, segments, kind = "trip", nav, liveLocationEnabled = false, nowMs, expiresAtMs }) {
  // Expired links are useless and hold nothing we need: sweep them on every create.
  await db.prepare(`DELETE FROM shares WHERE expires_at_ms <= :now`).run({ now: nowMs });
  await db.prepare(`
    INSERT INTO shares (token, title, kind, segments_json, nav_json, live_location_enabled, created_at_ms, expires_at_ms)
    VALUES (:token, :title, :kind, :segments_json, :nav_json, :live_location_enabled, :created, :expires)
  `).run({
    token, title: title ?? null, kind,
    segments_json: JSON.stringify(segments ?? []),
    nav_json: nav ? JSON.stringify(nav) : null,
    live_location_enabled: liveLocationEnabled ? 1 : 0,
    created: nowMs, expires: expiresAtMs,
  });
}

/** The stored share, or null. Expiry is the caller's decision (shares.mjs isExpired). */
export async function getShare(token) {
  const r = await db.prepare(`
    SELECT token, title, kind, segments_json, nav_json, nav_progress_json, nav_progress_at_ms,
           live_location_enabled, live_lat, live_lon, live_location_at_ms, created_at_ms, expires_at_ms
    FROM shares WHERE token = :token
  `).get({ token });
  if (!r) return null;
  return {
    token: r.token, title: r.title, kind: r.kind || "trip",
    segments: r.segments_json ? JSON.parse(r.segments_json) : [],
    nav: r.nav_json ? JSON.parse(r.nav_json) : null,
    navProgress: r.nav_progress_json ? JSON.parse(r.nav_progress_json) : null,
    navProgressAtMs: r.nav_progress_at_ms != null ? Number(r.nav_progress_at_ms) : null,
    liveLocationEnabled: !!(r.live_location_enabled && Number(r.live_location_enabled) !== 0),
    liveLat: r.live_lat != null ? Number(r.live_lat) : null,
    liveLon: r.live_lon != null ? Number(r.live_lon) : null,
    liveLocationAtMs: r.live_location_at_ms != null ? Number(r.live_location_at_ms) : null,
    created_at_ms: Number(r.created_at_ms), expires_at_ms: Number(r.expires_at_ms),
  };
}

/** The sharer's own app pushes this every so often while navigating — replaces the previous
 * snapshot outright, there is no history. Silently a no-op for a token that doesn't exist or
 * isn't a 'nav' share, so a stale/foreign token can't be used to probe which tokens are real. */
export async function updateShareProgress(token, progress, nowMs) {
  const info = await db.prepare(`
    UPDATE shares SET nav_progress_json = :progress, nav_progress_at_ms = :now
    WHERE token = :token AND kind = 'nav' AND expires_at_ms > :now
  `).run({ token, progress: JSON.stringify(progress), now: nowMs });
  return info.changes > 0;
}

/** The sharer's own app pushes this while "安全分享" (opt-in live-location) is on — for either
 * kind of share (trip or nav). Silently a no-op unless the sharer explicitly enabled
 * live_location_enabled on this exact token, so a stale/foreign token can't be used to start
 * broadcasting a coordinate that wasn't opted into. */
export async function updateShareLocation(token, { lat, lon }, nowMs) {
  const info = await db.prepare(`
    UPDATE shares SET live_lat = :lat, live_lon = :lon, live_location_at_ms = :now
    WHERE token = :token AND live_location_enabled = 1 AND expires_at_ms > :now
  `).run({ token, lat, lon, now: nowMs });
  return info.changes > 0;
}

export async function deleteShare(token) {
  await db.prepare(`DELETE FROM shares WHERE token = :token`).run({ token });
}
