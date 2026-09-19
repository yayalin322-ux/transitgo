import { REAL_RT } from "./realtimeFixture.mjs";
import { RealtimeState, arrivalState } from "../src/realtime/model.mjs";
import { mapBusRow, busArrivalsAtStop, busAlertsFor, busRoutePath, busStopsPath } from "../src/realtime/sources/bus.mjs";
import { mapMetroLiveBoard, mapMetroAlerts } from "../src/realtime/sources/metro.mjs";
import { mapTraTrain, mapTraAlerts } from "../src/realtime/sources/tra.mjs";
import { mapThsrAlerts } from "../src/realtime/sources/hsr.mjs";

let failed = false;
function check(label, cond) { console.log(`${cond ? "PASS" : "FAIL"} - ${label}`); if (!cond) failed = true; }
const fetchedAtMs = Date.parse("2026-09-19T13:40:00+08:00");

// --- state thresholds ---
check("ETA under 30 s -> arriving (the app's own 進站中 rule)", arrivalState(10) === RealtimeState.ARRIVING);
check("ETA 30-119 s -> approaching", arrivalState(90) === RealtimeState.APPROACHING);
check("ETA 2 min or more -> normal", arrivalState(600) === RealtimeState.NORMAL);
check("no ETA -> unknown (never guessed)", arrivalState(null) === RealtimeState.UNKNOWN);

// --- BUS (real Taipei 307 rows) ---
const rows307 = REAL_RT.busEtaTaipei307;
const normalRow = rows307.find((r) => r.StopStatus === 0 && r.EstimateTime > 120);
const m = mapBusRow(normalRow, { fetchedAtMs });
check("bus: StopStatus 0 + real EstimateTime -> normal with a real estimatedTime", m.state === RealtimeState.NORMAL && m.etaSeconds === normalRow.EstimateTime && m.estimatedTime !== null);
check("bus: estimatedTime = the row's own UpdateTime + EstimateTime", Date.parse(m.estimatedTime) === Date.parse(normalRow.UpdateTime) + normalRow.EstimateTime * 1000);
check("bus: scheduledTime and delaySeconds are null — TDX's ETA has no timetable, so no delay is invented", m.scheduledTime === null && m.delaySeconds === null);
check("bus: mode/source/route name carried", m.mode === "BUS" && m.source === "tdx.bus.estimatedTimeOfArrival" && m.routeName === "307");
const soon = mapBusRow({ ...normalRow, EstimateTime: 12 }, { fetchedAtMs });
check("bus: 12 s ETA -> arriving", soon.state === RealtimeState.ARRIVING);
const notDeparted = mapBusRow(rows307.find((r) => r.StopStatus === 1), { fetchedAtMs });
check("bus: StopStatus 1 -> notDeparted, no estimate", notDeparted.state === RealtimeState.NOT_DEPARTED && notDeparted.estimatedTime === null);
const notOperating = mapBusRow(rows307.find((r) => r.StopStatus === 4), { fetchedAtMs });
check("bus: StopStatus 4 -> notOperating", notOperating.state === RealtimeState.NOT_OPERATING);
check("bus: StopStatus 2 -> notStopping, 3 -> lastServicePassed (TDX values, verbatim)", mapBusRow({ ...normalRow, StopStatus: 2 }, { fetchedAtMs }).state === RealtimeState.NOT_STOPPING && mapBusRow({ ...normalRow, StopStatus: 3 }, { fetchedAtMs }).state === RealtimeState.LAST_SERVICE_PASSED);
check("bus: status 0 but no EstimateTime -> unknown, not a fabricated number", mapBusRow({ ...normalRow, EstimateTime: undefined }, { fetchedAtMs }).state === RealtimeState.UNKNOWN);
const hsz = mapBusRow(REAL_RT.busEtaHsinchu20[0], { fetchedAtMs });
check("bus (新竹 shape, no EstimateTime): keeps StopCountDown as stops-away instead of inventing minutes", hsz.state === RealtimeState.NOT_DEPARTED && hsz.etaSeconds === null);
check("bus: a '-1' plate is not a vehicle id", hsz.vehicleId === null);
const atStop = busArrivalsAtStop(rows307, normalRow.StopUID, { direction: normalRow.Direction, fetchedAtMs });
check("bus: arrivals filter to the stop and direction", atStop.length >= 1 && atStop.every((s) => s.stopUID === normalRow.StopUID && s.direction === normalRow.Direction));
check("bus: paths are TDX's scope-based ETA endpoints, route name URL-encoded", busRoutePath("City/Taipei", "藍1") === "v2/Bus/EstimatedTimeOfArrival/City/Taipei/%E8%97%8D1" && busStopsPath("InterCity", ["A", "B"]).includes("StopUID%20eq%20'A'"));

