import { DatabaseSync } from "node:sqlite";
import { unlinkSync, existsSync } from "node:fs";
import { ensureGtfsSchema } from "../src/gtfs/schema.mjs";
import { insertTrips, insertStopTimes, insertRoutes, insertStops } from "../src/tdx/ingest.mjs";
import { buildGraph, nodeId } from "../src/graph/builder.mjs";
import { saveGraphToDisk, loadGraphFromDisk } from "../src/graph/persist.mjs";
import { normalizeTRATimetable } from "../src/tdx/normalizer.mjs";

let failed = false;
function check(label, cond) {
  console.log(`${cond ? "PASS" : "FAIL"} - ${label}`);
  if (!cond) failed = true;
}

const db = new DatabaseSync(":memory:");
await ensureGtfsSchema(db);

await insertStops(db, "TRA", [
  { stop_id: "1000", stop_name: "臺北", stop_lat: 25.0478, stop_lon: 121.5171 },
  { stop_id: "3300", stop_name: "新竹", stop_lat: 24.8017, stop_lon: 120.9714 },
]);
const raw = {
  TrainTimetables: [{
    TrainInfo: { TrainNo: "152", TrainTypeName: { Zh_tw: "自強" } },
    StopTimes: [
      { StationID: "1000", ArrivalTime: "08:00", DepartureTime: "08:00" },
      { StationID: "3300", ArrivalTime: "08:54", DepartureTime: "08:56" },
    ],
  }],
};
const tra = normalizeTRATimetable(raw.TrainTimetables, "2026-09-14");
await insertTrips(db, "TRA", tra.trips);
await insertStopTimes(db, "TRA", tra.stopTimes);

const original = await buildGraph(db);
check("Real graph built with 2 nodes", original.nodeCount === 2);
check("Real graph built with 1 edge", original.edgeCount === 1);

const cachePath = "/tmp/transitgo_graph_persist_test.json";
if (existsSync(cachePath)) unlinkSync(cachePath);

saveGraphToDisk(original, cachePath);
check("Cache file exists after save", existsSync(cachePath));

const loaded = loadGraphFromDisk(cachePath);
check("Loaded graph is not null", loaded !== null);
check("Loaded graph has the same node count", loaded.nodeCount === original.nodeCount);
check("Loaded graph has the same edge count", loaded.edgeCount === original.edgeCount);
check("Loaded node keeps its real name", loaded.nodes.get(nodeId("TRA", "1000"))?.name === "臺北");
check("Loaded node keeps its real coordinates", loaded.nodes.get(nodeId("TRA", "3300"))?.lat === 24.8017);

const loadedEdge = loaded.neighbors(nodeId("TRA", "1000"))[0];
check("Loaded edge keeps its real departure time (28800s = 08:00)", loadedEdge?.departureSeconds === 8 * 3600);
check("Loaded edge keeps its real arrival time (08:54)", loadedEdge?.arrivalSeconds === 8 * 3600 + 54 * 60);
check("Loaded edge is still recognized as time-dependent (getter survives reconstruction)", loadedEdge?.isTimeDependent === true);
check("Loaded graph's serviceCalendar is a real Map, not a plain object", loaded.serviceCalendar instanceof Map);

check("Missing cache file returns null, not a throw", loadGraphFromDisk("/tmp/transitgo_graph_persist_does_not_exist.json") === null);

unlinkSync(cachePath);

console.log(failed ? "\nOVERALL: FAIL" : "\nOVERALL: PASS");
if (failed) process.exit(1);
