import { MultimodalGraph, TransitNode, TransitEdge, NodeType, Mode } from "../src/graph/model.mjs";
import { findRoute } from "../src/routing/astar.mjs";

let failed = false;
function check(label, cond) {
  console.log(`${cond ? "PASS" : "FAIL"} - ${label}`);
  if (!cond) failed = true;
}

const node = (id, lat = 25, lon = 121) => new TransitNode({ id, type: NodeType.STOP, name: id, lat, lon });
const headway = (id, from, to, routeId, extra = {}) => new TransitEdge({
  id, fromNodeId: from, toNodeId: to, mode: Mode.MRT, routeId,
  headwaySeconds: 600, travelSeconds: 60, windowStartSeconds: 0, windowEndSeconds: 86400, source: "test", ...extra,
});
const walk = (id, from, to, seconds) => new TransitEdge({ id, fromNodeId: from, toNodeId: to, mode: Mode.WALK, travelSeconds: seconds, distanceMeters: null, source: "test" });

// --- a 10-hop ride pays its half-headway wait ONCE, on boarding ---
{
  const g = new MultimodalGraph();
  for (let i = 0; i <= 10; i++) g.addNode(node(`S${i}`, 25 + i * 0.001));
  for (let i = 0; i < 10; i++) g.addEdge(headway(`e${i}`, `S${i}`, `S${i + 1}`, "L1"));
  const { route } = findRoute(g, "S0", "S10", 8 * 3600);
  check("10 hops of one ride: waiting is ONE half-headway (300s), not 10 of them", route.waitingSeconds === 300);
  check("10 hops of one ride: riding time is the sum of the hops (600s)", route.transitSeconds === 600);
  check("10 hops of one ride: no transfer counted", route.transfers === 0);
  check("10 hops of one ride: total = wait + ride", route.durationSeconds === 900);
}

// --- two different rides: two boardings, one transfer; a WALK between them does not hide it ---
{
  const g = new MultimodalGraph();
  for (const id of ["A", "B", "C", "D"]) g.addNode(node(id));
  g.addEdge(headway("ab", "A", "B", "L1"));
  g.addEdge(walk("bc", "B", "C", 240));
  g.addEdge(headway("cd", "C", "D", "L2"));
  const { route } = findRoute(g, "A", "D", 8 * 3600);
  check("ride, walk interchange, ride: exactly 1 transfer (the walk in between does not erase it)", route.transfers === 1);
  check("ride, walk interchange, ride: two boardings pay two waits", route.waitingSeconds === 600);
  check("ride, walk interchange, ride: interchange walk time counted as walking", route.walkingSeconds === 240);
}

// --- origin walk then first boarding is NOT a transfer ---
{
  const g = new MultimodalGraph();
  for (const id of ["O", "A", "B"]) g.addNode(node(id));
  g.addEdge(walk("oa", "O", "A", 60));
  g.addEdge(headway("ab", "A", "B", "L1"));
  const { route } = findRoute(g, "O", "B", 8 * 3600);
  check("walk then the first ride: 0 transfers", route.transfers === 0);
}

// --- the on-board state is not pruned by a cheaper on-foot arrival at the same station ---
{
  // Two ways to reach M: on the train (cost 400, already aboard so the next hop is free of
  // a new wait) or on foot (cost 195, cheaper AT M but it must wait again to board the next
  // ride). Overall the aboard path is cheaper (500 vs 595) — a search that pruned by node
  // alone would keep only the 195 arrival and miss it.
  const g = new MultimodalGraph();
  for (const id of ["A", "M", "Z"]) g.addNode(node(id));
  g.addEdge(headway("am", "A", "M", "L1", { travelSeconds: 100 }));
  g.addEdge(walk("am_walk", "A", "M", 195));
  g.addEdge(headway("mz", "M", "Z", "L1", { travelSeconds: 100 }));
  const { route } = findRoute(g, "A", "Z", 8 * 3600);
  const boardings = route.legs.filter((l) => l.mode === Mode.MRT).length;
  check("aboard-vs-on-foot at one station: the truly cheapest full route (stay aboard) is found", route.legs.length === 2 && boardings === 2 && route.durationSeconds === 500);
}

// --- service calendar applies to headway edges too ---
{
  const g = new MultimodalGraph();
  for (const id of ["A", "B"]) g.addNode(node(id));
  g.addEdge(headway("ab", "A", "B", "L1", { serviceKey: "F:平日" }));
  g.serviceCalendar = new Map([["F:平日", { calendarRow: { monday: 1, tuesday: 1, wednesday: 1, thursday: 1, friday: 1, saturday: 0, sunday: 0, start_date: null, end_date: null }, exceptions: new Map() }]]);
  check("weekday-only headway edge is usable on a Monday (20260921)", !!findRoute(g, "A", "B", 8 * 3600, { dateStr: "20260921" }).route);
  check("weekday-only headway edge is NOT usable on a Sunday (20260920)", findRoute(g, "A", "B", 8 * 3600, { dateStr: "20260920" }).error === "NO_ROUTE");
  check("without a query date the calendar is not applied (synthetic graphs)", !!findRoute(g, "A", "B", 8 * 3600).route);
}

// --- waitUnknown: usable, wait reported as null, never 0 ---
{
  const g = new MultimodalGraph();
  for (const id of ["A", "B", "C"]) g.addNode(node(id));
  g.addEdge(new TransitEdge({ id: "ab", fromNodeId: "A", toNodeId: "B", mode: Mode.MRT, routeId: "X", travelSeconds: 120, waitUnknown: true, source: "test" }));
  g.addEdge(new TransitEdge({ id: "bc", fromNodeId: "B", toNodeId: "C", mode: Mode.MRT, routeId: "X", travelSeconds: 120, waitUnknown: true, source: "test" }));
  const { route } = findRoute(g, "A", "C", 8 * 3600);
  check("wait-unknown ride is routed from its real run times", route.transitSeconds === 240);
  check("wait-unknown ride reports waitingSeconds null, not 0", route.waitingSeconds === null);
  check("wait-unknown legs are flagged estimated", route.legs.every((l) => l.isEstimated === true));
}

console.log(failed ? "\nOVERALL: FAIL" : "\nOVERALL: PASS");
process.exit(failed ? 1 : 0);
