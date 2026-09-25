/**
 * A station's departure board, split into 北上 / 南下, from TDX v3 StationLiveBoard (every train about to call at the
 * station, with its terminus, type, platform and real delay) plus the TRA station list (for coordinates).
 *
 * Why not TDX's own `Direction` field: it is 順行/逆行 per line, not north/south. Real rows from 2026-09-19 show it —
 * train 428 臺北 → 新左營 has Direction 0, train 6021 新營 → 新左營 has Direction 1, and both are heading south. So the
 * heading is worked out from where the train ends: a terminus clearly north of this station is 北上, clearly south is
 * 南下, and one within ~3 km of it in latitude (a branch line running sideways) is "other" rather than guessed.
 */

const DEAD_BAND_DEG = 0.03;   // ≈ 3.3 km of latitude

const hhmm = (t) => (typeof t === "string" && /^\d{2}:\d{2}/.test(t) ? t.slice(0, 5) : null);
const minutesOf = (hm) => (hm ? Number(hm.slice(0, 2)) * 60 + Number(hm.slice(3, 5)) : null);

/** TRA v3 Station response -> Map(stationId -> { name, lat, lon }). */
export function parseStationCoords(raw) {
  const out = new Map();
  for (const s of raw?.Stations ?? []) {
    const lat = s.StationPosition?.PositionLat, lon = s.StationPosition?.PositionLon;
    if (s.StationID != null && Number.isFinite(lat) && Number.isFinite(lon)) {
      out.set(String(s.StationID), { name: s.StationName?.Zh_tw ?? String(s.StationID), lat, lon });
    }
  }
  return out;
}

export function headingOf(fromLat, toLat) {
  if (!Number.isFinite(fromLat) || !Number.isFinite(toLat)) return "unknown";
  const d = toLat - fromLat;
  if (Math.abs(d) < DEAD_BAND_DEG) return "other";
  return d > 0 ? "north" : "south";
}

/**
 * @param board   TDX StationLiveBoard response ({ StationLiveBoards: [...] })
 * @param coords  Map from parseStationCoords (may be empty: headings are then "unknown", never guessed)
 * @param nowHm   "HH:mm" in Taipei time; trains that left more than `graceMin` ago are dropped
 */
export function buildRailBoard(board, { stationId, coords = new Map(), nowHm = null, graceMin = 2, limit = 12 } = {}) {
  const rows = (board?.StationLiveBoards ?? board ?? []).filter?.((r) => String(r.StationID) === String(stationId)) ?? [];
  const here = coords.get(String(stationId));
  const nowMin = minutesOf(nowHm);
  const trains = [];
  for (const r of rows) {
    const depart = hhmm(r.ScheduleDepartureTime) ?? hhmm(r.ScheduleArrivalTime);
    if (!depart) continue;
    const delay = Number.isFinite(r.DelayTime) ? r.DelayTime : null;
    // Compare on the clock, wrapping at midnight (a 00:10 train is "ahead" of 23:55, not 23 h behind).
    if (nowMin != null) {
      let ahead = (minutesOf(depart) + (delay ?? 0)) - nowMin;
      if (ahead < -720) ahead += 1440;
      if (ahead > 720) ahead -= 1440;
      if (ahead < -graceMin) continue;
    }
    const end = coords.get(String(r.EndingStationID));
    trains.push({
      trainNo: String(r.TrainNo),
      type: r.TrainTypeName?.Zh_tw ?? "",
      dest: r.EndingStationName?.Zh_tw ?? "",
      depart,
      delayMinutes: delay,
      platform: r.Platform ? String(r.Platform) : null,
      heading: here && end ? headingOf(here.lat, end.lat) : "unknown",
    });
  }
  const byTime = (a, b) => a.depart.localeCompare(b.depart) || a.trainNo.localeCompare(b.trainNo, "en", { numeric: true });
  trains.sort(byTime);
  const pick = (h) => trains.filter((t) => t.heading === h).slice(0, limit);
  return {
    station: { id: String(stationId), name: rows[0]?.StationName?.Zh_tw ?? here?.name ?? String(stationId) },
    northbound: pick("north"),
    southbound: pick("south"),
    other: [...pick("other"), ...pick("unknown")].sort(byTime).slice(0, limit),
    headingsKnown: !!here,
  };
}
