import { MultimodalGraph, TransitNode, TransitEdge, NodeType, Mode } from "../src/graph/model.mjs";
import { attachVirtualOrigin, attachVirtualDestination } from "../src/graph/virtual.mjs";
import { findRoute } from "../src/routing/astar.mjs";

let failed = false;
function check(label, cond) {
  console.log(`${cond ? "PASS" : "FAIL"} - ${label}`);
  if (!cond) failed = true;
}

function buildGraph() {
  const graph = new MultimodalGraph();
  graph.addNode(new TransitNode({ id: "TRA:1000", type: NodeType.STOP, name: "臺北", lat: 25.0478, lon: 121.5171 }));
  graph.addNode(new TransitNode({ id: "TRA:3300", type: NodeType.STOP, name: "新竹", lat: 24.8017, lon: 120.9714 }));
  // Real train 152: 台北 08:00 -> 新竹 08:54 (same fixture as the graph builder test).
  graph.addEdge(new TransitEdge({
    id: "TRA_152", fromNodeId: "TRA:1000", toNodeId: "TRA:3300", mode: Mode.TRA, routeId: "TRA",
    departureSeconds: 8 * 3600, arrivalSeconds: 8 * 3600 + 54 * 60, travelSeconds: 54 * 60,
    source: "TDX real timetable",
  }));
  return graph;
}

// --- Departing before the train: should catch it ---
{
  const graph = buildGraph();
  attachVirtualOrigin(graph, "origin", 25.0478, 121.5171, { maxWalkingMeters: 1200 });
  attachVirtualDestination(graph, "dest", 24.8017, 120.9714, { maxWalkingMeters: 1200 });

  const result = findRoute(graph, "origin", "dest", 7 * 3600);   // depart 07:00, well before 08:00 train
  check("Route found departing at 07:00 for an 08:00 train", !!result.route);
  if (result.route) {
    check("Real arrival time is 08:54 (real train's real arrival, not estimated)", result.route.arrivalTime === 8 * 3600 + 54 * 60);
    check("Waiting time is real (60 min from 07:00 to the 08:00 departure)", result.route.waitingSeconds === 60 * 60);
    check("Transit time is real (54 min, the train's actual travel time)", result.route.transitSeconds === 54 * 60);
    check("Walking time is ~0 (virtual nodes placed exactly at the real stations)", result.route.walkingSeconds === 0);
    check("Legs include the real TRA leg with its real route/mode", result.route.legs.some((l) => l.mode === Mode.TRA && l.routeId === "TRA"));
    check("Zero transfers for a single-leg trip", result.route.transfers === 0);
  }
}

// --- Departing after the only train already left: must fail honestly, not invent a route ---
{
  const graph = buildGraph();
  attachVirtualOrigin(graph, "origin", 25.0478, 121.5171, { maxWalkingMeters: 1200 });
  attachVirtualDestination(graph, "dest", 24.8017, 120.9714, { maxWalkingMeters: 1200 });

  const result = findRoute(graph, "origin", "dest", 8 * 3600 + 10 * 60);   // depart 08:10, train already left at 08:00
  check("NO_ROUTE when the only real trip has already departed (not a fabricated late arrival)", result.error === "NO_ROUTE");
}

// --- Same origin/destination (architecture doc section 18 #6) ---
{
  const graph = buildGraph();
  const result = findRoute(graph, "TRA:1000", "TRA:1000", 7 * 3600);
  check("Same origin and destination is rejected explicitly, not searched", result.error === "SAME_ORIGIN_DESTINATION");
}

console.log(failed ? "\nOVERALL: FAIL" : "\nOVERALL: PASS");
process.exit(failed ? 1 : 0);
