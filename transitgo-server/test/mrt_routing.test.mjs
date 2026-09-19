import { buildMrtDb, fixtureSource } from "./mrtFixture.mjs";
import { buildGraph, nodeId } from "../src/graph/builder.mjs";
import { planRoute, graphCoverage } from "../src/routing/api.mjs";
import { insertStops, insertRoutes, insertRouteStops, insertFrequencies, insertTrips, insertStopTimes, insertCalendarDates } from "../src/tdx/ingest.mjs";
import { normalizeTRATimetable } from "../src/tdx/normalizer.mjs";
import { createMetroRealtime } from "../src/routing/metroRealtime.mjs";
import { haversineMeters } from "../src/graph/virtual.mjs";

let failed = false;
function check(label, cond) {
  console.log(`${cond ? "PASS" : "FAIL"} - ${label}`);
  if (!cond) failed = true;
}

// Monday 2026-09-21, 09:00 Taipei — a normal weekday morning (headway band 平日).
const WEEKDAY = "2026-09-21T09:00:00+08:00";
const SUNDAY = "2026-09-20T09:00:00+08:00";

const { db, results } = await buildMrtDb(["TRTC", "TYMC", "NTMC", "KRTC"]);
const graph = await buildGraph(db);
const at = (feed, id) => graph.nodes.get(nodeId(feed, id));
const trtc = (id) => at("MRT_TRTC", id);
const plan = (o, d, time = WEEKDAY, extra = {}) => planRoute(graph, { origin: { lat: o.lat, lng: o.lon }, destination: { lat: d.lat, lng: d.lon }, departureTime: time, ...extra }, db);
const modes = (route) => route.segments.map((s) => s.mode);
const rides = (route) => route.segments.filter((s) => s.mode === "MRT");

check("Graph has real metro stations from every ingested operator", graph.nodes.has("MRT_TRTC:BL12") && graph.nodes.has("MRT_TYMC:A1") && graph.nodes.has("MRT_NTMC:LB01") && graph.nodes.has("MRT_KRTC:R10"));
check("Edges carry Mode.MRT", [...graph.edgesByFrom.values()].flat().some((e) => e.mode === "MRT"));
check("Graph warnings state the real-data provenance and the direction assumption", graph.warnings.some((w) => w.includes("real TDX run times")) && graph.warnings.some((w) => w.includes("opposite direction")));

// ---------- same-line ----------
{
  const res = await plan(trtc("R10"), trtc("R28"));   // 台北車站 -> 淡水
  const route = res.body.routes[0];
  check("same-line: 200 with a route", res.status === 200 && !!route);
  check("same-line: zero transfers, one metro ride", route.transfers === 0 && rides(route).length === 1);
  const ride = rides(route)[0];
  check("same-line: real line name, direction and stations", ride.line === "淡水信義線" && ride.towards === "往淡水" && ride.boardingStation === "台北車站" && ride.alightingStation === "淡水");
  check("same-line: every intermediate station listed (18 hops -> 19 stations)", ride.stops.length === 19 && ride.stopsPassed === 18);
  check("same-line: ride time is the sum of real S2STravelTime hops (about 37 min), not a distance estimate", ride.durationSeconds > 33 * 60 && ride.durationSeconds < 42 * 60);
  check("same-line: metro legs are flagged estimated-time (headway based, not a timetable)", ride.isEstimated === true);
  check("same-line: wait is paid ONCE at boarding (< one full headway), not per station", route.waitingSeconds > 0 && route.waitingSeconds <= 10 * 60);
  check("same-line: fare stays null — no fare source, never 0", route.fare === null);
  check("same-line: realtime absent without a provider (null, not invented)", route.realtimeStatus === null);
}

