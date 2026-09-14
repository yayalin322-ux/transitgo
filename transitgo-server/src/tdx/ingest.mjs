import { TDXProvider } from "./adapter.mjs";
import {
  normalizeTRAStations, normalizeTRATimetable,
  normalizeBusRoutes, normalizeBusStops, normalizeBusRouteStopSequence, normalizeBusSchedule,
  normalizeMetroStations, normalizeMetroStationSequence,
} from "./normalizer.mjs";

const provider = new TDXProvider();
const usingPg = !!process.env.DATABASE_URL;
// SQLite needs BEGIN IMMEDIATE to take a write lock upfront; Postgres's plain BEGIN
// already starts a real transaction and doesn't have an IMMEDIATE keyword.
const BEGIN = usingPg ? "BEGIN" : "BEGIN IMMEDIATE";
const NOW = usingPg ? "now()" : "datetime('now')";

// Postgres is a real network round trip now (Supabase, not local SQLite) — at ~150-200ms
// per statement, inserting hundreds/thousands of GTFS rows one at a time could take over
// a minute for a single busy route, well past Render/Cloudflare's own gateway timeout.
// That showed up as requests that looked hung forever (client gave up, but the server
// kept working in the background) rather than a real correctness bug. Folding many rows
// into one multi-row INSERT cuts that down to a handful of round trips per table. Keeping
// each row's own `?` count times the batch size comfortably under SQLite's default bound
// on parameters per statement (~999) is why the sizes below vary by column count.
async function batchInsert(db, sqlPrefix, tupleTemplate, sqlSuffix, rows, rowToArgs, batchSize) {
  for (let i = 0; i < rows.length; i += batchSize) {
    const chunk = rows.slice(i, i + batchSize);
    const sql = `${sqlPrefix} VALUES ${chunk.map(() => tupleTemplate).join(",")} ${sqlSuffix}`;
    const args = [];
    for (const row of chunk) args.push(...rowToArgs(row));
    await db.prepare(sql).run(...args);
  }
}

export async function insertStops(db, feedId, stops) {
  const rows = stops.filter((s) => s.stop_id);
  await batchInsert(
    db,
    `INSERT INTO gtfs_stops (feed_id, stop_id, stop_name, stop_lat, stop_lon, parent_station, location_type)`,
    `(?,?,?,?,?,NULL,0)`,
    `ON CONFLICT(feed_id, stop_id) DO UPDATE SET
      stop_name = excluded.stop_name, stop_lat = excluded.stop_lat, stop_lon = excluded.stop_lon`,
    rows,
    (s) => [feedId, s.stop_id, s.stop_name, s.stop_lat, s.stop_lon],
    150,
  );
}

export async function insertTrips(db, feedId, trips) {
  await batchInsert(
    db,
    `INSERT INTO gtfs_trips (feed_id, trip_id, route_id, service_id, direction_id, trip_headsign, shape_id)`,
    `(?,?,?,?,?,?,?)`,
    `ON CONFLICT(feed_id, trip_id) DO NOTHING`,
    trips,
    (t) => [feedId, t.trip_id, t.route_id, t.service_id, t.direction_id, t.trip_headsign, t.shape_id],
    100,
  );
}

export async function insertStopTimes(db, feedId, stopTimes) {
  await batchInsert(
    db,
    `INSERT INTO gtfs_stop_times (feed_id, trip_id, stop_id, arrival_time, departure_time, stop_sequence)`,
    `(?,?,?,?,?,?)`,
    `ON CONFLICT(feed_id, trip_id, stop_sequence) DO NOTHING`,
    stopTimes,
    (st) => [feedId, st.trip_id, st.stop_id, st.arrival_time, st.departure_time, st.stop_sequence],
    150,
  );
}

