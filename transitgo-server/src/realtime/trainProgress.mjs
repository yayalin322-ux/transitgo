/**
 * Where a 台鐵 train is now, in terms a passenger's family cares about: which station it just left or is at,
 * the next station, how many stops are left before the sharer boards / gets off, and when it should arrive.
 *
 * Inputs are what TDX really publishes — the train's timetable for the day (StopTimes) and its row from the
 * live train board (last station, 進站中／在站上／已離站, delay in minutes). Nothing is invented: a time that
 * is shown for a station the train has not reached yet is the timetable time PLUS the current delay, and is
 * labelled an estimate by the caller; with no live row there is no position, only the schedule.
 */

const DAY_MS = 86_400_000;

/** "HH:mm" on a Taipei date ("YYYY-MM-DD") → epoch ms; a time earlier than `afterMs` rolls to the next day. */
function taipeiMs(dateStr, hhmm, afterMs = null) {
  const [h, m] = String(hhmm ?? "").split(":").map(Number);
  if (!Number.isFinite(h) || !Number.isFinite(m)) return null;
  let ms = Date.parse(`${dateStr}T${String(h).padStart(2, "0")}:${String(m).padStart(2, "0")}:00+08:00`);
  if (!Number.isFinite(ms)) return null;
  while (afterMs != null && ms < afterMs) ms += DAY_MS;
  return ms;
}

/** TDX DailyTrainTimetable response → ordered stops with schedule times in epoch ms (after-midnight safe). */
export function parseTimetable(raw, dateStr) {
  const tt = (raw?.TrainTimetables ?? [])[0];
  if (!tt) return null;
  const stops = [];
  let last = null;
  for (const s of tt.StopTimes ?? []) {
    const arr = taipeiMs(dateStr, s.ArrivalTime ?? s.DepartureTime, last);
    const dep = taipeiMs(dateStr, s.DepartureTime ?? s.ArrivalTime, arr ?? last);
    if (arr == null && dep == null) continue;
    last = dep ?? arr;
    stops.push({ seq: s.StopSequence, stationId: String(s.StationID), name: s.StationName?.Zh_tw ?? String(s.StationID), arrMs: arr ?? dep, depMs: dep ?? arr });
  }
  if (stops.length < 2) return null;
  return {
    trainNo: String(tt.TrainInfo?.TrainNo ?? ""),
    trainType: tt.TrainInfo?.TrainTypeName?.Zh_tw ?? null,
    towards: tt.TrainInfo?.TripHeadSign ?? null,
    stops,
  };
}

/** One train's row from TDX v3 TrainLiveBoard → a small position record, or null. */
export function parseLiveRow(board, trainNo) {
  const row = (board?.TrainLiveBoards ?? []).find((r) => String(r.TrainNo) === String(trainNo));
  if (!row) return null;
  // TDX: 0 進站中, 1 在站上, 2 已離站. Anything else is reported as unknown, not guessed.
  const status = row.TrainStationStatus === 0 ? "approaching" : row.TrainStationStatus === 1 ? "at_station" : row.TrainStationStatus === 2 ? "departed" : "unknown";
  return {
    stationId: String(row.StationID),
    stationName: row.StationName?.Zh_tw ?? null,
    status,
    delayMinutes: Number.isFinite(row.DelayTime) ? row.DelayTime : null,
    updatedAtMs: Date.parse(row.UpdateTime ?? "") || null,
  };
}

const est = (ms, delayMin) => (ms == null ? null : ms + (Number.isFinite(delayMin) ? delayMin : 0) * 60_000);

/**
 * @param timetable  result of parseTimetable (or null)
 * @param live       result of parseLiveRow (or null = the train is not on the live board)
 * @param fromId,toId  the sharer's boarding / alighting station ids (TDX StationID) — optional
 */
export function summarizeTrain({ timetable, live, fromId = null, toId = null, nowMs }) {
  const out = {
    phase: "unknown", position: null, next: null, stopsToFrom: null, stopsToTo: null,
    delayMinutes: live?.delayMinutes ?? null, depMs: null, arrMs: null, depIsEstimate: false, arrIsEstimate: false, updatedAtMs: live?.updatedAtMs ?? null,
  };
  if (!timetable) {
    if (live) out.position = { stationId: live.stationId, stationName: live.stationName, status: live.status };
    out.phase = live ? "running" : "unknown";
    return out;
  }
  const { stops } = timetable;
  const idx = (id) => (id == null ? -1 : stops.findIndex((s) => s.stationId === String(id)));
  const iFrom = idx(fromId), iTo = idx(toId);
  const delay = live?.delayMinutes ?? null;

  if (iFrom >= 0) { out.depMs = est(stops[iFrom].depMs, delay); out.depIsEstimate = delay != null; }
  if (iTo >= 0) { out.arrMs = est(stops[iTo].arrMs, delay); out.arrIsEstimate = delay != null; }

  const cur = live ? idx(live.stationId) : -1;
  if (live && cur >= 0) {
    const s = stops[cur];
    out.position = { stationId: s.stationId, stationName: s.name, status: live.status };
    // The station the train reaches next: the current one while approaching it, the following one once it
    // is standing at / has left the current one.
    const nextIdx = live.status === "approaching" ? cur : cur + 1;
    if (live.status !== "unknown" && nextIdx < stops.length) {
      out.next = { stationId: stops[nextIdx].stationId, name: stops[nextIdx].name, estMs: est(stops[nextIdx].arrMs, delay) };
    }
    // Stops left before the sharer's stations: 0 = it is there or already past. The last station fully
    // reached is the current one unless the train is still only approaching it.
    const reached = live.status === "approaching" ? cur - 1 : cur;
    if (iFrom >= 0) out.stopsToFrom = Math.max(0, iFrom - reached);
    if (iTo >= 0) out.stopsToTo = Math.max(0, iTo - reached);
    const arrivedAtTo = iTo >= 0 && cur >= iTo && live.status !== "approaching";
    const atTerminus = cur === stops.length - 1 && live.status !== "approaching";
    if (arrivedAtTo || atTerminus) out.phase = "arrived";
    else if (iFrom >= 0 && reached < iFrom) out.phase = "beforeBoarding";
    else out.phase = "running";
    return out;
  }

  // Not on the live board (or a station we cannot place): only the timetable can be said.
  const firstDep = stops[0].depMs, lastArr = stops[stops.length - 1].arrMs;
  const boardMs = iFrom >= 0 ? stops[iFrom].depMs : firstDep;
  const alightMs = iTo >= 0 ? stops[iTo].arrMs : lastArr;
  if (nowMs < firstDep - 5 * 60_000) out.phase = "notStarted";
  else if (nowMs > lastArr + 20 * 60_000) out.phase = nowMs > alightMs ? "ended" : "unknown";
  else if (nowMs < boardMs && nowMs < firstDep) out.phase = "notStarted";
  else out.phase = "noLiveData";
  return out;
}
