import { MinHeap } from "./heap.mjs";
import { haversineMeters } from "../graph/virtual.mjs";
import { Mode } from "../graph/model.mjs";
import { isServiceActiveOn } from "../graph/calendar.mjs";
import { isBikeNodeId } from "../bike/config.mjs";

/**
 * One point in the search — architecture doc section 5: "State = Node + Time", not just
 * Node → Node. `previousState`/`previousEdge` form the backpointer chain used to
 * reconstruct the actual route once the destination is reached.
 */
class RoutingState {
  constructor({ nodeId, time, cost = 0, walkingSeconds = 0, waitingSeconds = 0, transitSeconds = 0, transfers = 0, fare = 0, fareKnown = true, waitKnown = true, lastTripKey = null, onboardKey = null, riding = false, bikeSeconds = 0, bikeMeters = 0, bikeAvailabilityUnknown = false, handlingSeconds = 0, previousState = null, previousEdge = null }) {
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
    // Sticky false once any boarded ride has no real headway/timetable behind it (see
    // TransitEdge.waitUnknown) — the route's waiting time is then genuinely unknown, and
    // reconstruct() reports waitingSeconds: null instead of a misleading 0.
    this.waitKnown = waitKnown;
    // The last *ride* boarded (persists across walking legs, so walk-then-board a
    // different ride still counts as a transfer) vs. the ride the previous edge itself was
    // on (null right after any walk) — only the latter means "still sitting on the same
    // train/bus", i.e. no new wait to pay.
    this.lastTripKey = lastTripKey;
    this.onboardKey = onboardKey;
    // YouBike: true from the moment a bike is rented until it is returned at a dock. Part of the
    // search state (a rider on a bike at a station is not comparable to a walker at the same station).
    this.riding = riding;
    this.bikeSeconds = bikeSeconds;
    this.bikeMeters = bikeMeters;
    // Sticky: some rent/return check had no usable realtime answer (see options.bike.check).
    this.bikeAvailabilityUnknown = bikeAvailabilityUnknown;
    // Unlock+return time folded into the FIRST bike edge of a ride (0 on every other edge).
    this.handlingSeconds = handlingSeconds;
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
    // YouBike layer. Absent/null = bike edges and bike stations are invisible to this search
    // (the pre-bike behavior, exactly). When present:
    //   check(nodeId, "rent"|"return") -> "yes" | "no" | "unknown"   realtime overlay, asked ONLY when
    //     a candidate station is actually about to be used — the graph itself holds no availability.
    //   unlockSeconds / returnSeconds — handling time (assumptions, see bike/config.mjs).
    bike = null,
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
  // Keyed by node AND the ride you're still sitting on: arriving at a station already
  // aboard a train (no new wait to pay for the next hop) is a different, not-comparable
  // state from arriving there on foot at a slightly lower cost — collapsing them would let
  // the cheaper-but-must-wait-again state wrongly prune the on-board one.
  const stateKey = (nodeId, onboardKey) => (onboardKey ? `${nodeId}|${onboardKey}` : nodeId);
  const bestCostAt = new Map([[stateKey(originId, null), 0]]);

  let expanded = 0;
  const MAX_EXPANSIONS = 200_000;   // circuit breaker, not a tuning knob — section 18's "找不到路線" must terminate, not hang

  while (!open.isEmpty()) {
    if (++expanded > MAX_EXPANSIONS) return { error: "SEARCH_TOO_LARGE" };
    const { state } = open.pop();

    if (state.nodeId === destinationId) return { route: reconstruct(state) };
    if (state.cost > (bestCostAt.get(stateKey(state.nodeId, state.onboardKey)) ?? Infinity)) continue;   // stale queue entry, a better path to this node already won

    for (const edge of graph.neighbors(state.nodeId)) {
      let nextTime, addedCost, walkingSeconds = state.walkingSeconds, waitingSeconds = state.waitingSeconds,
        transitSeconds = state.transitSeconds, transfers = state.transfers, fare = state.fare, fareKnown = state.fareKnown,
        waitKnown = state.waitKnown;
      let nextOnboardKey = null;
      let riding = false, bikeSeconds = state.bikeSeconds, bikeMeters = state.bikeMeters, bikeUnknown = state.bikeAvailabilityUnknown, handlingSeconds = 0;

      if (edge.mode === Mode.BIKE) {
        if (!bike) continue;
        // Renting: only on foot, only at a station that really has a bike. Riding on: no check.
        let handling = 0;
        if (!state.riding) {
          const verdict = bike.check(edge.fromNodeId, "rent");
          if (verdict === "no") continue;
          if (verdict === "unknown") bikeUnknown = true;
          handling = (bike.unlockSeconds ?? 0) + (bike.returnSeconds ?? 0);
        }
        const rideSeconds = (edge.travelSeconds ?? 0) + handling;
        nextTime = state.time + rideSeconds;
        bikeSeconds += rideSeconds;
        bikeMeters += edge.distanceMeters ?? 0;
        handlingSeconds = handling;
        // Boarding a bike after another ride is a transfer; carrying on riding is not.
        const bikeKey = "BIKE:";
        const isTransfer = !state.riding && state.lastTripKey != null && state.lastTripKey !== bikeKey;
        if (isTransfer) {
          transfers += 1;
          if (transfers > maxTransfers) continue;
        }
        fareKnown = false;   // no bike fare source exists: the route's fare is unknown, never 0
        addedCost = (profile.bikeWeight ?? profile.timeWeight) * rideSeconds + (isTransfer ? profile.transferPenaltySeconds : 0);
        nextOnboardKey = bikeKey;
        riding = true;
      } else if (edge.mode === Mode.WALK) {
        if (edge.travelSeconds == null) continue;
        if (walkingSeconds + edge.travelSeconds > maxWalkingSeconds) continue;
        if (state.riding) {
          // Leaving a dock while riding = returning the bike here: needs a free dock.
          const verdict = bike?.check(state.nodeId, "return") ?? "no";
          if (verdict === "no") continue;
          if (verdict === "unknown") bikeUnknown = true;
          riding = false;
        } else if (bike && isBikeNodeId(state.nodeId)) {
          continue;   // on foot at a dock the only thing to do is rent; docks are never walking bridges
        } else if (!bike && isBikeNodeId(edge.toNodeId)) {
          continue;   // bike layer off: dock stations are invisible
        }
        nextTime = state.time + edge.travelSeconds;
        walkingSeconds += edge.travelSeconds;
        addedCost = profile.walkingWeight * edge.travelSeconds;
      } else if (state.riding) {
        continue;   // cannot board anything while holding a bike
      } else if (edge.isTimeDependent || edge.isHeadwayBased || edge.waitUnknown) {
        // A transfer is boarding a *different ride* than the one you last rode — not
        // merely a different Mode enum value (bus route 1 to bus route 5 is a real transfer
        // even though both are Mode.BUS), and it still counts when a WALK sits in between
        // (station-to-station interchange), since lastTripKey persists across walking.
        const tripKey = `${edge.mode}:${edge.routeId ?? ""}`;
        // Already sitting on this exact ride from the previous hop: no boarding, so no new
        // wait — without this every stop-to-stop hop of one ride would each charge a fresh
        // half-headway wait (a 20-station metro ride would be padded by ~20 phantom waits).
        const continuingRide = state.onboardKey === tripKey;
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
          if (dateStr && edge.serviceKey && !isServiceActiveOn(graph.serviceCalendar?.get(edge.serviceKey), dateStr)) continue;   // e.g. a weekday-only headway band on a Sunday
          const timeOfDay = state.time % 86400;
          if (edge.windowStartSeconds != null && timeOfDay < edge.windowStartSeconds) continue;
          if (edge.windowEndSeconds != null && timeOfDay > edge.windowEndSeconds) continue;
          if (edge.waitUnknown) {
            // Real per-hop travel time but NO real headway/timetable for this route — the
            // wait is genuinely unknown, so it is neither guessed nor charged; the route
            // is flagged instead (waitKnown=false -> waitingSeconds: null in the result).
            wait = 0;
            if (!continuingRide) waitKnown = false;
          } else {
            // Expected wait under an assumption of uniform arrivals relative to the
            // schedule (half the real headway) — a standard, documented approximation for
            // headway-based routing, not an arbitrary number. Paid once, on boarding.
            wait = continuingRide ? 0 : edge.headwaySeconds / 2;
          }
          ride = edge.travelSeconds ?? 0;
          nextTime = state.time + wait + ride;
        }
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
        nextOnboardKey = tripKey;
      } else {
        continue;
      }

      const nextCost = state.cost + addedCost;
      const nextKey = stateKey(edge.toNodeId, nextOnboardKey);
      const known = bestCostAt.get(nextKey);
      if (known != null && nextCost >= known) continue;   // dominated — a strictly-as-good-or-better cost already found
      bestCostAt.set(nextKey, nextCost);

      const nextState = new RoutingState({
        nodeId: edge.toNodeId, time: nextTime, cost: nextCost,
        walkingSeconds, waitingSeconds, transitSeconds, transfers, fare, fareKnown, waitKnown,
        riding, bikeSeconds, bikeMeters, bikeAvailabilityUnknown: bikeUnknown, handlingSeconds,
        lastTripKey: edge.mode === Mode.WALK ? state.lastTripKey : nextOnboardKey,
        onboardKey: nextOnboardKey,
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
        ?? (s.previousEdge.travelSeconds != null ? s.time - s.previousEdge.travelSeconds - (s.handlingSeconds || 0) : s.previousState.time),
      arrivalSeconds: s.time,
      isEstimated: s.previousEdge.isHeadwayBased || s.previousEdge.waitUnknown,
      distanceMeters: s.previousEdge.distanceMeters,
      // "TDX LineTransfer (...)" for an in-station interchange walk, "Haversine estimate"
      // for a street walk, etc. — lets a client tell a metro interchange from a street walk.
      source: s.previousEdge.source ?? null,
      // "TRA:TRA_152_2026-09-14" for a real-trip edge — lets the realtime overlay know WHICH
      // train a leg boards (headway edges have no single trip, so null).
      serviceKey: s.previousEdge.isTimeDependent ? (s.previousEdge.serviceKey ?? null) : null,
      // BIKE legs: the un-detoured distance the estimated ride distance came from, and the unlock+return
      // handling time folded into this leg (first hop of a ride only).
      ...(s.previousEdge.mode === "BIKE" ? { straightLineMeters: s.previousEdge.straightLineMeters ?? null, handlingSeconds: s.handlingSeconds || 0 } : {}),
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
    // null (not 0) when a boarded ride has no real headway/timetable data — see waitKnown.
    waitingSeconds: finalState.waitKnown ? finalState.waitingSeconds : null,
    transitSeconds: finalState.transitSeconds,
    transfers: finalState.transfers,
    fare: finalState.fareKnown ? finalState.fare : null,
    walkingDistanceMeters,
    // YouBike totals (0 / false when the route has no bike leg).
    bikeSeconds: finalState.bikeSeconds,
    bikeMeters: finalState.bikeMeters,
    bikeAvailabilityUnknown: finalState.bikeAvailabilityUnknown,
    cost: finalState.cost,
    legs,
  };
}