export async function insertCalendarDates(db, feedId, calendarDates) {
  await batchInsert(
    db,
    `INSERT INTO gtfs_calendar_dates (feed_id, service_id, date, exception_type)`,
    `(?,?,?,?)`,
    `ON CONFLICT(feed_id, service_id, date) DO NOTHING`,
    calendarDates,
    (cd) => [feedId, cd.service_id, cd.date, cd.exception_type],
    200,
  );
}

export async function insertRoutes(db, rows) {
  await batchInsert(
    db,
    `INSERT INTO gtfs_routes (feed_id, route_id, agency_id, route_short_name, route_long_name, route_type)`,
    `(?,?,NULL,?,?,?)`,
    `ON CONFLICT(feed_id, route_id) DO UPDATE SET route_short_name = excluded.route_short_name`,
    rows,
    (r) => [r.feed_id, r.route_id, r.route_short_name, r.route_long_name, r.route_type],
    150,
  );
}

export async function insertFrequencies(db, feedId, freqs) {
  await batchInsert(
    db,
    `INSERT INTO transit_route_frequency
      (feed_id, route_id, direction, sub_route_name, service_day_label, start_time, end_time, min_headway_mins, max_headway_mins)`,
    `(?,?,?,?,?,?,?,?,?)`,
    `ON CONFLICT(feed_id, route_id, direction, service_day_label, start_time, end_time) DO UPDATE SET
      min_headway_mins = excluded.min_headway_mins, max_headway_mins = excluded.max_headway_mins,
      imported_at = ${NOW}`,
    freqs,
    (f) => [feedId, f.route_id, f.direction, f.sub_route_name, f.service_day_label, f.start_time, f.end_time, f.min_headway_mins, f.max_headway_mins],
    100,
  );
}

export async function insertRouteStops(db, feedId, routeId, rows) {
  await db.prepare(`DELETE FROM gtfs_route_stops WHERE feed_id = ? AND route_id = ?`).run(feedId, routeId);
  await batchInsert(
    db,
    `INSERT INTO gtfs_route_stops (feed_id, route_id, direction, stop_sequence, stop_id)`,
    `(?,?,?,?,?)`,
    `ON CONFLICT(feed_id, route_id, direction, stop_sequence) DO UPDATE SET stop_id = excluded.stop_id`,
    rows,
    (r) => [feedId, r.route_id, r.direction, r.stop_sequence, r.stop_id],
    150,
  );
}

/** Ingests real TRA timetable data for one origin→destination pair on one date. */
export async function ingestTRAPair(db, feedId, fromStationID, toStationID, dateStr) {
  const raw = await provider.getTRATimetable(fromStationID, toStationID, dateStr);
  const { trips, stopTimes, calendarDates } = normalizeTRATimetable(raw, dateStr);
  await db.exec(BEGIN);
  try {
    await insertTrips(db, feedId, trips);
    await insertStopTimes(db, feedId, stopTimes);
    await insertCalendarDates(db, feedId, calendarDates);
    await db.exec("COMMIT");
  } catch (e) {
    await db.exec("ROLLBACK");
    throw e;
  }
  return { trips: trips.length, stopTimes: stopTimes.length };
}

/** Ingests real TRA station list (stops only, no schedule). */
export async function ingestTRAStations(db, feedId) {
  const raw = await provider.getTRAStations();
  const stops = normalizeTRAStations(raw);
  await db.exec(BEGIN);
  try {
    await insertStops(db, feedId, stops);
    await db.exec("COMMIT");
  } catch (e) {
    await db.exec("ROLLBACK");
    throw e;
  }
  return { stops: stops.length };
}

