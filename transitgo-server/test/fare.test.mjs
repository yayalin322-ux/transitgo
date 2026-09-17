import { MultimodalGraph, TransitNode, TransitEdge, NodeType, Mode } from "../src/graph/model.mjs";
import { attachVirtualOrigin, attachVirtualDestination } from "../src/graph/virtual.mjs";
import { findRoute } from "../src/routing/astar.mjs";
import { rankRoutes } from "../src/routing/rank.mjs";

let failed = false;
function check(label, cond) {
  console.log(`${cond ? "PASS" : "FAIL"} - ${label}`);
  if (!cond) failed = true;
}

// --- No real fare data on this edge (today's actual state — no insert path anywhere
// ever writes a non-null TransitEdge.fare) — the route must report fare: null, never a
// fabricated 0. ---
{
  const graph = new MultimodalGraph();
  graph.addNode(new TransitNode({ id: "A", type: NodeType.STOP, name: "A", lat: 25.0, lon: 121.5 }));
  graph.addNode(new TransitNode({ id: "B", type: NodeType.STOP, name: "B", lat: 25.01, lon: 121.51 }));
  graph.addEdge(new TransitEdge({
    id: "e1", fromNodeId: "A", toNodeId: "B", mode: Mode.BUS, routeId: "R1",
    departureSeconds: 8 * 3600, arrivalSeconds: 8 * 3600 + 600, travelSeconds: 600,
    source: "TDX real timetable",   // fare intentionally omitted -> null, matching real ingest
  }));
  attachVirtualOrigin(graph, "origin", 25.0, 121.5, { maxWalkingMeters: 1500 });
  attachVirtualDestination(graph, "dest", 25.01, 121.51, { maxWalkingMeters: 1500 });

  const result = findRoute(graph, "origin", "dest", 7 * 3600 + 3000);
  check("Route found", !!result.route);
  check("fare is null when no edge on the route has real fare data (not fabricated 0)", result.route?.fare === null);
}

// --- A real, known fare on every transit edge along the route — the total should be a
// real sum, not null. ---
{
  const graph = new MultimodalGraph();
  graph.addNode(new TransitNode({ id: "A", type: NodeType.STOP, name: "A", lat: 25.0, lon: 121.5 }));
  graph.addNode(new TransitNode({ id: "B", type: NodeType.STOP, name: "B", lat: 25.01, lon: 121.51 }));
  graph.addEdge(new TransitEdge({
    id: "e1", fromNodeId: "A", toNodeId: "B", mode: Mode.BUS, routeId: "R1",
    departureSeconds: 8 * 3600, arrivalSeconds: 8 * 3600 + 600, travelSeconds: 600,
    fare: 30, source: "TDX real timetable",
  }));
  attachVirtualOrigin(graph, "origin", 25.0, 121.5, { maxWalkingMeters: 1500 });
  attachVirtualDestination(graph, "dest", 25.01, 121.51, { maxWalkingMeters: 1500 });

  const result = findRoute(graph, "origin", "dest", 7 * 3600 + 3000);
  check("fare is a real known number (30) when every transit edge has real fare data", result.route?.fare === 30);
}

// --- A route with one priced leg and one unpriced leg — must report null for the whole
// trip (a partial total that silently drops the unknown leg isn't "the price"). ---
{
  const graph = new MultimodalGraph();
  graph.addNode(new TransitNode({ id: "A", type: NodeType.STOP, name: "A", lat: 25.0, lon: 121.5 }));
  graph.addNode(new TransitNode({ id: "B", type: NodeType.STOP, name: "B", lat: 25.01, lon: 121.51 }));
  graph.addNode(new TransitNode({ id: "C", type: NodeType.STOP, name: "C", lat: 25.02, lon: 121.52 }));
  graph.addEdge(new TransitEdge({
    id: "e1", fromNodeId: "A", toNodeId: "B", mode: Mode.BUS, routeId: "R1",
    departureSeconds: 8 * 3600, arrivalSeconds: 8 * 3600 + 300, travelSeconds: 300,
    fare: 15, source: "TDX real timetable",
  }));
  graph.addEdge(new TransitEdge({
    id: "e2", fromNodeId: "B", toNodeId: "C", mode: Mode.BUS, routeId: "R2",
    departureSeconds: 8 * 3600 + 400, arrivalSeconds: 8 * 3600 + 700, travelSeconds: 300,
    source: "TDX real timetable",   // no fare on this leg
  }));
  attachVirtualOrigin(graph, "origin", 25.0, 121.5, { maxWalkingMeters: 1500 });
  attachVirtualDestination(graph, "dest", 25.02, 121.52, { maxWalkingMeters: 1500 });

  const result = findRoute(graph, "origin", "dest", 7 * 3600 + 3000);
  check("fare is null when even one leg's price is unknown, not a partial sum", result.route?.fare === null);
}

