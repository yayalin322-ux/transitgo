/**
 * GTFS static schema — Phase 1 of the multimodal routing engine (see the architecture
 * doc: Data Model → Graph Builder → Virtual Origin/Destination → A* → ...).
 *
 * This mirrors the standard GTFS text files (agency/routes/stops/trips/stop_times/
 * calendar/calendar_dates) almost verbatim rather than inventing a custom shape, because
 * every Taiwan transit operator that publishes GTFS (TRA, THSR, city bus systems, metro
 * systems) already conforms to this spec — an adapter step at import time, not a
 * redesign, is what "don't hardcode TDX into the routing engine" from the doc's dev
 * principles actually calls for.
 *
 * `feed_id` namespaces every table so multiple operators' GTFS feeds (which mint their
 * own route_id/stop_id/trip_id independently and WILL collide across operators) can
 * coexist in one database without stepping on each other. Re-importing a feed replaces
 * that feed_id's rows only — see gtfs/import.mjs — which is the "DataVersion, don't mix
 * old and new data" requirement: each import is one atomic swap, not an incremental
 * merge that could leave stale rows behind.
 */
export async function ensureGtfsSchema(db) {
  // Same schema on both engines — GTFS's own types (TEXT/REAL/INTEGER) are already
  // portable; the only real SQLite-ism here is the datetime('now') column default.
  const now = process.env.DATABASE_URL ? "now()" : "datetime('now')";
  await db.exec(`
    CREATE TABLE IF NOT EXISTS gtfs_feeds (
      feed_id     TEXT PRIMARY KEY,
      name        TEXT NOT NULL,
      source_url  TEXT,
      imported_at TEXT NOT NULL DEFAULT (${now}),
      row_counts  TEXT
    );

    CREATE TABLE IF NOT EXISTS gtfs_agency (
      feed_id          TEXT NOT NULL,
      agency_id        TEXT NOT NULL,
      agency_name      TEXT,
      agency_url       TEXT,
      agency_timezone  TEXT,
      PRIMARY KEY (feed_id, agency_id)
    );

    CREATE TABLE IF NOT EXISTS gtfs_routes (
      feed_id          TEXT NOT NULL,
      route_id         TEXT NOT NULL,
      agency_id        TEXT,
      route_short_name TEXT,
      route_long_name  TEXT,
      route_type       INTEGER,
      PRIMARY KEY (feed_id, route_id)
    );

    CREATE TABLE IF NOT EXISTS gtfs_stops (
      feed_id         TEXT NOT NULL,
      stop_id         TEXT NOT NULL,
      stop_name       TEXT,
      stop_lat        REAL,
      stop_lon        REAL,
      parent_station  TEXT,
      location_type   INTEGER,
      PRIMARY KEY (feed_id, stop_id)
    );
    CREATE INDEX IF NOT EXISTS idx_gtfs_stops_geo ON gtfs_stops (stop_lat, stop_lon);

    CREATE TABLE IF NOT EXISTS gtfs_trips (
      feed_id        TEXT NOT NULL,
      trip_id        TEXT NOT NULL,
      route_id       TEXT NOT NULL,
      service_id     TEXT NOT NULL,
      direction_id   INTEGER,
      trip_headsign  TEXT,
      shape_id       TEXT,
      PRIMARY KEY (feed_id, trip_id)
    );
    CREATE INDEX IF NOT EXISTS idx_gtfs_trips_route ON gtfs_trips (feed_id, route_id);
    CREATE INDEX IF NOT EXISTS idx_gtfs_trips_service ON gtfs_trips (feed_id, service_id);

    -- arrival_time/departure_time stay as GTFS's raw "HH:MM:SS" text (can exceed 24:00:00
    -- for a post-midnight trip on the *same* service day) — Phase 2's Graph Builder
    -- converts to seconds-since-midnight, this layer stores exactly what the feed said.
    --
    -- stop_id is nullable (not the GTFS spec default) because TDX's bus schedule
    -- endpoint gives real per-stop *times* for a trip without a StopUID attached to each
    -- one — only the route's ordered stop list (StopOfRoute) says which physical stop
    -- each position corresponds to. A null here means "real time, stop identity not yet
    -- resolved by sequence" — Graph Builder resolves it by joining against
    -- gtfs_trips.route_id's stop order, never by guessing.
    CREATE TABLE IF NOT EXISTS gtfs_stop_times (
      feed_id        TEXT NOT NULL,
      trip_id        TEXT NOT NULL,
      stop_id        TEXT,
      arrival_time   TEXT,
      departure_time TEXT,
      stop_sequence  INTEGER NOT NULL,
      PRIMARY KEY (feed_id, trip_id, stop_sequence)
    );
    CREATE INDEX IF NOT EXISTS idx_gtfs_stop_times_stop ON gtfs_stop_times (feed_id, stop_id);

    CREATE TABLE IF NOT EXISTS gtfs_calendar (
      feed_id     TEXT NOT NULL,
      service_id  TEXT NOT NULL,
      monday      INTEGER, tuesday INTEGER, wednesday INTEGER, thursday INTEGER,
      friday      INTEGER, saturday INTEGER, sunday INTEGER,
      start_date  TEXT,
      end_date    TEXT,
      PRIMARY KEY (feed_id, service_id)
    );

    CREATE TABLE IF NOT EXISTS gtfs_calendar_dates (
      feed_id         TEXT NOT NULL,
      service_id      TEXT NOT NULL,
      date            TEXT NOT NULL,
      exception_type  INTEGER NOT NULL,
      PRIMARY KEY (feed_id, service_id, date)
    );

    -- Most Taiwan city bus routes have no published fixed timetable in TDX — only a
    -- real headway (minHeadwayMins/maxHeadwayMins) per time-of-day band, straight from
    -- TDX's own v2/Bus/Schedule "Frequencys" field. This is NOT an invented average —
    -- it's what the operator itself filed with TDX. Routes that DO have a real
    -- timetable (TDX's "Timetables" field — common for intercity coach) go through
    -- gtfs_trips/gtfs_stop_times instead, same as TRA/THSR; this table only exists for
    -- the routes where that's genuinely not available.
    CREATE TABLE IF NOT EXISTS transit_route_frequency (
      feed_id           TEXT NOT NULL,
      route_id          TEXT NOT NULL,
      direction         INTEGER NOT NULL,
      sub_route_name    TEXT,
      service_day_label TEXT,
      start_time        TEXT NOT NULL,
      end_time          TEXT NOT NULL,
      min_headway_mins  INTEGER,
      max_headway_mins  INTEGER,
      source            TEXT NOT NULL DEFAULT 'TDX v2/Bus/Schedule Frequencys',
      imported_at       TEXT NOT NULL DEFAULT (${now}),
      PRIMARY KEY (feed_id, route_id, direction, service_day_label, start_time, end_time)
    );

    -- TDX's real, ordered stop list per route+direction (v2/Bus/StopOfRoute) — this is
    -- what resolves a bus trip's per-stop TIMES (which come back from v2/Bus/Schedule
    -- with no StopUID attached to each one) to the actual real station at that position.
    -- Without this table gtfs_stop_times.stop_id had to stay null for bus.
    -- Real per-hop travel time between two consecutive stations of one route — straight
    -- from TDX's own v2/Rail/Metro/S2STravelTime (RunTime + StopTime, in seconds). This is
    -- what lets a headway-based edge carry a REAL ride time instead of the distance/assumed-
    -- speed estimate bus headway edges have to fall back on. Only rows a real source
    -- actually published are ever stored here; a route with no row simply has no known hop time.
    CREATE TABLE IF NOT EXISTS transit_segment_times (
      feed_id       TEXT NOT NULL,
      route_id      TEXT NOT NULL,
      direction     INTEGER NOT NULL,
      stop_sequence INTEGER NOT NULL,
      from_stop_id  TEXT NOT NULL,
      to_stop_id    TEXT NOT NULL,
      run_seconds   INTEGER NOT NULL,
      stop_seconds  INTEGER NOT NULL DEFAULT 0,
      source        TEXT NOT NULL DEFAULT 'TDX v2/Rail/Metro/S2STravelTime',
      PRIMARY KEY (feed_id, route_id, direction, stop_sequence)
    );

    -- Real interchange links between two stops the operator itself says connect (TDX
    -- v2/Rail/Metro/LineTransfer): TransferTime is the operator-published minutes to
    -- change lines, not a computed walking distance — there is deliberately no distance
    -- column, because no source publishes one.
    CREATE TABLE IF NOT EXISTS transit_transfers (
      feed_id          TEXT NOT NULL,
      from_stop_id     TEXT NOT NULL,
      to_stop_id       TEXT NOT NULL,
      transfer_seconds INTEGER NOT NULL,
      on_site          INTEGER,
      source           TEXT NOT NULL DEFAULT 'TDX v2/Rail/Metro/LineTransfer',
      PRIMARY KEY (feed_id, from_stop_id, to_stop_id)
    );

    CREATE TABLE IF NOT EXISTS gtfs_route_stops (
      feed_id        TEXT NOT NULL,
      route_id       TEXT NOT NULL,
      direction      INTEGER NOT NULL,
      stop_sequence  INTEGER NOT NULL,
      stop_id        TEXT NOT NULL,
      PRIMARY KEY (feed_id, route_id, direction, stop_sequence)
    );
  `);
}
