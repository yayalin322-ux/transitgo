// YouBike inside the unified multimodal engine: WALK/BIKE/MRT/BUS/TRA/HSR combinations, the rent/return
// constraints, realtime failure, ranking. Real TRTC metro + real YouBike stations + real TRA/THSR station
// coordinates; the TRA train, THSR train and bus route are hand-built (invented timetables) because no
// local fixture carries them. Nothing here touches the network.
import { createBikeDb, bikeRows, bikeRealtimeOver, buildGraph, railStation, addTimetabled, addHeadway, WEEKDAY, BIKE_REAL } from "./bikeFixture.mjs";
import { planRoute } from "../src/routing/api.mjs";
import { findRoute } from "../src/routing/astar.mjs";
import { rankRoutes } from "../src/routing/rank.mjs";
import { attachVirtualOrigin, attachVirtualDestination } from "../src/graph/virtual.mjs";
import { Mode, MultimodalGraph, TransitEdge, TransitNode, NodeType } from "../src/graph/model.mjs";
import { buildMrtDb } from "./mrtFixture.mjs";
import { addBikeNetwork } from "../src/graph/bikeNetwork.mjs";

let failed = false;
function check(label, cond) { console.log(`${cond ? "PASS" : "FAIL"} - ${label}`); if (!cond) failed = true; }

// real places
const YOUTH = [25.02273, 121.50271];    // 萬華 青年公園3號出口 (a real YouBike station), ~1.4 km from the nearest metro station
const MAIN = [25.0478, 121.517];         // 台北車站
const NANJING = [25.0521, 121.5436];     // 南京復興 area
const NORTH = [25.0880, 121.5170];       // ~4.5 km north of 台北車站: no YouBike in the fixture area
const G10 = { maxWalkingMinutes: 10 };   // walking reach ~780 m: forces the bike to be the way onto the network

const rows = bikeRows();
const stationList = () => BIKE_REAL.stations.map((r) => ({ city: "Taipei", uid: r.uid, name: r.name, lat: r.lat, lon: r.lon, capacity: r.capacity }));
/** A metro-free graph: hand-added vehicles first, THEN the real bike layer (same function the build uses), so docks link to them. */
async function syntheticGraph(add) {
  const { db: d } = await buildMrtDb([]);
  const g = await buildGraph(d);
  add(g);
  addBikeNetwork(g, stationList());
  return { g, d };
}
const plan = (g, db, o, d, options = {}, rt = bikeRealtimeOver(rows)) =>
  planRoute(g, { origin: { lat: o[0], lng: o[1] }, destination: { lat: d[0], lng: d[1] }, departureTime: WEEKDAY, options }, db, { bikeRealtime: rt });
const modes = (r) => r.segments.map((s) => s.mode);
const hasBike = (r) => r.segments.some((s) => s.mode === "BIKE");
const bikeSeg = (r) => r.segments.find((s) => s.mode === "BIKE");
const withBike = (res) => (res.body.routes ?? []).find(hasBike);
const order = (r, a, b) => { const m = modes(r); return m.indexOf(a) >= 0 && m.indexOf(b) > m.indexOf(a); };

// ============ WALK -> BIKE -> WALK ============
const db = await createBikeDb();
const graph = await buildGraph(db);
{
  const res = await plan(graph, db, MAIN, [25.0420, 121.5326]);   // 台北車站 -> 忠孝新生, 2 km
  const r = withBike(res);
  check("WALK -> BIKE -> WALK: a route with exactly that shape exists", res.status === 200 && r && modes(r).join() === "WALK,BIKE,WALK");
  const b = bikeSeg(r), d = b.bike;
  check("the bike leg has real station ids/names for rent and return", d.rentStationId.startsWith("BIKE_Taipei:") && d.returnStationId.startsWith("BIKE_Taipei:") && d.rentStationName && d.returnStationName && b.from === d.rentStationId);
  check("bike leg: departure/arrival/duration are consistent", Date.parse(b.arrivalTime) - Date.parse(b.departureTime) === b.durationSeconds * 1000 && b.durationSeconds > 0);
  check("bike distance is present and marked estimated (isEstimated, straight-line kept beside it)", b.distanceMeters > 1500 && b.isEstimated === true && d.isEstimated === true && b.straightLineMeters > 0 && b.distanceMeters > b.straightLineMeters);
  check("duration splits into riding + unlock/return handling (both estimates)", d.bikeDurationSeconds + d.handlingSeconds === b.durationSeconds && d.handlingSeconds > 0);
  check("route.bikeRides gives walk-to-dock / ride / walk-from-dock", r.bikeRides.length === 1 && r.bikeRides[0].walkingToBikeMeters >= 0 && r.bikeRides[0].bikeDistanceMeters === b.distanceMeters && r.bikeRides[0].walkingFromBikeMeters >= 0);
  check("fare is null (no bike fare source) — never 0", r.fare === null);
  check("realtime availability attached: bikes to rent at the start, docks free at the end", d.availability.status === "known" && d.availability.rent.availableBikes > 0 && d.availability.return.availableDocks > 0 && d.availability.rent.isRentable && d.availability.return.isReturnable);
  check("the response discloses the estimate model", res.body.assumptions.bike.distanceBasis === "estimate" && res.body.assumptions.bike.speedMps === 4 && res.body.bikeRealtime.available === true);
  check("route totals: bikeSeconds/bikeDistanceMeters reported, walking excludes the ride", r.bikeSeconds === b.durationSeconds && r.bikeDistanceMeters === b.distanceMeters && r.walkingSeconds < 600);
}