// --- BUS alerts (real Taipei alerts): scope match + validity window ---
const [routeAlert, stopAlert] = REAL_RT.busAlertTaipei;
const inWindow = Date.parse(routeAlert.StartTime) + 1000;
const hit = busAlertsFor([routeAlert], { routeName: routeAlert.Scope.Routes[0].RouteName.Zh_tw, nowMs: inWindow });
check("bus alert: matches by route name inside its own StartTime..EndTime", hit.length === 1 && hit[0].title === routeAlert.Title);
check("bus alert: NOT shown before its StartTime (this real alert starts 2027-01-21)", busAlertsFor([routeAlert], { routeName: routeAlert.Scope.Routes[0].RouteName.Zh_tw, nowMs: fetchedAtMs }).length === 0);
check("bus alert: NOT shown after its EndTime", busAlertsFor([routeAlert], { routeName: routeAlert.Scope.Routes[0].RouteName.Zh_tw, nowMs: Date.parse(routeAlert.EndTime) + 1000 }).length === 0);
check("bus alert: an unrelated route gets nothing", busAlertsFor([routeAlert], { routeName: "不存在", nowMs: inWindow }).length === 0);
const stopScoped = busAlertsFor([{ ...stopAlert, StartTime: "2026-01-01T00:00:00+08:00", EndTime: "2027-01-01T00:00:00+08:00" }], { routeName: "x", stopIds: [stopAlert.Scope.Stops[0].StopID], nowMs: fetchedAtMs });
check("bus alert: matches by stop id too", stopScoped.length === 1);

// --- METRO ---
const tymc = REAL_RT.metroLiveBoardTYMC;
const a1 = mapMetroLiveBoard(tymc, { stationId: "A1", aheadStopIds: ["A13"], fetchedAtMs });
check("TYMC: several real upcoming trains toward the airport, soonest first", a1.length >= 2 && a1[0].etaSeconds <= a1[1].etaSeconds);
check("TYMC: EstimateTime is minutes -> seconds", a1[1].etaSeconds === tymc.filter((r) => r.StationID === "A1" && r.DestinationStationID === "A13").map((r) => r.EstimateTime).sort((x, y) => x - y)[1] * 60);
check("TYMC: 0 minutes -> arriving", a1[0].state === RealtimeState.ARRIVING);
check("TYMC: only trains heading toward the leg's later stations", a1.every((s) => s.towards === "往機場第二航廈站"));
check("TYMC: estimatedTime = UpdateTime + minutes", Date.parse(a1[1].estimatedTime) === Date.parse(tymc.find((r) => r.StationID === "A1").UpdateTime) + a1[1].etaSeconds * 1000);
const trtc = mapMetroLiveBoard(REAL_RT.metroLiveBoardTRTC, { stationId: REAL_RT.metroLiveBoardTRTC[0].StationID, fetchedAtMs });
check("TRTC: a row exists only while a train is at the platform (EstimateTime 0) -> arriving", trtc.length >= 1 && trtc.every((s) => s.state === RealtimeState.ARRIVING));
check("TRTC: no station/direction with no row is reported as a wait — an empty list means 'nothing arriving right now'", mapMetroLiveBoard(REAL_RT.metroLiveBoardTRTC, { stationId: "ZZ99", fetchedAtMs }).length === 0);
check("metro: a non-zero ServiceStatus is unknown with the raw code, not interpreted", mapMetroLiveBoard([{ ...tymc[0], ServiceStatus: 3 }], { stationId: tymc[0].StationID, fetchedAtMs })[0].state === RealtimeState.UNKNOWN);
check("metro alerts: TDX's 正常營運 (Status 1) is not an alert", mapMetroAlerts({ Alerts: [{ Title: "正常營運", Status: 1 }] }).length === 0);
check("metro alerts: a real notice passes through", mapMetroAlerts({ Alerts: [{ AlertID: "9", Title: "列車延誤", Status: 2, Description: "訊號" }] })[0].title === "列車延誤");

