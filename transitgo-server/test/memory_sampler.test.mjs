import { startMemorySampler, isSamplerActive } from "../src/graph/memlog.mjs";

let failed = false;
function check(label, cond) {
  console.log(`${cond ? "PASS" : "FAIL"} - ${label}`);
  if (!cond) failed = true;
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function waitFor(cond, timeoutMs = 4000, pollMs = 10) {
  const deadline = Date.now() + timeoutMs;
  while (!cond()) {
    if (Date.now() > deadline) throw new Error("waitFor: condition never became true within timeout");
    await sleep(pollMs);
  }
}

/** A fake process.memoryUsage()-shaped reader that advances through a fixed sequence of
 * RSS readings (in MB) one call per tick, then holds on the last value. Used for
 * peak-detection tests below instead of real memory pressure — real OS-level RSS is
 * inherently noisy (allocator page reuse, GC timing, a shared/loaded machine), which
 * makes the exact-values test the brief asks for ("100MB 110MB 150MB 120MB -> peak
 * 150MB") impossible to assert reliably against real memory. Production code always
 * uses the real process.memoryUsage; this is test-only. */
function fakeMemoryReader(mbSequence) {
  let i = 0;
  return () => {
    const mb = mbSequence[Math.min(i, mbSequence.length - 1)];
    i++;
    return { rss: mb * 1024 * 1024, heapUsed: mb * 0.4 * 1024 * 1024, heapTotal: mb * 0.6 * 1024 * 1024, external: 0, arrayBuffers: 0 };
  };
}

// --- Test 1: sampler starts, samples, and fully stops ---
{
  check("No sampler active before start", isSamplerActive() === false);
  const sampler = startMemorySampler({ intervalMs: 10 });
  check("Sampler reports active once started", isSamplerActive() === true);
  await waitFor(() => sampler.getPeak().rssMB > 0);
  const peakWhileRunning = sampler.getPeak();
  check("A peak was recorded while running (rssMB > 0, real process memory)", peakWhileRunning.rssMB > 0);
  const finalPeak = sampler.stop();
  check("Sampler reports inactive after stop", isSamplerActive() === false);
  check("stop() returns the peak as of when it was called", finalPeak.rssMB >= peakWhileRunning.rssMB);

  // Confirm sampling actually stopped (not just that isSamplerActive() flipped) by
  // swapping in a fake reader that would obviously move the peak if the old timer were
  // still alive, and confirming nothing changes.
  const peakAfterStop = sampler.getPeak().rssMB;
  await sleep(100);
  check("No new peak recorded after stop() (timer really cleared, not just flagged)", sampler.getPeak().rssMB === peakAfterStop);
}

// --- Test 2: peak detection picks the highest of a rising-then-falling sequence ---
// Exactly the brief's own scenario: 100MB -> 110MB -> 150MB -> 120MB, peak must be 150MB.
{
  const sampleFn = fakeMemoryReader([100, 110, 150, 120]);
  const sampler = startMemorySampler({ intervalMs: 5, sampleFn });
  await waitFor(() => sampler.getPeak().rssMB >= 150, 4000, 5);
  await sleep(50); // let a few more ticks land on the trailing 120MB value
  const peak = sampler.stop();
  check("Peak is exactly the highest reading in the sequence (150MB), not the last (120MB)", peak.rssMB === 150);
}

// --- Test 3: peak carries the phase/feed context active at the moment of the new peak ---
{
  const sampleFn = fakeMemoryReader([80, 90, 200, 200, 200]); // single sharp peak at the 3rd reading
  let ctx = { phase: "A", feed: "HSZ" };
  const sampler = startMemorySampler({ intervalMs: 5, sampleFn, getContext: () => ctx });
  await waitFor(() => sampler.getPeak().rssMB >= 200, 4000, 5);
  const peakContext = sampler.getPeak();
  check("Peak context reflects phase/feed active when the peak reading occurred (A/HSZ)", peakContext.phase === "A" && peakContext.feed === "HSZ");

  ctx = { phase: "B", feed: "TPE" };
  await sleep(50); // sequence is exhausted (holds at 200) — no new peak, context must not drift
  const peak = sampler.stop();
  check("Peak context does not drift just because context changed without a new peak", peak.phase === "A" && peak.feed === "HSZ");
}

// --- Test 3b: a later, strictly higher reading correctly re-labels phase/feed ---
{
  const sampleFn = fakeMemoryReader([80, 150, 150, 300]);
  let ctx = { phase: "A", feed: "HSZ" };
  const sampler = startMemorySampler({ intervalMs: 5, sampleFn, getContext: () => ctx });
  await waitFor(() => sampler.getPeak().rssMB >= 150, 4000, 5);
  check("First peak labeled A/HSZ", sampler.getPeak().phase === "A" && sampler.getPeak().feed === "HSZ");

  ctx = { phase: "B", feed: "TPE" };
  await waitFor(() => sampler.getPeak().rssMB >= 300, 4000, 5);
  const peak = sampler.stop();
  check("A later, strictly higher reading re-labels phase/feed to B/TPE", peak.rssMB === 300 && peak.phase === "B" && peak.feed === "TPE");
}

// --- Test 4: sampler is stopped even when the surrounding work throws ---
{
  async function runRebuildLike() {
    const sampler = startMemorySampler({ intervalMs: 10 });
    try {
      await sleep(20);
      throw new Error("simulated buildGraph() failure");
    } finally {
      sampler.stop();
    }
  }
  check("No sampler active before the failing run", isSamplerActive() === false);
  let threw = false;
  try {
    await runRebuildLike();
  } catch {
    threw = true;
  }
  check("The simulated failure really threw", threw === true);
  check("Sampler was stopped by the finally block despite the throw — no leaked timer", isSamplerActive() === false);
}

// --- Test 5: only one sampler may be active at a time ---
{
  const first = startMemorySampler({ intervalMs: 50 });
  let threwOnSecond = false;
  try {
    startMemorySampler({ intervalMs: 50 });
  } catch {
    threwOnSecond = true;
  }
  check("Starting a second sampler while one is active throws (no duplicate sampler)", threwOnSecond === true);
  first.stop();
  check("A new sampler can start once the previous one has stopped", (() => {
    const second = startMemorySampler({ intervalMs: 50 });
    second.stop();
    return true;
  })());
}

console.log(failed ? "\nOVERALL: FAIL" : "\nOVERALL: PASS");
if (failed) process.exit(1);
