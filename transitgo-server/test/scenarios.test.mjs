/**
 * Architecture doc section 19 — the exact 10 named integration scenarios, run against
 * the real engine (Graph Builder → Virtual OD → A* → Ranking → API), using
 * TDX-response-shaped fixtures where real TDX data isn't available yet (every attempt
 * to hit live TDX this session got 429 rate-limited — noted honestly, not hidden).
 */
import { MultimodalGraph, TransitNode, TransitEdge, NodeType, Mode } from "../src/graph/model.mjs";
import { planRoute } from "../src/routing/api.mjs";
import { findRoute } from "../src/routing/astar.mjs";
import { attachVirtualOrigin, attachVirtualDestination } from "../src/graph/virtual.mjs";

let failed = false;
function check(label, cond) {
  console.log(`${cond ? "PASS" : "FAIL"} - ${label}`);
  if (!cond) failed = true;
}

// --- Test 1: 住宅(GPS) → 公車站 → MRT → 目的地 ---
{
  const graph = new MultimodalGraph();
  graph.addNode(new TransitNode({ id: "BUS:stop1", type: NodeType.STOP, lat: 25.03, lon: 121.51 }));
  graph.addNode(new TransitNode({ id: "MRT:hub", type: NodeType.STOP, lat: 25.035, lon: 121.515 }));
  graph.addNode(new TransitNode({ id: "MRT:dest", type: NodeType.STOP, lat: 25.05, lon: 121.55 }));
  graph.addEdge(new TransitEdge({ id: "b1", fromNodeId: "BUS:stop1", toNodeId: "MRT:hub", mode: Mode.BUS, routeId: "1", headwaySeconds: 600, travelSeconds: 400, windowStartSeconds: 0, windowEndSeconds: 86400, source: "test" }));
  graph.addEdge(new TransitEdge({ id: "m1", fromNodeId: "MRT:hub", toNodeId: "MRT:dest", mode: Mode.MRT, routeId: "R", headwaySeconds: 300, travelSeconds: 900, windowStartSeconds: 0, windowEndSeconds: 86400, source: "test" }));
  const res = await planRoute(graph, { origin: { lat: 25.03, lng: 121.51 }, destination: { lat: 25.05, lng: 121.55 } });
  check("Test 1: 住宅→公車站→MRT→目的地 finds a real route with both BUS and MRT legs",
    res.status === 200 && res.body.routes[0].legs.some((l) => l.mode === "BUS") && res.body.routes[0].legs.some((l) => l.mode === "MRT"));
}

// --- Test 2: 住宅 → 公車 → 台鐵 → 目的地 ---
{
  // TRA:3300 is deliberately far from the origin (~5.5km, outside any walking radius) —
  // otherwise the engine correctly just walks straight there and the bus leg is never
  // needed at all, which was the actual first version of this fixture's mistake, not an
  // engine bug: attachVirtualOrigin will always prefer a real shorter path if one exists.
  const graph = new MultimodalGraph();
  graph.addNode(new TransitNode({ id: "BUS:s1", type: NodeType.STOP, lat: 24.80, lon: 120.97 }));
  graph.addNode(new TransitNode({ id: "TRA:3300", type: NodeType.STOP, lat: 24.85, lon: 120.97 }));
  graph.addNode(new TransitNode({ id: "TRA:1000", type: NodeType.STOP, lat: 25.0478, lon: 121.5171 }));
  graph.addEdge(new TransitEdge({ id: "b2", fromNodeId: "BUS:s1", toNodeId: "TRA:3300", mode: Mode.BUS, routeId: "5900", headwaySeconds: 900, travelSeconds: 300, windowStartSeconds: 0, windowEndSeconds: 86400, source: "test" }));
  graph.addEdge(new TransitEdge({ id: "tra1", fromNodeId: "TRA:3300", toNodeId: "TRA:1000", mode: Mode.TRA, routeId: "TRA", departureSeconds: 8 * 3600, arrivalSeconds: 8 * 3600 + 54 * 60, travelSeconds: 54 * 60, source: "TDX real timetable" }));
  const res = await planRoute(graph, { origin: { lat: 24.80, lng: 120.97 }, destination: { lat: 25.0478, lng: 121.5171 }, departureTime: "2026-09-14T07:00:00+08:00" });
  check("Test 2: 住宅→公車→台鐵→目的地 finds a real route with both BUS and TRA legs",
    res.status === 200 && res.body.routes[0].legs.some((l) => l.mode === "BUS") && res.body.routes[0].legs.some((l) => l.mode === "TRA"));
}

