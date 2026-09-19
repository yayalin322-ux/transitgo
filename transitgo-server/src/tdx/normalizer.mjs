/**
 * Normalizer — TDX's raw JSON (PascalCase, TDX-specific nesting) → the internal
 * gtfs_* / transit_route_frequency model from src/gtfs/schema.mjs. This is the ONLY place
 * that should know what TDX's fields are called; everything downstream (Graph Builder,
 * Routing Engine) only ever sees the internal model.
 */

/** Real MRT/metro stations — same shape as StationPosition everywhere else in TDX. */
export function normalizeMetroStations(rawStations) {
  return (rawStations ?? []).map((s) => ({
    stop_id: s.StationID,
    stop_name: s.StationName?.Zh_tw ?? null,
    stop_lat: s.StationPosition?.PositionLat ?? null,
    stop_lon: s.StationPosition?.PositionLon ?? null,
  }));
}

/** Real ordered station list per line (TDX's own Sequence) — same role as Bus's StopOfRoute. */
export function normalizeMetroStationSequence(rawStationOfLine, lineId) {
  const rows = [];
  for (const entry of rawStationOfLine ?? []) {
    if (entry.LineID !== lineId) continue;
    for (const s of entry.Stations ?? []) {
      if (!s.StationID || s.Sequence == null) continue;
      // Metro has no real "direction" split like bus does at this endpoint — direction 0
      // covers the line's own published station order; the reverse direction is the
      // same physical edges traversed backward, added separately by the ingest step.
      rows.push({ route_id: lineId, direction: 0, stop_sequence: s.Sequence, stop_id: s.StationID });
    }
  }
  return rows;
}

/** Metro stations from TDX's v2/Rail/Metro/Station — same fields as normalizeMetroStations, kept as-is. */

/** "HH:MM" -> minutes since midnight, or null. */
function hhmmToMinutes(t) {
  const m = /^(\d{1,2}):(\d{2})/.exec(t ?? "");
  return m ? Number(m[1]) * 60 + Number(m[2]) : null;
}

/** A band that ends at or before its start (e.g. "23:00"-"00:00") runs past midnight —
 * express it GTFS-style ("24:00") so the routing engine's plain seconds-since-midnight
 * comparison keeps the band usable instead of silently turning it into a zero-length one. */
function normalizeBandEnd(start, end) {
  const s = hhmmToMinutes(start), e = hhmmToMinutes(end);
  if (s == null || e == null || e > s) return end;
  const total = e + 24 * 60;
  return `${String(Math.floor(total / 60)).padStart(2, "0")}:${String(total % 60).padStart(2, "0")}`;
}

/**
 * Real per-hop metro run times (TDX v2/Rail/Metro/S2STravelTime). Real TDX data comes in
 * two shapes, both handled without inventing anything:
 *
 *   - CHAIN (台北捷運, 新北, 高雄捷運): each row is one consecutive hop, and a row's
 *     FromStationID is the previous row's ToStationID.
 *   - MATRIX (桃園機場捷運): rows are origin-to-every-station times, not hops. The stop
 *     order is recovered from the first origin's increasing times, and each consecutive
 *     hop uses the explicit row for that exact pair when TDX published one, else the
 *     difference of the two cumulative times. A hop with neither gets no edge.
 * Rows with no real RunTime, or a FromStationID equal to the ToStationID (KLRT's loop
 * rows), never produce a hop.
 *
 * Direction: TDX often publishes ONE direction per route (BL-1 runs 南港展覽館 -> 頂埔
 * only). The opposite direction is emitted as its own route (`${route_id}-R`) reusing the
 * published direction's per-hop time — a modeling assumption (recorded in `source`) — unless
 * TDX ALSO published that opposite direction itself (KRTC does), in which case the real
 * numbers are used and nothing is mirrored. A matrix also carries explicit reverse pairs,
 * used when present.
 *
 * Per hop `stop_seconds` is dwell at the FROM station; a hop's ride-plus-dwell is
 * run_seconds + stop_seconds. `base` is TDX's own RouteID (null when TDX gave none) — it is
 * what a Frequency row's RouteID is matched against.
 */
