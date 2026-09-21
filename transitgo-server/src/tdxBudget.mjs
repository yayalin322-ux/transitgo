/**
 * TDX allows only a handful of requests per minute per key (measured: 5). The background pollers (YouBike,
 * 台鐵／高鐵 alerts) and the calls a person is waiting on (share page, realtime for a trip) draw from that same
 * quota, and the pollers used to win — so a user's request often came back 429 ("rate_limited") and had to be
 * repeated. This gives the quota an order:
 *
 *   interactive — takes a slot immediately, or fails immediately (the caller answers from cache / says
 *                 "rate limited" at once instead of hanging);
 *   background  — waits its turn, and may never use the last `reservedForInteractive` slots of the window.
 *
 * Counted per client id, because two credential sets can be the same key.
 */
export function createBudget({
  perMinute = 5,
  reservedForInteractive = 3,
  windowMs = 60_000,
  now = () => Date.now(),
  sleep = (ms) => new Promise((r) => setTimeout(r, ms)),
  maxBackgroundWaitMs = 180_000,
} = {}) {
  const calls = new Map();   // clientId -> timestamps (ms) of calls in the current window

  function recent(id) {
    const t = now();
    const list = (calls.get(id) ?? []).filter((x) => t - x < windowMs);
    calls.set(id, list);
    return list;
  }
  const backgroundCap = Math.max(1, perMinute - reservedForInteractive);

  return {
    /** How many calls this window has used. */
    used: (id) => recent(id).length,

    /** Interactive: true and counts a call, or false (no wait). */
    tryAcquire(id) {
      const list = recent(id);
      if (list.length >= perMinute) return false;
      list.push(now());
      return true;
    },

    /** Background: resolves once a slot beyond the interactive reserve is free; false if it waited too long. */
    async acquireBackground(id) {
      const startedAt = now();
      for (;;) {
        const list = recent(id);
        if (list.length < backgroundCap) { list.push(now()); return true; }
        if (now() - startedAt > maxBackgroundWaitMs) return false;
        // wait until the oldest counted call leaves the window (at least a moment, at most a few seconds)
        const wait = Math.min(5_000, Math.max(250, windowMs - (now() - list[0]) + 50));
        await sleep(wait);
      }
    },
  };
}
