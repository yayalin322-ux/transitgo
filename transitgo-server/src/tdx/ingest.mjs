import { TDXProvider } from "./adapter.mjs";
import {
  normalizeTRAStations, normalizeTRATimetable,
  normalizeBusRoutes, normalizeBusStops, normalizeBusSchedule,
} from "./normalizer.mjs";

const provider = new TDXProvider();

export function insertStops(db, feedId, stops) {
  const ins = db.prepare(`
    INSERT INTO gtfs_stops (feed_id, stop_id, stop_name, stop_lat, stop_lon, parent_station, location_type)
    VALUES (?,?,?,?,?,NULL,0)
    ON CONFLICT(feed_id, stop_id) DO UPDATE SET
      stop_name = excluded.stop_name, stop_lat = excluded.stop_lat, stop_lon = excluded.stop_lon
  `);
  for (const s of stops) {
    if (!s.stop_id) continue;
    ins.run(feedId, s.stop_id, s.stop_name, s.stop_lat, s.stop_lon);
  }
}

export function insertTrips(db, feedId, trips) {
  const ins = db.prepare(`
    INSERT INTO gtfs_trips (feed_id, trip_id, route_id, service_id, direction_id, trip_headsign, shape_id)
    VALUES (?,?,?,?,?,?,?)
    ON CONFLICT(feed_id, trip_id) DO NOTHING
  `);
  for (const t of trips) ins.run(feedId, t.trip_id, t.route_id, t.service_id, t.direction_id, t.trip_headsign, t.shape_id);
}

export function insertStopTimes(db, feedId, stopTimes) {
  const ins = db.prepare(`
    INSERT INTO gtfs_stop_times (feed_id, trip_id, stop_id, arrival_time, departure_time, stop_sequence)
    VALUES (?,?,?,?,?,?)
    ON CONFLICT(feed_id, trip_id, stop_sequence) DO NOTHING
  `);
  for (const st of stopTimes) ins.run(feedId, st.trip_id, st.stop_id, st.arrival_time, st.departure_time, st.stop_sequence);
}

export function insertCalendarDates(db, feedId, calendarDates) {
  const ins = db.prepare(`
    INSERT INTO gtfs_calendar_dates (feed_id, service_id, date, exception_type)
    VALUES (?,?,?,?)
    ON CONFLICT(feed_id, service_id, date) DO NOTHING
  `);
  for (const cd of calendarDates) ins.run(feedId, cd.service_id, cd.date, cd.exception_type);
}

export function insertRoutes(db, rows) {
  const ins = db.prepare(`
    INSERT INTO gtfs_routes (feed_id, route_id, agency_id, route_short_name, route_long_name, route_type)
    VALUES (?,?,NULL,?,?,?)
    ON CONFLICT(feed_id, route_id) DO UPDATE SET route_short_name = excluded.route_short_name
  `);
  for (const r of rows) ins.run(r.feed_id, r.route_id, r.route_short_name, r.route_long_name, r.route_type);
}

export function insertFrequencies(db, feedId, freqs) {
  const ins = db.prepare(`
    INSERT INTO transit_route_frequency
      (feed_id, route_id, direction, sub_route_name, service_day_label, start_time, end_time, min_headway_mins, max_headway_mins)
    VALUES (?,?,?,?,?,?,?,?,?)
    ON CONFLICT(feed_id, route_id, direction, service_day_label, start_time, end_time) DO UPDATE SET
      min_headway_mins = excluded.min_headway_mins, max_headway_mins = excluded.max_headway_mins,
      imported_at = datetime('now')
  `);
  for (const f of freqs) {
    ins.run(feedId, f.route_id, f.direction, f.sub_route_name, f.service_day_label, f.start_time, f.end_time, f.min_headway_mins, f.max_headway_mins);
  }
}

/** Ingests real TRA timetable data for one origin→destination pair on one date. */
export async function ingestTRAPair(db, feedId, fromStationID, toStationID, dateStr) {
  const raw = await provider.getTRATimetable(fromStationID, toStationID, dateStr);
  const { trips, stopTimes, calendarDates } = normalizeTRATimetable(raw, dateStr);
  db.exec("BEGIN IMMEDIATE");
  try {
    insertTrips(db, feedId, trips);
    insertStopTimes(db, feedId, stopTimes);
    insertCalendarDates(db, feedId, calendarDates);
    db.exec("COMMIT");
  } catch (e) {
    db.exec("ROLLBACK");
    throw e;
  }
  return { trips: trips.length, stopTimes: stopTimes.length };
}

/** Ingests real TRA station list (stops only, no schedule). */
export async function ingestTRAStations(db, feedId) {
  const raw = await provider.getTRAStations();
  const stops = normalizeTRAStations(raw);
  db.exec("BEGIN IMMEDIATE");
  try {
    insertStops(db, feedId, stops);
    db.exec("COMMIT");
  } catch (e) {
    db.exec("ROLLBACK");
    throw e;
  }
  return { stops: stops.length };
}

/** Ingests one bus route's real schedule (timetable and/or headway, whatever TDX actually has) for one date. */
export async function ingestBusRouteSchedule(db, feedId, scopePath, routeId, routeNameZh, dateStr) {
  const [rawStops, rawSchedule] = await Promise.all([
    provider.getBusStopsOfRoute(scopePath, routeNameZh),
    provider.getBusSchedule(scopePath, routeNameZh),
  ]);
  const stops = normalizeBusStops(rawStops);
  const { trips, stopTimes, calendarDates, frequencies } = normalizeBusSchedule(rawSchedule, routeId, dateStr);

  db.exec("BEGIN IMMEDIATE");
  try {
    insertRoutes(db, [{ feed_id: feedId, route_id: routeId, route_short_name: routeNameZh, route_long_name: null, route_type: 3 }]);
    insertStops(db, feedId, stops);
    insertTrips(db, feedId, trips);
    insertStopTimes(db, feedId, stopTimes);
    insertCalendarDates(db, feedId, calendarDates);
    insertFrequencies(db, feedId, frequencies);
    db.exec("COMMIT");
  } catch (e) {
    db.exec("ROLLBACK");
    throw e;
  }
  return { stops: stops.length, trips: trips.length, stopTimes: stopTimes.length, frequencies: frequencies.length };
}