const MAX_PLAUSIBLE_HOP_SECONDS = 30 * 60;

export function normalizeMetroTravelTimes(rawS2S) {
  const SRC = "TDX v2/Rail/Metro/S2STravelTime";
  const SRC_MIRROR = `${SRC} (published for one direction only; opposite direction assumes the same run time)`;
  const SRC_DERIVED = `${SRC} (origin-to-station matrix; hop time derived from cumulative times)`;

  // 1) Per entry: the ordered stop list plus the seconds for each forward/backward hop.
  const parsed = [];
  for (const entry of rawS2S ?? []) {
    const rows = [...(entry.TravelTimes ?? [])]
      .filter((h) => h.FromStationID && h.ToStationID && h.FromStationID !== h.ToStationID && Number.isFinite(h.RunTime))
      .sort((a, b) => a.Sequence - b.Sequence);
    if (rows.length === 0) continue;
    const pairSeconds = new Map();   // "a>b" -> seconds (first row wins)
    for (const h of rows) {
      const k = `${h.FromStationID}>${h.ToStationID}`;
      if (!pairSeconds.has(k)) pairSeconds.set(k, { run: h.RunTime, stop: h.StopTime ?? 0 });
    }

    const isChain = rows.every((h, i) => i === 0 || h.FromStationID === rows[i - 1].ToStationID);
    let stops;
    let forward;   // Map "a>b" -> {run, stop, derived}
    let backward;  // Map "b>a" -> {run, stop} for real published reverse hops (matrix only)
    if (isChain) {
      stops = [rows[0].FromStationID, ...rows.map((h) => h.ToStationID)];
      forward = new Map(rows.map((h) => [`${h.FromStationID}>${h.ToStationID}`, { run: h.RunTime, stop: h.StopTime ?? 0, derived: false }]));
      backward = new Map();
    } else {
      const origin = rows[0].FromStationID;
      const fromOrigin = rows.filter((h) => h.FromStationID === origin).sort((a, b) => a.RunTime - b.RunTime);
      // A genuine origin-to-everywhere matrix has the first origin reaching (nearly) every
      // other station in the entry. A shape that doesn't (KLRT's per-destination rows do
      // not) can't be turned into an order without guessing, so it yields no hops at all.
      const allStations = new Set(rows.flatMap((h) => [h.FromStationID, h.ToStationID]));
      if (fromOrigin.length < 2 || fromOrigin.length < 0.6 * (allStations.size - 1)) continue;
      const cumulative = new Map([[origin, 0]]);
      stops = [origin];
      for (const h of fromOrigin) {
        if (cumulative.has(h.ToStationID)) continue;
        cumulative.set(h.ToStationID, h.RunTime + (h.StopTime ?? 0));
        stops.push(h.ToStationID);
      }
      forward = new Map();
      backward = new Map();
      for (let i = 0; i < stops.length - 1; i++) {
        const a = stops[i], b = stops[i + 1];
        const explicit = pairSeconds.get(`${a}>${b}`);
        if (explicit) forward.set(`${a}>${b}`, { ...explicit, derived: false });
        else {
          const diff = cumulative.get(b) - cumulative.get(a);
          if (diff > 0) forward.set(`${a}>${b}`, { run: diff, stop: 0, derived: true });
        }
        const reverse = pairSeconds.get(`${b}>${a}`);
        if (reverse) backward.set(`${b}>${a}`, reverse);
      }
    }
    if (stops.length < 2) continue;
    // Data-quality guard, not an estimate: no station-to-station metro hop takes more than
    // half an hour. An entry that implies one (KLRT's per-destination loop rows recover a
    // "hop" of 88 minutes) is a mis-shaped source, not a real timing — drop the whole entry
    // rather than build edges out of numbers that can't be right.
    if ([...forward.values()].some((h) => h.run + h.stop > MAX_PLAUSIBLE_HOP_SECONDS)) continue;
    parsed.push({ entry, stops, forward, backward, published: new Set() });
  }

  // 2) Is a route's opposite direction already published as its own entry (KRTC)? Compare stop lists.
  const stopKey = (arr) => arr.join(",");
  const publishedKeys = new Set(parsed.map((p) => stopKey(p.stops)));

  const routes = [];
  const segments = [];
  const usedIds = new Set();
  for (const p of parsed) {
    const e = p.entry;
    const base = e.RouteID || null;
    let routeId = base ?? `${e.LineID || e.LineNo || "M"}-T${e.TrainType ?? 0}`;
    if (usedIds.has(routeId)) routeId = `${routeId}@${p.stops[0]}>${p.stops[p.stops.length - 1]}`;
    usedIds.add(routeId);
    const lineId = e.LineID || e.LineNo || null;

    routes.push({ route_id: routeId, base, line_id: lineId, stops: p.stops });
    p.stops.slice(0, -1).forEach((a, i) => {
      const b = p.stops[i + 1];
      const h = p.forward.get(`${a}>${b}`);
      if (!h) return;
      segments.push({ route_id: routeId, direction: 0, stop_sequence: i + 1, from_stop_id: a, to_stop_id: b, run_seconds: h.run, stop_seconds: h.stop, source: h.derived ? SRC_DERIVED : SRC });
    });

    const reverseStops = [...p.stops].reverse();
    if (publishedKeys.has(stopKey(reverseStops))) continue;   // TDX published the opposite direction itself — don't mirror
    const reverseId = `${routeId}-R`;
    routes.push({ route_id: reverseId, base, line_id: lineId, stops: reverseStops });
    reverseStops.slice(0, -1).forEach((a, i) => {
      const b = reverseStops[i + 1];
      const real = p.backward.get(`${a}>${b}`);
      const mirrored = p.forward.get(`${b}>${a}`);
      const h = real ?? mirrored;
      if (!h) return;
      segments.push({ route_id: reverseId, direction: 0, stop_sequence: i + 1, from_stop_id: a, to_stop_id: b, run_seconds: h.run, stop_seconds: h.stop, source: real ? SRC : SRC_MIRROR });
    });
  }
  return { routes, segments };
}

