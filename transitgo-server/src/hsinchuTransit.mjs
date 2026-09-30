// 新竹縣交通地圖用的資料——議員要看的是「每一班公車（含公路客運）跟腳踏車，還有尖峰時段
// 班距夠不夠密、每個站點的密集度」。這支負責把 TDX 的原始資料組成那個頁面直接能用的形狀，
// 一天只重新抓一次（見 index.mjs 的排程），不是即時查詢——TDX 金鑰只有 5 req/min 的共用額度，
// 這裡一次要撈好幾支端點，跟即時查詢/YouBike 輪詢搶額度划不來，也沒必要（路線跟班表本來就
// 不會常常變）。
import cron from "node-cron";
import { get, tdxConfigured } from "./tdx.mjs";
import { setHsinchuTransitCache } from "./appdata.mjs";

const WEEKDAY_KEYS = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday"];
// 議員問的是「上下學上下班」——只看平日的尖峰時段，不含假日班表。
export const PEAK_WINDOWS = [
  { key: "morning", label: "早上尖峰（7-9 點）", startMin: 7 * 60, endMin: 9 * 60 },
  { key: "evening", label: "下午尖峰（16-18 點）", startMin: 16 * 60, endMin: 18 * 60 },
];

function toMin(hhmm) {
  if (typeof hhmm !== "string") return null;
  const m = /^(\d{1,2}):(\d{2})/.exec(hhmm);
  if (!m) return null;
  return Number(m[1]) * 60 + Number(m[2]);
}

/** "LINESTRING(lon lat,lon lat,...)" → [[lat,lon],...]（Leaflet 要 lat 在前）。壞掉的/空的
 * geometry 回傳空陣列，讓呼叫端自然跳過畫線，不會整支請求失敗。 */
export function parseLineStringLatLon(wkt) {
  const m = /LINESTRING\s*\(([^)]+)\)/i.exec(wkt || "");
  if (!m) return [];
  return m[1].split(",").map((pair) => {
    const [lon, lat] = pair.trim().split(/\s+/).map(Number);
    return [lat, lon];
  }).filter(([lat, lon]) => Number.isFinite(lat) && Number.isFinite(lon));
}

/** 只留週一到週五都有跑的班次（ServiceDay 全平日都是 1）——跟真正通勤族會遇到的情況一致，
 * 不含只有假日或單一天才有的特殊班。`stopUID` 為 null 時取每一班的「起站」時刻（路線整體的
 * 班距）；給一個實際的 StopUID 時，改取那一班「經過這一站」的時刻——同一班車在起站跟在某個
 * 中途站的時刻本來就不一樣，要算某個站牌自己的班距/密集度，必須用它自己的時刻，不能借用
 * 起站的。找不到那個站的 StopTimes 項目（理論上不該發生，但資料難免有缺）就跳過那一班，不
 * 讓整個站牌的統計掛掉。 */
function weekdayDeparturesAt(timetables, stopUID) {
  const out = [];
  for (const t of timetables || []) {
    if (!WEEKDAY_KEYS.every((d) => t.ServiceDay?.[d] === 1)) continue;
    const st = stopUID == null ? t.StopTimes?.[0] : t.StopTimes?.find((s) => s.StopUID === stopUID);
    const m = toMin(st?.DepartureTime ?? st?.ArrivalTime);
    if (m != null) out.push(m);
  }
  return out.sort((a, b) => a - b);
}

/** 一串（已經篩過平日、已經排序好的）分鐘數時刻，算某個時段窗口內的班次數與平均班距。
 * 班次 < 2 時 avgHeadwayMin 是 null——只有 0 或 1 班算不出「間隔」，頁面上要老實顯示
 * 「只有 N 班」而不是編一個假的班距。 */
