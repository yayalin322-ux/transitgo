// Service-level behaviour on REAL captured TDX responses, through a fake transport (no network).
import { REAL_RT, T0, fakeTdx } from "./realtimeFixture.mjs";
import { createRealtimeService } from "../src/realtime/service.mjs";
import { createRealtimeCache } from "../src/realtime/cache.mjs";

let failed = false;
function check(label, cond) { console.log(`${cond ? "PASS" : "FAIL"} - ${label}`); if (!cond) failed = true; }

const late = REAL_RT.traStationLiveBoard.StationLiveBoards.find((r) => r.DelayTime >= 5);
const bus = REAL_RT.busEtaTaipei307.find((r) => r.StopStatus === 0 && r.EstimateTime > 120);
const T = (hhmm) => `2026-09-19T${hhmm}:00+08:00`;

const tdx = () => fakeTdx({
  "v2/Bus/EstimatedTimeOfArrival/City/Taipei": REAL_RT.busEtaTaipei307,
  "v2/Bus/Alert/": REAL_RT.busAlertTaipei,
  "v3/Rail/TRA/StationLiveBoard/": REAL_RT.traStationLiveBoard,
  "v3/Rail/TRA/Alert": REAL_RT.traAlert,
  "v2/Rail/Metro/LiveBoard/TYMC": REAL_RT.metroLiveBoardTYMC,
  "v2/Rail/Metro/Alert/": { Alerts: [] },
  "v2/Rail/THSR/AlertInfo": REAL_RT.thsrAlertInfo,
});
const svc = (t, extra = {}) => createRealtimeService({ tdxGet: t, now: () => T0, ...extra });

const busSeg = { mode: "BUS", routeShortName: "307", routeId: bus.RouteUID, scopePath: "City/Taipei", from: `TPE:${bus.StopUID}`, to: "TPE:TPE999", departureTime: T("13:50"), arrivalTime: T("14:10") };
const traSeg = { mode: "TRA", routeShortName: "自強", from: `TRA:${late.StationID}`, to: "TRA:4340", tripId: `TRA_${late.TrainNo}_2026-09-19`, departureTime: T("13:57"), arrivalTime: T("14:40") };
const hsrSeg = { mode: "HSR", from: "THSR:1000", to: "THSR:1070", departureTime: T("15:00"), arrivalTime: T("15:50") };

// --- BUS ---
{
  const t = tdx(); const o = await svc(t).routeOverlay({ segments: [{ mode: "WALK" }, busSeg], departureTime: T("13:45"), arrivalTime: T("14:10") });
  const leg = o.legs[0];
  check("WALK legs are not part of the overlay", o.legs.length === 1 && o.legs[0].mode === "BUS");
  check("bus: leg carries real realtime arrivals", leg.available && leg.status.state === "normal" && leg.status.etaSeconds === bus.EstimateTime);
  check("bus: scheduledTime is the static plan's, untouched; estimate sits beside it", leg.scheduledTime === busSeg.departureTime && leg.estimatedTime !== null && leg.scheduledTime !== leg.estimatedTime);
  check("bus: etaSource realtime when an estimate exists", leg.etaSource === "realtime");
  check("bus: delaySeconds stays null (no timetable in TDX's ETA)", leg.status.delaySeconds === null && o.summary.delaySeconds === null);
}

// --- TRA delay -> ETA shift; the static schedule is not overwritten ---
{
  const o = await svc(tdx()).routeOverlay({ segments: [traSeg], departureTime: T("13:50"), arrivalTime: T("14:40") });
  const leg = o.legs[0];
  check("TRA: real DelayTime surfaces as delaySeconds", leg.status.delaySeconds === late.DelayTime * 60 && o.summary.delaySeconds === late.DelayTime * 60);
  check("TRA: state delayed", leg.status.state === "delayed" && o.summary.state === "delayed");
  check("TRA: route ETA = scheduled arrival + the real delay", o.eta.etaSource === "realtime" && o.eta.shiftSeconds === late.DelayTime * 60 && Date.parse(o.eta.estimatedArrivalTime) === Date.parse(T("14:40")) + late.DelayTime * 60_000);
  check("TRA: the leg keeps the timetable time", leg.scheduledTime === T("13:57"));
}

// --- boarding can never be earlier than reaching the stop ---
{
  const early = { ...busSeg, departureTime: T("14:00") };   // bus real ETA ~13:49; rider only arrives 13:55
  const o = await svc(tdx()).routeOverlay({ segments: [{ mode: "WALK", arrivalTime: T("13:55") }, early], departureTime: T("13:45"), arrivalTime: T("14:20") });
  check("an earlier real ETA than the rider can reach the stop does not pull arrival earlier than reach time", o.eta.shiftSeconds === Math.round((Date.parse(T("13:55")) - Date.parse(T("14:00"))) / 1000));
}

