// 新竹縣交通地圖的純邏輯部分（不連 TDX，網路呼叫的部分見 hsinchuTransit.mjs 本身的註解與
// 手動驗證紀錄）：WKT 路線幾何解析、平日尖峰班距計算、單一站點的班次密集度合併。
import { parseLineStringLatLon, peakHeadway, headwayInWindow, buildStopIndex, PEAK_WINDOWS } from "../src/hsinchuTransit.mjs";

let failed = false;
function check(label, cond, detail) { console.log(`${cond ? "PASS" : "FAIL"} - ${label}`); if (!cond) { failed = true; if (detail) console.log("   ", detail); } }

// ---- parseLineStringLatLon ----
check("parses a normal WKT LINESTRING into [lat,lon] pairs (note lon/lat swap)",
  JSON.stringify(parseLineStringLatLon("LINESTRING(121.01 24.83,121.02 24.84)")) === JSON.stringify([[24.83, 121.01], [24.84, 121.02]]));
check("a missing/empty geometry returns an empty array, not a throw", JSON.stringify(parseLineStringLatLon(null)) === "[]");
check("garbage input returns an empty array", JSON.stringify(parseLineStringLatLon("not a linestring")) === "[]");
check("a non-numeric coordinate pair is dropped rather than producing NaN", JSON.stringify(parseLineStringLatLon("LINESTRING(121.01 24.83,bad pair)")) === JSON.stringify([[24.83, 121.01]]));

// ---- headwayInWindow / peakHeadway ----
const weekday = { Sunday: 0, Monday: 1, Tuesday: 1, Wednesday: 1, Thursday: 1, Friday: 1, Saturday: 0 };
const weekendOnly = { Sunday: 1, Monday: 0, Tuesday: 0, Wednesday: 0, Thursday: 0, Friday: 0, Saturday: 1 };
const trip = (departureTime, serviceDay = weekday, stopUID = "S1") => ({ ServiceDay: serviceDay, StopTimes: [{ StopUID: stopUID, DepartureTime: departureTime }] });

check("headwayInWindow: computes the average gap between consecutive departures", headwayInWindow([390, 420, 450, 480, 510, 570], 420, 540).avgHeadwayMin === 30);
check("headwayInWindow: a single time in the window can't have a headway — tripCount 1, avgHeadwayMin null", JSON.stringify(headwayInWindow([420], 420, 540)) === JSON.stringify({ tripCount: 1, avgHeadwayMin: null }));
check("headwayInWindow: zero times in the window", JSON.stringify(headwayInWindow([], 420, 540)) === JSON.stringify({ tripCount: 0, avgHeadwayMin: null }));

{
  const r = peakHeadway([trip("06:50"), trip("07:00"), trip("07:30"), trip("08:00"), trip("08:30"), trip("09:30")], 7 * 60, 9 * 60);
  check("peakHeadway counts only trips inside the window", r.tripCount === 4);
  check("peakHeadway computes the average gap", r.avgHeadwayMin === 30);
}
{
  const r = peakHeadway([trip("07:00", weekendOnly), trip("08:00", weekendOnly)], 7 * 60, 9 * 60);
  check("peakHeadway excludes weekend-only trips from the weekday peak analysis", r.tripCount === 0);
}
check("PEAK_WINDOWS covers the morning and evening commute", PEAK_WINDOWS.map((w) => w.key).join(",") === "morning,evening");

// ---- buildStopIndex ----
{
  // 兩條不同路線都經過同一個實體站牌（同一個 StopUID），但各自的時刻表在「這一站」的時刻
  // 不一樣（不是起站時刻）——密集度要把兩條路線的班次「合計」在一起，用的是它們各自在這一站
  // 的到站時刻，不是各自的起站時刻。
  const routeA = {
    routeName: "A線", kind: "county", subRouteUID: "A01", headsign: "甲→乙",
    stops: [{ uid: "STOP1", name: "共同站", lat: 24.8, lon: 121.0, sequence: 2 }],
    timetables: [
      { ServiceDay: weekday, StopTimes: [{ StopUID: "ORIGIN", DepartureTime: "07:00" }, { StopUID: "STOP1", ArrivalTime: "07:10", DepartureTime: "07:10" }] },
      { ServiceDay: weekday, StopTimes: [{ StopUID: "ORIGIN", DepartureTime: "07:40" }, { StopUID: "STOP1", ArrivalTime: "07:50", DepartureTime: "07:50" }] },
    ],
  };
  const routeB = {
    routeName: "B線", kind: "county", subRouteUID: "B01", headsign: "丙→丁",
    stops: [{ uid: "STOP1", name: "共同站", lat: 24.8, lon: 121.0, sequence: 5 }],
    timetables: [
      { ServiceDay: weekday, StopTimes: [{ StopUID: "STOP1", ArrivalTime: "07:20", DepartureTime: "07:20" }] },
      { ServiceDay: weekday, StopTimes: [{ StopUID: "STOP1", ArrivalTime: "08:00", DepartureTime: "08:00" }] },
    ],
  };
  const index = buildStopIndex([routeA, routeB]);
  check("one physical stop shared by two routes produces one entry, not two", index.length === 1);
  const stop = index[0];
  check("the stop carries both routes' names", stop.routes.map((r) => r.routeName).sort().join(",") === "A線,B線");
  check("routeCount counts distinct route names", stop.routeCount === 2);
  check("the combined morning peak merges both routes' actual arrival times at THIS stop (07:10,07:20,07:50,08:00 → 4 trips)", stop.peak.morning.tripCount === 4);
  // 合併排序後是 07:10, 07:20, 07:50, 08:00 → 間隔 10, 30, 10 分鐘，平均 (10+30+10)/3 ≈ 16.67 → 17。
  check("...average headway across the merged, sorted times", stop.peak.morning.avgHeadwayMin === 17);
  check("hasScheduleData is true when at least one serving route has a real timetable", stop.hasScheduleData === true);
}
{
  // 只有沒有排班資料的路線（公路客運）經過的站——不能顯示「無班次」，要清楚標示「沒有時刻表
  // 資料可查」，兩者意思差很多。
  const intercityOnly = {
    routeName: "5700", kind: "intercity", subRouteUID: "570001", headsign: "竹北→台北",
    stops: [{ uid: "STOP2", name: "只有客運經過", lat: 24.7, lon: 121.1, sequence: 1 }],
    timetables: [],
  };
  const index = buildStopIndex([intercityOnly]);
  check("a stop only served by schedule-less (intercity) routes has hasScheduleData false", index[0].hasScheduleData === false);
  check("...and peak is null, not a fake zero-trip result", index[0].peak === null);
  check("...but the route is still listed (we do know it stops there)", index[0].routes.length === 1);
}
{
  // 一個站的「起站」（沒有自己的 StopUID 項目在時刻表裡，例如資料本身有缺）的班次應該被
  // 忽略，不會被誤算成這一站的班次。
  const missingStopTime = {
    routeName: "C線", kind: "county", subRouteUID: "C01", headsign: "戊→己",
    stops: [{ uid: "STOP3", name: "站", lat: 24.9, lon: 121.2, sequence: 1 }],
    timetables: [{ ServiceDay: weekday, StopTimes: [{ StopUID: "OTHER_STOP", DepartureTime: "07:00" }] }],
  };
  const index = buildStopIndex([missingStopTime]);
  check("a trip missing this stop's own StopTimes entry contributes nothing (not silently using another stop's time)", index[0].peak.morning.tripCount === 0);
}

process.exit(failed ? 1 : 0);
