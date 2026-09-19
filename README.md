# 交通即時查 (TransitGo)

iOS App（SwiftUI）串接 [TDX 運輸資料流通服務](https://tdx.transportdata.tw/) 與臺北市公車車上擁擠度開放資料。

## 功能

| 分頁 / 元件 | 內容 |
|------|------|
| 公車 / 客運 | **全台一次搜尋**（含公路客運），結果標示所屬地區；路線站序、即時到站、車輛位置、**車牌**、**低底盤 ♿ 圖示**、**雙北車上擁擠度**；ⓘ 路線資訊：**營運業者**、票價、路線圖、**班距時刻表** |
| 附近 | **地圖＋清單**，可切 公車 / YouBike / 捷運。公車站牌看經過路線與即時到站；YouBike 看即時可借可還；捷運看即時到站 |
| 軌道 | 台鐵／高鐵：選起訖站與出發時間（到分）查時刻，點班次看**各站到開時刻**與即時誤點。捷運：系統／路線／車站瀏覽＋即時到站看板 |
| 車票 | 兩種新增方式：查詢車次，或**直接輸入車次**＋起訖站＋座位；台鐵顯示即時誤點；一鍵開始追蹤 |
| 最愛 | 收藏路線（SwiftData 本機儲存） |
| 追蹤行程（靈動島） | 公車（到站倒數／車牌／擁擠度／座位）、列車（發車抵達倒數／誤點／車廂座位）、YouBike（即時可借可還）、捷運（下班車倒數／往方向） |
| 主畫面小工具 | 「時刻表」小工具（小 / 中），可設定台鐵、高鐵、公車站牌、**捷運到站**或 **YouBike** |
| 即時通知 | 軌道分頁右上鈴鐺。台鐵／高鐵營運異常自動顯示（正常不顯示）；高鐵座位狀態 O/L/X；透過自架後端可推播、發佈捷運事件公告、回收 App 錯誤回報 |

## 自架後端（選用）

`transitgo-server/` — 見該資料夾 README。功能：APNs 推播、發佈公告（含 `/admin` 網頁管理台）、
自動輪詢台鐵／高鐵營運異常並推播、收集 App 錯誤回報。
App 端在 `Config/Secrets.xcconfig` 填 `BACKEND_HOST`（主機名，不含 `http(s)://`）即啟用；留空則只保留「直接抓 TDX 顯示異常」。

## 開始開發

需求：Xcode 16+、[XcodeGen](https://github.com/yonyz/XcodeGen)（`brew install xcodegen`）。

```bash
cp Config/Secrets.example.xcconfig Config/Secrets.xcconfig   # 填入 TDX 金鑰
xcodegen generate
open TransitGo.xcodeproj
```

到 <https://tdx.transportdata.tw/user/dataservice/key> 申請金鑰。`Config/Secrets.xcconfig` 已 gitignore。

## 交通核心：路線規劃、即時資訊、行程導航

### 目前支援的交通方式（以及資料來源）

| 運具 | 路線規劃 | 即時資訊 | 備註 |
|---|---|---|---|
| 步行 | ✅（直線距離 ÷ 1.3 m/s 的估計，非街道路網） | — | 起訖點用 Virtual Origin/Destination 接到最近站點 |
| 公車 | ✅ 已匯入的縣市：新竹市/縣、桃園、臺北、新北、公路客運(THB) | ✅ 到站時間、公告；**無誤點數字** | TDX 到站資料沒有時刻表；站間行駛時間是「距離 ÷ 15 km/h」的估計 |
| 捷運 | ✅ 台北(TRTC)、桃園(TYMC)、新北(NTMC)、高雄(KRTC)：真實 S2STravelTime、班距、轉乘時間 | ✅ 桃園有下幾班；台北只有「進站中」；公告 | 反方向沿用正方向行駛時間（TDX 只發布單向）；高雄輕軌(KLRT)因資料不可信被拒收 |
| 台鐵 | ✅ 真實時刻表 | ✅ 到站、**誤點分鐘**、公告 | 需要該班次車次號 |
| 高鐵 | ✅ 真實時刻表 | ❌ 無即時到站/誤點來源（僅公告） | 明確回傳 `not_supported` |
| YouBike | ✅ 站點為 graph 節點，租/還車限制由即時可借還數判斷 | ✅ 可借/可還（來自後端輪詢快取，約 2 分鐘） | 騎乘距離＝直線×1.3、車速 4 m/s、租還各 30 s，**皆為估計**並在回應標示 |

### 路線規劃架構

```
View ─ ViewModel ─ UnifiedRoutingService ─ MultimodalRoutingService ─▶ POST /api/v1/routes
                         │                                              │
                         │                            planRoute: Virtual Origin/Destination（SpatialIndex）
                         │                            → 5 種 profile 各跑一次 Time-Dependent A*
                         │                            → 去重、dominance 過濾、標籤（最快/均衡/少轉乘/少走路）
                         └─ 舊的同城公車/捷運規劃器：僅在引擎無資料的區域作為後備
```

- `UnifiedRoutingService` 是 App 端唯一的「查路線」入口，回傳統一的 `RouteResult`（每段是 WALK/BUS/MRT/TRA/HSR/BIKE）。
- 票價：**沒有資料來源**，所有路線 `fare = null`，也不會產生「最便宜」標籤。
- YouBike 不會讓其他路線消失：有 bike 的路線勝出時，會另外搜一次「不含 bike」，讓公車等路線仍是候選。

### Graph 架構

- 記憶體內的 Multimodal Graph：STOP/STATION 節點＋時間相依邊（真實時刻表）、班距邊、捷運轉乘邊、YouBike 邊。
- 由 `POST /v1/admin/routing/rebuild` 建置（一次一個 feed，避免超出 Render 512 MB），序列化為 gzip artifact 存到 Supabase Storage，重啟時載入。
- YouBike 層：每站一個節點 `BIKE_<city>:<uid>`，只有名稱/座標（**不含可借還數**）；站與站之間只連最近 6 站（上限 2,500 m，用 SpatialIndex）；與既有站點只在 300 m 內才連步行邊。
- **變更 graph（例如新增運具）後，需要在部署後重建 graph 才會生效。**

### Realtime 架構

```
RealtimeTransitService（App，唯一入口，15 s 快取＋同請求共用）
        └▶ /v1/realtime/route · /v1/realtime/bus/stops · /v1/bike/availability
              └▶ createRealtimeService（後端：TTL 快取、負快取、in-flight 共用、逾時 4 s）
                    └▶ TDX（憑證只在後端）
```

- 即時資料只是疊在靜態路線上的選擇性資訊：失敗時顯示「即時資訊暫時無法取得」，**不影響路線是否存在**；時刻表時間永遠不會被即時資料覆蓋。
- 失敗對應：逾時→timeout、429→rate_limited、401/403→credential、空→no_data。
- YouBike 可借還：後端讀 poller 的共用快取（不是每次查路線都打上游）；資料過舊(>10 分鐘)或讀不到＝「未知」，路線保留並標示。

### 常用旅程 / 最近搜尋 / 行程導航

- **常用旅程**（SwiftData `FavoriteTrip`）存的是「起點、終點、偏好」，**不存路線**；每次開啟都重新規劃並重新查即時。`RecentTrip` 最多 10 筆。SwiftData schema 有正式的 V1→V2 migration。
- **行程導航**（`Features/Navigation`）：`TripNavigationService` → `TripEngine`（純邏輯狀態機）。依定位自動切換路段、轉乘提醒（下車前提醒）、抵達判定（需連續多筆定位、過濾低精度）、需要時才重新規劃（偏離路線/錯過班次；有冷卻與次數上限，不會每次定位都重算）、離線沿用最近一次路線、App 被關閉後可恢復。定位沿用既有的 `NavigationLocationTracker`，只有使用者按「開始行程」時才要求定位權限。

### 手動驗證工具（不屬於 `npm test`）

`transitgo-server/test/` 內的 `live_realtime.mjs`、`live_bike_routing.mjs`、`bike_density_probe.mjs`、`bike_proximity_probe.mjs`、`capture_bike_fixture.mjs`、`local_backend.mjs`：打真實 TDX / 政府 YouBike 資料，或起一個本機後端（真實 TDX 捷運資料＋即時 TDX）供 App 測試。需要 `.env`（不入版控）。

## 架構

```
TransitGo/
├── App/                入口、Tab 根畫面
├── Shared/             BusTripAttributes（Live Activity 屬性，App 與 Widget 共用）
├── Core/
│   ├── Networking/     TDXAuth、TDXClient、共用 DTO
│   ├── Location/       LocationManager（單次定位）
│   ├── MultimodalRoutingService / RealtimeTransitService   後端路線與即時的 App 端入口
│   └── Formatters
└── Features/
    ├── Bus/            UnifiedRoutingService、轉乘規劃、全台搜尋、附近站牌、擁擠度
    ├── Rail/           台鐵 / 高鐵時刻查詢
    ├── Bike/           BikeStationService（附近 / 可借還 / 路線候選站）
    ├── Favorites/      常用旅程、最近搜尋、舊有收藏（依種類分區）
    ├── Navigation/     TripSession / TripEngine / TripNavigationService / 導航畫面
    └── Tracking/       TripTracker（Live Activity + 到站推播）
TransitGoWidgets/       TimetableWidget、BusTripLiveActivity
TransitGoTests/         單元與整合測試（xcodebuild test）
transitgo-server/       後端（Node/Express）：路線引擎、即時、YouBike、公告/推播
```

## 測試

```bash
cd transitgo-server && npm test          # 後端：路線、graph、MRT、即時、YouBike 等
xcodebuild test -project TransitGo.xcodeproj -scheme TransitGo -destination 'platform=iOS Simulator,name=iPhone 17'
```

## 已知限制

**資料**
- **沒有票價資料**：所有路線 `fare = null`；「最低票價」偏好目前不可選。
- **公車沒有誤點數字**（TDX 到站資料無時刻表）；公車行駛時間、步行、騎乘距離與時間都是**估計**，回應中有標示。
- **高鐵沒有即時到站/誤點**；台北捷運即時只有「進站中」的列車（空結果不代表沒車）；桃園捷運分鐘單位為推論；台鐵「停駛」狀態依文件實作但尚未在正式資料出現過。
- 即時公告的原因/影響代碼語意未公開，只顯示 TDX 的標題與說明。
- 公車只涵蓋已匯入的縣市；其他地區由舊的同城規劃器後備。
- YouBike 可借還約每 2 分鐘更新，不是秒級；其他縣市（非直營市官方 feed）走 TDX，未逐縣確認。

**App / 導航**
- `client_secret` 內嵌於 App 且已被 TDX 拒絕（401）：仍直接呼叫 TDX 的舊功能（首頁附近站牌、站名搜尋等）目前會顯示認證失敗，應改走後端代理。
- 行程導航目前只完整支援 **App 前景**；背景定位 capability 已存在（TripKeepAlive）但導航尚未在背景驗證。地下段（捷運）沒有 GPS，依時刻表推算並標示「推測」；地圖上是各段端點的連線，沒有車輛實際行駛路徑。
- **尚未在真實 iPhone 上實測**定位與導航（只有模擬器與單元/整合測試）。
- 「設定 → 顯示示範資料」是使用者自行開啟的公車擁擠度示範資料（預設關閉，會標示為示範），不屬於路線/即時核心。
- 擁擠度僅雙北聯營公車有資料；全台公車搜尋為逐縣市查詢，忙碌時可能不完整。

**尚未支援**
- 航空、船運（graph 模型有 FERRY 類型但沒有資料）、完整票價、指定出發時間/週期排程的常用旅程、推播型導航提醒、背景導航。
