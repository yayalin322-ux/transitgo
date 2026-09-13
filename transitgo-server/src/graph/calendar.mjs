/**
 * Real GTFS service-calendar checking — architecture doc section 4: "必須支援：平日/
 * 週末/國定假日/特殊停駛日/加班車". Checked per-edge at ROUTE-SEARCH time (not baked
 * into the graph at build time) so the same in-memory graph works for any query date
 * without a rebuild — a cancellation for one specific date shouldn't require reloading
 * the whole graph, any more than a delay should (see section 15's same principle for
 * realtime data).
 */

const WEEKDAY_FIELDS = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"];

/**
 * @param {{calendarRow: object|null, exceptions: Map<string, number>}} serviceEntry
 * @param {string} dateStr "YYYYMMDD"
 */
export function isServiceActiveOn(serviceEntry, dateStr) {
  if (!serviceEntry) return true;   // no calendar info at all for this service — don't block on absence, that's not what this data means
  const exceptionType = serviceEntry.exceptions.get(dateStr);
  if (exceptionType === 2) return false;   // explicitly removed for this date — real 停駛
  if (exceptionType === 1) return true;    // explicitly added for this date, regardless of the weekly pattern

  const cal = serviceEntry.calendarRow;
  if (!cal) return true;   // calendar_dates-only service with no exception listed for this date — no reason to block it
  if (cal.start_date && dateStr < cal.start_date) return false;
  if (cal.end_date && dateStr > cal.end_date) return false;
  const dow = new Date(`${dateStr.slice(0, 4)}-${dateStr.slice(4, 6)}-${dateStr.slice(6, 8)}T00:00:00Z`).getUTCDay();
  return cal[WEEKDAY_FIELDS[dow]] === 1;
}

/** Loads every feed's calendar + calendar_dates into one lookup keyed "feedId:serviceId". */
export function loadServiceCalendar(db, feedClause, feedArgs) {
  const map = new Map();
  for (const row of db.prepare(`SELECT * FROM gtfs_calendar ${feedClause}`).all(...feedArgs)) {
    map.set(`${row.feed_id}:${row.service_id}`, { calendarRow: row, exceptions: new Map() });
  }
  for (const row of db.prepare(`SELECT * FROM gtfs_calendar_dates ${feedClause}`).all(...feedArgs)) {
    const key = `${row.feed_id}:${row.service_id}`;
    if (!map.has(key)) map.set(key, { calendarRow: null, exceptions: new Map() });
    map.get(key).exceptions.set(row.date, row.exception_type);
  }
  return map;
}
