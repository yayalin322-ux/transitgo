import { findRoute } from "./astar.mjs";
import { PROFILES } from "./profiles.mjs";

function routeSignature(route) {
  return route.legs.map((l) => `${l.mode}:${l.routeId ?? ""}:${l.fromNodeId}:${l.toNodeId}`).join("|");
}

/** A dominates B — architecture doc section 10 — if A is at least as good on every
 * major metric and strictly better on at least one. Fare only enters this comparison
 * when BOTH routes have real, known pricing — with no fare data ingested anywhere yet
 * (the common case today) every route's fare is null, and folding an unknown value into
 * a <=/< comparison either way would silently bias dominance on nothing. Once real fare
 * data exists, this is what stops a merely-faster-but-pricier route from crowding out a
 * genuinely cheaper alternative before LOWEST_COST ranking ever sees it. */
function dominates(a, b) {
  const fareComparable = a.fare != null && b.fare != null;
  const notWorse = a.durationSeconds <= b.durationSeconds && a.transfers <= b.transfers && a.walkingSeconds <= b.walkingSeconds
    && (!fareComparable || a.fare <= b.fare);
  const strictlyBetter = a.durationSeconds < b.durationSeconds || a.transfers < b.transfers || a.walkingSeconds < b.walkingSeconds
    || (fareComparable && a.fare < b.fare);
  return notWorse && strictlyBetter;
}

/**
 * Route Ranking — architecture doc section 9/10. Runs the same real search under each
 * RoutingProfile (different real routes usually come out, since a fewest-transfers
 * profile is willing to accept more real walking/waiting to avoid a transfer's flat
 * penalty, etc.), dedupes identical routes, removes dominated ones, and labels what's
 * left by whichever profile actually produced the best version of it — capped at the
 * requested count (3-5 per the doc).
 */
export function rankRoutes(graph, originId, destinationId, departureTimeSeconds, options = {}) {
  const { maxResults = 5, searchOptions = {} } = options;

  const candidates = [];   // { route, signature, profileKey }
  const bySignature = new Map();
  let anyNetworkIssue = false;

  for (const [profileKey, profile] of Object.entries(PROFILES)) {
    const result = findRoute(graph, originId, destinationId, departureTimeSeconds, { ...searchOptions, profile });
    if (result.error) {
      if (result.error === "SAME_ORIGIN_DESTINATION" || result.error === "UNKNOWN_DESTINATION") {
        return { error: result.error };   // not profile-dependent — no point trying the others
      }
      if (result.error === "SEARCH_TOO_LARGE") anyNetworkIssue = true;
      continue;
    }
    const sig = routeSignature(result.route);
    // Same real route can legitimately win under more than one profile — keep the
    // instance whichever profile is most "native" to it (first one found), not a
    // duplicate entry per profile.
    if (!bySignature.has(sig)) {
      bySignature.set(sig, { route: result.route, signature: sig, profileKeys: [profileKey] });
      candidates.push(bySignature.get(sig));
    } else {
      bySignature.get(sig).profileKeys.push(profileKey);
    }
  }

  if (candidates.length === 0) {
    return { error: anyNetworkIssue ? "SEARCH_TOO_LARGE" : "NO_ROUTE" };
  }

  // Remove dominated routes (section 10) — O(n²) over at most 4 candidates (one per
  // profile), trivially cheap.
  const survivors = candidates.filter((c) =>
    !candidates.some((other) => other !== c && dominates(other.route, c.route))
  );

  // Label by real metrics, not just "whichever profile happened to find it" — a route
  // that's simultaneously the fastest AND has the fewest transfers only needs one label.
  const withMetrics = survivors.map((c) => ({ ...c, route: c.route }));
  const fastest = withMetrics.reduce((a, b) => (b.route.durationSeconds < a.route.durationSeconds ? b : a));
  const fewestTransfers = withMetrics.reduce((a, b) => (b.route.transfers < a.route.transfers ? b : a));
  const leastWalking = withMetrics.reduce((a, b) => (b.route.walkingSeconds < a.route.walkingSeconds ? b : a));
  // Only ever label something LOWEST_COST when at least one candidate actually has a
  // real, known fare (astar.mjs sets route.fare to null, never a fabricated 0, whenever
  // any leg's price is unknown) — with no real fare data ingested anywhere yet (see
  // profiles.mjs's LOWEST_COST comment), every candidate is null right now, so this
  // never fires and no route gets mislabeled as "cheapest" based on nothing.
  const withKnownFare = withMetrics.filter((c) => c.route.fare != null);
  const cheapest = withKnownFare.length > 0
    ? withKnownFare.reduce((a, b) => (b.route.fare < a.route.fare ? b : a))
    : null;

  function labelFor(candidate) {
    if (candidate === fastest) return PROFILES.FASTEST;
    if (candidate === fewestTransfers) return PROFILES.FEWEST_TRANSFERS;
    if (candidate === leastWalking) return PROFILES.LEAST_WALKING;
    if (cheapest && candidate === cheapest) return PROFILES.LOWEST_COST;
    return PROFILES.BALANCED;
  }

  const labeled = withMetrics
    .sort((a, b) => a.route.cost - b.route.cost)
    .slice(0, maxResults)
    .map((c) => {
      const p = labelFor(c);
      return { label: p.label, emoji: p.emoji, route: c.route };
    });

  return { routes: labeled };
}
