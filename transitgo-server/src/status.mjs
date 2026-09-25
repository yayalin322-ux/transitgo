/**
 * The tiny public status the website shows ("伺服器：正常"). Deliberately less than /v1/health: no memory figures,
 * commit or database details — just whether the service is up, whether the route planner is ready, and how long it has
 * been running.
 */
export const STATUS_ORIGINS = Object.freeze(["https://yayalin.com", "https://www.yayalin.com"]);

export function buildStatus({ now = new Date(), uptimeSeconds = 0, routingLoaded = false } = {}) {
  return {
    ok: true,
    time: now.toISOString(),
    routing: routingLoaded ? "ready" : "loading",
    uptimeSeconds: Math.max(0, Math.round(uptimeSeconds)),
  };
}

/** The origin to echo in Access-Control-Allow-Origin, or null: only our own website may read it from a browser. */
export function allowedOrigin(origin) {
  return STATUS_ORIGINS.includes(origin) ? origin : null;
}
