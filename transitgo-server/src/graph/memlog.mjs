/**
 * Build-time memory instrumentation. Every claim about buildGraph()'s memory profile in
 * this codebase before this file existed was inferred, not measured — this module exists
 * so "which phase actually drives peak RSS" has a real, grep-able answer instead of
 * another guess.
 *
 * Deliberately logs only numeric process.memoryUsage() figures plus phase/feed/count
 * labels — never request/response bodies, TDX client ID/secret, DATABASE_URL,
 * ADMIN_TOKEN, or any user data.
 *
 * Module-level state (not a class instance threaded through buildGraph/saveGraphToDisk)
 * is deliberate here: this is profiling-only, off the routing/build correctness path,
 * and the rebuild lock (rebuildLock.mjs) already guarantees at most one build+persist
 * runs at a time, so there's no concurrent-tracker-mixing risk to design around.
 */

let peak = null;
let trackingStartedAt = null;
let baselineRssMB = null;

function toMB(bytes) {
  return Math.round((bytes / 1024 / 1024) * 10) / 10;
}

/** Call once at the very start of a build (before any DB query) — captures the RSS the
 * process was already sitting at (Express, poller intervals, etc. already resident) so
 * later numbers can be read as "on top of baseline," not confused with it. */
export function resetMemoryTracking() {
  const m = process.memoryUsage();
  baselineRssMB = toMB(m.rss);
  trackingStartedAt = Date.now();
  peak = { rssMB: 0, heapUsedMB: 0, externalMB: 0, phase: null, feed: null, elapsedMs: 0 };
  return baselineRssMB;
}

export function getBaselineRssMB() {
  return baselineRssMB;
}

/**
 * Logs one checkpoint and updates the running peak. `extra` may include `feed`,
 * `nodeCount`, `edgeCount`, or any other plain-value label — all printed as-is, so never
 * pass a secret through it.
 */
export function logMemory(phase, extra = {}) {
  const m = process.memoryUsage();
  const elapsedMs = trackingStartedAt != null ? Date.now() - trackingStartedAt : null;
  const snapshot = {
    phase,
    timestamp: new Date().toISOString(),
    rssMB: toMB(m.rss),
    heapUsedMB: toMB(m.heapUsed),
    heapTotalMB: toMB(m.heapTotal),
    externalMB: toMB(m.external),
    arrayBuffersMB: toMB(m.arrayBuffers),
    ...(elapsedMs != null ? { elapsedMs } : {}),
    ...extra,
  };
  console.log(`[GRAPH_MEMORY]\n${Object.entries(snapshot).map(([k, v]) => `${k}=${v}`).join("\n")}`);

  if (peak && snapshot.rssMB > peak.rssMB) {
    peak = {
      rssMB: snapshot.rssMB,
      heapUsedMB: snapshot.heapUsedMB,
      externalMB: snapshot.externalMB,
      phase,
      feed: extra.feed ?? null,
      elapsedMs: elapsedMs ?? 0,
    };
    console.log(`[GRAPH_PEAK]\nrssMB=${peak.rssMB}\nheapUsedMB=${peak.heapUsedMB}\nexternalMB=${peak.externalMB}\nphase=${peak.phase}\nfeed=${peak.feed ?? ""}\nelapsedMs=${peak.elapsedMs}`);
  }

  return { rssMB: snapshot.rssMB, heapUsedMB: snapshot.heapUsedMB };
}

export function getPeak() {
  return peak;
}

/** Prints the closing summary block. Call once, after persist completes (success or
 * failure — pass whatever counts/durations are known at that point). */
export function logMemorySummary({ nodeCount, edgeCount, buildDurationMs, persistDurationMs } = {}) {
  const finalRssMB = toMB(process.memoryUsage().rss);
  const lines = [
    "========== GRAPH MEMORY SUMMARY ==========",
    `baseline RSS: ${baselineRssMB ?? "n/a"} MB`,
    `peak RSS: ${peak?.rssMB ?? "n/a"} MB`,
    `final RSS: ${finalRssMB} MB`,
    "",
    `peak heapUsed: ${peak?.heapUsedMB ?? "n/a"} MB`,
    `peak external: ${peak?.externalMB ?? "n/a"} MB`,
    "",
    `peak phase: ${peak?.phase ?? "n/a"}`,
    `peak feed: ${peak?.feed ?? "n/a"}`,
    "",
    `node count: ${nodeCount ?? "n/a"}`,
    `edge count: ${edgeCount ?? "n/a"}`,
    "",
    `build duration: ${buildDurationMs != null ? (buildDurationMs / 1000).toFixed(1) + "s" : "n/a"}`,
    `persist duration: ${persistDurationMs != null ? (persistDurationMs / 1000).toFixed(1) + "s" : "n/a"}`,
    "===========================================",
  ];
  console.log(lines.join("\n"));
  return { baselineRssMB, peak, finalRssMB };
}
