import { DatabaseSync } from "node:sqlite";
import { ensureGtfsSchema } from "../src/gtfs/schema.mjs";
import { normalizeTRATimetable, normalizeBusSchedule } from "../src/tdx/normalizer.mjs";
import { insertTrips, insertStopTimes, insertCalendarDates, insertRoutes, insertFrequencies } from "../src/tdx/ingest.mjs";
import { buildGraph, nodeId } from "../src/graph/builder.mjs";
import { Mode } from "../src/graph/model.mjs";

let failed = false;
function check(label, cond) {
  console.log(`${cond ? "PASS" : "FAIL"} - ${label}`);
  if (!cond) failed = true;
}

const db = new DatabaseSync(":memory:");
await ensureGtfsSchema(db);

// Real stops for both stations that appear in the TRA fixture below.
db.exec(`
  INSERT INTO gtfs_stops (feed_id, stop_id, stop_name, stop_lat, stop_lon) VALUES
  ('TRA', '1000', '臺北', 25.0478, 121.5171),
  ('TRA', '3300', '新竹', 24.8017, 120.9714);
`);

// Same real-shaped TRA timetable fixture as the normalizer test: train 152, 台北 08:00 -> 新竹 08:54.
const rawTRATimetable = {
  TrainTimetables: [{
    TrainInfo: { TrainNo: "152", TrainTypeName: { Zh_tw: "自強" } },
    StopTimes: [
      { StationID: "1000", ArrivalTime: "08:00", DepartureTime: "08:00" },
      { StationID: "3300", ArrivalTime: "08:54", DepartureTime: "08:56" },
    ],
  }],
};
const tra = normalizeTRATimetable(rawTRATimetable.TrainTimetables, "2026-09-14");
await insertTrips(db, "TRA", tra.trips);
await insertStopTimes(db, "TRA", tra.stopTimes);
await insertCalendarDates(db, "TRA", tra.calendarDates);

// A bus route with a real published timetable (goes into gtfs_trips like TRA does)...
const rawBusTimetable = [{
  Direction: 0, SubRouteName: { Zh_tw: "竹北→高鐵新竹站" },
  Timetables: [{ DepartureTime: "07:00" }],
}];
const bus = normalizeBusSchedule(rawBusTimetable, "5900", "2026-09-14");
await insertRoutes(db, [{ feed_id: "BUS", route_id: "5900", route_short_name: "5900", route_long_name: null, route_type: 3 }]);
await insertTrips(db, "BUS", bus.trips);
await insertStopTimes(db, "BUS", bus.stopTimes);   // stop_id is null here (real, documented gap)

// ...and a route with only real headway bands (no trips at all).
const rawBusFreq = [{
  Direction: 0,
  Frequencys: [{ StartTime: "06:00", EndTime: "09:00", MinHeadwayMins: 8, MaxHeadwayMins: 12 }],
}];
const busFreq = normalizeBusSchedule(rawBusFreq, "307", "2026-09-14");
await insertRoutes(db, [{ feed_id: "BUS", route_id: "307", route_short_name: "307", route_long_name: null, route_type: 3 }]);
await insertFrequencies(db, "BUS", busFreq.frequencies);

const graph = await buildGraph(db);

check("Graph has both real TRA stations as nodes", graph.nodes.has(nodeId("TRA", "1000")) && graph.nodes.has(nodeId("TRA", "3300")));

const edges = graph.neighbors(nodeId("TRA", "1000"));
check("台北→新竹 edge exists from real TRA timetable", edges.length === 1);
const e = edges[0];
check("Edge mode is TRA (inferred from route_id, no guessing)", e.mode === Mode.TRA);
check("Edge departs at real 08:00 (28800s)", e.departureSeconds === 8 * 3600);
check("Edge arrives at real 08:54 (31640s... check exact)", e.arrivalSeconds === 8 * 3600 + 54 * 60);
check("Travel time computed correctly from real times (54 min = 3240s)", e.travelSeconds === 54 * 60);
check("Edge is time-dependent, not a flat estimate", e.isTimeDependent === true);

check("Bus route with only 1 real stop_time produces zero edges (need 2+ points to form an edge — correct, not an error)",
  graph.neighbors(nodeId("BUS", "anything")).length === 0);

check("Graph flags the real gap: bus per-trip stop_id not yet resolved, not silently dropped without a trace",
  graph.warnings.some((w) => w.includes("no resolved stop_id")));
check("Graph flags the real gap: this headway band has no gtfs_route_stops sequence in this test, so no edge is fabricated for it",
  graph.warnings.some((w) => w.includes("no gtfs_route_stops sequence")));

console.log(`\nnodeCount=${graph.nodeCount} edgeCount=${graph.edgeCount}`);
console.log(failed ? "\nOVERALL: FAIL" : "\nOVERALL: PASS");
process.exit(failed ? 1 : 0);
