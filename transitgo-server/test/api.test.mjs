import { MultimodalGraph, TransitNode, TransitEdge, NodeType, Mode } from "../src/graph/model.mjs";
import { planRoute } from "../src/routing/api.mjs";

let failed = false;
function check(label, cond) {
  console.log(`${cond ? "PASS" : "FAIL"} - ${label}`);
  if (!cond) failed = true;
}

// Real Taipei coordinates: 台北車站 area (stop A) to 台北101 area (stop D), same idea as
// the architecture doc's own worked example, connected by one always-on headway route.
function buildGraph() {
  const graph = new MultimodalGraph();
  graph.addNode(new TransitNode({ id: "BUS:A", type: NodeType.STOP, name: "站A", lat: 25.0478, lon: 121.5171 }));
  graph.addNode(new TransitNode({ id: "BUS:D", type: NodeType.STOP, name: "站D", lat: 25.0339, lon: 121.5645 }));
  graph.addEdge(new TransitEdge({
    id: "AtoD", fromNodeId: "BUS:A", toNodeId: "BUS:D", mode: Mode.BUS, routeId: "20",
    headwaySeconds: 600, travelSeconds: 900, windowStartSeconds: 0, windowEndSeconds: 86400,
    source: "test",
  }));
  return graph;
}

// --- Happy path: real GPS points near both stops, ranked routes back ---
{
  const graph = buildGraph();
  const before = { nodes: graph.nodeCount, edges: graph.edgeCount };
  const res = planRoute(graph, {
    origin: { lat: 25.0478, lng: 121.5171 },
    destination: { lat: 25.0339, lng: 121.5645 },
    departureTime: "2026-09-13T10:00:00+08:00",
  });
  check("200 with real routes for a real reachable OD pair", res.status === 200 && res.body.routes.length > 0);
  check("Response has a requestId", typeof res.body.requestId === "string" && res.body.requestId.length > 0);
  const r = res.body.routes[0];
  check("Route has real ISO departure/arrival times, not raw seconds", typeof r.departureTime === "string" && r.departureTime.includes("2026-09-13"));
  const busLeg = r.legs.find((l) => l.mode === "BUS");
  check("Leg carries mode/routeId/times", busLeg?.routeId === "20" && typeof busLeg?.departureTime === "string");
  check("Virtual origin/destination nodes cleaned up after the request — graph doesn't grow", graph.nodeCount === before.nodes && graph.edgeCount === before.edges);
}

// --- Same origin and destination (architecture doc section 18 #6) ---
{
  const res = planRoute(buildGraph(), {
    origin: { lat: 25.0478, lng: 121.5171 },
    destination: { lat: 25.0478, lng: 121.5171 },
  });
  check("SAME_ORIGIN_DESTINATION when origin==destination coordinate", res.status === 404 && res.body.error.code === "SAME_ORIGIN_DESTINATION");
}

// --- No nearby stop (architecture doc section 18 #1/#2) ---
{
  const res = planRoute(buildGraph(), {
    origin: { lat: 24.1, lng: 120.6 },   // 台中, nothing in this tiny test graph
    destination: { lat: 25.0339, lng: 121.5645 },
  });
  check("NO_ORIGIN_NEARBY when genuinely nothing is near the origin", res.status === 404 && res.body.error.code === "NO_ORIGIN_NEARBY");
}

// --- Malformed request ---
{
  const res = planRoute(buildGraph(), { origin: { lat: 25 } });
  check("400 INVALID_REQUEST for a malformed body (missing destination)", res.status === 400 && res.body.error.code === "INVALID_REQUEST");
}

// --- Specific profile requested — needs a graph with genuinely divergent routes
// (same fixture idea as route_ranking.test.mjs) to actually distinguish "少轉乘" ---
{
  function buildDivergentGraph() {
    const graph = new MultimodalGraph();
    for (const [id, lat, lon] of [["BUS:A", 25.0478, 121.5171], ["BUS:B", 25.04, 121.53], ["BUS:D", 25.0339, 121.5645]]) {
      graph.addNode(new TransitNode({ id, type: NodeType.STOP, lat, lon }));
    }
    graph.addEdge(new TransitEdge({ id: "direct", fromNodeId: "BUS:A", toNodeId: "BUS:D", mode: Mode.BUS, routeId: "DIRECT", headwaySeconds: 900, travelSeconds: 1550, windowStartSeconds: 0, windowEndSeconds: 86400, source: "test" }));
    graph.addEdge(new TransitEdge({ id: "leg1", fromNodeId: "BUS:A", toNodeId: "BUS:B", mode: Mode.BUS, routeId: "L1", headwaySeconds: 600, travelSeconds: 600, windowStartSeconds: 0, windowEndSeconds: 86400, source: "test" }));
    graph.addEdge(new TransitEdge({ id: "leg2", fromNodeId: "BUS:B", toNodeId: "BUS:D", mode: Mode.BUS, routeId: "L2", headwaySeconds: 600, travelSeconds: 500, windowStartSeconds: 0, windowEndSeconds: 86400, source: "test" }));
    return graph;
  }
  const res = planRoute(buildDivergentGraph(), {
    origin: { lat: 25.0478, lng: 121.5171 },
    destination: { lat: 25.0339, lng: 121.5645 },
    profile: "FEWEST_TRANSFERS",
  });
  check("Requesting a specific profile narrows to exactly one labeled route", res.status === 200 && res.body.routes.length === 1 && res.body.routes[0].label === "少轉乘");
  check("The FEWEST_TRANSFERS route really has fewer transfers than the alternative", res.status === 200 && res.body.routes[0].transfers === 0);
}

// --- Architecture doc Test 10: origin/destination 300m apart should favor walking,
// not force a transit detour that doesn't make sense at that range ---
{
  function buildRoundaboutGraph() {
    const graph = new MultimodalGraph();
    graph.addNode(new TransitNode({ id: "BUS:A", type: NodeType.STOP, lat: 25.0478, lon: 121.5171 }));
    graph.addNode(new TransitNode({ id: "BUS:D", type: NodeType.STOP, lat: 25.0490, lon: 121.5175 }));   // ~300m away
    // A transit "option" exists but is deliberately slow/roundabout — real 300m walk
    // (≈231s at 1.3 m/s) should still win on cost.
    graph.addEdge(new TransitEdge({
      id: "roundabout", fromNodeId: "BUS:A", toNodeId: "BUS:D", mode: Mode.BUS, routeId: "99",
      headwaySeconds: 1200, travelSeconds: 900, windowStartSeconds: 0, windowEndSeconds: 86400,
      source: "test",
    }));
    return graph;
  }
  const res = planRoute(buildRoundaboutGraph(), {
    origin: { lat: 25.0478, lng: 121.5171 },
    destination: { lat: 25.0490, lng: 121.5175 },
  });
  check("300m apart returns real routes (not an error)", res.status === 200 && res.body.routes.length > 0);
  if (res.status === 200) {
    const fastest = res.body.routes.find((r) => r.label === "最快") ?? res.body.routes[0];
    check("The fastest option is a direct walk (no BUS leg), not a slow transit detour",
      !fastest.legs.some((l) => l.mode === "BUS"));
  }
}

console.log(failed ? "\nOVERALL: FAIL" : "\nOVERALL: PASS");
process.exit(failed ? 1 : 0);