// --- HSR: honest not-supported, alerts still separate ---
{
  const o = await svc(tdx()).routeOverlay({ segments: [hsrSeg], arrivalTime: T("15:50") });
  check("HSR: available=false, reason not_supported (no fake arrival)", !o.legs[0].available && o.legs[0].reason === "not_supported" && o.legs[0].status === null);
  check("HSR: etaSource stays scheduled", o.legs[0].etaSource === "scheduled" && o.eta.etaSource === "scheduled");
  check("HSR: the all-normal AlertInfo entry produces no alert", o.legs[0].alerts.length === 0 && o.legs[0].alertsAvailable);
}

// --- MRT (TYMC) ---
{
  const db = { prepare: () => ({ all: async () => [
    { direction: 0, stop_sequence: 1, stop_id: "A1" }, { direction: 0, stop_sequence: 2, stop_id: "A2" }, { direction: 0, stop_sequence: 13, stop_id: "A13" }] }) };
  const seg = { mode: "MRT", routeId: "A", from: "MRT_TYMC:A1", to: "MRT_TYMC:A13", departureTime: T("13:50"), line: "桃園機場捷運線" };
  const o = await svc(tdx(), { db }).routeOverlay({ segments: [seg], arrivalTime: T("14:40") });
  check("MRT: real TYMC arrivals toward the leg's direction", o.legs[0].available && o.legs[0].arrivals.length >= 1 && o.legs[0].arrivals.every((a) => a.mode === "MRT"));
  // TRTC: only arriving-now rows exist, so a station with no row is NOT a delay/absence claim
  const trtcSeg = { mode: "MRT", from: "MRT_TRTC:ZZ99", to: "MRT_TRTC:ZZ98", departureTime: T("13:50") };
  const t2 = fakeTdx({ "v2/Rail/Metro/LiveBoard/TRTC": REAL_RT.metroLiveBoardTRTC, "v2/Rail/Metro/Alert/": { Alerts: [] } });
  const o2 = await svc(t2, { db }).routeOverlay({ segments: [trtcSeg], arrivalTime: T("14:40") });
  check("MRT (TRTC): no row at that station -> no_data (not 'delayed', not 'failed')", !o2.legs[0].available && o2.legs[0].reason === "no_data" && o2.legs[0].etaSource === "scheduled");
}

// --- caching + in-flight sharing ---
{
  const t = tdx(); const s = svc(t);
  const args = { segments: [busSeg], arrivalTime: T("14:10") };
  await Promise.all([s.routeOverlay(args), s.routeOverlay(args), s.routeOverlay(args)]);
  const busCalls = () => t.calls.filter((p) => p.includes("EstimatedTimeOfArrival")).length;
  check("3 concurrent identical requests -> ONE upstream bus ETA call", busCalls() === 1);
  await s.routeOverlay(args); await s.routeOverlay(args);
  check("repeat requests inside the TTL hit the cache (still 1 call)", busCalls() === 1);
  check("stats reflect sharing + cache hits", s.cache.stats.networkCalls === t.calls.length && s.cache.stats.cacheHits >= 2);
  let clock = T0; const cache = createRealtimeCache({ now: () => clock });
  const t3 = tdx(); const s3 = createRealtimeService({ tdxGet: t3, cache, now: () => clock });
  await s3.routeOverlay(args); clock += 16_000; await s3.routeOverlay(args);
  check("after the bus ETA TTL (15 s) the next request refreshes", t3.calls.filter((p) => p.includes("EstimatedTimeOfArrival")).length === 2);
}

// --- nearby list ---
{
  const t = tdx(); const s = svc(t);
  const r = await s.busStopArrivals({ scopePath: "City/Taipei", stopUIDs: [bus.StopUID, "TPE_NONE"] });
  check("nearby: arrivals grouped per requested stop, soonest first", r.available && r.stops[bus.StopUID].length >= 1 && r.stops["TPE_NONE"].length === 0);
  await s.busStopArrivals({ scopePath: "City/Taipei", stopUIDs: ["TPE_NONE", bus.StopUID] });
  check("nearby: same stop set in another order shares the cache", t.calls.length === 1);
}

console.log(failed ? "\nOVERALL: FAIL" : "\nOVERALL: PASS");
process.exit(failed ? 1 : 0);