export function headwayInWindow(departureMinutes, startMin, endMin) {
  const inWindow = (departureMinutes || []).filter((m) => m >= startMin && m <= endMin);
  if (inWindow.length < 2) return { tripCount: inWindow.length, avgHeadwayMin: null };
  const gaps = [];
  for (let i = 1; i < inWindow.length; i++) gaps.push(inWindow[i] - inWindow[i - 1]);
  const avgHeadwayMin = Math.round(gaps.reduce((s, g) => s + g, 0) / gaps.length);
  return { tripCount: inWindow.length, avgHeadwayMin };
}

/** 一個子路線（單一方向）在某個時段窗口內、從「起站」算的平日班距——沿用舊名維持相容，實際
 * 是 weekdayDeparturesAt(timetables, null) 再套 headwayInWindow 的組合。 */
export function peakHeadway(timetables, startMin, endMin) {
  return headwayInWindow(weekdayDeparturesAt(timetables, null), startMin, endMin);
}

/** 「單一站點的班次公車密集度」：把所有子路線的站牌攤開、依實體站牌（StopUID）合併——一個
 * 站牌常常同時有好幾條路線經過，議員真正關心的是「這一站」到底有多少班車，不是只看單一路線。
 * `subRoutesWithSchedule` 是 [{ routeName, kind, subRouteUID, headsign, stops, timetables }]。
 * 回傳每一站：站名/座標、經過的路線清單、平日尖峰兩個時段「所有路線合計」的班次數與平均間隔。
 * `hasScheduleData` 是 false 時代表這一站經過的路線都沒有 TDX 排班資料可查（例如只有公路客運
 * 經過）——頁面要顯示「無時刻表資料」而不是「無班次」，兩者意思差很多，不能混為一談。 */
export function buildStopIndex(subRoutesWithSchedule) {
  const byStop = new Map();
  for (const sr of subRoutesWithSchedule) {
    for (const stop of sr.stops) {
      if (!byStop.has(stop.uid)) {
        byStop.set(stop.uid, {
          uid: stop.uid, name: stop.name, lat: stop.lat, lon: stop.lon,
          routes: [], departures: [], hasScheduleData: false,
        });
      }
      const entry = byStop.get(stop.uid);
      entry.routes.push({ routeName: sr.routeName, subRouteUID: sr.subRouteUID, headsign: sr.headsign, kind: sr.kind });
      if (sr.timetables && sr.timetables.length > 0) {
        entry.hasScheduleData = true;
        entry.departures.push(...weekdayDeparturesAt(sr.timetables, stop.uid));
      }
    }
  }
  return [...byStop.values()].map((s) => {
    const sortedDepartures = s.departures.sort((a, b) => a - b);
    return {
      uid: s.uid, name: s.name, lat: s.lat, lon: s.lon,
      routeCount: new Set(s.routes.map((r) => r.routeName)).size,
      routes: s.routes,
      hasScheduleData: s.hasScheduleData,
      peak: s.hasScheduleData
        ? Object.fromEntries(PEAK_WINDOWS.map((w) => [w.key, headwayInWindow(sortedDepartures, w.startMin, w.endMin)]))
        : null,
    };
  });
}

function groupByKey(rows, key) {
  const out = new Map();
  for (const r of rows) {
    const k = r[key];
    if (!out.has(k)) out.set(k, []);
    out.get(k).push(r);
  }
  return out;
}

/** 新竹縣的縣市公車（不含公路客運）：路線＋站牌＋線型＋平日尖峰班距，一次 4 支 TDX 端點
 * （都是整個縣一次撈完，不用每條路線各打一次）。回傳 { routes, stopIndexEntries }——
 * routes 是給前端顯示用的精簡版（不含原始 Timetables，那個陣列很大，前端只需要算好的
 * peak），stopIndexEntries 是給 buildStopIndex 用的內部中間格式（含 timetables），兩者
 * 分開才不會把同一份原始班表資料在回應裡重複放兩次。 */
