import { RealtimeState, RealtimeSource, arrivalState, makeStatus, iso } from "../model.mjs";

/** TDX bus StopStatus, verbatim (the app's own StopArrival.displayText uses the same 5 values). */
const STOP_STATUS = {
  1: RealtimeState.NOT_DEPARTED,
  2: RealtimeState.NOT_STOPPING,
  3: RealtimeState.LAST_SERVICE_PASSED,
  4: RealtimeState.NOT_OPERATING,
};

/** Path for one route's ETA at every stop (both directions). `scopePath` is TDX's own
 * fragment ("City/Taipei", "InterCity") — the same value the routing engine already returns. */
export function busRoutePath(scopePath, routeName) {
  return `v2/Bus/EstimatedTimeOfArrival/${scopePath}/${encodeURIComponent(routeName)}`;
}

/** Path for the ETAs at a set of physical stops (every route serving them). */
export function busStopsPath(scopePath, stopUIDs) {
  const filter = stopUIDs.map((u) => `StopUID eq '${String(u).replace(/'/g, "''")}'`).join(" or ");
  return `v2/Bus/EstimatedTimeOfArrival/${scopePath}?$filter=${encodeURIComponent(filter)}&$top=160`;
}

const validPlate = (p) => (p && p !== "-1" ? p : null);

/**
 * One TDX ETA row -> RealtimeStatus. Two real shapes exist: most cities give
 * `EstimateTime` (seconds); 新竹 gives no EstimateTime at all, only `StopCountDown` (stops
 * away) — that is kept as an extra, never converted to a made-up number of minutes.
 * `scheduledTime` is always null: TDX's ETA carries no timetable, so a bus has no
 * scheduled time to compare against and therefore no delay figure.
 */
export function mapBusRow(row, { fetchedAtMs }) {
  const updatedMs = Date.parse(row.UpdateTime ?? row.SrcUpdateTime ?? row.DataTime ?? "") || fetchedAtMs;
  const status = Number(row.StopStatus ?? 0);
  const fixed = STOP_STATUS[status];
  const eta = Number.isFinite(row.EstimateTime) ? row.EstimateTime : null;

  let state, estimatedTime = null;
  if (fixed) state = fixed;
  else if (status === 0 && eta != null) { state = arrivalState(eta); estimatedTime = iso(updatedMs + eta * 1000); }
  else state = RealtimeState.UNKNOWN;   // "normal" status but no usable number

  return makeStatus({
    mode: "BUS",
    routeId: row.RouteUID ?? row.RouteID ?? null,
    vehicleId: validPlate(row.PlateNumb),
    estimatedTime,
    state,
    source: RealtimeSource.TDX_BUS_ETA,
    updatedAt: iso(updatedMs),
    extra: {
      routeName: row.RouteName?.Zh_tw ?? null,
      stopUID: row.StopUID ?? null,
      direction: Number.isFinite(row.Direction) ? row.Direction : null,
      etaSeconds: state === RealtimeState.NOT_DEPARTED || fixed ? null : eta,
      stopsAway: Number.isFinite(row.StopCountDown) && !fixed ? row.StopCountDown : null,
      isLastBus: row.IsLastBus === true ? true : null,
    },
  });
}

/** Statuses for one physical stop out of a whole-route response (optionally one direction). */
export function busArrivalsAtStop(rows, stopUID, { direction = null, fetchedAtMs }) {
  return (rows ?? [])
    .filter((r) => r.StopUID === stopUID && (direction == null || r.Direction === direction))
    .map((r) => mapBusRow(r, { fetchedAtMs }))
    .sort((a, b) => (a.etaSeconds ?? 1e9) - (b.etaSeconds ?? 1e9));
}

/** Bus alerts that apply to one route/stop RIGHT NOW: inside the alert's own StartTime/EndTime
 * window and naming the route (by TDX route name) or the stop. Title/Description are TDX's
 * words, passed through; Cause/Effect/Status codes are not interpreted (their meaning isn't
 * documented anywhere this project can verify). */
export function busAlertsFor(alerts, { routeName, stopIds = [], nowMs }) {
  return (alerts ?? []).filter((a) => {
    const start = Date.parse(a.StartTime ?? ""), end = Date.parse(a.EndTime ?? "");
    if (Number.isFinite(start) && nowMs < start) return false;
    if (Number.isFinite(end) && nowMs > end) return false;
    const routes = a.Scope?.Routes ?? [], stops = a.Scope?.Stops ?? [];
    return routes.some((r) => r.RouteName?.Zh_tw === routeName)
      || stops.some((s) => stopIds.includes(s.StopID) || stopIds.includes(s.StopUID));
  }).map((a) => ({
    id: String(a.AlertID ?? ""), title: a.Title ?? "", description: a.Description ?? null,
    source: RealtimeSource.TDX_BUS_ALERT, startTime: a.StartTime ?? null, endTime: a.EndTime ?? null, updatedAt: a.UpdateTime ?? null,
  }));
}