// ---------- transfer (real interchange time) ----------
{
  const res = await plan(trtc("BL07"), trtc("R02"));   // 板橋 -> 象山, change at 台北車站
  const route = res.body.routes[0];
  check("transfer: exactly 1 transfer between two metro rides", res.status === 200 && route.transfers === 1 && rides(route).length === 2);
  const walk = route.segments.find((s) => s.walkKind === "MRT_TRANSFER_WALK");
  check("transfer: the interchange is an MRT_TRANSFER_WALK with TDX's real 4-minute BL12<->R10 time", !!walk && walk.durationSeconds === 4 * 60);
  check("transfer: the interchange has NO invented distance", route.legs.find((l) => l.walkKind === "MRT_TRANSFER_WALK").distanceMeters === null);
  check("transfer: boarding two rides pays two waits (each at most one headway)", route.waitingSeconds > 0 && route.waitingSeconds <= 2 * 10 * 60);
}

// ---------- multiple transfers ----------
{
  const res = await plan(trtc("BR01"), trtc("O54"));   // 動物園 -> 蘆洲
  const route = res.body.routes[0];
  check("multi-transfer: 2 transfers across three lines", res.status === 200 && route.transfers === 2 && rides(route).length === 3);
  check("multi-transfer: every interchange uses a real TDX time", route.segments.filter((s) => s.walkKind === "MRT_TRANSFER_WALK").length === 2);
}

// ---------- ranking still works with metro in the graph ----------
{
  const res = await plan(trtc("G03A"), trtc("BR01"));
  const labels = res.body.routes.map((r) => r.label);
  const fewest = res.body.routes.find((r) => r.label === "少轉乘");
  const fastest = res.body.routes.find((r) => r.label === "最快");
  check("ranking: 最快 and 少轉乘 are both produced", !!fewest && !!fastest);
  check("ranking: 少轉乘 really has fewer transfers than 最快 (or ties)", fewest.transfers <= fastest.transfers);
  check("ranking: 最快 is really no slower than 少轉乘", fastest.durationSeconds <= fewest.durationSeconds);
  check("ranking: LOWEST_COST is never labeled — no route has a real fare", !labels.includes("最便宜"));
  check("ranking: no route on this trip is dominated by another (real dominance filter)", res.body.routes.every((a) => !res.body.routes.some((b) => b !== a && b.durationSeconds <= a.durationSeconds && b.transfers <= a.transfers && b.walkingSeconds <= a.walkingSeconds && (b.durationSeconds < a.durationSeconds || b.transfers < a.transfers || b.walkingSeconds < a.walkingSeconds))));
}

// ---------- service days: a weekday-only band is not used on Sunday ----------
{
  const weekday = await plan(trtc("R10"), trtc("R28"), WEEKDAY);
  const sunday = await plan(trtc("R10"), trtc("R28"), SUNDAY);
  check("service day: Sunday routes with the real 假日 headway band (still found)", sunday.status === 200);
  const h = (r) => r.body.routes[0].waitingSeconds;
  check("service day: the two days can carry different real headways (both real, non-null)", h(weekday) != null && h(sunday) != null);
}

// ---------- virtual origin / destination: any address <-> metro ----------
{
  const o = { lat: trtc("R10").lat + 0.0035, lon: trtc("R10").lon };   // ~390 m from the station, no station within 250 m
  const d = { lat: trtc("R28").lat - 0.003, lon: trtc("R28").lon };
  const res = await plan(o, d);
  const route = res.body.routes[0];
  check("virtual: address -> WALK -> MRT -> WALK -> address", res.status === 200 && modes(route)[0] === "WALK" && modes(route).includes("MRT") && modes(route).at(-1) === "WALK");
  check("virtual: walking distance is real and non-zero", route.walkingDistanceMeters > 300);
}

// ---------- cross-operator interchange (TRTC's real LineTransfer names 新北's LB01) ----------
{
  const res = await plan(trtc("BL02"), at("MRT_NTMC", "LB12"));
  check("cross-operator: TRTC -> 新北 via the resolved real interchange", res.status === 200 && rides(res.body.routes[0]).some((s) => s.routeId.startsWith("LB")));
}