export async function fetchHsinchuCountyBuses() {
  const [routes, stopsRows, scheduleRows, shapeRows] = await Promise.all([
    get("v2/Bus/Route/City/HsinchuCounty"),
    get("v2/Bus/StopOfRoute/City/HsinchuCounty"),
    get("v2/Bus/Schedule/City/HsinchuCounty"),
    get("v2/Bus/Shape/City/HsinchuCounty"),
  ]);
  const stopsBySub = groupByKey(stopsRows, "SubRouteUID");
  const scheduleBySub = groupByKey(scheduleRows, "SubRouteUID");
  const shapeBySub = groupByKey(shapeRows, "SubRouteUID");

  const stopIndexEntries = [];
  const outRoutes = routes.map((route) => ({
    routeUID: route.RouteUID,
    name: route.RouteName?.Zh_tw ?? route.RouteID,
    operator: route.Operators?.[0]?.OperatorName?.Zh_tw ?? null,
    kind: "county",   // 縣市公車，跟下面的 intercity 分開標示
    subRoutes: (route.SubRoutes ?? []).map((sub) => {
      const stopRow = stopsBySub.get(sub.SubRouteUID)?.[0];
      const shapeRow = shapeBySub.get(sub.SubRouteUID)?.[0];
      const timetables = scheduleBySub.get(sub.SubRouteUID)?.[0]?.Timetables ?? [];
      const stops = (stopRow?.Stops ?? []).map((s) => ({
        uid: s.StopUID, name: s.StopName?.Zh_tw ?? "", sequence: s.StopSequence,
        lat: s.StopPosition?.PositionLat ?? null, lon: s.StopPosition?.PositionLon ?? null,
      }));
      const headsign = sub.Headsign ?? `${sub.DepartureStopNameZh}→${sub.DestinationStopNameZh}`;
      stopIndexEntries.push({
        routeName: route.RouteName?.Zh_tw ?? route.RouteID, kind: "county",
        subRouteUID: sub.SubRouteUID, headsign, stops, timetables,
      });
      return {
        subRouteUID: sub.SubRouteUID,
        direction: sub.Direction,
        headsign,
        stops,
        path: parseLineStringLatLon(shapeRow?.Geometry),
        peak: Object.fromEntries(PEAK_WINDOWS.map((w) => [w.key, peakHeadway(timetables, w.startMin, w.endMin)])),
      };
    }),
  }));
  return { routes: outRoutes, stopIndexEntries };
}

/** 會停靠新竹縣的公路客運（跨區路線，例如台灣好行、國道客運在地方的接駁段）——TDX 的公路
 * 客運資料是全國一次撈（沒有縣市範圍），用「這條路線的站牌裡，有沒有任何一站的
 * LocationCityCode 是 HSQ（新竹縣）」來篩，而不是用路線名稱猜（名稱不一定有「新竹」兩個字，
 * 但站牌本身的縣市代碼是 TDX 資料裡本來就有、可靠的欄位）。
 *
 * 全國公路客運資料量大，這支目前只抓路線＋站牌，先求「列出有哪些路線、停靠站」；尖峰班距
 * 分析（跟縣市公車一樣需要 Schedule）視額度狀況之後再擴充——公路客運多半本來就是低頻率的
 * 定時班次，不是每條都有 TDX 可查的 Schedule 資料。回傳形狀同 fetchHsinchuCountyBuses。 */
