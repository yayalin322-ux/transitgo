import { RebuildLock } from "../src/graph/rebuildLock.mjs";

let failed = false;
function check(label, cond) {
  console.log(`${cond ? "PASS" : "FAIL"} - ${label}`);
  if (!cond) failed = true;
}

function deferred() {
  let resolve, reject;
  const promise = new Promise((res, rej) => { resolve = res; reject = rej; });
  return { promise, resolve, reject };
}

// --- Concurrent rebuild is refused (409-equivalent), not queued or run in parallel ---
{
  const lock = new RebuildLock();
  const gate = deferred();
  let runCount = 0;
  const runFn = () => { runCount++; return gate.promise; };

  const first = lock.start(runFn);
  check("First rebuild starts", first.started === true);
  check("Lock reports building while in flight", lock.isBuilding() === true);

  const second = lock.start(runFn);
  check("Concurrent second rebuild is refused", second.started === false);
  check("Refused attempt does not run the build function again", runCount === 1);
  check("Refused attempt's state still shows the in-flight build", second.state.status === "building");

  gate.resolve({ nodeCount: 10, edgeCount: 20 });
  await first.promise;
  check("Lock reports completed after a successful build", lock.state.status === "completed");
  check("Completed state carries real node/edge counts", lock.state.nodeCount === 10 && lock.state.edgeCount === 20);
  check("Completed state has a duration", typeof lock.state.durationSeconds === "number");

  const third = lock.start(() => Promise.resolve({ nodeCount: 1, edgeCount: 1 }));
  check("A new rebuild can start once the previous one has completed", third.started === true);
  await third.promise;
}

// --- Progress updates flow through to lock.state (for the status endpoint) ---
{
  const lock = new RebuildLock();
  const gate = deferred();
  const { started, promise } = lock.start(async (onProgress) => {
    onProgress({ phase: "nodes", memoryMB: 123, progress: 40, nodeCount: 5, edgeCount: 0 });
    return gate.promise;
  });
  check("Rebuild starts", started === true);
  // onProgress is called synchronously inside the async runFn before it awaits the gate.
  await Promise.resolve(); // let the microtask queue flush the runFn's first tick
  check("Progress phase reaches lock.state", lock.state.phase === "nodes");
  check("Progress memoryMB reaches lock.state", lock.state.memoryMB === 123);
  check("Progress nodeCount reaches lock.state", lock.state.nodeCount === 5);
  gate.resolve({ nodeCount: 5, edgeCount: 8 });
  await promise;
}

// --- Failure simulation: build throws (e.g. a real OOM, a DB error mid-query) ---
{
  const lock = new RebuildLock();
  const { promise } = lock.start(async () => { throw new Error("simulated database query failure"); });
  let threw = false;
  try { await promise; } catch { threw = true; }
  check("A failing build's promise rejects (caller can catch it)", threw === true);
  check("Lock reports failed status after a thrown error", lock.state.status === "failed");
  check("Failure message is preserved", lock.state.error === "simulated database query failure");
  check("Lock is no longer 'building' after a failure — a retry is possible", lock.isBuilding() === false);

  const retry = lock.start(() => Promise.resolve({ nodeCount: 1, edgeCount: 1 }));
  check("A rebuild can be retried after a failure", retry.started === true);
  await retry.promise;
}

// --- Failure simulation: an out-of-memory style error is classified explicitly ---
{
  const lock = new RebuildLock();
  const { promise } = lock.start(async () => { throw new Error("JavaScript heap out of memory"); });
  try { await promise; } catch {}
  check("An OOM-shaped error is classified as out_of_memory, not a raw message", lock.state.error === "out_of_memory");
}

console.log(failed ? "\nOVERALL: FAIL" : "\nOVERALL: PASS");
if (failed) process.exit(1);
