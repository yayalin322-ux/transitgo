/**
 * Why a realtime lookup produced nothing — the client must be able to tell these apart
 * (the brief's failure matrix), because each means something different to a rider and
 * none of them means "the route doesn't exist":
 *
 *   timeout       TDX (or the network) didn't answer in time     -> "即時資料暫時無法取得"
 *   rate_limited  HTTP 429 from TDX                              -> "暫時被限流，稍後再試"
 *   credential    HTTP 401/403, or a token request refused       -> "即時資料憑證異常"
 *   no_data       TDX answered fine but had nothing for this     -> "目前沒有即時資料"
 *   unavailable   any other failure (5xx, network, bad payload)  -> "即時資料暫時無法取得"
 *   not_supported this mode has no reliable realtime source      -> (no realtime shown)
 */
export const RealtimeReason = Object.freeze({
  TIMEOUT: "timeout",
  RATE_LIMITED: "rate_limited",
  CREDENTIAL: "credential",
  NO_DATA: "no_data",
  UNAVAILABLE: "unavailable",
  NOT_SUPPORTED: "not_supported",
});

/** Maps whatever a TDX call threw onto a RealtimeReason. Never returns null. */
export function classifyRealtimeError(e) {
  if (!e) return RealtimeReason.UNAVAILABLE;
  if (e.name === "TimeoutError" || e.name === "AbortError" || e.message === "timeout") return RealtimeReason.TIMEOUT;
  const status = e.status ?? Number(/\s(\d{3})$/.exec(e.message ?? "")?.[1]);
  if (status === 429) return RealtimeReason.RATE_LIMITED;
  if (status === 401 || status === 403) return RealtimeReason.CREDENTIAL;
  return RealtimeReason.UNAVAILABLE;
}

/** A lookup that failed with a known reason — thrown by loaders, caught by the cache. */
export class RealtimeError extends Error {
  constructor(reason, message = reason) {
    super(message);
    this.name = "RealtimeError";
    this.reason = reason;
  }
}