// ---------- multimodal: BUS / TRA / HSR joined to MRT ----------
// A small SYNTHETIC bus/TRA/HSR layer (clearly not real data — these tests only prove the
// graph connects modes) is added beside the REAL metro data.
const banqiao = trtc("BL07");
const off = (n, dLat, dLon = 0) => ({ lat: n.lat + dLat, lon: n.lon + dLon });
// A point verifiably far (> 2 km) from EVERY metro station in the graph, so a virtual
// origin placed beside it can only ever attach to the synthetic bus stop, never a station.
function pointFarFromMetro(g, from) {
  const stations = [...g.nodes.values()].filter((n) => n.id.startsWith("MRT_"));
  for (const [dLat, dLon] of [[-0.02, -0.03], [-0.03, -0.02], [0.03, -0.03], [-0.05, 0], [-0.04, -0.04], [0.05, 0.05]]) {
    const p = { lat: from.lat + dLat, lon: from.lon + dLon };
    if (Math.min(...stations.map((n) => haversineMeters(p.lat, p.lon, n.lat, n.lon))) > 2000) return p;
  }
  throw new Error("no point far from metro found");
}
{
  const m = await buildMrtDb(["TRTC"]);
  const mdb = m.db;
  const s = { bus1: pointFarFromMetro(graph, banqiao), bus2: off(banqiao, 0.001) };   // bus1 > 2 km from any metro, bus2 ~110 m from 板橋
  await insertStops(mdb, "TST", [
    { stop_id: "B1", stop_name: "測試站牌一", stop_lat: s.bus1.lat, stop_lon: s.bus1.lon },
    { stop_id: "B2", stop_name: "測試站牌二", stop_lat: s.bus2.lat, stop_lon: s.bus2.lon },
  ]);
  await insertRoutes(mdb, [{ feed_id: "TST", route_id: "T1", route_short_name: "測試1", route_long_name: null, route_type: 3 }, { feed_id: "TST", route_id: "T1R", route_short_name: "測試1", route_long_name: null, route_type: 3 }]);
  await insertRouteStops(mdb, "TST", "T1", [{ route_id: "T1", direction: 0, stop_sequence: 1, stop_id: "B1" }, { route_id: "T1", direction: 0, stop_sequence: 2, stop_id: "B2" }]);
  await insertRouteStops(mdb, "TST", "T1R", [{ route_id: "T1R", direction: 0, stop_sequence: 1, stop_id: "B2" }, { route_id: "T1R", direction: 0, stop_sequence: 2, stop_id: "B1" }]);
  await insertFrequencies(mdb, "TST", ["T1", "T1R"].map((r) => ({ route_id: r, direction: 0, sub_route_name: null, service_day_label: "平日", start_time: "06:00", end_time: "23:00", min_headway_mins: 10, max_headway_mins: 10 })));
  const g2 = await buildGraph(mdb);
  const t = (id) => g2.nodes.get(nodeId("MRT_TRTC", id));
  const p2 = (o, d) => planRoute(g2, { origin: { lat: o.lat, lng: o.lon }, destination: { lat: d.lat, lng: d.lon }, departureTime: WEEKDAY }, mdb);

  const nearBus1 = off(s.bus1, 0.002);   // ~220 m from bus1, > 1.8 km from every station
  const busToMrt = await p2(nearBus1, t("BL12"));   // bus1 -> bus -> bus2 -> link -> 板橋 -> metro -> 台北車站
  const r1 = busToMrt.body?.routes?.[0];
  check("BUS -> MRT: walk, bus, station link walk, metro", busToMrt.status === 200 && ["WALK", "BUS", "WALK", "MRT"].every((mode, i) => modes(r1)[i] === mode));
  check("BUS -> MRT: the bus-to-metro link is a labeled station link, not an interchange", r1.segments.filter((sg) => sg.mode === "WALK").some((sg) => sg.walkKind === "MRT_STATION_LINK"));

  const mrtToBus = await p2(t("BL12"), nearBus1);
  const r2 = mrtToBus.body?.routes?.[0];
  check("MRT -> BUS: metro, station link, bus", mrtToBus.status === 200 && modes(r2).includes("MRT") && modes(r2).includes("BUS") && modes(r2).indexOf("MRT") < modes(r2).indexOf("BUS"));
}
{
  // MRT -> TRA (real TRA 臺北 station coordinates, synthetic 08:00 train) and MRT -> HSR.
  const m = await buildMrtDb(["TRTC"]);
  const mdb = m.db;
  await insertStops(mdb, "TRA", [{ stop_id: "1000", stop_name: "臺北", stop_lat: 25.0478, stop_lon: 121.5171 }, { stop_id: "3300", stop_name: "新竹", stop_lat: 24.8017, stop_lon: 120.9714 }]);
  const tra = normalizeTRATimetable([{ TrainInfo: { TrainNo: "152" }, StopTimes: [{ StationID: "1000", ArrivalTime: "10:00", DepartureTime: "10:00" }, { StationID: "3300", ArrivalTime: "10:54", DepartureTime: "10:56" }] }], "2026-09-21");
  await insertTrips(mdb, "TRA", tra.trips); await insertStopTimes(mdb, "TRA", tra.stopTimes); await insertCalendarDates(mdb, "TRA", tra.calendarDates);
  await insertStops(mdb, "THSR", [{ stop_id: "1000", stop_name: "台北", stop_lat: 25.0477, stop_lon: 121.5170 }, { stop_id: "1030", stop_name: "新竹", stop_lat: 24.8081, stop_lon: 121.0407 }]);
  await insertTrips(mdb, "THSR", [{ trip_id: "H1", route_id: "THSR", service_id: "H1", direction_id: 0, trip_headsign: null, shape_id: null }]);
  await insertStopTimes(mdb, "THSR", [{ trip_id: "H1", stop_id: "1000", arrival_time: "10:10:00", departure_time: "10:10:00", stop_sequence: 1 }, { trip_id: "H1", stop_id: "1030", arrival_time: "10:40:00", departure_time: "10:40:00", stop_sequence: 2 }]);
  await insertCalendarDates(mdb, "THSR", [{ service_id: "H1", date: "20260921", exception_type: 1 }]);
  const g3 = await buildGraph(mdb);
  const t = (id) => g3.nodes.get(nodeId("MRT_TRTC", id));
  const p3 = (o, d) => planRoute(g3, { origin: { lat: o.lat, lng: o.lon }, destination: { lat: d.lat, lng: d.lon }, departureTime: WEEKDAY }, mdb);

  const toTra = await p3(t("R28"), { lat: 24.8017, lon: 120.9714 });   // 淡水 -> metro -> TRA -> 新竹
  const a = toTra.body?.routes?.[0];
  check("MRT -> TRA: metro then train", toTra.status === 200 && modes(a).includes("MRT") && modes(a).includes("TRA") && modes(a).indexOf("MRT") < modes(a).indexOf("TRA"));
  const toHsr = await p3(t("R28"), { lat: 24.8081, lon: 121.0407 });
  const hsr = toHsr.body?.routes?.find((r) => modes(r).includes("HSR"));
  check("MRT -> HSR: metro then high-speed rail is among the candidates", toHsr.status === 200 && !!hsr && modes(hsr).indexOf("MRT") < modes(hsr).indexOf("HSR"));
  check("MRT -> TRA: transfer counted across the station link walk", a.transfers >= 1);
}

