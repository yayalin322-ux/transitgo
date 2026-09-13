/**
 * RoutingProfile — architecture doc section 8. Every weight is configurable, not hardcoded
 * into the search itself (findRoute takes a profile object, never reads these constants
 * directly) — these are just the four presets the doc asked for as a starting point.
 *
 * Cost is an additive weighted sum (timeWeight*rideTime + walkingWeight*walkTime +
 * waitingWeight*waitTime + a flat transferPenaltySeconds per transfer), not the literal
 * product chain the doc's pseudocode listed — a multiplicative chain across
 * fundamentally different units (seconds × a unitless walking multiplier × ...) doesn't
 * actually produce a sane cost, and every real routing engine (OpenTripPlanner, Google's
 * internal one, etc.) uses a weighted sum for exactly this reason. The tunable knobs the
 * doc asked for (favor speed vs favor fewer transfers vs favor less walking) all still
 * work the same way with a sum.
 */
export const PROFILES = {
  FASTEST: {
    label: "最快", emoji: "🚀",
    timeWeight: 1, walkingWeight: 0.5, waitingWeight: 1, transferPenaltySeconds: 180, fareWeight: 0,
  },
  BALANCED: {
    label: "最均衡", emoji: "⚖️",
    timeWeight: 1, walkingWeight: 1.5, waitingWeight: 1.2, transferPenaltySeconds: 360, fareWeight: 0,
  },
  FEWEST_TRANSFERS: {
    label: "少轉乘", emoji: "🔄",
    timeWeight: 1, walkingWeight: 0.8, waitingWeight: 1, transferPenaltySeconds: 900, fareWeight: 0,
  },
  LEAST_WALKING: {
    label: "少走路", emoji: "🚶",
    timeWeight: 1, walkingWeight: 4, waitingWeight: 1, transferPenaltySeconds: 480, fareWeight: 0,
  },
};
