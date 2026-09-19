import { createRealtimeCache, withTimeout } from "../src/realtime/cache.mjs";
import { RealtimeError, RealtimeReason, classifyRealtimeError } from "../src/realtime/errors.mjs";

let failed = false;
function check(label, cond) {
  console.log(`${cond ? "PASS" : "FAIL"} - ${label}`);
  if (!cond) failed = true;
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// --- same request twice -> ONE network call ---
{
  let t = 0, calls = 0;
  const cache = createRealtimeCache({ now: () => t });
  const load = async () => { calls++; return { eta: 180 }; };
  const a = await cache.getOrLoad("bus:182", load, { ttlMs: 15_000 });
  const b = await cache.getOrLoad("bus:182", load, { ttlMs: 15_000 });
  check("second identical request inside the TTL is served from cache", calls === 1 && a.cached === false && b.cached === true && b.value.eta === 180);
  t = 16_000;
  await cache.getOrLoad("bus:182", load, { ttlMs: 15_000 });
  check("after the TTL a fresh network call is made", calls === 2);
  await cache.getOrLoad("bus:5", load, { ttlMs: 15_000 });
  check("different keys are cached independently", calls === 3);
}

// --- concurrent identical requests share ONE in-flight call ---
{
  let calls = 0;
  const cache = createRealtimeCache();
  const load = async () => { calls++; await sleep(30); return "x"; };
  const results = await Promise.all([1, 2, 3, 4].map(() => cache.getOrLoad("k", load, { ttlMs: 1000 })));
  check("4 simultaneous identical requests -> exactly 1 upstream call", calls === 1 && cache.stats.networkCalls === 1);
  check("the 3 followers report cached (shared in-flight) and all get the value", results.filter((r) => r.cached).length === 3 && results.every((r) => r.value === "x"));
  check("shared in-flight is counted", cache.stats.sharedInflight === 3);
}

// --- failures are typed and negative-cached ---
{
  let t = 0, calls = 0;
  const cache = createRealtimeCache({ now: () => t });
  const rate = async () => { calls++; throw Object.assign(new Error("TDX x 429"), { status: 429 }); };
  const r1 = await cache.getOrLoad("k", rate, { ttlMs: 15_000 });
  check("429 -> ok:false, reason rate_limited", r1.ok === false && r1.reason === RealtimeReason.RATE_LIMITED);
  await cache.getOrLoad("k", rate, { ttlMs: 15_000 });
  check("a rate-limited source is NOT retried inside its failure TTL (30s)", calls === 1);
  t = 31_000; await cache.getOrLoad("k", rate, { ttlMs: 15_000 });
  check("...but is retried after it", calls === 2);
}
{
  let calls = 0;
  const cache = createRealtimeCache();
  const bad = async () => { calls++; throw Object.assign(new Error("TDX auth 401"), { status: 401, kind: "auth" }); };
  const r = await cache.getOrLoad("k", bad, { ttlMs: 1000 });
  check("401 -> reason credential", r.ok === false && r.reason === RealtimeReason.CREDENTIAL);
  await cache.getOrLoad("k", bad, { ttlMs: 1000 });
  check("a credential failure is remembered (no quota burned retrying)", calls === 1);
}

// --- classification matrix ---
check("403 -> credential", classifyRealtimeError({ status: 403, message: "x" }) === RealtimeReason.CREDENTIAL);
check("message-only 'TDX path 429' -> rate_limited (older errors without .status)", classifyRealtimeError(new Error("TDX v2/Bus/x 429")) === RealtimeReason.RATE_LIMITED);
check("AbortSignal.timeout's TimeoutError -> timeout", classifyRealtimeError(Object.assign(new Error("t"), { name: "TimeoutError" })) === RealtimeReason.TIMEOUT);
check("500 -> unavailable", classifyRealtimeError({ status: 500, message: "TDX x 500" }) === RealtimeReason.UNAVAILABLE);
check("a loader-thrown RealtimeError keeps its own reason (no_data)", (await createRealtimeCache().getOrLoad("k", async () => { throw new RealtimeError(RealtimeReason.NO_DATA); }, { ttlMs: 1 })).reason === RealtimeReason.NO_DATA);

// --- timeout helper ---
{
  const started = Date.now();
  let reason;
  try { await withTimeout(new Promise(() => {}), 30); } catch (e) { reason = classifyRealtimeError(e); }
  check("withTimeout rejects a hung call as 'timeout' quickly", reason === RealtimeReason.TIMEOUT && Date.now() - started < 1000);
  check("withTimeout passes a fast result through", (await withTimeout(Promise.resolve(7), 1000)) === 7);
}

// --- bounded memory ---
{
  let t = 0;
  const cache = createRealtimeCache({ now: () => t });
  for (let i = 0; i < 50; i++) await cache.getOrLoad(`k${i}`, async () => i, { ttlMs: 1000 });
  t = 5000; cache.sweep();
  check("sweep() drops expired entries so the cache can't grow forever", cache.size() === 0);
}

console.log(failed ? "\nOVERALL: FAIL" : "\nOVERALL: PASS");
process.exit(failed ? 1 : 0);
