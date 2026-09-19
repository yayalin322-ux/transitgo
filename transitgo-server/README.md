# TransitGo Server

小型後端：推播、公告、App 回報、以及自動抓台鐵／高鐵營運異常。

## 快速啟動

```bash
cd transitgo-server
cp .env.example .env
$EDITOR .env          # 至少設 ADMIN_TOKEN；要自動台鐵高鐵公告就填 TDX_CLIENT_ID/SECRET
npm install
npm start
```

啟動後：
- 管理台：<http://localhost:8787/admin>（輸入 `ADMIN_TOKEN`）
- 健康檢查：`GET /v1/health`

沒有 Apple 開發者帳號也能跑 —— APNs 欄位留空會進 **DRY RUN**，推播只寫 log；App 端的輪詢仍會拿到公告。

## API

| 方法 | 路徑 | 說明 |
|------|------|------|
| `POST` | `/v1/devices` | App 註冊裝置 `{ token, platform, appVersion }` |
| `GET`  | `/v1/announcements?since=<ISO>` | App 取公告（僅生效中、未過期） |
| `POST` | `/v1/reports` | App 回報 `{ type, message, context?, appVersion?, os? }`（每 IP 每分鐘 20 次） |
| `POST` | `/v1/admin/announcements` | 發佈公告 + 推播（需 `Authorization: Bearer <ADMIN_TOKEN>`） |
| `DELETE` | `/v1/admin/announcements/:id` | 下架公告 |
| `GET`  | `/v1/admin/announcements` | 全部公告（含已下架） |
| `GET`  | `/v1/admin/reports?limit=` | 看 App 回報 |

### 路線 / 即時 / YouBike（另見專案根目錄 README 的架構說明）

| 方法 | 路徑 | 說明 |
|------|------|------|
| `POST` | `/api/v1/routes` | 多模式路線規劃（WALK/BUS/MRT/TRA/HSR/BIKE）；可帶 `options.allowBike:false`、`options.bikeUnavailable:"exclude"` |
| `GET`  | `/v1/routing/coverage` | graph 目前真正涵蓋的公車/軌道/捷運/YouBike |
| `POST` | `/v1/realtime/route` | 對一條已規劃路線的即時疊加（每段可用性、延誤、公告）；失敗回 `available:false` 與原因，不回錯誤碼 |
| `GET`  | `/v1/realtime/bus/stops?scope=&stops=` | 附近站牌的即時到站（最多 12 站） |
| `GET`  | `/v1/realtime/capabilities` | 各運具真實有的即時資料、TTL 與限制 |
| `GET`  | `/v1/bike/nearby` · `/v1/bike/search` | YouBike 附近站與名稱搜尋（共用快取） |
| `GET`  | `/v1/bike/availability?stations=` | 指定站（`BIKE_<city>:<uid>`）的可借/可還 |
| `GET`  | `/v1/bike/candidates?lat&lon&role=rent\|return` | 路線規劃用的候選站（與規劃器同一份 graph 索引與可借還快照） |
| `POST` | `/v1/admin/routing/rebuild` | 重建 graph（需 admin；graph 變更後必須執行） |

TDX 憑證只存在後端環境變數（`TDX_ROUTING_CLIENT_ID/SECRET`），App 不需要也不應該持有。

### 測試

```bash
npm test     # 全部套件（路線、graph、MRT、即時、YouBike…），使用真實 TDX/政府資料的擷取檔，不連網
```

不屬於 `npm test` 的手動工具（需要 `.env`，會連真實資料）：`test/live_realtime.mjs`、`test/live_bike_routing.mjs`、`test/bike_density_probe.mjs`、`test/bike_proximity_probe.mjs`、`test/capture_bike_fixture.mjs`、`test/local_backend.mjs`。

### 手動發佈（例：張文/旅客事件）

```bash
curl -X POST http://localhost:8787/v1/admin/announcements \
  -H "Authorization: Bearer $ADMIN_TOKEN" -H "Content-Type: application/json" \
  -d '{"category":"metro","severity":"warning",
       "title":"板南線列車延誤",
       "body":"忠孝復興站有旅客事件，往南港方向列車延誤約 10 分。",
       "expiresInMinutes":120}'
```

`category`: `metro` / `rail` / `bus` / `general`　`severity`: `info` / `warning` / `critical`

## 自動台鐵／高鐵異常

填了 `TDX_CLIENT_ID/SECRET` 後，每 `ALERT_POLL_MINUTES` 分鐘檢查
`v3/Rail/TRA/Alert`、`v2/Rail/THSR/AlertInfo`：

- 由正常 → 異常：自動建立 `rail` 警示公告並推播
- 由異常 → 正常：發一則「已恢復正常」資訊公告（`ANNOUNCE_RECOVERY=false` 可關）
- 一直正常：不顯示、不推播

## APNs 設定（要真的推播才需要）

1. Apple Developer → Keys → 建一把 **APNs Auth Key**，下載 `AuthKey_XXXX.p8`
2. `.env` 填 `APNS_KEY_PATH` / `APNS_KEY_ID` / `APNS_TEAM_ID` / `APNS_BUNDLE_ID`
3. App 專案開啟 **Push Notifications** capability（`aps-environment` entitlement）
4. 開發階段 `APNS_PRODUCTION=false`（sandbox）；TestFlight/上架用 `true`

## Docker

```bash
docker build -t transitgo-server .
docker run -d -p 8787:8787 -v $PWD/data:/data --env-file .env transitgo-server
```

## 部署到 Render（免信用卡）

repo 根目錄的 `render.yaml` 已經設定好這個 blueprint：

1. [render.com](https://render.com) 用 GitHub 帳號登入 → **New → Blueprint** → 選這個 repo。
   Render 會自動讀到 `render.yaml`，root directory 已指到 `transitgo-server/`。
2. 部署前會要你手動填幾個標成 `sync: false` 的環境變數：`ADMIN_TOKEN`、
   `TDX_CLIENT_ID`、`TDX_CLIENT_SECRET`（不填 TDX 的話，自動公告 / YouBike 輪詢就不會啟動，其餘 API 仍正常）。
3. Deploy 完，Render 給的網址（去掉 `https://`）就是 App `Config/Secrets.xcconfig` 裡的 `BACKEND_HOST`。

**免費方案的兩個限制：**
- **沒有永久磁碟** —— 每次重新部署／服務被喚醒重啟，`data/transitgo.db`（公告、評分、回報、YouBike 快取）都會重置。YouBike 快取本來就每 2 分鐘重抓一次無所謂，但評分 / 回報歷史會遺失。想要資料不遺失的話要嘛加 Render 的付費永久磁碟，要嘛換用 `firebase/`（Firestore 永久儲存，但 Cloud Functions 需要 Blaze 方案 = 要綁卡）。
- **閒置 15 分鐘會休眠**，休眠時 `node-cron` 的排程（YouBike／台鐵高鐵輪詢）也會跟著停，直到下一個請求把它叫醒才恢復。想保持常駐，可以用 UptimeRobot 之類的免費服務每 10 分鐘 ping 一次 `/v1/health`。

推播（APNs）一樣可以留空跑 DRY RUN；真的要推播的話，因為 Render 免費方案沒有永久磁碟放 `.p8`，把 `.p8` 檔案內容整個貼進 `APNS_KEY_CONTENT` 環境變數（不要用 `APNS_KEY_PATH`）。
