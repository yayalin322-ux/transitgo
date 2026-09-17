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

// --- Continuous RSS sampler -------------------------------------------------------
//
// The checkpoint-based logMemory() above only sees RSS at the moments buildGraph()/
// saveGraphToDisk() happen to call report() — a spike that rises and falls entirely
// *between* two checkpoints (e.g. mid-way through a single large query's JS-side row
// processing) would never show up in `peak` above. This sampler polls
// process.memoryUsage() on a timer instead, independent of where the build code
// happens to call out to it, to answer whether such a between-checkpoint spike exists.
//
// Deliberately keeps only the running peak, never a history array — a rebuild can run
// for minutes, and a sample every 100ms for that long would be tens of thousands of
// objects retained for no reason (v.s. the "找不到最終答案" instrumentation this whole
// module exists to avoid). Logs only on a new peak, a phase checkpoint, or at the end,
// never per-tick — see the explicit "不要每 100ms 印 log" requirement.
let activeSampler = null;

/**
 * Starts continuous RSS sampling. Only one sampler may be active at a time (mirrors the
 * rebuild lock's "at most one build in flight" invariant) — starting a second one while
 * one is running throws rather than silently creating two timers.
 *
 * `getContext()` is called on every tick to label a potential new peak with whatever the
 * caller currently considers "phase"/"feed" to be — the sampler itself has no idea what
 * build phase is running, by design (kept decoupled from buildGraph's control flow).
 */
export function startMemorySampler({ intervalMs = 100, getContext = () => ({}), sampleFn = process.memoryUsage } = {}) {
  if (activeSampler) {
    throw new Error("startMemorySampler: a sampler is already running — only one rebuild's sampler may be active at a time");
  }

  const startedAt = Date.now();
  const continuousPeak = { rssMB: 0, heapUsedMB: 0, externalMB: 0, arrayBuffersMB: 0, phase: null, feed: null, elapsedMs: 0, timestamp: null };

  // `sampleFn` defaults to the real process.memoryUsage but is injectable — real OS-level
  // RSS is inherently noisy (allocator page reuse, GC timing, other processes on a shared
  // machine), which makes peak-detection *logic* hard to test deterministically against
  // it. Tests inject a fake sequence of readings instead; production code never passes
  // this option and always measures the real process.
  const tick = () => {
    const m = sampleFn();
    const rssMB = toMB(m.rss);
    if (rssMB > continuousPeak.rssMB) {
      const ctx = getContext() || {};
      continuousPeak.rssMB = rssMB;
      continuousPeak.heapUsedMB = toMB(m.heapUsed);
      continuousPeak.externalMB = toMB(m.external);
      continuousPeak.arrayBuffersMB = toMB(m.arrayBuffers);
      continuousPeak.phase = ctx.phase ?? null;
      continuousPeak.feed = ctx.feed ?? null;
      continuousPeak.elapsedMs = Date.now() - startedAt;
      continuousPeak.timestamp = new Date().toISOString();
      console.log(
        `[GRAPH_MEMORY_PEAK]\nrssMB=${continuousPeak.rssMB}\nheapUsedMB=${continuousPeak.heapUsedMB}\n` +
        `externalMB=${continuousPeak.externalMB}\narrayBuffersMB=${continuousPeak.arrayBuffersMB}\n` +
        `phase=${continuousPeak.phase ?? ""}\nfeed=${continuousPeak.feed ?? ""}\nelapsedMs=${continuousPeak.elapsedMs}`
      );
    }
  };

  const timer = setInterval(tick, intervalMs);
  timer.unref?.(); // never keep the process alive just for sampling

  activeSampler = {
    stop() {
      if (activeSampler !== this) return continuousPeak; // already stopped
      clearInterval(timer);
      activeSampler = null;
      return continuousPeak;
    },
    getPeak() {
      return continuousPeak;
    },
  };
  return activeSampler;
}

/** True while a sampler is running — lets a caller (or a test) confirm the "one sampler
 * per rebuild" invariant without reaching into module-private state. */
export function isSamplerActive() {
  return activeSampler !== null;
}

/** Prints the closing summary block. Call once, after persist completes (success or
 * failure — pass whatever counts/durations are known at that point).
 *
 * `continuousPeak` (from a sampler's `getPeak()`/`stop()`) is reported separately from
 * the checkpoint-based `peak` above — they measure different things (discrete call
 * sites vs. a 100ms-resolution timer) and must never be collapsed into one number. See
 * the module doc comment on `startMemorySampler`. */
export function logMemorySummary({ nodeCount, edgeCount, buildDurationMs, persistDurationMs, continuousPeak } = {}) {
  const finalRssMB = toMB(process.memoryUsage().rss);
  const totalDurationMs = (buildDurationMs ?? 0) + (persistDurationMs ?? 0);
  const fmtS = (ms) => (ms != null ? (ms / 1000).toFixed(1) + "s" : "n/a");
  const lines = [
    "========== GRAPH MEMORY SUMMARY ==========",
    `baseline RSS: ${baselineRssMB ?? "n/a"} MB`,
    `final RSS: ${finalRssMB} MB`,
    "",
    `Checkpoint Peak RSS: ${peak?.rssMB ?? "n/a"} MB`,
    `Checkpoint Peak Heap: ${peak?.heapUsedMB ?? "n/a"} MB`,
    "",
    `Continuous Peak RSS: ${continuousPeak?.rssMB ?? "n/a"} MB`,
    `Continuous Peak Heap: ${continuousPeak?.heapUsedMB ?? "n/a"} MB`,
    `Continuous Peak External: ${continuousPeak?.externalMB ?? "n/a"} MB`,
    "",
    `Continuous Peak Phase: ${continuousPeak?.phase ?? "n/a"}`,
    `Continuous Peak Feed: ${continuousPeak?.feed ?? "n/a"}`,
    `Continuous Peak Timestamp: ${continuousPeak?.timestamp ?? "n/a"}`,
    "",
    `node count: ${nodeCount ?? "n/a"}`,
    `edge count: ${edgeCount ?? "n/a"}`,
    "",
    `Build Duration: ${fmtS(buildDurationMs)}`,
    `Persist Duration: ${fmtS(persistDurationMs)}`,
    `Total Rebuild Duration: ${fmtS(totalDurationMs)}`,
    "===========================================",
  ];
  console.log(lines.join("\n"));
  return { baselineRssMB, peak, continuousPeak, finalRssMB };
}
