import AdmZip from "adm-zip";
import { parseCsv } from "./csv.mjs";

/**
 * Imports a standard GTFS zip (agency.txt, routes.txt, stops.txt, trips.txt,
 * stop_times.txt, calendar.txt, calendar_dates.txt) into the gtfs_* tables under
 * `feedId`, replacing whatever that feed_id previously held.
 *
 * One atomic swap, not an incremental merge — the "DataVersion, don't mix old and new
 * data" requirement from the architecture doc. Every table's old rows for this feed_id
 * are deleted and the new ones inserted inside a single transaction, so a request that
 * runs mid-import always sees either the complete old feed or the complete new one,
 * never a half-swapped mix.
 *
 * calendar.txt and calendar_dates.txt are both optional per the GTFS spec (a feed only
 * needs one of them) — missing files are just skipped, not an error.
 */
export function importGtfsZip(db, feedId, zipBuffer, meta = {}) {
  const zip = new AdmZip(zipBuffer);
  const entries = new Map(zip.getEntries().map((e) => [e.entryName, e]));

  function readCsv(filename) {
    const entry = entries.get(filename);
    if (!entry) return null;
    return parseCsv(entry.getData().toString("utf8"));
  }

  const agency = readCsv("agency.txt") ?? [];
  const routes = readCsv("routes.txt");
  const stops = readCsv("stops.txt");
  const trips = readCsv("trips.txt");
  const stopTimes = readCsv("stop_times.txt");
  const calendar = readCsv("calendar.txt") ?? [];
  const calendarDates = readCsv("calendar_dates.txt") ?? [];

  if (!routes || !stops || !trips || !stopTimes) {
    throw new Error("missing required GTFS file (routes/stops/trips/stop_times.txt)");
  }
  if (calendar.length === 0 && calendarDates.length === 0) {
    throw new Error("feed has neither calendar.txt nor calendar_dates.txt — no service days defined");
  }

  const counts = {
    agency: agency.length, routes: routes.length, stops: stops.length,
    trips: trips.length, stop_times: stopTimes.length,
    calendar: calendar.length, calendar_dates: calendarDates.length,
  };

  db.exec("BEGIN IMMEDIATE");
  try {
    for (const table of ["gtfs_agency", "gtfs_routes", "gtfs_stops", "gtfs_trips", "gtfs_stop_times", "gtfs_calendar", "gtfs_calendar_dates"]) {
      db.prepare(`DELETE FROM ${table} WHERE feed_id = ?`).run(feedId);
    }

    const insAgency = db.prepare(`INSERT INTO gtfs_agency (feed_id, agency_id, agency_name, agency_url, agency_timezone) VALUES (?,?,?,?,?)`);
    for (const a of agency) {
      insAgency.run(feedId, a.agency_id || "default", a.agency_name ?? null, a.agency_url ?? null, a.agency_timezone ?? null);
    }

    const insRoute = db.prepare(`INSERT INTO gtfs_routes (feed_id, route_id, agency_id, route_short_name, route_long_name, route_type) VALUES (?,?,?,?,?,?)`);
    for (const r of routes) {
      insRoute.run(feedId, r.route_id, r.agency_id || null, r.route_short_name ?? null, r.route_long_name ?? null, r.route_type != null ? parseInt(r.route_type, 10) : null);
    }

    const insStop = db.prepare(`INSERT INTO gtfs_stops (feed_id, stop_id, stop_name, stop_lat, stop_lon, parent_station, location_type) VALUES (?,?,?,?,?,?,?)`);
    for (const s of stops) {
      insStop.run(feedId, s.stop_id, s.stop_name ?? null, s.stop_lat ? parseFloat(s.stop_lat) : null, s.stop_lon ? parseFloat(s.stop_lon) : null, s.parent_station || null, s.location_type != null && s.location_type !== "" ? parseInt(s.location_type, 10) : 0);
    }

    const insTrip = db.prepare(`INSERT INTO gtfs_trips (feed_id, trip_id, route_id, service_id, direction_id, trip_headsign, shape_id) VALUES (?,?,?,?,?,?,?)`);
    for (const t of trips) {
      insTrip.run(feedId, t.trip_id, t.route_id, t.service_id, t.direction_id != null && t.direction_id !== "" ? parseInt(t.direction_id, 10) : null, t.trip_headsign || null, t.shape_id || null);
    }

    const insStopTime = db.prepare(`INSERT INTO gtfs_stop_times (feed_id, trip_id, stop_id, arrival_time, departure_time, stop_sequence) VALUES (?,?,?,?,?,?)`);
    for (const st of stopTimes) {
      insStopTime.run(feedId, st.trip_id, st.stop_id, st.arrival_time || null, st.departure_time || null, parseInt(st.stop_sequence, 10));
    }

    const insCal = db.prepare(`INSERT INTO gtfs_calendar (feed_id, service_id, monday, tuesday, wednesday, thursday, friday, saturday, sunday, start_date, end_date) VALUES (?,?,?,?,?,?,?,?,?,?,?)`);
    for (const c of calendar) {
      insCal.run(feedId, c.service_id, +c.monday, +c.tuesday, +c.wednesday, +c.thursday, +c.friday, +c.saturday, +c.sunday, c.start_date, c.end_date);
    }

    const insCalDate = db.prepare(`INSERT INTO gtfs_calendar_dates (feed_id, service_id, date, exception_type) VALUES (?,?,?,?)`);
    for (const cd of calendarDates) {
      insCalDate.run(feedId, cd.service_id, cd.date, parseInt(cd.exception_type, 10));
    }

    db.prepare(`
      INSERT INTO gtfs_feeds (feed_id, name, source_url, imported_at, row_counts)
      VALUES (:feed_id, :name, :source_url, datetime('now'), :row_counts)
      ON CONFLICT(feed_id) DO UPDATE SET
        name = excluded.name, source_url = excluded.source_url,
        imported_at = excluded.imported_at, row_counts = excluded.row_counts
    `).run({
      feed_id: feedId,
      name: meta.name ?? feedId,
      source_url: meta.sourceUrl ?? null,
      row_counts: JSON.stringify(counts),
    });

    db.exec("COMMIT");
  } catch (e) {
    db.exec("ROLLBACK");
    throw e;
  }

  return counts;
}