/** Ingests one bus route's real schedule (timetable and/or headway, whatever TDX actually has) for one date. */
export async function ingestBusRouteSchedule(db, feedId, scopePath, routeId, routeNameZh, dateStr) {
  const t0 = Date.now();
  const trace = (label) => console.log(`[ingest ${routeId}] ${label} +${Date.now() - t0}ms`);
  trace("start");
  const [rawStops, rawSchedule] = await Promise.all([
    provider.getBusStopsOfRoute(scopePath, routeNameZh),
    provider.getBusSchedule(scopePath, routeNameZh),
  ]);
  trace(`tdx fetched (stops=${rawStops?.length ?? "?"} schedule=${rawSchedule?.length ?? "?"})`);
  const stops = normalizeBusStops(rawStops);
  const routeStops = normalizeBusRouteStopSequence(rawStops, routeId);
  const stopSequenceByDirection = new Map();
  for (const r of routeStops) {
    if (!stopSequenceByDirection.has(r.direction)) stopSequenceByDirection.set(r.direction, []);
    stopSequenceByDirection.get(r.direction)[r.stop_sequence - 1] = r.stop_id;
  }
  const { trips, stopTimes, calendarDates, frequencies } = normalizeBusSchedule(rawSchedule, routeId, dateStr, stopSequenceByDirection);
  trace(`normalized (stops=${stops.length} routeStops=${routeStops.length} trips=${trips.length} stopTimes=${stopTimes.length} calendarDates=${calendarDates.length} frequencies=${frequencies.length})`);

  await db.exec(BEGIN);
  trace("BEGIN done");
  try {
    await insertRoutes(db, [{ feed_id: feedId, route_id: routeId, route_short_name: routeNameZh, route_long_name: null, route_type: 3 }]);
    trace("insertRoutes done");
    await insertStops(db, feedId, stops);
    trace("insertStops done");
    await insertRouteStops(db, feedId, routeId, routeStops);
    trace("insertRouteStops done");
    await insertTrips(db, feedId, trips);
    trace("insertTrips done");
    await insertStopTimes(db, feedId, stopTimes);
    trace("insertStopTimes done");
    await insertCalendarDates(db, feedId, calendarDates);
    trace("insertCalendarDates done");
    await insertFrequencies(db, feedId, frequencies);
    trace("insertFrequencies done");
    await db.exec("COMMIT");
    trace("COMMIT done");
  } catch (e) {
    trace(`ERROR: ${e.message}`);
    await db.exec("ROLLBACK");
    trace("ROLLBACK done");
    throw e;
  }
  return { stops: stops.length, trips: trips.length, stopTimes: stopTimes.length, frequencies: frequencies.length, routeStops: routeStops.length };
}

/**
 * Ingests real MRT/metro station topology for one line — stations + their real ordered
 * sequence, both directions (the same physical stations, traversed backward for the
 * opposite direction — TDX's StationOfLine only publishes one order).
 *
 * NOTE: this is topology only, no schedule/headway data — TDX's Metro endpoints this
 * adapter has verified access to (Station, StationOfLine) don't include one. No edges
 * get built from this alone yet (Graph Builder needs either gtfs_stop_times or
 * transit_route_frequency to build a time-dependent/headway edge); FirstLastTimetable is
 * the likely real source for that, not yet wired in — same "structure now, data
 * later" pattern as the bus stop_id-resolution and headway-edge gaps before it.
 */
export async function ingestMetroLine(db, feedId, operatorCode, lineId, lineNameZh) {
  const [rawStations, rawStationOfLine] = await Promise.all([
    provider.getMetroStations(operatorCode),
    provider.getMetroStationOfLine(operatorCode),
  ]);
  const stops = normalizeMetroStations(rawStations);
  const forward = normalizeMetroStationSequence(rawStationOfLine, lineId);
  const backward = forward.map((r, i, arr) => ({ ...r, direction: 1, stop_sequence: arr.length - i })).reverse();
  const routeStops = [...forward, ...backward];

  await db.exec(BEGIN);
  try {
    await insertRoutes(db, [{ feed_id: feedId, route_id: lineId, route_short_name: lineNameZh ?? lineId, route_long_name: null, route_type: 1 }]);
    await insertStops(db, feedId, stops);
    await insertRouteStops(db, feedId, lineId, routeStops);
    await db.exec("COMMIT");
  } catch (e) {
    await db.exec("ROLLBACK");
    throw e;
  }
  return { stops: stops.length, routeStops: routeStops.length };
}
