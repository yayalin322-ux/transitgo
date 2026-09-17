import { MultimodalGraph, TransitNode, NodeType } from "../src/graph/model.mjs";
import { attachVirtualOrigin, attachVirtualDestination, findNearbyStops, haversineMeters } from "../src/graph/virtual.mjs";
import { SpatialIndex } from "../src/graph/spatialIndex.mjs";

let failed = false;
function check(label, cond) {
  console.log(`${cond ? "PASS" : "FAIL"} - ${label}`);
  if (!cond) failed = true;
}

// Real coordinates: 台北車站 and 新竹車站 (same as the graph builder test), ~80km apart —
// far beyond any walking radius from each other, good for proving radius filtering works.
const graph = new MultimodalGraph();
graph.addNode(new TransitNode({ id: "TRA:1000", type: NodeType.STOP, name: "臺北", lat: 25.0478, lon: 121.5171 }));
graph.addNode(new TransitNode({ id: "TRA:3300", type: NodeType.STOP, name: "新竹", lat: 24.8017, lon: 120.9714 }));
// A stop ~300m from 臺北 (rough offset), to test the 500m tier finds it directly.
graph.addNode(new TransitNode({ id: "BUS:near1", type: NodeType.STOP, name: "近站1", lat: 25.0478 + 0.0027, lon: 121.5171 }));

// --- findNearbyStops ---
const near = findNearbyStops(graph, 25.0478, 121.5171, { radii: [500, 800, 1200] });
check("Finds both 台北 itself and the ~300m stop within 500m, not 新竹", near.some((n) => n.node.id === "TRA:1000") && near.some((n) => n.node.id === "BUS:near1") && !near.some((n) => n.node.id === "TRA:3300"));
check("Results sorted nearest-first", near[0].distanceMeters <= near[near.length - 1].distanceMeters);

const farOnly = findNearbyStops(graph, 22.6273, 120.3014, { radii: [500, 800, 1200] }); // 高雄 — nothing in this tiny graph nearby
check("No nearby stops within max radius returns empty, not a crash or a fabricated match", farOnly.length === 0);

// A maxRadius below the smallest preset step used to make the very first preset fail
// `radius > maxRadius` and break out before trying anything — returning [] even for a
// stop at 0 meters. maxRadius itself must always be a real, tried step.
const tightRadius = findNearbyStops(graph, 25.0478, 121.5171, { radii: [500, 800, 1200], maxRadius: 200 });
check("A maxRadius smaller than every preset step still finds a stop at 0m (regression)", tightRadius.some((n) => n.node.id === "TRA:1000"));

// --- attachVirtualOrigin ---
const originId = attachVirtualOrigin(graph, "virtual_origin_1", 25.0478, 121.5171, { maxWalkingMeters: 1200 });
check("Virtual origin attached (real nearby stops exist)", originId === "virtual_origin_1");
check("Virtual origin node has type VIRTUAL", graph.nodes.get("virtual_origin_1")?.type === NodeType.VIRTUAL);
const originEdges = graph.neighbors("virtual_origin_1");
check("Virtual origin has WALK edges to nearby real stops (not to 新竹, too far)", originEdges.every((e) => e.mode === "WALK") && originEdges.some((e) => e.toNodeId === "TRA:1000") && !originEdges.some((e) => e.toNodeId === "TRA:3300"));

const walkToSelf = originEdges.find((e) => e.toNodeId === "TRA:1000");
const expectedSeconds = Math.round(haversineMeters(25.0478, 121.5171, 25.0478, 121.5171) / 1.3);
check("Walk time computed from real distance/speed, not a flat guess (0m away here -> 0s)", walkToSelf?.travelSeconds === expectedSeconds && expectedSeconds === 0);

// --- attachVirtualDestination ---
const destId = attachVirtualDestination(graph, "virtual_dest_1", 24.8017, 120.9714, { maxWalkingMeters: 1200 });
check("Virtual destination attached near 新竹", destId === "virtual_dest_1");
const intoDest = [...graph.edgesByFrom.get("TRA:3300") ?? []].filter((e) => e.toNodeId === "virtual_dest_1");
check("新竹 has a real WALK edge INTO the virtual destination (reversed direction from origin)", intoDest.length === 1);

// --- no nearby transit at all (architecture doc section 18 #1) ---
const noneId = attachVirtualOrigin(graph, "virtual_origin_nowhere", 22.6273, 120.3014, { maxWalkingMeters: 1200 });
check("Origin with genuinely nothing nearby returns null (caller must surface NO_NEARBY_STOP, not silently continue)", noneId === null);
check("No node was added for the failed attach", !graph.nodes.has("virtual_origin_nowhere"));

// --- SpatialIndex must agree with a plain linear scan at every radius, on real
// coordinates — this is the structure findNearbyStops() is actually backed by now that
// the graph is national scale (~76k nodes after the multi-city + TRA/THSR ingest); a
// grid-bucket bug here would silently make routing miss real nearby stops. ---
{
  const bigGraph = new MultimodalGraph();
  bigGraph.addNode(new TransitNode({ id: "TRA:1000", type: NodeType.STOP, name: "臺北", lat: 25.0478, lon: 121.5171 }));
  bigGraph.addNode(new TransitNode({ id: "BUS:near1", type: NodeType.STOP, name: "近站1", lat: 25.0478 + 0.0027, lon: 121.5171 }));
  bigGraph.addNode(new TransitNode({ id: "TRA:3300", type: NodeType.STOP, name: "新竹", lat: 24.8017, lon: 120.9714 }));
  bigGraph.addNode(new TransitNode({ id: "VIRT:1", type: NodeType.VIRTUAL, lat: 25.0478, lon: 121.5171 }));

  const index = new SpatialIndex(bigGraph.nodes.values());
  for (const radius of [100, 500, 1200, 5000, 100_000]) {
    const indexed = new Set(index.near(25.0478, 121.5171, radius, haversineMeters).map((h) => h.node.id));
    const linear = new Set();
    for (const node of bigGraph.nodes.values()) {
      if (node.type === NodeType.VIRTUAL || node.lat == null) continue;
      if (haversineMeters(25.0478, 121.5171, node.lat, node.lon) <= radius) linear.add(node.id);
    }
    const same = indexed.size === linear.size && [...indexed].every((id) => linear.has(id));
    check(`SpatialIndex matches a linear scan at radius=${radius}m`, same);
  }
  check("SpatialIndex never returns a VIRTUAL node", !index.near(25.0478, 121.5171, 100_000, haversineMeters).some((h) => h.node.id === "VIRT:1"));
}

console.log(failed ? "\nOVERALL: FAIL" : "\nOVERALL: PASS");
process.exit(failed ? 1 : 0);