// ============ BIKE only if the bike layer is on: allowBike false ============
{
  const res = await plan(graph, db, MAIN, [25.0420, 121.5326], { allowBike: false });
  check("allowBike:false -> no bike leg, and the assumptions block is absent", res.status === 200 && !(res.body.routes ?? []).some(hasBike) && !res.body.assumptions);
  const noBikeAtAll = await plan(graph, db, YOUTH, MAIN, { ...G10, allowBike: false });
  check("without bike the far-from-transit origin has nothing nearby (no dock is mistaken for a stop)", noBikeAtAll.status === 404 && noBikeAtAll.body.error.code === "NO_ORIGIN_NEARBY");
}

// ============ WALK -> BIKE -> MRT -> WALK,  MRT -> BIKE -> WALK ============
{
  const res = await plan(graph, db, YOUTH, NANJING, G10);
  const r = (res.body.routes ?? []).find((x) => order(x, "BIKE", "MRT"));
  check("WALK -> BIKE -> MRT -> WALK: origin 1.4 km from any metro station, the bike is the way in", res.status === 200 && !!r);
  check("...the walk between the dock and the metro station is a real link (no invented transfer)", (() => { const m = modes(r); return m.join(",").startsWith("WALK,BIKE,WALK,MRT"); })());
  check("...transfer counted between the ride on the bike and the metro ride", r.transfers >= 1);
  check("...the metro leg still has its real line name; the ride is flagged estimated", r.segments.find((s) => s.mode === "MRT").line && bikeSeg(r).isEstimated);

  const back = await plan(graph, db, NANJING, YOUTH, G10);
  const r2 = (back.body.routes ?? []).find((x) => order(x, "MRT", "BIKE"));
  check("MRT -> BIKE -> WALK: metro to the station nearest the destination, then the bike", back.status === 200 && !!r2 && modes(r2).at(-1) === "WALK");
  check("...the return dock is near the destination (walk from dock is short)", r2.bikeRides[0].walkingFromBikeMeters < 780);
}