// --- Test 3: 住宅 → 高鐵 → MRT → 目的地 ---
{
  const graph = new MultimodalGraph();
  graph.addNode(new TransitNode({ id: "THSR:hsinchu", type: NodeType.STOP, lat: 24.807, lon: 121.04 }));
  graph.addNode(new TransitNode({ id: "THSR:taipei", type: NodeType.STOP, lat: 25.048, lon: 121.517 }));
  graph.addNode(new TransitNode({ id: "MRT:d", type: NodeType.STOP, lat: 25.05, lon: 121.55 }));
  graph.addEdge(new TransitEdge({ id: "hsr1", fromNodeId: "THSR:hsinchu", toNodeId: "THSR:taipei", mode: Mode.HSR, routeId: "THSR", departureSeconds: 8 * 3600, arrivalSeconds: 8 * 3600 + 30 * 60, travelSeconds: 30 * 60, source: "TDX real timetable" }));
  graph.addEdge(new TransitEdge({ id: "m2", fromNodeId: "THSR:taipei", toNodeId: "MRT:d", mode: Mode.MRT, routeId: "R", headwaySeconds: 300, travelSeconds: 600, windowStartSeconds: 0, windowEndSeconds: 86400, source: "test" }));
  const res = await planRoute(graph, { origin: { lat: 24.807, lng: 121.04 }, destination: { lat: 25.05, lng: 121.55 }, departureTime: "2026-09-14T07:00:00+08:00" });
  check("Test 3: 住宅→高鐵→MRT→目的地 finds a real route with both HSR and MRT legs",
    res.status === 200 && res.body.routes[0].legs.some((l) => l.mode === "HSR") && res.body.routes[0].legs.some((l) => l.mode === "MRT"));
}

// --- Test 4: 兩個完全不是交通站點的 GPS 座標 ---
{
  const graph = new MultimodalGraph();
  graph.addNode(new TransitNode({ id: "BUS:near1", type: NodeType.STOP, lat: 25.0300, lon: 121.5100 }));
  graph.addNode(new TransitNode({ id: "BUS:near2", type: NodeType.STOP, lat: 25.0350, lon: 121.5200 }));
  graph.addEdge(new TransitEdge({ id: "b3", fromNodeId: "BUS:near1", toNodeId: "BUS:near2", mode: Mode.BUS, routeId: "9", headwaySeconds: 600, travelSeconds: 500, windowStartSeconds: 0, windowEndSeconds: 86400, source: "test" }));
  // Neither GPS point IS a stop — both are ~150-200m away, real addresses/random points.
  const res = await planRoute(graph, { origin: { lat: 25.0295, lng: 121.5095 }, destination: { lat: 25.0355, lng: 121.5205 } });
  check("Test 4: neither GPS point is itself a station, route still found via virtual origin/destination walk legs",
    res.status === 200 && res.body.routes[0].legs.some((l) => l.mode === "WALK") && res.body.routes[0].legs.some((l) => l.mode === "BUS"));
}

// --- Test 5: 附近沒有交通站 ---
{
  const graph = new MultimodalGraph();
  graph.addNode(new TransitNode({ id: "BUS:only", type: NodeType.STOP, lat: 25.03, lon: 121.51 }));
  const res = await planRoute(graph, { origin: { lat: 22.6, lng: 120.3 }, destination: { lat: 25.03, lng: 121.51 } });   // 高雄 — nothing there in this graph
  check("Test 5: genuinely no nearby stop returns NO_ORIGIN_NEARBY, not a fabricated route", res.status === 404 && res.body.error.code === "NO_ORIGIN_NEARBY");
}

// --- Test 6: 下一班車需要等待 20 分鐘 ---
{
  const graph = new MultimodalGraph();
  graph.addNode(new TransitNode({ id: "A", type: NodeType.STOP, lat: 25.03, lon: 121.51 }));
  graph.addNode(new TransitNode({ id: "D", type: NodeType.STOP, lat: 25.04, lon: 121.52 }));
  // Depart at 10:12 (per the doc's own example), next real bus at 10:32 — a real 20 min wait.
  graph.addEdge(new TransitEdge({ id: "wait20", fromNodeId: "A", toNodeId: "D", mode: Mode.BUS, routeId: "1", departureSeconds: 10 * 3600 + 32 * 60, arrivalSeconds: 10 * 3600 + 47 * 60, travelSeconds: 15 * 60, source: "TDX real timetable" }));
  const result = findRoute(graph, "A", "D", 10 * 3600 + 12 * 60);
  check("Test 6: waiting time is exactly the real 20 minutes to the next real departure (not estimated/rounded)",
    result.route?.waitingSeconds === 20 * 60);
}

// --- Test 7: 某班次停駛（real calendar_dates exception_type=2） ---
{
  const graph = new MultimodalGraph();
  graph.addNode(new TransitNode({ id: "A", type: NodeType.STOP, lat: 25.03, lon: 121.51 }));
  graph.addNode(new TransitNode({ id: "D", type: NodeType.STOP, lat: 25.04, lon: 121.52 }));
  graph.addEdge(new TransitEdge({
    id: "cancelled_trip", fromNodeId: "A", toNodeId: "D", mode: Mode.BUS, routeId: "1",
    departureSeconds: 10 * 3600, arrivalSeconds: 10 * 3600 + 600, travelSeconds: 600,
    serviceKey: "TEST:svc1", source: "TDX real timetable",
  }));
  graph.serviceCalendar = new Map([["TEST:svc1", { calendarRow: null, exceptions: new Map([["20260914", 2]]) }]]);   // real 停駛 exception for this exact date
  const cancelled = findRoute(graph, "A", "D", 9 * 3600, { dateStr: "20260914" });
  check("Test 7: NO_ROUTE on the real cancelled date — the cancelled trip is correctly excluded, not silently offered", cancelled.error === "NO_ROUTE");
  const normalDay = findRoute(graph, "A", "D", 9 * 3600, { dateStr: "20260915" });
  check("Test 7: the SAME trip is usable on a different real date with no exception recorded", !!normalDay.route);
}

