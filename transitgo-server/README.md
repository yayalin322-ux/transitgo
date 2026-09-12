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
