import { RealtimeSource } from "../model.mjs";

export const thsrAlertPath = () => "v2/Rail/THSR/AlertInfo";

/**
 * HSR realtime: TDX has NO per-train delay/arrival feed for 高鐵 (v2/Rail/THSR/LiveBoard
 * returns 404; only seat availability and network alerts exist), so HSR arrival/delay is
 * `not_supported` — never derived from the timetable and presented as live. What IS real
 * is the network alert list; TDX's all-zero AlertID / "全線營運正常" entry is "nothing wrong".
 */
export function mapThsrAlerts(raw) {
  return (Array.isArray(raw) ? raw : [])
    .filter((a) => a && a.AlertID && a.AlertID !== "00000000-0000-0000-0000-000000000000" && !/正常|normal/i.test(a.Title ?? ""))
    .map((a) => ({ id: String(a.AlertID), title: a.Title ?? "營運異常", description: a.Description ?? null, source: RealtimeSource.TDX_THSR_ALERT, updatedAt: a.UpdateTime ?? null }));
}
