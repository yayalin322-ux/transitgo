/**
 * Normalizer — TDX's raw JSON (PascalCase, TDX-specific nesting) → the internal
 * gtfs_* / transit_route_frequency model from src/gtfs/schema.mjs. This is the ONLY place
 * that should know what TDX's fields are called; everything downstream (Graph Builder,
 * Routing Engine) only ever sees the internal model.
 */

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
 * A bus route's Schedule entry has EITHER `Timetables` (a real published schedule —
 * common for intercity coach) OR `Frequencys` (real headway bands — the norm for city
 * bus) OR occasionally both for different time windows. Split accordingly rather than
 * picking one and discarding the other; never synthesize a value neither field gave us.
 */
export function normalizeBusSchedule(scheduleEntries, routeId, dateStr) {
  const trips = [];
  const stopTimes = [];
  const calendarDates = [];
  const frequencies = [];

  for (const entry of scheduleEntries ?? []) {
    const direction = entry.Direction ?? 0;

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
            trip_id: tripKey, stop_id: null,   // TDX's per-trip StopTimes here don't carry StopUID — Graph Builder joins by sequence against StopOfRoute
            arrival_time: st.ArrivalTime ?? st.DepartureTime ?? null,
            departure_time: st.DepartureTime ?? st.ArrivalTime ?? null,
            stop_sequence: i + 1,
          });
        });
      } else if (tt.DepartureTime) {
        // Route-level single departure time with no per-stop breakdown — still real data,
        // just coarser; stop_id null the same way, resolved against StopOfRoute later.
        stopTimes.push({ trip_id: tripKey, stop_id: null, arrival_time: tt.ArrivalTime ?? tt.DepartureTime, departure_time: tt.DepartureTime, stop_sequence: 1 });
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