// --- Test 8: 需要轉乘兩次 ---
{
  const graph = new MultimodalGraph();
  for (const id of ["A", "B", "C", "D"]) graph.addNode(new TransitNode({ id, type: NodeType.STOP, lat: 25, lon: 121 }));
  graph.addEdge(new TransitEdge({ id: "l1", fromNodeId: "A", toNodeId: "B", mode: Mode.BUS, routeId: "1", headwaySeconds: 600, travelSeconds: 400, windowStartSeconds: 0, windowEndSeconds: 86400, source: "test" }));
  graph.addEdge(new TransitEdge({ id: "l2", fromNodeId: "B", toNodeId: "C", mode: Mode.MRT, routeId: "R", headwaySeconds: 300, travelSeconds: 500, windowStartSeconds: 0, windowEndSeconds: 86400, source: "test" }));
  graph.addEdge(new TransitEdge({ id: "l3", fromNodeId: "C", toNodeId: "D", mode: Mode.BUS, routeId: "9", headwaySeconds: 600, travelSeconds: 300, windowStartSeconds: 0, windowEndSeconds: 86400, source: "test" }));
  const result = findRoute(graph, "A", "D", 8 * 3600, { maxTransfers: 3 });
  check("Test 8: a real 2-transfer route (BUS 1 -> MRT R -> BUS 9) is found and correctly counted", result.route?.transfers === 2);
}

// --- Test 9: 最快路線與少轉乘路線不同 (already covered thoroughly in route_ranking.test.mjs — reconfirmed here at the API level) ---
{
  const graph = new MultimodalGraph();
  graph.addNode(new TransitNode({ id: "A", type: NodeType.STOP, lat: 25.0478, lon: 121.5171 }));
  graph.addNode(new TransitNode({ id: "B", type: NodeType.STOP, lat: 25.04, lon: 121.53 }));
  graph.addNode(new TransitNode({ id: "D", type: NodeType.STOP, lat: 25.0339, lon: 121.5645 }));
  graph.addEdge(new TransitEdge({ id: "direct", fromNodeId: "A", toNodeId: "D", mode: Mode.BUS, routeId: "DIRECT", headwaySeconds: 900, travelSeconds: 1550, windowStartSeconds: 0, windowEndSeconds: 86400, source: "test" }));
  graph.addEdge(new TransitEdge({ id: "leg1", fromNodeId: "A", toNodeId: "B", mode: Mode.BUS, routeId: "L1", headwaySeconds: 600, travelSeconds: 600, windowStartSeconds: 0, windowEndSeconds: 86400, source: "test" }));
  graph.addEdge(new TransitEdge({ id: "leg2", fromNodeId: "B", toNodeId: "D", mode: Mode.BUS, routeId: "L2", headwaySeconds: 600, travelSeconds: 500, windowStartSeconds: 0, windowEndSeconds: 86400, source: "test" }));
  const res = await planRoute(graph, { origin: { lat: 25.0478, lng: 121.5171 }, destination: { lat: 25.0339, lng: 121.5645 } });
  const fastest = res.body.routes.find((r) => r.label === "最快");
  const fewest = res.body.routes.find((r) => r.label === "少轉乘");
  check("Test 9: 最快 and 少轉乘 are genuinely different routes at the API level",
    res.status === 200 && fastest && fewest && fastest.transfers !== fewest.transfers);
}

// --- Test 10: 起點與終點距離 300m，應優先推薦步行 (already directly covered in api.test.mjs — reconfirmed here) ---
{
  const graph = new MultimodalGraph();
  graph.addNode(new TransitNode({ id: "A", type: NodeType.STOP, lat: 25.0478, lon: 121.5171 }));
  graph.addNode(new TransitNode({ id: "D", type: NodeType.STOP, lat: 25.0490, lon: 121.5175 }));
  graph.addEdge(new TransitEdge({ id: "roundabout", fromNodeId: "A", toNodeId: "D", mode: Mode.BUS, routeId: "99", headwaySeconds: 1200, travelSeconds: 900, windowStartSeconds: 0, windowEndSeconds: 86400, source: "test" }));
  const res = await planRoute(graph, { origin: { lat: 25.0478, lng: 121.5171 }, destination: { lat: 25.0490, lng: 121.5175 } });
  const fastest = res.body.routes.find((r) => r.label === "最快") ?? res.body.routes[0];
  check("Test 10: 300m apart favors a direct walk over a slow transit detour", res.status === 200 && !fastest.legs.some((l) => l.mode === "BUS"));
}

console.log(failed ? "\nOVERALL: FAIL" : "\nOVERALL: PASS");
process.exit(failed ? 1 : 0);
