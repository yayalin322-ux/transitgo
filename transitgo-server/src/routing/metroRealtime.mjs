import { getRouting } from "../tdx.mjs";

/**
 * Best-effort live metro status for a route result (TDX v2/Rail/Metro/Alert/{operator}).
 * Strictly optional: the static route is already fully computed before this is consulted,
 * and any failure here (TDX rate limit, timeout, an operator with no Alert feed) resolves
 * to `null`, which the caller reports as `{ available: false }` — never as a route failure.
 *
 * TDX's free quota is ~5 requests/minute, so every operator's answer is cached — a
 * successful lookup for `ttlMs`, a failed one for `failureTtlMs` (so a rate-limited
 * operator isn't retried on every single route request).
 */
export function createMetroRealtime({ fetchAlerts = (op) => getRouting(`v2/Rail/Metro/Alert/${op}`), ttlMs = 60_000, failureTtlMs = 30_000, timeoutMs = 1500, now = () => Date.now() } = {}) {
  const cache = new Map();   // operator -> { at, ttl, value }

  async function lookup(operator) {
    let timer;
    const timeout = new Promise((_, reject) => { timer = setTimeout(() => reject(new Error("timeout")), timeoutMs); });
    try {
      const raw = await Promise.race([fetchAlerts(operator), timeout]);
      // Status 1 with the "正常營運" title is TDX's own "nothing wrong" entry; anything else
      // is an actual notice, passed through verbatim (title/description are TDX's text).
      const alerts = (raw?.Alerts ?? [])
        .filter((a) => a && a.Status !== 1)
        .map((a) => ({ title: a.Title ?? "營運異常", description: a.Description ?? null, updateTime: a.UpdateTime ?? null }));
      return { alerts };
    } finally {
      clearTimeout(timer);
    }
  }

  return {
    /** Resolves `{ alerts: [...] }`, or `null` when live status can't be obtained right now. */
    async metroStatus(operator) {
      const hit = cache.get(operator);
      if (hit && now() - hit.at < hit.ttl) return hit.value;
      let value = null;
      try {
        value = await lookup(operator);
      } catch {
        value = null;
      }
      cache.set(operator, { at: now(), ttl: value ? ttlMs : failureTtlMs, value });
      return value;
    },
  };
}