/**
 * Real metro headway bands (TDX v2/Rail/Metro/Frequency) plus the service-day calendar
 * rows they need. A band is published per RouteID and ServiceTag (平日/假日/…) and is
 * applied to every route `normalizeMetroTravelTimes` derived from that RouteID (including
 * a mirrored `-R` opposite). A route with no matching band simply gets no headway rows —
 * the Graph Builder then marks it wait-unknown rather than guessing. `NationalHolidays`
 * has no date list behind it anywhere in this data, so a weekday national holiday is NOT
 * modeled: the calendar encodes only the weekday flags TDX actually published.
 */
export function normalizeMetroFrequencies(rawFrequency, routes = []) {
  const routesByBase = new Map();
  for (const r of routes) {
    if (!r.base) continue;
    if (!routesByBase.has(r.base)) routesByBase.set(r.base, []);
    routesByBase.get(r.base).push(r.route_id);
  }
  const frequencies = [];
  const calendars = new Map();
  for (const entry of rawFrequency ?? []) {
    const tag = entry.ServiceDay?.ServiceTag;
    const targets = routesByBase.get(entry.RouteID);
    if (!tag || !targets) continue;
    const d = entry.ServiceDay;
    calendars.set(tag, {
      service_id: tag,
      monday: d.Monday ? 1 : 0, tuesday: d.Tuesday ? 1 : 0, wednesday: d.Wednesday ? 1 : 0, thursday: d.Thursday ? 1 : 0,
      friday: d.Friday ? 1 : 0, saturday: d.Saturday ? 1 : 0, sunday: d.Sunday ? 1 : 0,
    });
    for (const h of entry.Headways ?? []) {
      if (!h.StartTime || !h.EndTime) continue;
      if (h.MinHeadwayMins == null && h.MaxHeadwayMins == null) continue;
      for (const rid of targets) {
        frequencies.push({
          route_id: rid, direction: 0, sub_route_name: null, service_day_label: tag,
          start_time: h.StartTime, end_time: normalizeBandEnd(h.StartTime, h.EndTime),
          min_headway_mins: h.MinHeadwayMins ?? null, max_headway_mins: h.MaxHeadwayMins ?? null,
        });
      }
    }
  }
  return { frequencies, calendars: [...calendars.values()] };
}

