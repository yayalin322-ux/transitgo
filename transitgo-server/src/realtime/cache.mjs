import { RealtimeReason, RealtimeError, classifyRealtimeError } from "./errors.mjs";

/**
 * Short-lived cache + in-flight de-duplication in front of every TDX realtime call.
 *
 * Why it exists: TDX's per-key quota is tiny (~5 requests/minute on the free tier), and one
 * screen can ask the same question several times at once (route card, map, station detail,
 * nearby list). Concurrent identical requests share ONE upstream call; a fresh answer is
 * reused for the source's TTL; a failure is remembered for a (shorter, reason-specific)
 * time so a rate-limited or credential-broken source is not hammered on every request.
 *
 * A cache entry is either a success `{ ok: true, value, fetchedAt }` or a failure
 * `{ ok: false, reason, fetchedAt }` — callers get the same shape either way, plus
 * `cached` (true when no network call was made for this request).
 */
export function createRealtimeCache({ now = () => Date.now(), failureTtlMs = {} } = {}) {
  // How long each failure kind is remembered. Credential problems don't fix themselves in
  // seconds and every retry burns quota; a timeout is often transient.
  const failureTtl = {
    [RealtimeReason.RATE_LIMITED]: 30_000,
    [RealtimeReason.CREDENTIAL]: 60_000,
    [RealtimeReason.TIMEOUT]: 10_000,
    [RealtimeReason.UNAVAILABLE]: 10_000,
    ...failureTtlMs,
  };
  const entries = new Map();    // key -> { result, expiresAt }
  const inflight = new Map();   // key -> Promise<result>
  const stats = { networkCalls: 0, cacheHits: 0, sharedInflight: 0 };

  async function getOrLoad(key, loader, { ttlMs }) {
    const hit = entries.get(key);
    if (hit && hit.expiresAt > now()) {
      stats.cacheHits++;
      return { ...hit.result, cached: true };
    }
    const running = inflight.get(key);
    if (running) {
      stats.sharedInflight++;
      return { ...(await running), cached: true };
    }

    const promise = (async () => {
      stats.networkCalls++;
      let result;
      let ttl;
      try {
        const value = await loader();
        result = { ok: true, value, fetchedAt: now() };
        ttl = ttlMs;
      } catch (e) {
        const reason = e instanceof RealtimeError ? e.reason : classifyRealtimeError(e);
        result = { ok: false, reason, fetchedAt: now() };
        ttl = failureTtl[reason] ?? 10_000;
      }
      entries.set(key, { result, expiresAt: now() + ttl });
      return result;
    })().finally(() => inflight.delete(key));

    inflight.set(key, promise);
    return { ...(await promise), cached: false };
  }

  return {
    getOrLoad,
    stats,
    /** Drops expired entries — called opportunistically so the map can't grow without bound. */
    sweep() {
      const t = now();
      for (const [k, v] of entries) if (v.expiresAt <= t) entries.delete(k);
    },
    size: () => entries.size,
  };
}

/** Races a promise against a deadline; rejects with `Error("timeout")` (classified TIMEOUT). */
export function withTimeout(promise, ms) {
  let timer;
  const deadline = new Promise((_, reject) => { timer = setTimeout(() => reject(new Error("timeout")), ms); });
  return Promise.race([promise, deadline]).finally(() => clearTimeout(timer));
}
