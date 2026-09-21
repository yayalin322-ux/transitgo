import { RealtimeState, RealtimeSource, makeStatus, iso } from "../model.mjs";

export const traStationBoardPath = (stationId) => `v3/Rail/TRA/StationLiveBoard/Station/${encodeURIComponent(stationId)}`;
export const traAlertPath = () => "v3/Rail/TRA/Alert";
/** Every running train's last station + delay, in ONE call (about 140 trains): the whole share page costs one read. */
export const traTrainLiveBoardPath = () => "v3/Rail/TRA/TrainLiveBoard";
/** One train's stop times. TDX has today's timetable and the general one; a future date's daily timetable is 404. */
export const traTimetablePath = (trainNo, isToday) =>
  isToday ? `v3/Rail/TRA/DailyTrainTimetable/Today/TrainNo/${encodeURIComponent(trainNo)}` : `v3/Rail/TRA/GeneralTrainTimetable/TrainNo/${encodeURIComponent(trainNo)}`;

/** "HH:mm:ss" on a Taipei calendar date ("YYYY-MM-DD") -> epoch ms. */
function taipeiTimeMs(dateStr, hhmmss) {
  if (!dateStr || !hhmmss) return null;
  const ms = Date.parse(`${dateStr}T${hhmmss}+08:00`);
  return Number.isFinite(ms) ? ms : null;
}

/**
 * One train's real status at one station, from TDX v3 StationLiveBoard (updates every 30 s).
 * `DelayTime` is minutes; RunningStatus 0 = on time, 1 = delayed (all 143 live rows seen on
 * 2026-09-19 fit exactly: status 1 <=> DelayTime > 0). Times are the schedule TDX itself
 * returns plus that real delay — the estimate is never invented.
 *
 * RunningStatus 2 is mapped to `cancelled` per TDX's documentation but has NOT been
 * observed in live data; any other value is `unknown` with the raw code.
 */
export function mapTraTrain(board, { stationId, trainNo, dateStr, fetchedAtMs }) {
  const row = (board?.StationLiveBoards ?? board ?? []).find?.((r) => r.StationID === stationId && String(r.TrainNo) === String(trainNo));
  if (!row) return null;
  const delayMin = Number.isFinite(row.DelayTime) ? row.DelayTime : null;
  const scheduledMs = taipeiTimeMs(dateStr, row.ScheduleDepartureTime ?? row.ScheduleArrivalTime);
  const updatedMs = Date.parse(row.UpdateTime ?? "") || fetchedAtMs;

  let state;
  if (row.RunningStatus === 2) state = RealtimeState.CANCELLED;
  else if (row.RunningStatus === 0 || row.RunningStatus === 1) state = delayMin > 0 ? RealtimeState.DELAYED : RealtimeState.NORMAL;
  else state = RealtimeState.UNKNOWN;

  return makeStatus({
    mode: "TRA",
    routeId: "TRA",
    tripId: String(row.TrainNo),
    scheduledTime: iso(scheduledMs),
    estimatedTime: scheduledMs != null && delayMin != null && state !== RealtimeState.CANCELLED ? iso(scheduledMs + delayMin * 60_000) : null,
    delaySeconds: delayMin == null ? null : delayMin * 60,
    state,
    source: RealtimeSource.TDX_TRA_STATION_LIVEBOARD,
    updatedAt: iso(updatedMs),
    extra: {
      trainType: row.TrainTypeName?.Zh_tw ?? null,
      towards: row.EndingStationName?.Zh_tw ? `往${row.EndingStationName.Zh_tw}` : null,
      platform: row.Platform || null,
      rawRunningStatus: state === RealtimeState.UNKNOWN ? row.RunningStatus ?? null : null,
    },
  });
}

/** TRA network alerts: TDX's "全線營運正常" (Status 1) is not an alert. */
export function mapTraAlerts(raw) {
  return (raw?.Alerts ?? [])
    .filter((a) => a && a.Status !== 1)
    .map((a) => ({ id: String(a.AlertID ?? a.Title ?? ""), title: a.Title ?? "營運異常", description: a.Description ?? null, source: RealtimeSource.TDX_TRA_ALERT, updatedAt: a.UpdateTime ?? null }));
}
