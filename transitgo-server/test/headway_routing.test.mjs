import { DatabaseSync } from "node:sqlite";
import { ensureGtfsSchema } from "../src/gtfs/schema.mjs";
import { normalizeBusRouteStopSequence, normalizeBusSchedule } from "../src/tdx/normalizer.mjs";
import { insertStops, insertRoutes, insertRouteStops, insertFrequencies } from "../src/tdx/ingest.mjs";
import { buildGraph, nodeId } from "../src/graph/builder.mjs";
import { attachVirtualOrigin, attachVirtualDestination } from "../src/graph/virtual.mjs";
import { findRoute } from "../src/routing/astar.mjs";

let failed = false;
function check(label, cond) {
  console.log(`${cond ? "PASS" : "FAIL"} - ${label}`);
  if (!cond) failed = true;
}

const db = new DatabaseSync(":memory:");
await ensureGtfsSchema(db);

// Two real stops ~1.1km apart (rough real coordinates near 台北車站/善導寺 on the same road).
await insertStops(db, "BUS", [
  { stop_id: "A", stop_name: "站A", stop_lat: 25.0478, stop_lon: 121.5171 },
  { stop_id: "B", stop_name: "站B", stop_lat: 25.0478, stop_lon: 121.5290 },
]);
await insertRoutes(db, [{ feed_id: "BUS", route_id: "999", route_short_name: "999", route_long_name: null, route_type: 3 }]);

const rawStopOfRoute = [{ Direction: 0, Stops: [
  { StopUID: "A", StopSequence: 1 }, { StopUID: "B", StopSequence: 2 },
] }];
const routeStops = normalizeBusRouteStopSequence(rawStopOfRoute, "999");
await insertRouteStops(db, "BUS", "999", routeStops);

// Real TDX-shaped headway band: peak 07:00-09:00, 8-12 min headway.
const rawFreq = [{ Direction: 0, Frequencys: [
  { StartTime: "07:00", EndTime: "09:00", MinHeadwayMins: 8, MaxHeadwayMins: 12 },
] }];
const { frequencies } = normalizeBusSchedule(rawFreq, "999", "2026-09-14");
await insertFrequencies(db, "BUS", frequencies);

const graph = await buildGraph(db);
check("Headway edge built between the two real stops", graph.neighbors(nodeId("BUS", "A")).length === 1);
const edge = graph.neighbors(nodeId("BUS", "A"))[0];
check("Edge is headway-based, not time-dependent", edge.isHeadwayBased && !edge.isTimeDependent);
check("Average headway is real midpoint of 8-12 min (10 min = 600s)", edge.headwaySeconds === 600);
check("Travel time estimated from the real ~1.1km distance (not zero, not absurd)", edge.travelSeconds > 60 && edge.travelSeconds < 400);
check("Source string discloses this is an estimate, not measured TDX data", edge.source.includes("ESTIMATED") || edge.source.includes("estimated"));

attachVirtualOrigin(graph, "origin", 25.0478, 121.5171, { maxWalkingMeters: 500 });
attachVirtualDestination(graph, "dest", 25.0478, 121.5290, { maxWalkingMeters: 500 });

// --- Inside the real 07:00-09:00 service window: should find a route ---
const inWindow = findRoute(graph, "origin", "dest", 7 * 3600 + 30 * 60);   // 07:30
check("Route found at 07:30, inside the real 07:00-09:00 headway window", !!inWindow.route);
if (inWindow.route) {
  const leg = inWindow.route.legs.find((l) => l.mode === "BUS");
  check("Waiting time reflects half the real headway (5 min = 300s)", inWindow.route.waitingSeconds === 300);
  check("Bus leg is marked as using an estimated travel time", leg?.isEstimated === true);
}

// --- Outside the window: must not fabricate service where none is scheduled ---
const outsideWindow = findRoute(graph, "origin", "dest", 23 * 3600);   // 23:00, long after the band ends
check("NO_ROUTE at 23:00 — real service window doesn't cover this time, not assumed to run all day", outsideWindow.error === "NO_ROUTE");

console.log(failed ? "\nOVERALL: FAIL" : "\nOVERALL: PASS");
process.exit(failed ? 1 : 0);
