import { MultimodalGraph, TransitNode, TransitEdge, NodeType, Mode } from "../src/graph/model.mjs";
import { rankRoutes } from "../src/routing/rank.mjs";

let failed = false;
function check(label, cond) {
  console.log(`${cond ? "PASS" : "FAIL"} - ${label}`);
  if (!cond) failed = true;
}

// A direct headway route (0 transfers) that's real-time SLOWER, and a 2-leg route
// (1 transfer) that's real-time FASTER — set up so FASTEST and FEWEST_TRANSFERS must
// genuinely disagree about which one is "better", proving the profile weights actually
// change the outcome rather than always returning the same search result.
function buildGraph() {
  const graph = new MultimodalGraph();
  for (const id of ["A", "B", "D"]) {
    graph.addNode(new TransitNode({ id, type: NodeType.STOP, lat: 25, lon: 121 }));
  }
  // Direct: wait 450s (900 headway / 2) + ride 1550s = 2000s real, 0 transfers.
  graph.addEdge(new TransitEdge({
    id: "direct", fromNodeId: "A", toNodeId: "D", mode: Mode.BUS, routeId: "DIRECT",
    headwaySeconds: 900, travelSeconds: 1550, windowStartSeconds: 0, windowEndSeconds: 86400,
    source: "test",
  }));
  // Via B: (wait 300 + ride 600) + (wait 300 + ride 500) = 1700s real, 1 transfer.
  graph.addEdge(new TransitEdge({
    id: "leg1", fromNodeId: "A", toNodeId: "B", mode: Mode.BUS, routeId: "L1",
    headwaySeconds: 600, travelSeconds: 600, windowStartSeconds: 0, windowEndSeconds: 86400,
    source: "test",
  }));
  graph.addEdge(new TransitEdge({
    id: "leg2", fromNodeId: "B", toNodeId: "D", mode: Mode.BUS, routeId: "L2",
    headwaySeconds: 600, travelSeconds: 500, windowStartSeconds: 0, windowEndSeconds: 86400,
    source: "test",
  }));
  return graph;
}

const result = rankRoutes(buildGraph(), "A", "D", 8 * 3600, { maxResults: 5 });
check("Ranking returns candidate routes", Array.isArray(result.routes) && result.routes.length >= 2);

if (result.routes) {
  const fastestEntry = result.routes.find((r) => r.label === "最快");
  const fewestEntry = result.routes.find((r) => r.label === "少轉乘");

  check("最快 (FASTEST) picks the real-time-faster 2-leg route (1700s), not the slower direct one",
    fastestEntry?.route.durationSeconds === 1700 && fastestEntry?.route.transfers === 1);
  check("少轉乘 (FEWEST_TRANSFERS) picks the direct 0-transfer route despite it being slower (2000s)",
    fewestEntry?.route.transfers === 0 && fewestEntry?.route.durationSeconds === 2000);
  check("The two labeled routes are genuinely different routes, not the same one twice",
    fastestEntry && fewestEntry && fastestEntry.route.legs.length !== fewestEntry.route.legs.length);

  // Every returned route must be a real, non-dominated candidate — no route worse than
  // another on every metric should survive (architecture doc section 10).
  const allNonDominated = result.routes.every((r1) =>
    !result.routes.some((r2) =>
      r2 !== r1
      && r2.route.durationSeconds <= r1.route.durationSeconds
      && r2.route.transfers <= r1.route.transfers
      && r2.route.walkingSeconds <= r1.route.walkingSeconds
      && (r2.route.durationSeconds < r1.route.durationSeconds || r2.route.transfers < r1.route.transfers || r2.route.walkingSeconds < r1.route.walkingSeconds)
    )
  );
  check("No dominated route survives in the final list", allNonDominated);
}

// --- Same origin/destination still rejected outright, same as findRoute alone ---
const same = rankRoutes(buildGraph(), "A", "A", 8 * 3600);
check("rankRoutes propagates SAME_ORIGIN_DESTINATION instead of returning empty/fake results", same.error === "SAME_ORIGIN_DESTINATION");

console.log(failed ? "\nOVERALL: FAIL" : "\nOVERALL: PASS");
process.exit(failed ? 1 : 0);
