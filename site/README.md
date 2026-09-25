# 交通即時查 TransitGo — 公開網頁（隱私權政策／服務條款／客服）

靜態網頁，放在 `https://yayalin.com/app/` 底下：

| 網址 | 檔案 |
|---|---|
| `/app/support/` | `app/support/index.html`（客服與意見回饋、常見問題） |
| `/app/privacy/` | `app/privacy/index.html`（隱私權政策） |
| `/app/terms/` | `app/terms/index.html`（服務條款） |
| `/app/` | `app/index.html`（導到 support） |
| 共用樣式 | `app/style.css` |

App 內的連結寫在 `TransitGo/Core/SupportLinks.swift`（`https://yayalin.com/app/...`）。

## 上線

把 `site/app/` 整個資料夾放到 yayalin.com 網站根目錄下的 `app/`（也就是 `https://yayalin.com/app/support/` 打得開就對了）。
沒有任何建置步驟、沒有外部相依。上線後用瀏覽器開三個網址確認，再把 App 上架用的「隱私權政策網址」填成 `https://yayalin.com/app/privacy/`。

## 修改內容時

- 隱私權政策必須跟 App 實際收集的資料一致：新增任何會蒐集或上傳資料的功能，就要回來更新 `privacy/index.html` 並改「生效日期」。
- 這些文件是依 App 實際行為寫的白話草稿，**不是法律意見**；正式商業化或上架前建議請律師看過（特別是第 5 節個資權利、服務條款的免責與管轄）。
