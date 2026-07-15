# FreeSwitch Dashboard 專案重整總結

**日期**：2026-07-01
**範圍**：Dialplan UI 整合、側邊欄優化、前後端程式碼模組化重整、正式部署

---

## 一、起因

1. Dialplan 相關功能散落在三個地方：sidebar 3 個獨立項目（路由規則／系統內建／自定義）+ 設定頁裡又有一個容易混淆的「Dialplan 設定」子選單，使用者常搞不清楚要去哪裡改東西。
2. 側邊欄項目越來越多，空間不夠用。
3. `index.html`（10,634 行）、`server.py`（3,470 行）都變成單一巨石檔案，難以維護。

---

## 二、UI 整合（第一階段）

| 項目 | 處理方式 |
|---|---|
| Dialplan 路由規則／系統內建／自定義 | 合併成一個 sidebar 項目「Dialplan 路由設定」，內部用左側樹狀選單切換 3 個子頁（仿設定頁版面） |
| 設定頁「Dialplan 設定」分組 | 整組移除。「Context 清單」（跟新頁面功能重複）直接砍掉；「檔案路徑」拉平成獨立項目；「重載指令」搬到 ESL 終端機頁面變成常用指令快捷區 |
| Sidebar 空間 | 監控／管理／系統三個分類做成可收合 accordion，狀態存 `localStorage`，重整不會跑掉 |

---

## 三、程式碼模組化重整（第二階段）

### 問題
- `server.py`：3,470 行、約 70 個 API 端點全部寫在同一支檔案，只有 3 個 dialplan 模組有用 `APIRouter` 拆開。
- `index.html`：10,634 行、293 個函式全部塞在同一個 `<script>` 標籤裡。
- 資料夾裡混了 Dashboard 程式碼、FreeSwitch 自己的設定檔（`internal.xml`、`ivr_runner.lua`）、一份意外留下的複本檔案（`dialplan_routes - 複製.py`）。

### 處理方式

**清理**
- 刪除 `dialplan_routes - 複製.py`（確認為意外複本）
- `internal.xml` / `ivr_runner.lua` 維持原狀不動（屬於 FreeSwitch 本身，非 Dashboard app）

**後端**：`server.py` 拆成

```
server.py              ← 只留 app 建立、middleware、mount、include_router、lifespan
core/
  ├─ state.py           跨 router 共用的執行期狀態（ext_status、reg_log 等）
  ├─ constants.py        跨 router 共用常數（FS_RESERVED、音檔路徑等）
  ├─ runtime.py           ESL 事件回調、log/CDR 每日排程、WebSocket 啟動
  ├─ esl_client.py / ws_manager.py / backup_manager.py / dialplan_common.py  （既有模組搬入）
routers/                15 個依領域拆分的 APIRouter + 既有 3 個 dialplan 模組
  calls / logs / settings / cdr / dialplan_files / vars / extensions /
  files / gateway / recordings / groups / ivr / sounds / numbers / backup /
  dialplan_routes / dialplan_system_extensions / dialplan_custom
tests/test_dialplan_routes.py
```

**前端**：`index.html` 拆成

```
static/
  index.html            純 HTML 骨架
  css/style.css
  js/
    common.js            後端連線設定、WebSocket、API 工具、分機狀態快取（最先載入）
    overview-report.js / calls.js / extensions-groups.js / cdr.js /
    gateway.js / esl.js / logs.js / settings-vars.js / backup.js /
    recordings.js / sounds.js / ivr.js / numbers.js / dialplan.js
    init.js              App 啟動進入點（switchPage/pages 物件也在這裡，必須最後載入）
```

### 驗證方式（不是肉眼檢查，是自動化比對）
- **後端**：把拆分前後兩版都實際 import 起來、用 `TestClient` 打 `/openapi.json`，逐一比對所有路徑與 HTTP method → **74 條路由，完全一致**。
- **前端**：把拆分前後所有頂層 `function` / `const` / `let` 宣告名稱排序後 diff → **297 個函式、107 個變數，完全一致**。
- 順手發現並修正：`requirements.txt` 原本漏列 `python-multipart`、`lxml`（程式碼其實一直在用）。

---

## 四、部署過程與遇到的問題

### 部署步驟
1. 解壓新結構到暫存資料夾（`/opt/fs-dashboard-new/fs-dashboard`）
2. 用機器上現有的 `settings.json` 蓋掉新版本的（避免 ESL 密碼等設定跑掉）
3. 用該 service 實際使用的 venv（`/opt/myapp/venv`）安裝 `requirements.txt`
4. 停機 → 搬移資料夾（舊版保留備份 `fs-dashboard.bak-日期`）→ 重啟
5. `systemctl status` + `journalctl` 確認 ESL 連線、WebSocket、排程都正常啟動

### 發現並修正的問題

| 問題 | 原因 | 修正方式 |
|---|---|---|
| `Uncaught ReferenceError: renderOverview is not defined`<br>`Cannot access 'pages' before initialization` | `pages` 物件寫死引用各頁面的 render 函式，但被誤放進**最先載入**的 `common.js`；此時其他頁面的 render 函式都還沒定義，物件初始化失敗，之後所有 `switchPage()` 呼叫全部連帶炸掉 | 把 `pages` 物件、`switchPage`、`refreshData` 移到**最後載入**的 `init.js`（放在啟動呼叫之前），確保所有頁面函式都已載入完成才組裝 `pages` |

修正後重新跑過一次完整的函式/變數 diff，確認沒有遺漏或重複，只補了一個小 patch（`common.js` + `init.js` 兩檔），不需重新部署整包。

---

## 五、最終結果

- ✅ Dialplan 三合一頁面 + 側邊欄可收合，測試通過
- ✅ 後端 74 條 API 路由，拆分前後行為完全一致
- ✅ 前端所有函式/變數完整保留，無遺漏
- ✅ ESL 連線、WebSocket、排程、備份功能皆正常
- ✅ 使用者驗證：**server 正常，功能正常**

---

## 六、後續維護指引

- **新增 API 端點**：去對應領域的 `routers/*.py` 加一個 `@router.get/post/...`，不用再改 `server.py`。
- **新增前端頁面**：在 `static/js/` 新增檔案，在 `static/index.html` 補一行 `<script src="/static/js/xxx.js">`，**務必放在 `init.js` 之前**。
- **跨 router 共用邏輯**：兩個 router 互相呼叫是正常的（例如 `numbers.py` 需要 `groups.py` 的函式），但避免「互相 import」造成循環依賴；真的要共用的常數/狀態放進 `core/constants.py` 或 `core/state.py`。
- **`pages` 物件的教訓**：任何直接寫死引用其他檔案函式的物件/陣列，一定要放在「所有依賴的函式都已定義」之後再宣告——這條規則之後加新頁面時也要注意。
