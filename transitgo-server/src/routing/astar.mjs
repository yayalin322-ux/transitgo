import { MinHeap } from "./heap.mjs";
import { haversineMeters } from "../graph/virtual.mjs";
import { Mode } from "../graph/model.mjs";
import { isServiceActiveOn } from "../graph/calendar.mjs";

/**
 * One point in the search — architecture doc section 5: "State = Node + Time", not just
 * Node → Node. `previousState`/`previousEdge` form the backpointer chain used to
 * reconstruct the actual route once the destination is reached.
 */
class RoutingState {
  constructor({ nodeId, time, cost = 0, walkingSeconds = 0, waitingSeconds = 0, transitSeconds = 0, transfers = 0, fare = 0, fareKnown = true, lastTripKey = null, previousState = null, previousEdge = null }) {
    this.nodeId = nodeId;
    this.time = time;               // real clock time (seconds since midnight) — drives which real trips/headway windows are reachable
    this.cost = cost;               // accumulated g(n) under the active RoutingProfile's weights — drives ranking/pruning, not real time
    this.walkingSeconds = walkingSeconds;
    this.waitingSeconds = waitingSeconds;
    this.transitSeconds = transitSeconds;
    this.transfers = transfers;
    this.fare = fare;
    // Sticky false the moment any transit edge along this path has no real fare data —
    // a partial sum that silently skipped an unpriced leg isn't "the price", it's a
    // wrong number that happens to look like one. See reconstruct(): a route whose
    // fareKnown ends up false reports fare: null, never a misleading 0.
    this.fareKnown = fareKnown;
    this.lastTripKey = lastTripKey;
    this.previousState = previousState;
    this.previousEdge = previousEdge;
  }
}

/**
 * Time-Dependent A* — architecture doc section 5/6. f(n) = g(n) + h(n):
 *   g(n) = elapsed real seconds since departureTime (walking + waiting + riding, all real)
 *   h(n) = Haversine(n, destination) / heuristicSpeedMps
 *
 * heuristicSpeedMps must be at or above the fastest mode actually in the graph (HSR-class
 * speed) for A* to stay admissible — too low and the search can return a suboptimal
 * route; too high just explores a bit more before converging, still correct. Defaults to
 * 70 m/s (~252 km/h, above THSR's real top speed) for exactly that reason.
 *
 * Respects real per-edge departure times (an edge is only usable if its departureSeconds
 * is at or after the arrival time at its from-node) and real headway service windows.
 * Counts a transfer whenever the *ride* changes (different mode, or same mode but a
 * different route — e.g. bus route 1 to bus route 5 is a transfer even though both are
 * Mode.BUS), never for a WALK leg (section 7). Does not yet apply calendar/service-day
 * filtering or realtime delays — that's Phase 8 (Realtime).
 */
