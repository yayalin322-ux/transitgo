// Reproduces PR #2's PARENT commit's saveGraphToDisk (a single JSON.stringify(payload)
// call over the whole graph) inline — not by modifying src/graph/persist.mjs, which now
// has the new streaming version — purely so it can be benchmarked against the same
// synthetic graph for a fair before/after comparison. Copied verbatim from commit
// 9e76d46's transitgo-server/src/graph/persist.mjs (git show 9e76d46:...), only renamed.
import { writeFileSync, renameSync, unlinkSync, existsSync } from "node:fs";
import { buildSyntheticGraph } from "./synthetic_bench.mjs";
import { logMemory, resetMemoryTracking, logMemorySummary, getPeak, startMemorySampler } from "../src/graph/memlog.mjs";

function serviceCalendarToJSON(serviceCalendar) {
  const out = [];
  for (const [key, entry] of serviceCalendar ?? []) {
    out.push([key, {
      calendarRow: entry.calendarRow ?? null,
      exceptions: [...(entry.exceptions ?? new Map())],
    }]);
  }
  return out;
}

function saveGraphToDiskOld(graph, filePath) {
  logMemory("old_persist_start", { nodeCount: graph.nodeCount, edgeCount: graph.edgeCount });
  const payload = {
    formatVersion: 1,
    builtAt: graph.builtAt,
    dataVersion: graph.dataVersion,
    warnings: graph.warnings ?? [],
    nodes: [...graph.nodes.values()],
    edges: [...graph.edgesByFrom.values()].flat(),
    serviceCalendar: serviceCalendarToJSON(graph.serviceCalendar),
  };
  logMemory("old_persist_after_payload_assembled", { nodeCount: graph.nodeCount, edgeCount: graph.edgeCount });
  const tmpPath = `${filePath}.tmp`;
  const json = JSON.stringify(payload);
  logMemory("old_persist_after_stringify", { jsonLengthMB: Math.round(json.length / 1024 / 1024 * 10) / 10 });
  writeFileSync(tmpPath, json);
  renameSync(tmpPath, filePath);
  logMemory("old_persist_complete");
}

const graph = buildSyntheticGraph();
logMemory("old_graph_ready", { nodeCount: graph.nodeCount, edgeCount: graph.edgeCount });

const outPath = "/tmp/bench_old_graph_cache.json";
let currentPhase = "old_persist_start";
const sampler = startMemorySampler({ intervalMs: 100, getContext: () => ({ phase: currentPhase, feed: null }) });
const t0 = Date.now();
saveGraphToDiskOld(graph, outPath);
const durationMs = Date.now() - t0;
const continuousPeak = sampler.stop();

logMemorySummary({ nodeCount: graph.nodeCount, edgeCount: graph.edgeCount, persistDurationMs: durationMs, continuousPeak });
const checkpointPeak = getPeak();
console.log(`\n[bench_old] duration=${durationMs}ms checkpointPeakRSS=${checkpointPeak.rssMB}MB (phase=${checkpointPeak.phase}) continuousPeakRSS=${continuousPeak.rssMB}MB (phase=${continuousPeak.phase}, 100ms sampling)`);

if (existsSync(outPath)) unlinkSync(outPath);
