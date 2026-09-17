// Runs the CURRENT (PR #2) streaming saveGraphToDisk against the same synthetic graph
// shape as bench_persist_old.mjs, in its own fresh process, for a fair peak-RSS
// comparison against the pre-PR#2 single-JSON.stringify version.
import { existsSync, unlinkSync } from "node:fs";
import { buildSyntheticGraph } from "./synthetic_bench.mjs";
import { saveGraphToDisk } from "../src/graph/persist.mjs";
import { logMemory, getPeak, logMemorySummary } from "../src/graph/memlog.mjs";

const graph = buildSyntheticGraph();
logMemory("new_graph_ready", { nodeCount: graph.nodeCount, edgeCount: graph.edgeCount });

const outPath = "/tmp/bench_new_graph_cache.json";
const t0 = Date.now();
await saveGraphToDisk(graph, outPath);
const durationMs = Date.now() - t0;

logMemorySummary({ nodeCount: graph.nodeCount, edgeCount: graph.edgeCount, persistDurationMs: durationMs });
const peak = getPeak();
console.log(`\n[bench_new] persist duration=${durationMs}ms peakRSS=${peak.rssMB}MB peakPhase=${peak.phase}`);

if (existsSync(outPath)) unlinkSync(outPath);
if (existsSync(`${outPath}.tmp`)) unlinkSync(`${outPath}.tmp`);