// --- rankRoutes must never hand out the LOWEST_COST label when no candidate has real
// fare data — today's actual state, since nothing ingests fare yet. ---
{
  const graph = new MultimodalGraph();
  graph.addNode(new TransitNode({ id: "A", type: NodeType.STOP, name: "A", lat: 25.0, lon: 121.5 }));
  graph.addNode(new TransitNode({ id: "B", type: NodeType.STOP, name: "B", lat: 25.01, lon: 121.51 }));
  graph.addEdge(new TransitEdge({
    id: "e1", fromNodeId: "A", toNodeId: "B", mode: Mode.BUS, routeId: "R1",
    departureSeconds: 8 * 3600, arrivalSeconds: 8 * 3600 + 600, travelSeconds: 600,
    source: "TDX real timetable",
  }));
  attachVirtualOrigin(graph, "origin", 25.0, 121.5, { maxWalkingMeters: 1500 });
  attachVirtualDestination(graph, "dest", 25.01, 121.51, { maxWalkingMeters: 1500 });

  const result = rankRoutes(graph, "origin", "dest", 7 * 3600 + 3000);
  check("Ranking succeeds", !result.error);
  check("No route is labeled 最便宜 when no candidate has real fare data", !(result.routes ?? []).some((r) => r.label === "最便宜"));
}

// --- Once real fare data exists, the genuinely cheaper route gets the LOWEST_COST label.
// Same total ride time as the direct route (600s split 300+300) so this isolates the
// price signal from the time signal — only the fare gap (100 vs 20) and the transfer
// penalty are in play. ---
{
  // A and B are ~4.5km apart — far beyond any walking radius used below, so unlike the
  // earlier blocks in this file (where stops sit meters from origin/destination and a
  // direct walk edge would legitimately win on every metric), a real transit ride is
  // the only way to actually get from origin to destination here.
  const graph = new MultimodalGraph();
  graph.addNode(new TransitNode({ id: "A", type: NodeType.STOP, name: "A", lat: 25.0, lon: 121.5 }));
  graph.addNode(new TransitNode({ id: "B", type: NodeType.STOP, name: "B", lat: 25.03, lon: 121.53 }));
  graph.addNode(new TransitNode({ id: "M", type: NodeType.STOP, name: "M", lat: 25.015, lon: 121.515 }));
  // Direct, expensive.
  graph.addEdge(new TransitEdge({
    id: "direct", fromNodeId: "A", toNodeId: "B", mode: Mode.BUS, routeId: "EXPRESS",
    departureSeconds: 8 * 3600, arrivalSeconds: 8 * 3600 + 600, travelSeconds: 600,
    fare: 100, source: "TDX real timetable",
  }));
  // Via M, cheaper, same total ride time, one extra transfer.
  graph.addEdge(new TransitEdge({
    id: "leg1", fromNodeId: "A", toNodeId: "M", mode: Mode.BUS, routeId: "LOCAL1",
    departureSeconds: 8 * 3600, arrivalSeconds: 8 * 3600 + 300, travelSeconds: 300,
    fare: 10, source: "TDX real timetable",
  }));
  graph.addEdge(new TransitEdge({
    id: "leg2", fromNodeId: "M", toNodeId: "B", mode: Mode.BUS, routeId: "LOCAL2",
    departureSeconds: 8 * 3600 + 300, arrivalSeconds: 8 * 3600 + 600, travelSeconds: 300,
    fare: 10, source: "TDX real timetable",
  }));
  attachVirtualOrigin(graph, "origin", 25.0, 121.5, { maxWalkingMeters: 300 });
  attachVirtualDestination(graph, "dest", 25.03, 121.53, { maxWalkingMeters: 300 });

  const result = rankRoutes(graph, "origin", "dest", 8 * 3600 - 100);
  const cheapest = (result.routes ?? []).find((r) => r.label === "最便宜");
  check("A route is labeled 最便宜 once real fare data exists", !!cheapest);
  check("The 最便宜-labeled route is really the cheaper one (20, not 100)", cheapest?.route.fare === 20);
}

// --- walkingDistanceMeters is a real, summed distance from the actual WALK legs, not a
// duration-only figure — origin/destination are offset from the real stops so there's
// real walking on both ends of the ride. ---
{
  const graph = new MultimodalGraph();
  graph.addNode(new TransitNode({ id: "A", type: NodeType.STOP, name: "A", lat: 25.0, lon: 121.5 }));
  graph.addNode(new TransitNode({ id: "B", type: NodeType.STOP, name: "B", lat: 25.03, lon: 121.53 }));
  graph.addEdge(new TransitEdge({
    id: "e1", fromNodeId: "A", toNodeId: "B", mode: Mode.BUS, routeId: "R1",
    departureSeconds: 8 * 3600, arrivalSeconds: 8 * 3600 + 600, travelSeconds: 600,
    source: "TDX real timetable",
  }));
  // ~150m from A, ~150m from B — real walking on both ends.
  attachVirtualOrigin(graph, "origin", 25.0013, 121.5, { maxWalkingMeters: 300 });
  attachVirtualDestination(graph, "dest", 25.03, 121.5313, { maxWalkingMeters: 300 });

  const result = findRoute(graph, "origin", "dest", 7 * 3600 + 3000);
  check("Route found", !!result.route);
  check("walkingDistanceMeters is a real positive number, not just duration-derived", result.route?.walkingDistanceMeters > 0 && result.route?.walkingDistanceMeters < 400);
}

console.log(failed ? "\nOVERALL: FAIL" : "\nOVERALL: PASS");
if (failed) process.exit(1);