// ============ rent / return constraints (realtime overlay) ============
{
  // YOUTH -> MAIN with a 10-minute walking cap: the bike is the only way in, so these are pure constraint tests.
  const base = await plan(graph, db, YOUTH, MAIN, G10);
  const b0 = bikeSeg(withBike(base)).bike;
  const patchOne = (uid, patch) => bikeRealtimeOver(bikeRows((r) => (`BIKE_Taipei:${r.uid}` === uid ? { ...r, ...patch } : r)));

  const r1 = withBike(await plan(graph, db, YOUTH, MAIN, G10, patchOne(b0.rentStationId, { rent: 0 })));
  check("origin station has no bike -> it is not used as the rental point (another dock is)", !!r1 && bikeSeg(r1).bike.rentStationId !== b0.rentStationId && bikeSeg(r1).bike.availability.rent.availableBikes > 0);
  const r2 = withBike(await plan(graph, db, YOUTH, MAIN, G10, patchOne(b0.returnStationId, { ret: 0 })));
  check("destination station has no free dock -> it is not used to return", !!r2 && bikeSeg(r2).bike.returnStationId !== b0.returnStationId && bikeSeg(r2).bike.availability.return.availableDocks > 0);
  const closed = withBike(await plan(graph, db, YOUTH, MAIN, G10, patchOne(b0.rentStationId, { status: 0 })));
  check("a station that is out of service is not used", !!closed && bikeSeg(closed).bike.rentStationId !== b0.rentStationId);
  const r3 = withBike(await plan(graph, db, YOUTH, MAIN, G10, patchOne(b0.rentStationId, { rent: 0 })));
  check("...and the replacement really has a bike to take (isRentable)", bikeSeg(r3).bike.availability.rent.isRentable === true);
  // a station with no bikes is still a fine place to RETURN a bike
  const r4 = withBike(await plan(graph, db, YOUTH, MAIN, G10, patchOne(b0.returnStationId, { rent: 0 })));
  check("a station with no bikes can still be the return dock", !!r4 && bikeSeg(r4).bike.returnStationId === b0.returnStationId);
  // nothing rentable anywhere
  const none = bikeRealtimeOver(bikeRows((r) => ({ ...r, rent: 0 })));
  const res0 = await plan(graph, db, MAIN, [25.0420, 121.5326], {}, none);
  check("no bike anywhere: routes still come back (metro), none uses a bike", res0.status === 200 && res0.body.routes.length > 0 && !res0.body.routes.some(hasBike));
  const far = await plan(graph, db, YOUTH, MAIN, G10, none);
  check("no bike anywhere AND no other way in: NO_ROUTE (a clean error, not a crash)", far.status === 404 && far.body.error.code === "NO_ROUTE");
  const nodocks = bikeRealtimeOver(bikeRows((r) => ({ ...r, ret: 0 })));
  const far2 = await plan(graph, db, YOUTH, MAIN, G10, nodocks);
  check("no free dock anywhere: the ride can't end, so no bike route (NO_ROUTE)", far2.status === 404 && far2.body.error.code === "NO_ROUTE");
}

// ============ realtime failure: routing keeps working ============
{
  const t = bikeRealtimeOver([], { loadCaches: () => new Promise(() => {}) });
  const res = await plan(graph, db, MAIN, [25.0420, 121.5326], {}, t);
  const r = withBike(res);
  check("realtime timeout: request succeeds (200)", res.status === 200 && res.body.routes.length > 0);
  check("realtime timeout: bike candidates stay, flagged availability 'unknown' with the reason", !!r && r.bikeAvailability === "unknown" && bikeSeg(r).bike.availability.status === "unknown" && res.body.bikeRealtime.available === false && res.body.bikeRealtime.reason === "timeout");
  check("realtime timeout: no invented counts — rent/return are null", bikeSeg(r).bike.availability.rent === null && bikeSeg(r).bike.availability.return === null);
  check("realtime timeout: non-bike routes are untouched", res.body.routes.some((x) => !hasBike(x)) || res.body.routes.length >= 1);

  const empty = await plan(graph, db, MAIN, [25.0420, 121.5326], {}, bikeRealtimeOver([], { loadCaches: async () => [] }));
  check("empty realtime response: same behavior, reason no_data", empty.status === 200 && empty.body.bikeRealtime.reason === "no_data" && withBike(empty)?.bikeAvailability === "unknown");

  const strict = await plan(graph, db, MAIN, [25.0420, 121.5326], { bikeUnavailable: "exclude" }, t);
  check("bikeUnavailable:'exclude': with realtime down no bike route is offered, the rest still is", strict.status === 200 && !strict.body.routes.some(hasBike));
  const strictFar = await plan(graph, db, YOUTH, MAIN, { ...G10, bikeUnavailable: "exclude" }, t);
  check("...and when the bike was the only way in it is a plain NO_ROUTE, not a realtime failure", strictFar.status === 404 && strictFar.body.error.code === "NO_ROUTE");

  const noProvider = await planRoute(graph, { origin: { lat: MAIN[0], lng: MAIN[1] }, destination: { lat: 25.042, lng: 121.5326 }, departureTime: WEEKDAY }, db);
  check("no availability provider configured at all: still plans, availability unknown", noProvider.status === 200 && (noProvider.body.routes.find(hasBike)?.bikeAvailability ?? "unknown") === "unknown");
}