/**
 * Real interchange links (TDX v2/Rail/Metro/LineTransfer): `TransferTime` is the
 * operator-published minutes to change between the two stations, converted to seconds.
 * Only rows with a real TransferTime are kept — a link with no time is dropped, not
 * defaulted. TDX often lists only one direction of an interchange; the reverse is added
 * with the same time only when the source didn't also list it explicitly.
 */
export function normalizeMetroTransfers(rawTransfers) {
  const byPair = new Map();
  for (const t of rawTransfers ?? []) {
    if (!t.FromStationID || !t.ToStationID || !(t.TransferTime > 0)) continue;
    byPair.set(`${t.FromStationID}>${t.ToStationID}`, {
      from_stop_id: t.FromStationID, to_stop_id: t.ToStationID,
      transfer_seconds: Math.round(t.TransferTime * 60), on_site: t.IsOnSiteTransfer ?? null,
    });
  }
  for (const t of [...byPair.values()]) {
    const key = `${t.to_stop_id}>${t.from_stop_id}`;
    if (!byPair.has(key)) byPair.set(key, { ...t, from_stop_id: t.to_stop_id, to_stop_id: t.from_stop_id });
  }
  return [...byPair.values()];
}

/** Real line display names: `Line` rows (LineID -> LineName.Zh_tw), falling back to the id. */
export function normalizeMetroLineNames(rawLines) {
  const names = new Map();
  for (const l of rawLines ?? []) {
    const id = l.LineID ?? l.LineNo;
    if (id && l.LineName?.Zh_tw) names.set(id, l.LineName.Zh_tw);
  }
  return names;
}

export function normalizeTRAStations(rawStations) {
  return (rawStations ?? []).map((s) => ({
    stop_id: s.StationID,
    stop_name: s.StationName?.Zh_tw ?? s.StationName ?? null,
    stop_lat: s.StationPosition?.PositionLat ?? null,
    stop_lon: s.StationPosition?.PositionLon ?? null,
  }));
}

/**
 * One TRA OD timetable query returns real trips for exactly the ONE date requested —
 * it does not imply "runs every day". So each trip gets its own calendar_dates
 * exception (type 1 = service added on this date) rather than a fabricated weekly
 * gtfs_calendar row we have no evidence for.
 */
export function normalizeTRATimetable(rawTrainTimetables, dateStr) {
  const trips = [];
  const stopTimes = [];
  const calendarDates = [];
  for (const tt of rawTrainTimetables ?? []) {
    const trainNo = tt.TrainInfo?.TrainNo;
    if (!trainNo) continue;
    const tripId = `TRA_${trainNo}_${dateStr}`;
    const serviceId = `TRA_${trainNo}_${dateStr}`;
    trips.push({
      trip_id: tripId,
      route_id: "TRA",
      service_id: serviceId,
      direction_id: null,
      trip_headsign: tt.TrainInfo?.TrainTypeName?.Zh_tw ?? null,
      shape_id: null,
    });
    calendarDates.push({ service_id: serviceId, date: dateStr.replace(/-/g, ""), exception_type: 1 });
    (tt.StopTimes ?? []).forEach((st, i) => {
      if (!st.StationID) return;
      stopTimes.push({
        trip_id: tripId,
        stop_id: st.StationID,
        arrival_time: st.ArrivalTime ?? st.DepartureTime ?? null,
        departure_time: st.DepartureTime ?? st.ArrivalTime ?? null,
        stop_sequence: i + 1,
      });
    });
  }
  return { trips, stopTimes, calendarDates };
}