export function findRoute(graph, originId, destinationId, departureTimeSeconds, options = {}) {
  const {
    maxWalkingSeconds = Infinity,
    maxTransfers = Infinity,
    heuristicSpeedMps = 70,
    // RoutingProfile (architecture doc section 8) — every weight configurable, never
    // hardcoded into the search itself. Defaults to an unweighted "just minimize real
    // elapsed time" profile when the caller doesn't pass one.
    profile = { timeWeight: 1, walkingWeight: 1, waitingWeight: 1, transferPenaltySeconds: 0, fareWeight: 0 },
    // "YYYYMMDD" — which real calendar date this search is for, checked against
    // gtfs_calendar/gtfs_calendar_dates per edge (weekday pattern, holidays, real 停駛
    // cancellations). No date = no calendar filtering (useful for synthetic/test graphs
    // that don't model calendars at all).
    dateStr = null,
  } = options;

  if (originId === destinationId) {
    return { error: "SAME_ORIGIN_DESTINATION" };
  }
  const destNode = graph.nodes.get(destinationId);
  if (!destNode) return { error: "UNKNOWN_DESTINATION" };

  function heuristic(nodeId) {
    const n = graph.nodes.get(nodeId);
    if (!n || n.lat == null || destNode.lat == null) return 0;
    return haversineMeters(n.lat, n.lon, destNode.lat, destNode.lon) / heuristicSpeedMps;
  }

  const startState = new RoutingState({ nodeId: originId, time: departureTimeSeconds });
  const open = new MinHeap();
  open.push({ priority: heuristic(originId), state: startState });
  // Pruning is on accumulated *cost* (profile-weighted), not raw arrival time — under
  // e.g. LEAST_WALKING, an earlier-arriving-but-more-walking path is not "better".
  const bestCostAt = new Map([[originId, 0]]);

  let expanded = 0;
  const MAX_EXPANSIONS = 200_000;   // circuit breaker, not a tuning knob — section 18's "找不到路線" must terminate, not hang

  while (!open.isEmpty()) {
    if (++expanded > MAX_EXPANSIONS) return { error: "SEARCH_TOO_LARGE" };
    const { state } = open.pop();

    if (state.nodeId === destinationId) return { route: reconstruct(state) };
    if (state.cost > (bestCostAt.get(state.nodeId) ?? Infinity)) continue;   // stale queue entry, a better path to this node already won

    for (const edge of graph.neighbors(state.nodeId)) {
      let nextTime, addedCost, walkingSeconds = state.walkingSeconds, waitingSeconds = state.waitingSeconds,
        transitSeconds = state.transitSeconds, transfers = state.transfers, fare = state.fare, fareKnown = state.fareKnown;

      if (edge.mode === Mode.WALK) {
        if (edge.travelSeconds == null) continue;
        if (walkingSeconds + edge.travelSeconds > maxWalkingSeconds) continue;
        nextTime = state.time + edge.travelSeconds;
        walkingSeconds += edge.travelSeconds;
        addedCost = profile.walkingWeight * edge.travelSeconds;
      } else if (edge.isTimeDependent || edge.isHeadwayBased) {
        let wait, ride;
        if (edge.isTimeDependent) {
          if (dateStr && edge.serviceKey && !isServiceActiveOn(graph.serviceCalendar?.get(edge.serviceKey), dateStr)) continue;   // real 停駛/off-calendar — this specific trip isn't running on this date
          if (edge.departureSeconds < state.time) continue;   // real trip, already departed relative to this state — can't catch it
          wait = edge.departureSeconds - state.time;
          ride = edge.travelSeconds ?? (edge.arrivalSeconds - edge.departureSeconds);
          nextTime = edge.arrivalSeconds;
        } else {
          // Real headway band, real service window (e.g. TDX's own "07:00"-"09:00" peak
          // band) — outside it this route/direction isn't running at that frequency
          // (may not be running at all), so the edge simply isn't usable then.
          const timeOfDay = state.time % 86400;
          if (edge.windowStartSeconds != null && timeOfDay < edge.windowStartSeconds) continue;
          if (edge.windowEndSeconds != null && timeOfDay > edge.windowEndSeconds) continue;
          // Expected wait under an assumption of uniform arrivals relative to the bus
          // schedule (half the real headway) — a standard, documented approximation
          // for headway-based routing, not an arbitrary number.
          wait = edge.headwaySeconds / 2;
          ride = edge.travelSeconds ?? 0;
          nextTime = state.time + wait + ride;
        }
        // A transfer is boarding a *different ride* than the one you were just on — not
        // merely a different Mode enum value. Switching from bus route 1 to bus route 5
        // is a real transfer even though both are Mode.BUS; comparing by mode alone
        // missed exactly that case.
        const tripKey = `${edge.mode}:${edge.routeId ?? ""}`;
        const isTransfer = state.lastTripKey != null && state.lastTripKey !== tripKey;
        if (isTransfer) {
          transfers += 1;
          if (transfers > maxTransfers) continue;
        }
        waitingSeconds += wait;
        transitSeconds += ride;
        if (edge.fare == null) fareKnown = false;
        else fare += edge.fare;
        addedCost = profile.timeWeight * ride + profile.waitingWeight * wait
          + (isTransfer ? profile.transferPenaltySeconds : 0) + profile.fareWeight * (edge.fare ?? 0);
      } else {
        continue;
      }

      const nextCost = state.cost + addedCost;
      const known = bestCostAt.get(edge.toNodeId);
      if (known != null && nextCost >= known) continue;   // dominated — a strictly-as-good-or-better cost already found
      bestCostAt.set(edge.toNodeId, nextCost);

      const nextState = new RoutingState({
        nodeId: edge.toNodeId, time: nextTime, cost: nextCost,
        walkingSeconds, waitingSeconds, transitSeconds, transfers, fare, fareKnown,
        lastTripKey: edge.mode === Mode.WALK ? null : `${edge.mode}:${edge.routeId ?? ""}`,
        previousState: state, previousEdge: edge,
      });
      open.push({ priority: nextCost + heuristic(edge.toNodeId), state: nextState });
    }
  }
  return { error: "NO_ROUTE" };
}

function reconstruct(finalState) {
  const legs = [];
  let s = finalState;
  while (s.previousEdge) {
    legs.unshift({
      mode: s.previousEdge.mode,
      routeId: s.previousEdge.routeId,
      fromNodeId: s.previousEdge.fromNodeId,
      toNodeId: s.previousEdge.toNodeId,
      // A headway edge has no fixed departureSeconds of its own — the real boarding
      // instant is (arrival - ride time), not the previous node's arrival time (that
      // would wrongly fold the wait into the leg's own duration).
      departureSeconds: s.previousEdge.departureSeconds
        ?? (s.previousEdge.travelSeconds != null ? s.time - s.previousEdge.travelSeconds : s.previousState.time),
      arrivalSeconds: s.time,
      isEstimated: s.previousEdge.isHeadwayBased,
      distanceMeters: s.previousEdge.distanceMeters,
    });
    s = s.previousState;
  }
  // Real distance, summed from each WALK leg's own haversine measurement — 0 (not null)
  // when there's genuinely no walking, since that IS a known, real answer, unlike fare.
  const walkingDistanceMeters = legs.reduce((sum, l) => sum + (l.mode === "WALK" ? (l.distanceMeters ?? 0) : 0), 0);
  return {
    originId: s.nodeId,
    destinationId: finalState.nodeId,
    departureTime: s.time,
    arrivalTime: finalState.time,
    durationSeconds: finalState.time - s.time,
    walkingSeconds: finalState.walkingSeconds,
    waitingSeconds: finalState.waitingSeconds,
    transitSeconds: finalState.transitSeconds,
    transfers: finalState.transfers,
    fare: finalState.fareKnown ? finalState.fare : null,
    walkingDistanceMeters,
    cost: finalState.cost,
    legs,
  };
}
