import { DatabaseSync } from "node:sqlite";
import { ensureGtfsSchema } from "../src/gtfs/schema.mjs";
import { normalizeMetroStations, normalizeMetroStationSequence } from "../src/tdx/normalizer.mjs";
import { insertStops, insertRoutes, insertRouteStops } from "../src/tdx/ingest.mjs";
import { buildGraph, nodeId } from "../src/graph/builder.mjs";
import { Mode } from "../src/graph/model.mjs";

let failed = false;
function check(label, cond) {
  console.log(`${cond ? "PASS" : "FAIL"} - ${label}`);
  if (!cond) failed = true;
}

// Fixture shaped like the real TDX v2/Rail/Metro/Station and /StationOfLine responses
// (verified field names from the app's own MetroModels.swift: StationID/StationName/
// StationPosition, and Sequence/StationID/Stations under LineID).
const rawStations = [
  { StationID: "BL12", StationName: { Zh_tw: "台北車站" }, StationPosition: { PositionLat: 25.0478, PositionLon: 121.5171 } },
  { StationID: "BL11", StationName: { Zh_tw: "西門" }, StationPosition: { PositionLat: 25.0421, PositionLon: 121.5083 } },
];
const rawStationOfLine = [
  { LineID: "BL", Stations: [
    { Sequence: 1, StationID: "BL11", StationName: { Zh_tw: "西門" } },
    { Sequence: 2, StationID: "BL12", StationName: { Zh_tw: "台北車站" } },
  ] },
];

const db = new DatabaseSync(":memory:");
await ensureGtfsSchema(db);

const stops = normalizeMetroStations(rawStations);
check("Real metro stations normalized with real lat/lon", stops.length === 2 && stops.find((s) => s.stop_id === "BL12")?.stop_lat === 25.0478);
await insertStops(db, "MRT", stops);

const forward = normalizeMetroStationSequence(rawStationOfLine, "BL");
check("Real station sequence extracted in TDX's own order", forward.length === 2 && forward[0].stop_id === "BL11" && forward[0].stop_sequence === 1);

const backward = forward.map((r, i, arr) => ({ ...r, direction: 1, stop_sequence: arr.length - i })).reverse();
await insertRoutes(db, [{ feed_id: "MRT", route_id: "BL", route_short_name: "板南線", route_long_name: null, route_type: 1 }]);
await insertRouteStops(db, "MRT", "BL", [...forward, ...backward]);

const stored = db.prepare("SELECT * FROM gtfs_route_stops WHERE feed_id='MRT' AND route_id='BL' ORDER BY direction, stop_sequence").all();
check("Both directions persisted (4 rows: 2 stations x 2 directions)", stored.length === 4);
check("Direction 1 is the real reverse order of direction 0", stored[2].stop_id === "BL12" && stored[3].stop_id === "BL11");

const graph = await buildGraph(db);
check("Graph has real MRT stations as nodes", graph.nodes.has(nodeId("MRT", "BL11")) && graph.nodes.has(nodeId("MRT", "BL12")));
check("No edges yet — no schedule/headway data ingested for metro, correctly not fabricated", graph.edgeCount === 0);

console.log(failed ? "\nOVERALL: FAIL" : "\nOVERALL: PASS");
process.exit(failed ? 1 : 0);