export function normalizeTHSRStations(rawStations) {
  return (rawStations ?? []).map((s) => ({
    stop_id: s.StationID,
    stop_name: s.StationName?.Zh_tw ?? s.StationName ?? null,
    stop_lat: s.StationPosition?.PositionLat ?? null,
    stop_lon: s.StationPosition?.PositionLon ?? null,
  }));
}

/**
 * THSR's OD timetable shape differs from TRA's: one flat entry per train with just its
 * Origin/DestinationStopTime for the queried pair (StopSequence 1/2), not a full
 * multi-stop StopTimes array — TDX doesn't expose THSR's intermediate-station times via
 * this endpoint the way it does for TRA. That's a real, documented gap (an O-D leg
 * ingested this way only ever produces a 2-stop trip covering exactly the queried pair),
 * not a normalizer bug — ingesting enough real adjacent-station pairs is what turns
 * these into a usable multi-hop THSR line in the graph. Same "one date, one real
 * calendar_dates exception" reasoning as TRA: a query result is evidence for that date
 * only, not a fabricated weekly pattern.
 */
export function normalizeTHSRTimetable(rawODTimetables, dateStr) {
  const trips = [];
  const stopTimes = [];
  const calendarDates = [];
  for (const tt of rawODTimetables ?? []) {
    const trainNo = tt.DailyTrainInfo?.TrainNo;
    const origin = tt.OriginStopTime;
    const dest = tt.DestinationStopTime;
    if (!trainNo || !origin?.StationID || !dest?.StationID) continue;
    const tripId = `THSR_${trainNo}_${origin.StationID}_${dest.StationID}_${dateStr}`;
    const serviceId = tripId;
    trips.push({
      trip_id: tripId,
      route_id: "THSR",
      service_id: serviceId,
      direction_id: tt.DailyTrainInfo?.Direction ?? null,
      trip_headsign: tt.DailyTrainInfo?.EndingStationName?.Zh_tw ?? null,
      shape_id: null,
    });
    calendarDates.push({ service_id: serviceId, date: dateStr.replace(/-/g, ""), exception_type: 1 });
    stopTimes.push({
      trip_id: tripId,
      stop_id: origin.StationID,
      arrival_time: origin.ArrivalTime ?? origin.DepartureTime ?? null,
      departure_time: origin.DepartureTime ?? origin.ArrivalTime ?? null,
      stop_sequence: 1,
    });
    stopTimes.push({
      trip_id: tripId,
      stop_id: dest.StationID,
      arrival_time: dest.ArrivalTime ?? dest.DepartureTime ?? null,
      departure_time: dest.DepartureTime ?? dest.ArrivalTime ?? null,
      stop_sequence: 2,
    });
  }
  return { trips, stopTimes, calendarDates };
}

export function normalizeBusRoutes(rawRoutes, feedId) {
  return (rawRoutes ?? []).map((r) => ({
    feed_id: feedId,
    route_id: r.RouteUID ?? r.RouteID,
    route_short_name: r.RouteName?.Zh_tw ?? null,
    route_long_name: null,
    route_type: 3,
  }));
}

export function normalizeBusStops(rawStopsOfRoute) {
  const stops = [];
  for (const entry of rawStopsOfRoute ?? []) {
    for (const s of entry.Stops ?? []) {
      if (!s.StopUID) continue;
      stops.push({
        stop_id: s.StopUID,
        stop_name: s.StopName?.Zh_tw ?? null,
        stop_lat: s.StopPosition?.PositionLat ?? null,
        stop_lon: s.StopPosition?.PositionLon ?? null,
      });
    }
  }
  return stops;
}

/**
 * The route's real, TDX-ordered stop list per direction (v2/Bus/StopOfRoute's own
 * `StopSequence` field) — this is what lets a Schedule response's per-stop *times*
 * (which carry no StopUID of their own) be matched back to real stations by position.
 */
export function normalizeBusRouteStopSequence(rawStopsOfRoute, routeId) {
  const rows = [];
  for (const entry of rawStopsOfRoute ?? []) {
    const direction = entry.Direction ?? 0;
    for (const s of entry.Stops ?? []) {
      if (!s.StopUID || s.StopSequence == null) continue;
      rows.push({ route_id: routeId, direction, stop_sequence: s.StopSequence, stop_id: s.StopUID });
    }
  }
  return rows;
}

