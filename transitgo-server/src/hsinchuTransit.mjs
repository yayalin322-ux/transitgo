// 新竹縣交通地圖用的資料——議員要看的是「每一班公車（含公路客運）跟腳踏車，還有尖峰時段
// 班距夠不夠密」。這支負責把 TDX 的原始資料組成那個頁面直接能用的形狀，一天只重新抓一次
// （見 index.mjs 的排程），不是即時查詢——TDX 金鑰只有 5 req/min 的共用額度，這裡一次要撈
// 好幾支端點，跟即時查詢/YouBike 輪詢搶額度划不來，也沒必要（路線跟班表本來就不會常常變）。
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

/** 一個子路線（單一方向）在某個時段窗口內的平日班距——只算週一到週五都有跑的班次
 * （ServiceDay 全平日都是 1），跟真正通勤族會遇到的情況一致，不含只有假日或單一天的特殊班。
 * 回傳 tripCount（那個時段內的班次數）跟 avgHeadwayMin（平均班距，班次 < 2 時是 null，
 * 因為只有 0 或 1 班算不出「間隔」，頁面上要老實顯示「只有 N 班」而不是編一個假的班距）。 */
export function peakHeadway(timetables, startMin, endMin) {
  const departures = (timetables || [])
    .filter((t) => WEEKDAY_KEYS.every((d) => t.ServiceDay?.[d] === 1))
    .map((t) => toMin(t.StopTimes?.[0]?.DepartureTime))
    .filter((m) => m != null && m >= startMin && m <= endMin)
    .sort((a, b) => a - b);
  if (departures.length < 2) return { tripCount: departures.length, avgHeadwayMin: null };
  const gaps = [];
  for (let i = 1; i < departures.length; i++) gaps.push(departures[i] - departures[i - 1]);
  const avgHeadwayMin = Math.round(gaps.reduce((s, g) => s + g, 0) / gaps.length);
  return { tripCount: departures.length, avgHeadwayMin };
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
 * （都是整個縣一次撈完，不用每條路線各打一次）。 */
export async function fetchHsinchuCountyBuses() {
  const [routes, stopsRows, scheduleRows, shapeRows] = await Promise.all([
    get("v2/Bus/Route/City/HsinchuCounty?$format=JSON"),
    get("v2/Bus/StopOfRoute/City/HsinchuCounty?$format=JSON"),
    get("v2/Bus/Schedule/City/HsinchuCounty?$format=JSON"),
    get("v2/Bus/Shape/City/HsinchuCounty?$format=JSON"),
  ]);
  const stopsBySub = groupByKey(stopsRows, "SubRouteUID");
  const scheduleBySub = groupByKey(scheduleRows, "SubRouteUID");
  const shapeBySub = groupByKey(shapeRows, "SubRouteUID");

  return routes.map((route) => ({
    routeUID: route.RouteUID,
    name: route.RouteName?.Zh_tw ?? route.RouteID,
    operator: route.Operators?.[0]?.OperatorName?.Zh_tw ?? null,
    kind: "county",   // 縣市公車，跟下面的 intercity 分開標示
    subRoutes: (route.SubRoutes ?? []).map((sub) => {
      const stopRow = stopsBySub.get(sub.SubRouteUID)?.[0];
      const shapeRow = shapeBySub.get(sub.SubRouteUID)?.[0];
      const timetables = scheduleBySub.get(sub.SubRouteUID)?.[0]?.Timetables ?? [];
      return {
        subRouteUID: sub.SubRouteUID,
        direction: sub.Direction,
        headsign: sub.Headsign ?? `${sub.DepartureStopNameZh}→${sub.DestinationStopNameZh}`,
        stops: (stopRow?.Stops ?? []).map((s) => ({
          uid: s.StopUID, name: s.StopName?.Zh_tw ?? "", sequence: s.StopSequence,
          lat: s.StopPosition?.PositionLat ?? null, lon: s.StopPosition?.PositionLon ?? null,
        })),
        path: parseLineStringLatLon(shapeRow?.Geometry),
        peak: Object.fromEntries(PEAK_WINDOWS.map((w) => [w.key, peakHeadway(timetables, w.startMin, w.endMin)])),
      };
    }),
  }));
}

/** 會停靠新竹縣的公路客運（跨區路線，例如台灣好行、國道客運在地方的接駁段）——TDX 的公路
 * 客運資料是全國一次撈（沒有縣市範圍），用「這條路線的站牌裡，有沒有任何一站的
 * LocationCityCode 是 HSQ（新竹縣）」來篩，而不是用路線名稱猜（名稱不一定有「新竹」兩個字，
 * 但站牌本身的縣市代碼是 TDX 資料裡本來就有、可靠的欄位）。
 *
 * 全國公路客運資料量大，這支目前只抓路線＋站牌，先求「列出有哪些路線、停靠站」；尖峰班距
 * 分析（跟縣市公車一樣需要 Schedule）視額度狀況之後再擴充——公路客運多半本來就是低頻率的
 * 定時班次，不是每條都有 TDX 可查的 Schedule 資料。 */
export async function fetchIntercityBusesServingHsinchu() {
  const [routes, stopsRows] = await Promise.all([
    get("v2/Bus/Route/InterCity?$format=JSON"),
    get("v2/Bus/StopOfRoute/InterCity?$format=JSON"),
  ]);
  const stopsBySub = groupByKey(stopsRows, "SubRouteUID");
  const hsqSubRouteUIDs = new Set(
    stopsRows
      .filter((r) => (r.Stops ?? []).some((s) => s.LocationCityCode === "HSQ"))
      .map((r) => r.SubRouteUID),
  );
  if (hsqSubRouteUIDs.size === 0) return [];

  return routes
    .map((route) => ({
      routeUID: route.RouteUID,
      name: route.RouteName?.Zh_tw ?? route.RouteID,
      operator: route.Operators?.[0]?.OperatorName?.Zh_tw ?? null,
      kind: "intercity",
      subRoutes: (route.SubRoutes ?? [])
        .filter((sub) => hsqSubRouteUIDs.has(sub.SubRouteUID))
        .map((sub) => {
          const stopRow = stopsBySub.get(sub.SubRouteUID)?.[0];
          return {
            subRouteUID: sub.SubRouteUID,
            direction: sub.Direction,
            headsign: sub.Headsign ?? `${sub.DepartureStopNameZh}→${sub.DestinationStopNameZh}`,
            stops: (stopRow?.Stops ?? []).map((s) => ({
              uid: s.StopUID, name: s.StopName?.Zh_tw ?? "", sequence: s.StopSequence,
              lat: s.StopPosition?.PositionLat ?? null, lon: s.StopPosition?.PositionLon ?? null,
            })),
            path: [],   // 公路客運的 Shape 目前不在這支的範圍內，先用站牌順序畫在地圖上就好
            peak: null,   // 見上方註解：多半沒有 TDX 排班資料可算班距
          };
        }),
    }))
    .filter((r) => r.subRoutes.length > 0);
}

/** 兩者一起撈，任一半失敗都不讓另一半陪葬——公路客運資料量大、比較容易踩到額度或格式問題，
 * 縣市公車那半（比較核心、已經驗證過欄位）不應該因此整個開天窗。 */
export async function fetchHsinchuTransitOverview() {
  const result = { countyBuses: [], intercityBuses: [], errors: [] };
  try {
    result.countyBuses = await fetchHsinchuCountyBuses();
  } catch (e) {
    result.errors.push(`countyBuses: ${e.message}`);
  }
  try {
    result.intercityBuses = await fetchIntercityBusesServingHsinchu();
  } catch (e) {
    result.errors.push(`intercityBuses: ${e.message}`);
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
      `${overview.intercityBuses.length} intercity routes` +
      (overview.errors.length ? ` (errors: ${overview.errors.join(" | ")})` : ""),
    );
  };
  run().catch((e) => console.warn(`[hsinchu-transit] initial run failed: ${e.message}`));
  cron.schedule("40 4 * * *", () => run().catch((e) => console.warn(`[hsinchu-transit] run failed: ${e.message}`)));
  console.log("[hsinchu-transit] polling once, then daily");
}
