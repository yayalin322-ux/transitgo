// Nearest bus stops from the graph: grouping across feeds, InterCity scope, exclusion of rail/metro/bike,
// and the "graph has no bus data here" signal. Real 竹北 coordinates; stop names/ids are hand-built.
import { MultimodalGraph, TransitNode, NodeType, Mode } from "../src/graph/model.mjs";
import { findNearbyBusStops, BUS_FEED_SCOPE, normalizedStopName } from "../src/graph/busStops.mjs";

let failed = false;
function check(label, cond) { console.log(`${cond ? "PASS" : "FAIL"} - ${label}`); if (!cond) failed = true; }

const HERE = [24.8393, 121.0093];   // 竹北
const stop = (id, name, lat, lon, mode = null) => new TransitNode({ id, type: NodeType.STOP, mode, name, lat, lon });
function graph() {
  const g = new MultimodalGraph();
  // the same pole under the city feed and the InterCity feed, one "站" variant
  g.addNode(stop("HSQ:HSQ001", "竹北火車站", 24.8400, 121.0095));
  g.addNode(stop("THB:THB900", "竹北火車站", 24.8401, 121.0096));
  g.addNode(stop("HSQ:HSQ002", "天后宮站", 24.8420, 121.0110));
  g.addNode(stop("THB:THB901", "天后宮", 24.8421, 121.0111));
  g.addNode(stop("THB:THB902", "飛利浦", 24.8410, 121.0050));         // InterCity only
  g.addNode(stop("TRA:1030", "竹北", 24.8395, 121.0092));             // rail — must never appear as a bus stop
  g.addNode(stop("MRT_TRTC:R10", "台北車站", 24.8394, 121.0094));     // metro — same
  g.addNode(stop("BIKE_HsinchuCounty:500", "臺鐵竹北車站", 24.8396, 121.0093, Mode.BIKE));
  g.addNode(stop("HSQ:HSQ999", "很遠的站", 24.9500, 121.1500));
  return g;
}

const r = findNearbyBusStops(graph(), HERE[0], HERE[1], { radiusMeters: 500 });
const names = r.stops.map((s) => s.name);
check("covered", r.covered === true);
check("rail, metro and bike nodes are not bus stops", !names.includes("竹北") && !names.includes("台北車站") && !names.includes("臺鐵竹北車站"));
check("far stop excluded from the radius", !names.includes("很遠的站"));
const station = r.stops.find((s) => s.name === "竹北火車站");
check("same-name city + InterCity stop is ONE physical stop", station && station.stops.length === 2);
check("…carrying both scopes and their UIDs", station && station.stops.some((s) => s.scope === "City/HsinchuCounty" && s.stopUID === "HSQ001") && station.stops.some((s) => s.scope === "InterCity" && s.stopUID === "THB900"));
const temple = r.stops.find((s) => s.name.startsWith("天后宮"));
check("'站' suffix variant merges (天后宮站 / 天后宮)", temple && temple.stops.length === 2 && r.stops.filter((s) => s.name.startsWith("天后宮")).length === 1);
const philips = r.stops.find((s) => s.name === "飛利浦");
check("InterCity-only stop is kept, InterCity scope only", philips && philips.stops.length === 1 && philips.stops[0].scope === "InterCity");
check("nearest first", r.stops.every((s, i) => i === 0 || r.stops[i - 1].distanceMeters <= s.distanceMeters));
check("limit respected", findNearbyBusStops(graph(), HERE[0], HERE[1], { radiusMeters: 500, limit: 1 }).stops.length === 1);

const far = findNearbyBusStops(graph(), 23.0, 120.2, { radiusMeters: 500 });   // 台南: nothing in this graph
check("no bus data here → covered:false and no stops (not 'no stops nearby')", far.covered === false && far.stops.length === 0);
const gapOnly = findNearbyBusStops(graph(), 24.8393, 121.0400, { radiusMeters: 200 });   // ~3 km east of the stops, inside coverage radius
check("inside coverage but nothing within the radius → covered:true, empty", gapOnly.covered === true && gapOnly.stops.length === 0);
check("scope map: InterCity feed → InterCity; HSQ → HsinchuCounty", BUS_FEED_SCOPE.THB === "InterCity" && BUS_FEED_SCOPE.HSQ === "City/HsinchuCounty");
check("no rail/metro feed in the bus scope map", !("TRA" in BUS_FEED_SCOPE) && !("THSR" in BUS_FEED_SCOPE) && !("MRT_TRTC" in BUS_FEED_SCOPE));
check("normalizedStopName keeps 2-char names whole, strips a trailing 站 otherwise", normalizedStopName("竹站") === "竹站" && normalizedStopName("天后宮站") === "天后宮");
process.exit(failed ? 1 : 0);
