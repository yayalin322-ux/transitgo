/**
 * Every number the bike model uses, in one place, each marked with what it rests on.
 * Nothing here is a fare or a live value.
 */
export const BIKE_CONFIG = Object.freeze({
  // --- graph sparsity: MEASURED (test/bike_density_probe.mjs, live gov YouBike feeds, 7,452 stations in 5 cities) ---
  // Each station links to its K nearest stations within a distance cap; links are used in both
  // directions. A fixed 800 m radius needed 140k edges for 95% reachability; K=6/2500 m needs 53k
  // for 98% (chain length only ~9% above straight line), and still reaches sparse areas (Taoyuan,
  // Taichung suburbs) where a fixed radius leaves stations isolated.
  linkNearestK: 6,
  linkMaxMeters: 2500,

  // --- transit <-> bike-station walking links: MEASURED (test/bike_proximity_probe.mjs) ---
  // Nearest YouBike to a real station: 台北捷運 122/122 within 300 m (median 45 m), 台鐵 70/95,
  // 高鐵 6/12 (the rest have none in the checked cities). Only the nearest stop PER FEED is linked.
  stopLinkMaxMeters: 300,
  walkingSpeedMps: 1.3,           // same estimate the rest of the graph uses for WALK

  // --- virtual origin/destination -> bike stations ---
  walkToStationMaxMeters: 800,
  walkToStationCandidates: 6,     // nearest N stations only (never a full scan, never all stations in range)

  // --- riding: ASSUMPTIONS (no bike-path network and no trip-speed data exist in this project) ---
  // A ride's distance is the straight line x a detour factor and its time is distance / speed.
  // Both are flagged `isEstimated` on every result; change them here, not in the search.
  detourFactor: 1.3,
  speedMps: 4.0,                  // 14.4 km/h, a typical urban shared-bike pace
  unlockSeconds: 30,
  returnSeconds: 30,

  // --- realtime availability ---
  // The poller refreshes every BIKE_POLL_MINUTES (2). Cache a snapshot for 15 s so a burst of
  // route queries costs one DB read; treat a snapshot older than 10 min (poller stalled) as unknown.
  snapshotTtlMs: 15_000,
  staleMs: 10 * 60_000,
});

export const BIKE_FEED_PREFIX = "BIKE_";
export const bikeFeedOf = (city) => `${BIKE_FEED_PREFIX}${city}`;
export const isBikeNodeId = (id) => String(id).startsWith(BIKE_FEED_PREFIX);
