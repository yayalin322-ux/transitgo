import { MinHeap } from "./heap.mjs";
import { haversineMeters } from "../graph/virtual.mjs";
import { Mode } from "../graph/model.mjs";

/**
 * One point in the search — architecture doc section 5: "State = Node + Time", not just
 * Node → Node. `previousState`/`previousEdge` form the backpointer chain used to
 * reconstruct the actual route once the destination is reached.
 */
class RoutingState {
  constructor({ nodeId, time, walkingSeconds = 0, waitingSeconds = 0, transitSeconds = 0, transfers = 0, lastMode = null, previousState = null, previousEdge = null }) {
    this.nodeId = nodeId;
    this.time = time;               // clock time (seconds since midnight) at this node
    this.walkingSeconds = walkingSeconds;
    this.waitingSeconds = waitingSeconds;
    this.transitSeconds = transitSeconds;
    this.transfers = transfers;
    this.lastMode = lastMode;
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
 * "Basic" here (Phase 4) means: it already respects real per-edge departure times (an
 * edge is only usable if its departureSeconds >= the arrival time at its from-node) and
 * counts a transfer only between two non-WALK edges of different modes (section 7) — but
 * it does not yet apply calendar/service-day filtering, realtime delays, or
 * headway-based edges (none exist in the graph yet — see Phase 2's warnings). That's
 * Phase 5.
 */
export function findRoute(graph, originId, destinationId, departureTimeSeconds, options = {}) {
  const {
    maxWalkingSeconds = Infinity,
    maxTransfers = Infinity,
    heuristicSpeedMps = 70,
    transferPenaltySeconds = 0,   // added to g(n) per transfer — Phase 8's RoutingProfile will make this configurable per profile
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
  const bestTimeAt = new Map([[originId, departureTimeSeconds]]);

  let expanded = 0;
  const MAX_EXPANSIONS = 200_000;   // circuit breaker, not a tuning knob — section 18's "找不到路線" must terminate, not hang

  while (!open.isEmpty()) {
    if (++expanded > MAX_EXPANSIONS) return { error: "SEARCH_TOO_LARGE" };
    const { state } = open.pop();

    if (state.nodeId === destinationId) return { route: reconstruct(state) };
    if (state.time > (bestTimeAt.get(state.nodeId) ?? Infinity)) continue;   // stale queue entry, a better path to this node already won

    for (const edge of graph.neighbors(state.nodeId)) {
      let nextTime, walkingSeconds = state.walkingSeconds, waitingSeconds = state.waitingSeconds,
        transitSeconds = state.transitSeconds, transfers = state.transfers;

      if (edge.mode === Mode.WALK) {
        if (edge.travelSeconds == null) continue;
        if (walkingSeconds + edge.travelSeconds > maxWalkingSeconds) continue;
        nextTime = state.time + edge.travelSeconds;
        walkingSeconds += edge.travelSeconds;
      } else if (edge.isTimeDependent) {
        if (edge.departureSeconds < state.time) continue;   // real trip, already departed relative to this state — can't catch it
        const wait = edge.departureSeconds - state.time;
        const ride = edge.travelSeconds ?? (edge.arrivalSeconds - edge.departureSeconds);
        const isTransfer = state.lastMode != null && state.lastMode !== Mode.WALK && state.lastMode !== edge.mode;
        if (isTransfer) {
          transfers += 1;
          if (transfers > maxTransfers) continue;
        }
        waitingSeconds += wait;
        transitSeconds += ride;
        nextTime = edge.arrivalSeconds;
      } else if (edge.isHeadwayBased) {
        // Real headway band, real service window (e.g. TDX's own "07:00"-"09:00" peak
        // band) — outside it this route/direction isn't running at that frequency
        // (may not be running at all), so the edge simply isn't usable then.
        const timeOfDay = state.time % 86400;
        if (edge.windowStartSeconds != null && timeOfDay < edge.windowStartSeconds) continue;
        if (edge.windowEndSeconds != null && timeOfDay > edge.windowEndSeconds) continue;
        // Expected wait under an assumption of uniform arrivals relative to the bus
        // schedule (half the real headway) — a standard, documented approximation for
        // headway-based routing, not an arbitrary number.
        const wait = edge.headwaySeconds / 2;
        const ride = edge.travelSeconds ?? 0;
        const isTransfer = state.lastMode != null && state.lastMode !== Mode.WALK && state.lastMode !== edge.mode;
        if (isTransfer) {
          transfers += 1;
          if (transfers > maxTransfers) continue;
        }
        waitingSeconds += wait;
        transitSeconds += ride;
        nextTime = state.time + wait + ride;
      } else {
        continue;
      }

      const known = bestTimeAt.get(edge.toNodeId);
      if (known != null && nextTime >= known) continue;   // dominated — a strictly-as-good-or-better arrival already found
      bestTimeAt.set(edge.toNodeId, nextTime);

      const nextState = new RoutingState({
        nodeId: edge.toNodeId, time: nextTime,
        walkingSeconds, waitingSeconds, transitSeconds, transfers,
        lastMode: edge.mode,
        previousState: state, previousEdge: edge,
      });
      const g = (nextTime - departureTimeSeconds) + transfers * transferPenaltySeconds;
      open.push({ priority: g + heuristic(edge.toNodeId), state: nextState });
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
    });
    s = s.previousState;
  }
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
    legs,
  };
}
