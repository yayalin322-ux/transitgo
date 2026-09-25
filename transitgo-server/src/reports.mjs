/** Bounds for what /v1/reports accepts, so a bad client cannot store megabytes per row. */
export const REPORT_LIMITS = Object.freeze({ type: 40, message: 4000, contextBytes: 4000 });

/** `null` = reject (no usable type). Otherwise the same report with every field held to its limit. */
export function clampReport({ type, message, context, appVersion, os, device } = {}) {
  if (typeof type !== "string" || !type.trim()) return null;
  const s = (v, n) => (typeof v === "string" ? v.slice(0, n) : null);
  let ctx = null;
  if (context && typeof context === "object") {
    try { const j = JSON.stringify(context); ctx = j.length <= REPORT_LIMITS.contextBytes ? context : { truncated: true }; } catch { ctx = null; }
  }
  return {
    type: type.trim().slice(0, REPORT_LIMITS.type),
    message: s(message, REPORT_LIMITS.message) ?? "",
    context: ctx,
    appVersion: s(appVersion, 40), os: s(os, 80), device: s(device, 80),
  };
}