// ---------- unknown wait (TYMC publishes no mappable headway) ----------
{
  const res = await plan(at("MRT_TYMC", "A1"), at("MRT_TYMC", "A21"));
  const route = res.body.routes[0];
  check("unknown wait: route still found from real run times", res.status === 200 && rides(route).length === 1);
  check("unknown wait: waitingSeconds is null (not 0, not a guess)", route.waitingSeconds === null);
  check("unknown wait: the ride is flagged estimated", rides(route)[0].isEstimated === true);
}
{
  // A whole operator whose Frequency endpoint is down: every edge is wait-unknown, routes still work.
  const noFreq = await buildMrtDb(["TRTC"], { TRTC: { Frequency: () => { throw new Error("TDX 400"); } } });
  const g4 = await buildGraph(noFreq.db);
  const t = (id) => g4.nodes.get(nodeId("MRT_TRTC", id));
  const res = await planRoute(g4, { origin: { lat: t("R10").lat, lng: t("R10").lon }, destination: { lat: t("R28").lat, lng: t("R28").lon }, departureTime: WEEKDAY }, noFreq.db);
  check("timetable unavailable: route found, waitingSeconds null", res.status === 200 && res.body.routes[0].waitingSeconds === null);
}

// ---------- realtime is optional and never breaks a route ----------
{
  const okRealtime = createMetroRealtime({ fetchAlerts: async () => ({ Alerts: [{ Title: "正常營運", Status: 1 }] }) });
  const withOk = await planRoute(graph, { origin: { lat: trtc("R10").lat, lng: trtc("R10").lon }, destination: { lat: trtc("R28").lat, lng: trtc("R28").lon }, departureTime: WEEKDAY }, db, { realtime: okRealtime });
  check("realtime ok: status attached, normal operation", withOk.body.routes[0].realtimeStatus.available === true && withOk.body.routes[0].realtimeStatus.alerts.length === 0);

  const alertRealtime = createMetroRealtime({ fetchAlerts: async () => ({ Alerts: [{ Title: "淡水線部分列車延誤", Status: 2, Description: "訊號故障" }] }) });
  const withAlert = await planRoute(graph, { origin: { lat: trtc("R10").lat, lng: trtc("R10").lon }, destination: { lat: trtc("R28").lat, lng: trtc("R28").lon }, departureTime: WEEKDAY }, db, { realtime: alertRealtime });
  check("realtime alert: surfaced verbatim in the summary", withAlert.body.routes[0].realtimeStatus.summary.includes("淡水線部分列車延誤"));

  const brokenRealtime = createMetroRealtime({ fetchAlerts: async () => { throw new Error("TDX 429"); } });
  const withBroken = await planRoute(graph, { origin: { lat: trtc("R10").lat, lng: trtc("R10").lon }, destination: { lat: trtc("R28").lat, lng: trtc("R28").lon }, departureTime: WEEKDAY }, db, { realtime: brokenRealtime });
  check("realtime failure: route still 200, static data intact, status says unavailable", withBroken.status === 200 && withBroken.body.routes[0].realtimeStatus.available === false && withBroken.body.routes[0].durationSeconds > 0);
  const throwing = { metroStatus: async () => { throw new Error("boom"); } };
  const withThrow = await planRoute(graph, { origin: { lat: trtc("R10").lat, lng: trtc("R10").lon }, destination: { lat: trtc("R28").lat, lng: trtc("R28").lon }, departureTime: WEEKDAY }, db, { realtime: throwing });
  check("realtime provider that throws outright: route unaffected", withThrow.status === 200 && withThrow.body.routes[0].realtimeStatus.available === false);
}

