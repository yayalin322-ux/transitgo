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

## 架構

```
TransitGo/
├── App/                入口、Tab 根畫面
├── Shared/             BusTripAttributes（Live Activity 屬性，App 與 Widget 共用）
├── Core/
│   ├── Networking/     TDXAuth（OAuth2）、TDXClient（含 429 重試）、共用 DTO
│   ├── Location/       LocationManager
│   └── Formatters
└── Features/
    ├── Bus/            全台搜尋（BusScope 扇出）、站序詳情、附近站牌、擁擠度資料源
    ├── Rail/           台鐵 / 高鐵時刻查詢
    ├── Tracking/       TripTracker（Live Activity + 到站推播）、TrackTripSheet
    └── Favorites/      SwiftData 收藏
TransitGoWidgets/       TimetableWidget（AppIntent 設定）、BusTripLiveActivity（靈動島）
```

## 已知限制

- **擁擠度資料源**：雙北聯營公車來自臺北市公車動態資訊中心的 `BusSeatEvent.gz`（gzip，App 內自行解壓，約每分鐘更新）。公路客運與其他縣市無擁擠度資料。若來源中斷可於「設定」開啟示範資料。
- **車牌**：公路客運的到站 API 直接帶車牌；各縣市市區公車的到站 API 不帶車牌，改由「車輛動態」比對後顯示。
- **全台搜尋**：TDX 無單一全國端點，App 對 22 縣市 + 公路客運逐一查詢（限流 3 併發、429 自動重試），忙碌時會顯示「結果可能不完整」，可用右上角篩選單一地區確保完整。
- `client_secret` 內嵌於 App，正式上架前應改後端代理 token。
- 台鐵時刻為「當日時刻表」，非即時誤點資訊。

## 待辦

- [ ] 台鐵誤點 / 高鐵剩餘座位（`AvailableSeatStatusList`）
- [ ] 路線地圖（MapKit + `BusShape`）
- [ ] 全台路線清單本機快取，改為離線搜尋（免逐縣市查詢）
- [ ] 收藏公車站牌
- [ ] 後端 token 代理
