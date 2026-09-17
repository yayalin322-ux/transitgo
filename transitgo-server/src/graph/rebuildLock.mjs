/**
 * Rebuild lock + status tracker for the graph build, factored out of index.mjs so it can
 * be unit-tested without spinning up the whole HTTP server. A concurrent second rebuild
 * would double every temporary array/Map buildGraph() allocates on top of a graph the
 * first rebuild is already holding — on an instance where a single build alone has been
 * observed to approach the memory limit, that's the difference between "slow" and "OOM
 * killed", so a second request while one is already running must be refused (409), not
 * queued or run in parallel.
 */
export class RebuildLock {
  constructor() {
    this.state = { status: "idle" };
  }

  isBuilding() {
    return this.state.status === "building";
  }

  /** Runs `runFn(onProgress)` if nothing is already building; returns {started:false} if
   * one is already in flight (the caller should respond 409 in that case). `runFn` does
   * the real build+persist+swap and resolves once fully done or rejects with the failure. */
  start(runFn) {
    if (this.isBuilding()) return { started: false, state: this.state };

    const startedAt = new Date().toISOString();
    this.state = { status: "building", phase: "start", progress: 0, startedAt, updatedAt: startedAt };

    const onProgress = ({ phase, memoryMB, progress, nodeCount, edgeCount }) => {
      this.state = {
        status: "building",
        phase,
        progress: progress ?? this.state.progress ?? 0,
        nodeCount: nodeCount ?? this.state.nodeCount,
        edgeCount: edgeCount ?? this.state.edgeCount,
        memoryMB,
        startedAt,
        updatedAt: new Date().toISOString(),
      };
    };

    const t0 = Date.now();
    const run = (async () => {
      try {
        const result = await runFn(onProgress);
        this.state = {
          status: "completed",
          durationSeconds: Math.round((Date.now() - t0) / 1000),
          nodeCount: result.nodeCount,
          edgeCount: result.edgeCount,
          startedAt,
          updatedAt: new Date().toISOString(),
        };
        return result;
      } catch (e) {
        const isOom = /heap out of memory|ENOMEM/i.test(e?.message || "");
        this.state = {
          status: "failed",
          error: isOom ? "out_of_memory" : (e?.message || "unknown error"),
          startedAt,
          updatedAt: new Date().toISOString(),
        };
        throw e;
      }
    })();

    return { started: true, promise: run };
  }
}
