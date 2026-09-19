/**
 * The one realtime shape every source is normalized into. Deliberately free of any UI
 * wording — clients map `state` to text themselves. A field a source does not really
 * provide is `null`, never a default: e.g. TDX publishes no schedule for headway-run
 * buses, so a bus `delaySeconds` is null, not 0.
 *
 * States are only ever ones a source actually reported (or a plain threshold on a real
 * ETA, see arrivalState):
 *   normal / approaching / arriving  — from a real ETA
 *   delayed                          — a real, positive delay figure (TRA DelayTime)
 *   notDeparted / notStopping / lastServicePassed / notOperating
 *                                    — TDX bus StopStatus 1 / 2 / 3 / 4, verbatim
 *   cancelled                        — a source explicitly reporting cancellation (TRA
 *                                      RunningStatus 2 per TDX docs; not yet seen in live
 *                                      data, so covered by fixture tests only)
 *   unknown                          — the source answered but with a value we can't interpret
 */
export const RealtimeState = Object.freeze({
  NORMAL: "normal",
  APPROACHING: "approaching",
  ARRIVING: "arriving",
  DELAYED: "delayed",
  CANCELLED: "cancelled",
  NOT_DEPARTED: "notDeparted",
  NOT_STOPPING: "notStopping",
  LAST_SERVICE_PASSED: "lastServicePassed",
  NOT_OPERATING: "notOperating",
  UNKNOWN: "unknown",
});

export const RealtimeSource = Object.freeze({
  TDX_BUS_ETA: "tdx.bus.estimatedTimeOfArrival",
  TDX_METRO_LIVEBOARD: "tdx.metro.liveBoard",
  TDX_TRA_STATION_LIVEBOARD: "tdx.tra.stationLiveBoard",
  TDX_BUS_ALERT: "tdx.bus.alert",
  TDX_METRO_ALERT: "tdx.metro.alert",
  TDX_TRA_ALERT: "tdx.tra.alert",
  TDX_THSR_ALERT: "tdx.thsr.alertInfo",
});

/** Same thresholds the app's own Fmt.eta uses ("進站中" under 30 s): under 30 s arriving,
 * under 2 min approaching, otherwise normal. A plain rule on a real ETA, not an invented state. */
export function arrivalState(etaSeconds) {
  if (etaSeconds == null) return RealtimeState.UNKNOWN;
  if (etaSeconds < 30) return RealtimeState.ARRIVING;
  if (etaSeconds < 120) return RealtimeState.APPROACHING;
  return RealtimeState.NORMAL;
}

/** Builds one RealtimeStatus (ISO strings for times so it serializes as-is). */
export function makeStatus({ mode, routeId = null, tripId = null, vehicleId = null, scheduledTime = null, estimatedTime = null, delaySeconds = null, state, source, updatedAt, extra = {} }) {
  return {
    mode, routeId, tripId, vehicleId,
    scheduledTime, estimatedTime, delaySeconds,
    state, source, updatedAt,
    ...extra,
  };
}

const iso = (ms) => (Number.isFinite(ms) ? new Date(ms).toISOString() : null);
export { iso };
