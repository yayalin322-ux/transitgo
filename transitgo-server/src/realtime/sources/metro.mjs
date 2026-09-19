import { RealtimeState, RealtimeSource, arrivalState, makeStatus, iso } from "../model.mjs";

export const metroLiveBoardPath = (operator) => `v2/Rail/Metro/LiveBoard/${operator}`;
export const metroAlertPath = (operator) => `v2/Rail/Metro/Alert/${operator}`;

/**
 * TDX metro LiveBoard rows -> the next trains at one station heading toward `routeStops`'
 * later stations. What each operator really publishes (checked against live data,
 * 2026-09-19):
 *   - 桃園機場捷運 (TYMC): several upcoming trains per direction, `EstimateTime` in MINUTES
 *     (the 15-min spacing of 0/22/37... matches its published 15-min headway).
 *   - 台北捷運 (TRTC): only trains arriving right now (EstimateTime 0) — no forward-looking
 *     ETAs at all. An empty result for TRTC means "nothing arriving this instant", NOT
 *     "no train coming"; callers must not show it as a wait time.
 * `ServiceStatus` is 0 in every live row seen; any other value is passed as unknown with
 * the raw code rather than guessed at.
 */
export function mapMetroLiveBoard(rows, { stationId, aheadStopIds, fetchedAtMs }) {
  const ahead = new Set(aheadStopIds ?? []);
  return (rows ?? [])
    .filter((r) => r.StationID === stationId && (ahead.size === 0 || ahead.has(r.DestinationStationID) || ahead.has(r.DestinationStaionID)))
    .map((r) => {
      const updatedMs = Date.parse(r.UpdateTime ?? r.SrcUpdateTime ?? "") || fetchedAtMs;
      const minutes = Number.isFinite(r.EstimateTime) ? r.EstimateTime : null;
      const etaSeconds = minutes == null ? null : minutes * 60;
      const normalService = r.ServiceStatus === 0;
      return makeStatus({
        mode: "MRT",
        routeId: r.LineID ?? null,
        estimatedTime: normalService && etaSeconds != null ? iso(updatedMs + etaSeconds * 1000) : null,
        // A 0-minute row is a train at/arriving at the platform; the minute granularity
        // means anything under 1 is "arriving", not a precise seconds figure.
        state: !normalService ? RealtimeState.UNKNOWN : etaSeconds === 0 ? RealtimeState.ARRIVING : arrivalState(etaSeconds),
        source: RealtimeSource.TDX_METRO_LIVEBOARD,
        updatedAt: iso(updatedMs),
        extra: {
          towards: r.TripHeadSign ?? null,
          etaSeconds: normalService ? etaSeconds : null,
          rawServiceStatus: normalService ? null : (r.ServiceStatus ?? null),
        },
      });
    })
    .sort((a, b) => (a.etaSeconds ?? 1e9) - (b.etaSeconds ?? 1e9));
}

/** Alerts for one operator: TDX's own "nothing wrong" entry (Status 1) is filtered out. */
export function mapMetroAlerts(raw) {
  return (raw?.Alerts ?? [])
    .filter((a) => a && a.Status !== 1)
    .map((a) => ({ id: String(a.AlertID ?? ""), title: a.Title ?? "營運異常", description: a.Description ?? null, source: RealtimeSource.TDX_METRO_ALERT, updatedAt: a.UpdateTime ?? null }));
}