export async function fetchIntercityBusesServingHsinchu() {
  const [routes, stopsRows] = await Promise.all([
    get("v2/Bus/Route/InterCity"),
    get("v2/Bus/StopOfRoute/InterCity"),
  ]);
  const stopsBySub = groupByKey(stopsRows, "SubRouteUID");
  const hsqSubRouteUIDs = new Set(
    stopsRows
      .filter((r) => (r.Stops ?? []).some((s) => s.LocationCityCode === "HSQ"))
      .map((r) => r.SubRouteUID),
  );
  if (hsqSubRouteUIDs.size === 0) return { routes: [], stopIndexEntries: [] };

  const stopIndexEntries = [];
  const outRoutes = routes
    .map((route) => ({
      routeUID: route.RouteUID,
      name: route.RouteName?.Zh_tw ?? route.RouteID,
      operator: route.Operators?.[0]?.OperatorName?.Zh_tw ?? null,
      kind: "intercity",
      subRoutes: (route.SubRoutes ?? [])
        .filter((sub) => hsqSubRouteUIDs.has(sub.SubRouteUID))
        .map((sub) => {
          const stopRow = stopsBySub.get(sub.SubRouteUID)?.[0];
          const stops = (stopRow?.Stops ?? []).map((s) => ({
            uid: s.StopUID, name: s.StopName?.Zh_tw ?? "", sequence: s.StopSequence,
            lat: s.StopPosition?.PositionLat ?? null, lon: s.StopPosition?.PositionLon ?? null,
          }));
          const headsign = sub.Headsign ?? `${sub.DepartureStopNameZh}→${sub.DestinationStopNameZh}`;
          stopIndexEntries.push({
            routeName: route.RouteName?.Zh_tw ?? route.RouteID, kind: "intercity",
            subRouteUID: sub.SubRouteUID, headsign, stops, timetables: [],   // 見上方註解：沒有排班資料
          });
          return {
            subRouteUID: sub.SubRouteUID,
            direction: sub.Direction,
            headsign,
            stops,
            path: [],   // 公路客運的 Shape 目前不在這支的範圍內，先用站牌順序畫在地圖上就好
            peak: null,   // 見上方註解：多半沒有 TDX 排班資料可算班距
          };
        }),
    }))
    .filter((r) => r.subRoutes.length > 0);
  return { routes: outRoutes, stopIndexEntries };
}

/** 三者一起撈，任一部分失敗都不讓其他部分陪葬——公路客運資料量大、比較容易踩到額度或格式
 * 問題，縣市公車那部分（比較核心、已經驗證過欄位）不應該因此整個開天窗。 */
export async function fetchHsinchuTransitOverview() {
  const result = { countyBuses: [], intercityBuses: [], stops: [], errors: [] };
  let countyEntries = [];
  let intercityEntries = [];
  try {
    const { routes, stopIndexEntries } = await fetchHsinchuCountyBuses();
    result.countyBuses = routes;
    countyEntries = stopIndexEntries;
  } catch (e) {
    result.errors.push(`countyBuses: ${e.message}`);
  }
  try {
    const { routes, stopIndexEntries } = await fetchIntercityBusesServingHsinchu();
    result.intercityBuses = routes;
    intercityEntries = stopIndexEntries;
  } catch (e) {
    result.errors.push(`intercityBuses: ${e.message}`);
  }
  try {
    result.stops = buildStopIndex([...countyEntries, ...intercityEntries]);
  } catch (e) {
    result.errors.push(`stops: ${e.message}`);
  }
  result.generatedAt = new Date().toISOString();
  return result;
}

/** 靜態路線/班表資料，一天重新抓一次就夠——議員的頁面讀的是 setHsinchuTransitCache 存下來
 * 的成品，不是每個請求都重新打 TDX。用 HSINCHU_TRANSIT_ENABLED=1 開關，預設不啟用（免得每個
 * 部署都平白多跑一份用不到的排程、佔掉共用的 TDX 額度）。 */
export function startHsinchuTransitPoller() {
  if (process.env.HSINCHU_TRANSIT_ENABLED !== "1") return;
  if (!tdxConfigured()) {
    console.log("[hsinchu-transit] TDX not configured — skipping");
    return;
  }
  const run = async () => {
    const overview = await fetchHsinchuTransitOverview();
    await setHsinchuTransitCache(overview);
    console.log(
      `[hsinchu-transit] cached ${overview.countyBuses.length} county routes, ` +
      `${overview.intercityBuses.length} intercity routes, ${overview.stops.length} stops` +
      (overview.errors.length ? ` (errors: ${overview.errors.join(" | ")})` : ""),
    );
  };
  run().catch((e) => console.warn(`[hsinchu-transit] initial run failed: ${e.message}`));
  cron.schedule("40 4 * * *", () => run().catch((e) => console.warn(`[hsinchu-transit] run failed: ${e.message}`)));
  console.log("[hsinchu-transit] polling once, then daily");
}