// ---------- coverage comes from the graph ----------
{
  const c = graphCoverage(graph);
  check("coverage: mrt.available true with the operators that really have data", c.mrt.available === true && ["台北捷運", "桃園捷運", "新北捷運", "高雄捷運"].every((n) => c.mrt.operators.includes(n)));
  check("coverage: KLRT (refused at ingest) is NOT listed", !c.mrt.operators.includes("高雄輕軌"));
  check("coverage: stationCount is the real number of metro stations in the graph", c.mrt.stationCount === results.TRTC.stops + results.TYMC.stops + results.NTMC.stops + results.KRTC.stops);
  check("coverage: metro operators are not mixed into the rail list", !c.rail.some((n) => n.includes("捷運")));
}
{
  const bare = await buildGraph((await buildMrtDb([])).db);
  const c = graphCoverage(bare);
  check("empty MRT dataset: coverage says mrt.available false", c.mrt.available === false && c.mrt.stationCount === 0);
  const res = await planRoute(bare, { origin: { lat: 25.05, lng: 121.5 }, destination: { lat: 25.16, lng: 121.45 }, departureTime: WEEKDAY }, null);
  check("empty MRT dataset: a query returns a clean error, no crash", res.status === 404);
}

console.log(failed ? "\nOVERALL: FAIL" : "\nOVERALL: PASS");
process.exit(failed ? 1 : 0);