// --- TRA (real StationLiveBoard) ---
const board = REAL_RT.traStationLiveBoard;
const late = board.StationLiveBoards.find((r) => r.DelayTime >= 5);
const lateStatus = mapTraTrain(board, { stationId: late.StationID, trainNo: late.TrainNo, dateStr: "2026-09-19", fetchedAtMs });
check("TRA: DelayTime minutes -> delaySeconds", lateStatus.delaySeconds === late.DelayTime * 60);
check("TRA: real delay -> state delayed (RunningStatus 1)", lateStatus.state === RealtimeState.DELAYED);
check("TRA: estimatedTime = the real schedule + the real delay; scheduledTime kept untouched", Date.parse(lateStatus.estimatedTime) - Date.parse(lateStatus.scheduledTime) === late.DelayTime * 60_000);
check("TRA: train type / direction carried", lateStatus.trainType === late.TrainTypeName.Zh_tw && lateStatus.towards === `往${late.EndingStationName.Zh_tw}`);
const onTime = board.StationLiveBoards.find((r) => r.RunningStatus === 0);
if (onTime) {
  const s = mapTraTrain(board, { stationId: onTime.StationID, trainNo: onTime.TrainNo, dateStr: "2026-09-19", fetchedAtMs });
  check("TRA: RunningStatus 0 and no delay -> normal, delay 0", s.state === RealtimeState.NORMAL && s.delaySeconds === 0);
}
const cancelBoard = { StationLiveBoards: [{ ...late, RunningStatus: 2 }] };
const cancelled = mapTraTrain(cancelBoard, { stationId: late.StationID, trainNo: late.TrainNo, dateStr: "2026-09-19", fetchedAtMs });
check("TRA: RunningStatus 2 -> cancelled with NO estimate (fixture-derived: not yet seen live)", cancelled.state === RealtimeState.CANCELLED && cancelled.estimatedTime === null);
check("TRA: an unrecognised RunningStatus is unknown + raw code", mapTraTrain({ StationLiveBoards: [{ ...late, RunningStatus: 7 }] }, { stationId: late.StationID, trainNo: late.TrainNo, dateStr: "2026-09-19", fetchedAtMs }).rawRunningStatus === 7);
check("TRA: a train not on this station's board -> null (no data), not a guess", mapTraTrain(board, { stationId: late.StationID, trainNo: "99999", dateStr: "2026-09-19", fetchedAtMs }) === null);
check("TRA alerts: 全線營運正常 (Status 1) is not an alert", mapTraAlerts(REAL_RT.traAlert).length === 0);

// --- HSR ---
check("HSR alerts: TDX's all-zero '全線營運正常' entry is not an alert", mapThsrAlerts(REAL_RT.thsrAlertInfo).length === 0);
check("HSR alerts: a real notice passes through", mapThsrAlerts([{ AlertID: "abc", Title: "部分班次停駛" }])[0].title === "部分班次停駛");

console.log(failed ? "\nOVERALL: FAIL" : "\nOVERALL: PASS");
process.exit(failed ? 1 : 0);