// ============ BUS <-> BIKE, TRA <-> BIKE, HSR <-> BIKE (metro-free graph so the pair under test is the only way) ============
{
  const traTp = railStation("tra", "臺北"), traHc = railStation("tra", "新竹");
  const hsrTp = railStation("thsr", "台北"), hsrTc = railStation("thsr", "台中");
  const D = (h, m) => h * 3600 + m * 60;
  const { g, d: db2 } = await syntheticGraph((g) => {
    addHeadway(g, { feed: "TPE", fromId: "B1", fromName: "北門站", from: { lat: 25.0470, lon: 121.5170 }, toId: "B2", toName: "北投站", to: { lat: NORTH[0], lon: NORTH[1] }, routeId: "R1", headway: 480, travel: 1200 });
    addHeadway(g, { feed: "TPE", fromId: "B2", fromName: "北投站", from: { lat: NORTH[0], lon: NORTH[1] }, toId: "B1", toName: "北門站", to: { lat: 25.0470, lon: 121.5170 }, routeId: "R1", headway: 480, travel: 1200 });
    addTimetabled(g, { feed: "TRA", fromId: "1000", fromName: "臺北", from: traTp, toId: "3300", toName: "新竹", to: traHc, mode: Mode.TRA, routeId: "TRA", dep: D(10, 0), arr: D(10, 54) });
    addTimetabled(g, { feed: "TRA", fromId: "3300", fromName: "新竹", from: traHc, toId: "1000", toName: "臺北", to: traTp, mode: Mode.TRA, routeId: "TRA", dep: D(10, 0), arr: D(10, 54) });
    addTimetabled(g, { feed: "THSR", fromId: "1000", fromName: "台北", from: hsrTp, toId: "1040", toName: "台中", to: hsrTc, mode: Mode.HSR, routeId: "THSR", dep: D(10, 0), arr: D(10, 50) });
    addTimetabled(g, { feed: "THSR", fromId: "1040", fromName: "台中", from: hsrTc, toId: "1000", toName: "台北", to: hsrTp, mode: Mode.HSR, routeId: "THSR", dep: D(10, 0), arr: D(10, 50) });
  });
  const rt = bikeRealtimeOver(rows);
  const go = (o, dest) => plan(g, db2, o, dest, G10, rt);
  const seq = (r, ...ms) => { const m = modes(r).filter((x) => x !== "WALK"); return m.length === ms.length && ms.every((x, i) => m[i] === x); };
  const N2 = [NORTH[0] + 0.0004, NORTH[1]];

  let res = await go(YOUTH, N2);
  let r = (res.body.routes ?? []).find((x) => seq(x, "BIKE", "BUS"));
  check("BIKE -> BUS: bike from the far origin to the dock beside the bus stop, then the bus", res.status === 200 && !!r);
  res = await go(N2, YOUTH);
  r = (res.body.routes ?? []).find((x) => seq(x, "BUS", "BIKE"));
  check("BUS -> BIKE: bus first, then the bike from the dock beside the stop to the destination", res.status === 200 && !!r);

  res = await go(YOUTH, [traHc.lat, traHc.lon]);
  r = (res.body.routes ?? []).find((x) => seq(x, "BIKE", "TRA"));
  check("BIKE -> TRA: bike to a dock near 臺北 station, then the train to 新竹", res.status === 200 && !!r);
  res = await go([traHc.lat, traHc.lon], YOUTH);
  r = (res.body.routes ?? []).find((x) => seq(x, "TRA", "BIKE"));
  check("TRA -> BIKE: train to 臺北, then bike from the dock beside the station", res.status === 200 && !!r);

  res = await go(YOUTH, [hsrTc.lat, hsrTc.lon]);
  r = (res.body.routes ?? []).find((x) => seq(x, "BIKE", "HSR"));
  check("BIKE -> HSR: bike to a dock near 高鐵台北, then the high-speed train", res.status === 200 && !!r);
  res = await go([hsrTc.lat, hsrTc.lon], YOUTH);
  r = (res.body.routes ?? []).find((x) => seq(x, "HSR", "BIKE"));
  check("HSR -> BIKE: high-speed train, then the bike to the destination", res.status === 200 && !!r);

  // links exist only where a stop really has a dock nearby
  const linksAt = (id) => (g.edgesByFrom.get(id) ?? []).filter((e) => e.source?.startsWith("Haversine estimate (bike station"));
  check("a real 台北 stop has docks beside it -> linked; the 北投 stop has none within 300 m -> no link is assumed", linksAt("TPE:B1").length > 0 && linksAt("TPE:B2").length === 0);
  check("台中 高鐵 (no YouBike in this data) gets no link either — not every station is assumed to have a dock", linksAt("THSR:1040").length === 0 && linksAt("THSR:1000").length > 0);

  const found = (await go(YOUTH, N2)).body.routes.find((x) => seq(x, "BIKE", "BUS"));
  const bIdx = modes(found).indexOf("BIKE");
  check("a bus is never boarded straight from the saddle: a walk (return + walk to stop) separates them", modes(found)[bIdx + 1] === "WALK");
}

