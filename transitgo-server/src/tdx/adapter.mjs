import { getRouting as get } from "../tdx.mjs";
import { TransitDataProvider } from "./provider.mjs";

/**
 * TDXProvider — implements TransitDataProvider against the real TDX endpoints this
 * project already has verified, working access to (the iOS app's RailService.swift and
 * BusService.swift use these exact paths successfully today):
 *
 *   TRA stations   v3/Rail/TRA/Station
 *   TRA timetable  v3/Rail/TRA/DailyTrainTimetable/OD/{from}/to/{to}/{date}   — REAL per-trip schedule
 *   Bus routes     v2/Bus/Route/{scope}
 *   Bus stops      v2/Bus/StopOfRoute/{scope}
 *   Bus schedule   v2/Bus/Schedule/{scope}   — "Timetables" (real schedule, e.g. most
 *                  intercity coach) when the operator publishes one, else "Frequencys"
 *                  (real headway bands TDX gets from the operator — not invented)
 *
 * `scope` here is TDX's own path fragment, e.g. "City/Hsinchu" or "InterCity" — same
 * convention as the Swift app's `BusScope.pathComponent`, so this stays in sync with a
 * concept that's already proven correct rather than reinventing scoping rules.
 *
 * NOTE: every method here has been written against field shapes already verified by the
 * working Swift decoders (RailModels.swift / BusModels.swift), but has NOT yet been
 * exercised against a live call end-to-end from this file — this account's TDX quota
 * (~5 req/min) has been rate-limited on every attempt made while building this. Treat
 * this as reviewed-but-not-live-tested until a real ingest run confirms it.
 */
export class TDXProvider extends TransitDataProvider {
  async getTRAStations() {
    const d = await get("v3/Rail/TRA/Station");
    return d?.Stations ?? [];
  }

  /** Real per-trip timetable between two TRA stations on one date (YYYY-MM-DD). */
  async getTRATimetable(fromStationID, toStationID, dateStr) {
    const d = await get(`v3/Rail/TRA/DailyTrainTimetable/OD/${fromStationID}/to/${toStationID}/${dateStr}`);
    return d?.TrainTimetables ?? [];
  }

  // Same two endpoints, THSR side — verified working in the app's own RailService.swift
  // (v2/Rail/THSR/Station, v2/Rail/THSR/DailyTimetable/OD/{from}/to/{to}/{date}). THSR's
  // OD response shape differs from TRA's: one flat entry per train with just its
  // Origin/DestinationStopTime for the queried pair, not a full multi-stop StopTimes
  // array — see normalizeTHSRTimetable for how that's turned into the same
  // trips/stopTimes shape TRA produces.
  async getTHSRStations() {
    const d = await get("v2/Rail/THSR/Station");
    return d ?? [];
  }

  /** Real per-trip origin/destination times between two THSR stations on one date (YYYY-MM-DD). */
  async getTHSRTimetable(fromStationID, toStationID, dateStr) {
    const d = await get(`v2/Rail/THSR/DailyTimetable/OD/${fromStationID}/to/${toStationID}/${dateStr}`);
    return d ?? [];
  }

  async getBusRoutes(scopePath) {
    return get(`v2/Bus/Route/${scopePath}`);
  }

  async getBusStopsOfRoute(scopePath, routeNameZh) {
    return get(`v2/Bus/StopOfRoute/${scopePath}?${routeFilter(routeNameZh)}`);
  }

  /** Returns the raw TDX BusScheduleEntry[] — callers split Timetables vs Frequencys, see normalizer.mjs. */
  async getBusSchedule(scopePath, routeNameZh) {
    return get(`v2/Bus/Schedule/${scopePath}?${routeFilter(routeNameZh)}`);
  }

  /** `operator` is TDX's own code, e.g. "TRTC" (Taipei Metro), "KRTC" (Kaohsiung). */
  async getMetroStations(operatorCode) {
    return get(`v2/Rail/Metro/Station/${operatorCode}`);
  }

  /** Real ordered station sequence per line — same role as Bus's StopOfRoute. */
  async getMetroStationOfLine(operatorCode) {
    return get(`v2/Rail/Metro/StationOfLine/${operatorCode}`);
  }
}

function routeFilter(routeNameZh) {
  const escaped = routeNameZh.replace(/'/g, "''");
  return `$filter=${encodeURIComponent(`RouteName/Zh_tw eq '${escaped}'`)}`;
}