/**
 * A bus route's Schedule entry has EITHER `Timetables` (a real published schedule —
 * common for intercity coach) OR `Frequencys` (real headway bands — the norm for city
 * bus) OR occasionally both for different time windows. Split accordingly rather than
 * picking one and discarding the other; never synthesize a value neither field gave us.
 *
 * `stopSequenceByDirection` (direction -> ordered [stopUID, ...] from StopOfRoute) lets
 * a Timetable's per-stop times — which arrive as a bare array with no StopUID per entry —
 * get resolved to the real station at that position; a position past the end of the
 * known stop list (a StopOfRoute/Schedule mismatch, which does happen) is left null
 * rather than guessed.
 */
export function normalizeBusSchedule(scheduleEntries, routeId, dateStr, stopSequenceByDirection = new Map()) {
  const trips = [];
  const stopTimes = [];
  const calendarDates = [];
  const frequencies = [];

  for (const entry of scheduleEntries ?? []) {
    const direction = entry.Direction ?? 0;
    const orderedStopIDs = stopSequenceByDirection.get(direction) ?? [];

    for (const tt of entry.Timetables ?? []) {
      const stopTimesRaw = tt.StopTimes;
      const tripKey = `BUS_${routeId}_${direction}_${tt.DepartureTime ?? stopTimesRaw?.[0]?.DepartureTime ?? Math.random()}_${dateStr}`;
      trips.push({
        trip_id: tripKey, route_id: routeId,
        service_id: `${tripKey}_svc`, direction_id: direction,
        trip_headsign: entry.SubRouteName?.Zh_tw ?? null, shape_id: null,
      });
      calendarDates.push({ service_id: `${tripKey}_svc`, date: dateStr.replace(/-/g, ""), exception_type: 1 });

      if (Array.isArray(stopTimesRaw) && stopTimesRaw.length > 0) {
        stopTimesRaw.forEach((st, i) => {
          stopTimes.push({
            trip_id: tripKey,
            // Position i in this array is real (i-th stop the trip serves) — resolved to
            // the real station at that position via StopOfRoute's own ordering; only
            // null if that route's stop list wasn't available or the arrays mismatch.
            stop_id: orderedStopIDs[i] ?? null,
            arrival_time: st.ArrivalTime ?? st.DepartureTime ?? null,
            departure_time: st.DepartureTime ?? st.ArrivalTime ?? null,
            stop_sequence: i + 1,
          });
        });
      } else if (tt.DepartureTime) {
        // Route-level single departure time with no per-stop breakdown — still real
        // data, just coarser; this is always the origin stop (position 0).
        stopTimes.push({ trip_id: tripKey, stop_id: orderedStopIDs[0] ?? null, arrival_time: tt.ArrivalTime ?? tt.DepartureTime, departure_time: tt.DepartureTime, stop_sequence: 1 });
      }
    }

    for (const f of entry.Frequencys ?? []) {
      frequencies.push({
        route_id: routeId,
        direction,
        sub_route_name: entry.SubRouteName?.Zh_tw ?? null,
        service_day_label: serviceDayLabel(f.ServiceDay),
        start_time: f.StartTime,
        end_time: f.EndTime,
        min_headway_mins: f.MinHeadwayMins ?? null,
        max_headway_mins: f.MaxHeadwayMins ?? null,
      });
    }
  }
  return { trips, stopTimes, calendarDates, frequencies };
}

function serviceDayLabel(sd) {
  if (!sd) return "每日";
  const flags = [sd.Sunday, sd.Monday, sd.Tuesday, sd.Wednesday, sd.Thursday, sd.Friday, sd.Saturday].map((v) => v === 1);
  const names = ["日", "一", "二", "三", "四", "五", "六"];
  const on = names.filter((_, i) => flags[i]);
  if (on.length === 7) return "每日";
  if (on.length === 0) return "未知";
  return on.map((n) => `週${n}`).join("");
}