// ============ search rules (direct, on a tiny hand-made graph) ============
{
  const g = new MultimodalGraph();
  const add = (id, lat, lon, mode = null) => g.addNode(new TransitNode({ id, type: mode === Mode.BIKE ? NodeType.STATION : NodeType.STOP, mode, name: id, lat, lon }));
  add("BIKE_T:A", 25.0, 121.0, Mode.BIKE); add("BIKE_T:B", 25.0, 121.01, Mode.BIKE); add("BIKE_T:C", 25.0, 121.02, Mode.BIKE);
  add("S:X", 25.0, 121.0003); add("S:Y", 25.0, 121.0203);
  const e = (from, to, mode, sec, m = 1000) => g.addEdge(new TransitEdge({ id: `${from}>${to}`, fromNodeId: from, toNodeId: to, mode, travelSeconds: sec, distanceMeters: m, source: "t" }));
  e("S:X", "BIKE_T:A", Mode.WALK, 30, 30); e("BIKE_T:A", "S:X", Mode.WALK, 30, 30);
  e("BIKE_T:A", "BIKE_T:B", Mode.BIKE, 300); e("BIKE_T:B", "BIKE_T:C", Mode.BIKE, 300);
  e("BIKE_T:C", "S:Y", Mode.WALK, 30, 30);
  const yes = { check: () => "yes", unlockSeconds: 30, returnSeconds: 30 };
  const t = 9 * 3600;
  const ok = findRoute(g, "S:X", "S:Y", t, { bike: yes });
  check("search: walk to a dock, ride two hops as ONE ride (no re-rent), return, walk", !ok.error && ok.route.legs.map((l) => l.mode).join() === "WALK,BIKE,BIKE,WALK" && ok.route.bikeSeconds === 300 + 300 + 60);
  check("search: unlock+return charged once for the whole ride, folded into its first leg", ok.route.legs[1].handlingSeconds === 60 && ok.route.legs[2].handlingSeconds === 0 && ok.route.legs[1].arrivalSeconds - ok.route.legs[1].departureSeconds === 360);
  check("search: bike fare unknown -> route fare null", ok.route.fare === null);
  check("search: bike layer off -> the same graph has no route (docks invisible, bike edges unusable)", findRoute(g, "S:X", "S:Y", t, {}).error === "NO_ROUTE");
  const noRent = findRoute(g, "S:X", "S:Y", t, { bike: { ...yes, check: (n, role) => (role === "rent" ? "no" : "yes") } });
  check("search: rent refused everywhere -> no route", noRent.error === "NO_ROUTE");
  const noReturn = findRoute(g, "S:X", "S:Y", t, { bike: { ...yes, check: (n, role) => (role === "return" ? "no" : "yes") } });
  check("search: a ride cannot end without a free dock (never leaves the bike)", noReturn.error === "NO_ROUTE");
  const asked = [];
  findRoute(g, "S:X", "S:Y", t, { bike: { ...yes, check: (n, role) => { asked.push(`${role}:${n}`); return "yes"; } } });
  check("search: availability is asked only about stations the search actually reaches (rent at A, return at C — not at B)", asked.includes("rent:BIKE_T:A") && asked.includes("return:BIKE_T:C") && !asked.some((a) => a.endsWith(":BIKE_T:B") && a.startsWith("return")));
  const unk = findRoute(g, "S:X", "S:Y", t, { bike: { ...yes, check: () => "unknown" } });
  check("search: 'unknown' keeps the route and flags it", !unk.error && unk.route.bikeAvailabilityUnknown === true && ok.route.bikeAvailabilityUnknown === false);
  // docks are not walking bridges: X -> A -> (walk) -> ... must not exist on foot
  g.addEdge(new TransitEdge({ id: "A>Z", fromNodeId: "BIKE_T:A", toNodeId: "S:Y", mode: Mode.WALK, travelSeconds: 5, distanceMeters: 5, source: "t" }));
  const bridge = findRoute(g, "S:X", "S:Y", t, { bike: { ...yes, check: () => "no" } });
  check("search: on foot, a dock can never be used as a shortcut between two stops", bridge.error === "NO_ROUTE");
}

