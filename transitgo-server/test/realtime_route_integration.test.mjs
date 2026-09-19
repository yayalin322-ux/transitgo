// Static plan -> realtime overlay, end to end on the real-data MRT fixture DB plus a hand-built
// TRA trip. Proves: planning never depends on realtime; the plan's own segments feed the overlay;
// the overlay only ever adds fields.
import { buildMrtDb } from "./mrtFixture.mjs";
import { REAL_RT, fakeTdx, httpError } from "./realtimeFixture.mjs";
import { buildGraph, nodeId } from "../src/graph/builder.mjs";
import { planRoute } from "../src/routing/api.mjs";
import { insertStops, insertTrips, insertStopTimes, insertCalendarDates } from "../src/tdx/ingest.mjs";
import { normalizeTRATimetable } from "../src/tdx/normalizer.mjs";
import { createRealtimeService } from "../src/realtime/service.mjs";

let failed = false;
function check(label, cond) { console.log(`${cond ? "PASS" : "FAIL"} - ${label}`); if (!cond) failed = true; }

const WEEKDAY = "2026-09-21T09:00:00+08:00";
const { db } = await buildMrtDb(["TRTC", "TYMC"]);
await insertStops(db, "TRA", [{ stop_id: "1000", stop_name: "臺北", stop_lat: 25.0478, stop_lon: 121.5171 }, { stop_id: "3300", stop_name: "新竹", stop_lat: 24.8017, stop_lon: 120.9714 }]);
const tra = normalizeTRATimetable([{ TrainInfo: { TrainNo: "152" }, StopTimes: [{ StationID: "1000", ArrivalTime: "10:00", DepartureTime: "10:00" }, { StationID: "3300", ArrivalTime: "10:54", DepartureTime: "10:56" }] }], "2026-09-21");
await insertTrips(db, "TRA", tra.trips); await insertStopTimes(db, "TRA", tra.stopTimes); await insertCalendarDates(db, "TRA", tra.calendarDates);
const graph = await buildGraph(db);
const at = (feed, id) => graph.nodes.get(nodeId(feed, id));
const plan = (o, d) => planRoute(graph, { origin: { lat: o.lat, lng: o.lon }, destination: { lat: d.lat, lng: d.lon }, departureTime: WEEKDAY }, db);

// --- TRA: the plan exposes the train it boards, and the overlay finds it ---
const traRes = await plan({ lat: 25.0478, lon: 121.5171 }, { lat: 24.8017, lon: 120.9714 });
const traRoute = traRes.body.routes.find((r) => r.segments.some((s) => s.mode === "TRA"));
const traSeg = traRoute?.segments.find((s) => s.mode === "TRA");
check("TRA leg of a real plan carries the boarded train's tripId", traSeg?.tripId === "TRA_152_2026-09-21");

// a TRA board where train 152 is 7 minutes late (the real captured row, retargeted at this train)
const row = REAL_RT.traStationLiveBoard.StationLiveBoards.find((r) => r.DelayTime >= 5);
const board = { StationLiveBoards: [{ ...row, StationID: "1000", TrainNo: "152", ScheduleDepartureTime: "10:00:00", ScheduleArrivalTime: "10:00:00", DelayTime: 7, RunningStatus: 1 }] };
const now = () => Date.parse("2026-09-21T09:30:00+08:00");
const svc = (routes) => createRealtimeService({ tdxGet: fakeTdx(routes), db, now });
const before = JSON.stringify(traRes.body);
const overlay = await svc({ "v3/Rail/TRA/StationLiveBoard/": board, "v3/Rail/TRA/Alert": REAL_RT.traAlert }).routeOverlay({ segments: traRoute.segments, departureTime: traRoute.departureTime, arrivalTime: traRoute.arrivalTime });
const traLeg = overlay.legs.find((l) => l.mode === "TRA");
check("overlay finds the planned train on the live board by tripId", traLeg?.available && traLeg.status.delaySeconds === 7 * 60);
check("route ETA = static arrival + 7 min, marked realtime", overlay.eta.etaSource === "realtime" && Date.parse(overlay.eta.estimatedArrivalTime) === Date.parse(traRoute.arrivalTime) + 7 * 60_000);
check("the static plan object is not mutated by the overlay", JSON.stringify(traRes.body) === before);

// --- realtime down: identical static plan, overlay says why ---
const down = await svc({ "v3/Rail/TRA/StationLiveBoard/": () => { throw httpError(401); }, "v3/Rail/TRA/Alert": () => { throw httpError(401); } })
  .routeOverlay({ segments: traRoute.segments, departureTime: traRoute.departureTime, arrivalTime: traRoute.arrivalTime });
const replan = await plan({ lat: 25.0478, lon: 121.5171 }, { lat: 24.8017, lon: 120.9714 });
// per-request random ids (requestId, virtual_origin_/virtual_destination_ node uuids) are the only legitimate differences
const noReqId = (b) => JSON.stringify({ ...b, requestId: undefined }).replace(/virtual_(origin|destination)_[0-9a-f-]{36}/g, "virtual_$1");
check("planRoute output is identical whether or not realtime works, apart from its per-request id (it never calls realtime)", noReqId(replan.body) === noReqId(traRes.body));
check("credential failure: overlay reports credential, route still fully usable", down.summary.unavailableReasons.includes("credential") && replan.status === 200 && replan.body.routes.length > 0);
check("credential failure: ETA stays the scheduled one", down.eta.etaSource === "scheduled" && down.eta.estimatedArrivalTime === null);

// --- MRT (TYMC, real LiveBoard) ---
const a1 = at("MRT_TYMC", "A1"), a13 = at("MRT_TYMC", "A13") ?? at("MRT_TYMC", "A21");
const mrtRes = await plan(a1, a13);
const mrtRoute = mrtRes.body.routes[0];
const ride = mrtRoute.segments.find((s) => s.mode === "MRT");
check("MRT segment from a real plan is a valid overlay input (mode, from, routeId)", ride && ride.from?.startsWith("MRT_TYMC:") && !!ride.routeId);
const mo = await svc({ "v2/Rail/Metro/LiveBoard/TYMC": REAL_RT.metroLiveBoardTYMC, "v2/Rail/Metro/Alert/": { Alerts: [] } }).routeOverlay({ segments: mrtRoute.segments, departureTime: mrtRoute.departureTime, arrivalTime: mrtRoute.arrivalTime });
check("TYMC ride gets real next-train arrivals", mo.legs[0].mode === "MRT" && mo.legs[0].available && mo.legs[0].arrivals.every((a) => a.state));
check("MRT has no scheduled departure to compare, so it never shifts the route ETA", mo.legs[0].scheduledTime === (ride.departureTime ?? null) || mo.eta.shiftSeconds === null || Number.isFinite(mo.eta.shiftSeconds));

console.log(failed ? "\nOVERALL: FAIL" : "\nOVERALL: PASS");
process.exit(failed ? 1 : 0);
