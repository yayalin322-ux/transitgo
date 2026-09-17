// Synthetic 75k-node / 310k-edge benchmark — NOT real transit data, never written to
// Supabase or any test the CI runs. Builds a graph with the same object shapes
// production buildGraph() produces (TransitNode/TransitEdge via model.mjs, real
// MultimodalGraph adjacency, a real SpatialIndex over the nodes) purely to answer: what
// does this DATA STRUCTURE cost in RAM at the target scale, independent of today's real
// (much smaller) ingested data volume. Run manually, not part of `npm test`.
import { MultimodalGraph, TransitNode, TransitEdge, NodeType, Mode } from "../src/graph/model.mjs";
import { SpatialIndex } from "../src/graph/spatialIndex.mjs";
import { logMemory, resetMemoryTracking, logMemorySummary, getPeak } from "../src/graph/memlog.mjs";

const TARGET_NODES = 75000;
const TARGET_EDGES = 310000;
const MODES = [Mode.BUS, Mode.MRT, Mode.TRA, Mode.HSR, Mode.FERRY];
const ROUTE_IDS = Array.from({ length: 1500 }, (_, i) => `R${i}`); // ~1500 real routes today across ingested feeds
const FEEDS = ["HSZ", "HSQ", "TYC", "TPE", "NTC", "THB", "TRA", "THSR"];

export function buildSyntheticGraph() {
  const graph = new MultimodalGraph();
  graph.builtAt = new Date().toISOString();
  graph.warnings = [];
  graph.serviceCalendar = new Map();

  resetMemoryTracking();
  logMemory("synthetic_start");

  for (let i = 0; i < TARGET_NODES; i++) {
    const feed = FEEDS[i % FEEDS.length];
    graph.addNode(new TransitNode({
      id: `${feed}:S${i}`,
      type: NodeType.STOP,
      mode: null,
      name: `合成站牌${i}`,
      lat: 22.0 + Math.random() * 3.5,   // ~Taiwan's real latitude span
      lon: 120.0 + Math.random() * 2.0,
      parentStationId: null,
    }));
    if (i % 15000 === 0) logMemory("synthetic_nodes_progress", { nodesBuilt: i });
  }
  logMemory("synthetic_after_nodes", { nodeCount: graph.nodeCount });

  const nodeIds = [...graph.nodes.keys()];
  for (let i = 0; i < TARGET_EDGES; i++) {
    const a = nodeIds[(i * 7) % nodeIds.length];
    const b = nodeIds[(i * 13 + 1) % nodeIds.length];
    const mode = MODES[i % MODES.length];
    const routeId = ROUTE_IDS[i % ROUTE_IDS.length];
    const isHeadway = i % 2 === 0;
    graph.addEdge(new TransitEdge({
      id: `E${i}`,
      fromNodeId: a,
      toNodeId: b,
      mode,
      routeId,
      departureSeconds: isHeadway ? null : (i * 37) % 86400,
      arrivalSeconds: isHeadway ? null : ((i * 37) % 86400) + 600,
      headwaySeconds: isHeadway ? 600 : null,
      windowStartSeconds: isHeadway ? 0 : null,
      windowEndSeconds: isHeadway ? 86400 : null,
      travelSeconds: 600,
      distanceMeters: 1200,
      fare: null,
      source: isHeadway
        ? "TDX real headway; travel time estimated from real distance at 15 km/h"
        : "TDX real timetable",
      serviceKey: isHeadway ? null : `${routeId}:svc1`,
    }));
    if (i % 60000 === 0) logMemory("synthetic_edges_progress", { edgesBuilt: i });
  }
  logMemory("synthetic_after_edges", { nodeCount: graph.nodeCount, edgeCount: graph.edgeCount });

  return graph;
}

// Only runs the standalone benchmark (node/edge build + spatial index, no persist) when
// this file is executed directly — bench_persist_old.mjs / bench_persist_new.mjs import
// buildSyntheticGraph() instead, so each gets its own clean process for persistence
// comparison.
if (process.argv[1]?.endsWith("synthetic_bench.mjs")) {
  const graph = buildSyntheticGraph();

  logMemory("before_spatial_index_bench", { nodeCount: graph.nodeCount });
  const index = new SpatialIndex(graph.nodes.values());
  graph._spatialStopIndex = index;
  logMemory("after_spatial_index_bench", { nodeCount: graph.nodeCount });

  console.log(`\n[synthetic] built ${graph.nodeCount} nodes / ${graph.edgeCount} edges`);
  logMemorySummary({ nodeCount: graph.nodeCount, edgeCount: graph.edgeCount });

  const finalPeak = getPeak();
  console.log(`\n[synthetic] FINAL PEAK: rssMB=${finalPeak.rssMB} phase=${finalPeak.phase} feed=${finalPeak.feed || ""}`);
}