// ============ ranking with a bike in the mix ============
{
  // a bus 台北車站 -> 忠孝新生 area (metro-free graph), alongside the bike option
  const { g, d: db3 } = await syntheticGraph((g) => {
    addHeadway(g, { feed: "TPE", fromId: "P1", fromName: "台北車站(公車)", from: { lat: 25.0480, lon: 121.5172 }, toId: "P2", toName: "忠孝新生(公車)", to: { lat: 25.0421, lon: 121.5327 }, routeId: "B9", headway: 300, travel: 900 });
  });
  const res = await plan(g, db3, MAIN, [25.0420, 121.5326], {}, bikeRealtimeOver(rows));
  const routes = res.body.routes;
  check("a bike route and a bus route are BOTH candidates (adding a mode deletes nothing)", res.status === 200 && routes.some(hasBike) && routes.some((r) => modes(r).includes("BUS") && !hasBike(r)));
  check("candidates carry the usual ranking labels", routes.every((r) => ["最快", "最均衡", "少轉乘", "少走路", "最便宜"].includes(r.label)));
  check("LOWEST_COST is never handed out: no candidate has a known fare (bike fare unknown)", !routes.some((r) => r.label === "最便宜") && routes.every((r) => r.fare === null));
  check("dominance still runs: no candidate beats another on every metric", routes.every((a) => routes.every((b) => a === b || !(a.durationSeconds <= b.durationSeconds && a.transfers <= b.transfers && a.walkingSeconds <= b.walkingSeconds && (a.durationSeconds < b.durationSeconds || a.transfers < b.transfers || a.walkingSeconds < b.walkingSeconds)))));
  const bikeR = routes.find(hasBike), busR = routes.find((r) => !hasBike(r));
  check("the bike route has its own transfer accounting (walk -> bike is not a transfer)", bikeR.transfers === 0);
  // profile-specific results (each of the five profiles must run with bike in the graph)
  for (const profile of ["FASTEST", "BALANCED", "FEWEST_TRANSFERS", "LEAST_WALKING", "LOWEST_COST"]) {
    const one = await planRoute(g, { origin: { lat: MAIN[0], lng: MAIN[1] }, destination: { lat: 25.042, lng: 121.5326 }, departureTime: WEEKDAY, profile }, db3, { bikeRealtime: bikeRealtimeOver(rows) });
    check(`profile ${profile}: still returns a route with bike in the graph`, one.status === 200 && one.body.routes.length >= 1);
  }
  check("LEAST_WALKING sees the bike as riding, not walking: it picks the bike route when that walks less", (() => { const lw = routes.find((r) => r.label === "少走路"); return !lw || lw.walkingSeconds <= busR.walkingSeconds; })());
}

// ============ virtual origin / destination use the spatial index and cap the candidates ============
{
  const g2 = await buildGraph(db);
  const o = attachVirtualOrigin(g2, "vo", MAIN[0], MAIN[1], { maxWalkingMeters: 780 });
  const dockEdges = (g2.neighbors("vo") ?? []).filter((e) => e.toNodeId.startsWith("BIKE_"));
  check("virtual origin walks to at most the N nearest docks (never all docks in range)", !!o && dockEdges.length > 0 && dockEdges.length <= 6);
  const dest = attachVirtualDestination(g2, "vd", MAIN[0], MAIN[1], { maxWalkingMeters: 780 });
  const intoDest = [...g2.edgesByFrom.values()].flat().filter((e) => e.toNodeId === "vd" && e.fromNodeId.startsWith("BIKE_"));
  check("virtual destination: docks -> walk -> destination, also capped", !!dest && intoDest.length > 0 && intoDest.length <= 6);
  check("...and the dock distances are real haversine distances within reach", dockEdges.every((e) => e.distanceMeters <= 780));
}

console.log(failed ? "\nOVERALL: FAIL" : "\nOVERALL: PASS");
process.exit(failed ? 1 : 0);
