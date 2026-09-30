// 新竹縣交通地圖的純邏輯部分（不連 TDX，網路呼叫的部分見 hsinchuTransit.mjs 本身的註解與
// 手動驗證紀錄）：WKT 路線幾何解析、平日尖峰班距計算。
import { parseLineStringLatLon, peakHeadway, PEAK_WINDOWS } from "../src/hsinchuTransit.mjs";

let failed = false;
function check(label, cond, detail) { console.log(`${cond ? "PASS" : "FAIL"} - ${label}`); if (!cond) { failed = true; if (detail) console.log("   ", detail); } }

// ---- parseLineStringLatLon ----
check("parses a normal WKT LINESTRING into [lat,lon] pairs (note lon/lat swap)",
  JSON.stringify(parseLineStringLatLon("LINESTRING(121.01 24.83,121.02 24.84)")) === JSON.stringify([[24.83, 121.01], [24.84, 121.02]]));
check("a missing/empty geometry returns an empty array, not a throw", JSON.stringify(parseLineStringLatLon(null)) === "[]");
check("garbage input returns an empty array", JSON.stringify(parseLineStringLatLon("not a linestring")) === "[]");
check("a non-numeric coordinate pair is dropped rather than producing NaN", JSON.stringify(parseLineStringLatLon("LINESTRING(121.01 24.83,bad pair)")) === JSON.stringify([[24.83, 121.01]]));

// ---- peakHeadway ----
const weekday = { Sunday: 0, Monday: 1, Tuesday: 1, Wednesday: 1, Thursday: 1, Friday: 1, Saturday: 0 };
const weekendOnly = { Sunday: 1, Monday: 0, Tuesday: 0, Wednesday: 0, Thursday: 0, Friday: 0, Saturday: 1 };
const trip = (departureTime, serviceDay = weekday) => ({ ServiceDay: serviceDay, StopTimes: [{ DepartureTime: departureTime }] });

{
  // 4 班在 7-9 點窗口內，間隔 30/30/30 分鐘 → 平均班距 30。
  const r = peakHeadway([trip("06:50"), trip("07:00"), trip("07:30"), trip("08:00"), trip("08:30"), trip("09:30")], 7 * 60, 9 * 60);
  check("counts only trips inside the window", r.tripCount === 4);
  check("computes the average gap between consecutive departures", r.avgHeadwayMin === 30);
}
{
  const r = peakHeadway([trip("07:00")], 7 * 60, 9 * 60);
  check("a single trip in the window can't have a headway — reports tripCount 1, avgHeadwayMin null (not a made-up number)", r.tripCount === 1 && r.avgHeadwayMin === null);
}
{
  const r = peakHeadway([], 7 * 60, 9 * 60);
  check("zero trips in the window", r.tripCount === 0 && r.avgHeadwayMin === null);
}
{
  // 只有假日班次的行程，在平日尖峰分析裡不該被算進去——議員問的是通勤，不是週末。
  const r = peakHeadway([trip("07:00", weekendOnly), trip("08:00", weekendOnly)], 7 * 60, 9 * 60);
  check("weekend-only trips are excluded from the weekday peak analysis", r.tripCount === 0);
}
{
  // 一班平日固定跑、一班只有週日跑——只有前者該被算進去。
  const r = peakHeadway([trip("07:00", weekday), trip("07:30", weekendOnly), trip("08:00", weekday)], 7 * 60, 9 * 60);
  check("a mixed list only counts the genuinely weekday trips", r.tripCount === 2 && r.avgHeadwayMin === 60);
}
check("PEAK_WINDOWS covers the morning and evening commute", PEAK_WINDOWS.map((w) => w.key).join(",") === "morning,evening");

process.exit(failed ? 1 : 0);
