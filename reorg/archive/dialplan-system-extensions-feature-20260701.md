# FreeSwitch Dashboard — Dialplan 類型二（系統內建 Extension）開發總結

**日期**：2026-07-01
**涵蓋範圍**：`dialplan_common.py` 抽取（重構）、類型二後端＋前端（新功能）、部署除錯紀錄
**狀態**：✅ 已完成，網頁測試通過

---

## 一、背景

延續 `dialplan-routing-rule-20260701.md` 的規劃，本次完成：
1. 把類型一（外撥路由規則）裡「跟檔案類型無關」的共用機制抽成獨立模組，供類型二/三共用
2. 實作類型二：系統內建 Extension 唯讀檢視

---

## 二、`dialplan_common.py`（新檔，重構抽取）

### 抽取原因

`_reload_and_verify()`、ESL 注入等機制原本寫在 `dialplan_routes.py`（類型一專屬模組）裡，函式名還帶底線（模組內私有慣例）。類型三要用到同一套 reload/rollback 機制時，若直接 `from dialplan_routes import _reload_and_verify` 形同「向兄弟模組借私有函式」，長期會讓模組間互相牽連。因此抽成 `dialplan_common.py`，作為類型一/二/三共用的基礎設施層。

### 提供的函式

| 函式 | 說明 |
|---|---|
| `init_esl(esl_instance)` | 注入 ESL 連線物件，三個 dialplan 模組共用同一顆 |
| `make_backup(filepath, suffix="bak")` | 建立時間戳備份檔，回傳備份路徑 |
| `reload_and_verify(target_filepath, backup_path)` | 執行 `reloadxml` 並驗證結果，失敗自動從備份還原+再次 reload+丟 500 |
| `force_reload()` | 靜默呼叫一次 reloadxml，吞掉例外，給呼叫端已自行完成複雜 rollback 後使用 |
| `rollback_new_file(filepath)` | 「新增」情境專用：沒有備份可還原時，直接刪除半成品新檔並重新 reload |

### 刻意不搬過去的東西

`build_regex()` / `find_conflicts()` 這類「外撥路由規則」特有的號碼樣式比對邏輯，**留在 `dialplan_routes.py`**，不搬進共用模組——類型三的模板（時段路由、黑名單）語意跟「destination_number → bridge gateway」不同，硬共用會綁死未來的擴充彈性。

### `dialplan_routes.py` 的變動

- 移除 `_esl`、`init_esl()`、`_reload_and_verify()` 的原始定義
- 改為 `from dialplan_common import init_esl, make_backup, reload_and_verify, rollback_new_file, force_reload`
- `init_esl` 以同名重新匯出，**`server.py` 既有的 `dialplan_routes.init_esl(esl)` 呼叫完全不用修改**
- `create_route` / `update_route` / `upgrade_legacy_route` / `delete_route` / `toggle_route` 五個寫入端點改用共用函式，行為與重構前完全一致

### 驗證方式

- `py_compile` 語法檢查
- 實際 `import` + `TestClient` 端到端測試：create / update / toggle 正常流程 + create / update / delete 三種 reload 失敗時的 rollback 情境，全部通過，行為與重構前一致

---

## 三、類型二：系統內建 Extension（唯讀檢視）✅ 已完成

### 後端：`dialplan_system_extensions.py`（新檔）

- 解析 `default.xml` / `public.xml`，只挑出**有 `destination_number` 條件**的 extension（沒有的如 `unloop`、`global` 等系統內部保護機制，不是使用者會撥打的號碼，直接略過）
- `DEFAULT_EXT_DESCRIPTIONS`：白話說明對照表，key 用 extension 的 `name` 屬性（不是號碼——很多 extension 對應的是號碼範圍或正規式功能碼，單一號碼當 key 涵蓋不了）
- 對照專案裡實際的 `default.xml`／`public.xml` 跑過解析器，**67 筆全部覆蓋**（含 6 筆原本沒對照到的：`global-intercept`、`group-intercept`、`intercept-ext`、`redial`，以及兩個保底 catch-all `enum`／`acknowledge_call`）
- 只有一個端點 `GET /api/dialplan/system-extensions`，**沒有任何寫入 API**——這是防止誤改系統內建 extension 的第一道防線
- 回傳內容含 `raw_xml`（該 extension 的原始 XML 片段），供前端「展開查看原始 XML」使用

### 前端：`dialplan-system-extensions-ui.js`（新檔）

- 比照 `dialplan-routes-ui.js` 風格：table + 搜尋框 + 每列「▾ 原始 XML」摺疊按鈕
- 搜尋跟展開/收合都只局部更新 `#sysext-tbody`，搜尋框輸入焦點不會丟失
- 展開狀態用 `Set` 存 index（不依賴 DOM），搜尋過濾跟展開狀態互不干擾
- 純唯讀：沒有任何編輯/刪除按鈕
- 用 jsdom 模擬瀏覽器環境跑過：初始渲染、展開/收合、搜尋過濾、索引對應正確性，全部通過

### 發現並修正的規劃文件落差

`dialplan-routing-rule-20260701.md` 第三節範例表跟實際 `default.xml` 對不上：

| 文件寫的 | 實際 XML |
|---|---|
| `9999` → `hold_music` | 實際是 `9664` |
| `9699` → `eavesdrop` | `eavesdrop` 實際對應 `88xxxx`／`*0...`／`779`，沒有 `9699` 這個號碼 |

`DEFAULT_EXT_DESCRIPTIONS` 是直接對照解析器跑出來的真實資料寫的，上面兩處已修正。**建議之後拿正式環境的 `default.xml` 再核一次**，這次核對用的是專案裡的版本。

---

## 四、部署整合

### `server.py`

```python
import dialplan_system_extensions
app.include_router(dialplan_system_extensions.router)
```

不需要呼叫 `init_esl`（類型二純唯讀，沒有 reload/rollback 需求）。

### `index.html`（單一大型內嵌 `<script>`，三處插入點）

| 插入點 | 內容 |
|---|---|
| nav 選單（`dialplan_routes` 項目後） | `<div class="nav-item" data-page="dialplan_system_ext" ...>` |
| `pages` 物件（`dialplan_routes:` 那行後） | `dialplan_system_ext: { render: renderSystemExtensions, title: '系統內建 Extension' },` |
| `<script>` 主體結尾前 | 整段貼上 `dialplan-system-extensions-ui.js` |

### 部署踩到的坑（記錄給下次參考）

實際貼程式碼進 `index.html` 時發生兩次疊代錯誤，都是**手動貼上時漏補/多刪大括號**：

1. **第一次**：把 `dialplan_system_extensions.py`（Python 檔）整段貼進 `<script>` 裡，且貼在 `testRouteNumber()` 函式內部。後果：`"""` 這類 Python 語法讓整個 `<script>` 直接 `SyntaxError`，整頁白屏。
2. **第二次**：改貼對檔案（JS），但 `testRouteNumber()` 缺少的收尾 `}` 沒有補在正確位置——被移到了新增程式碼區塊的最後面。因為括號數量對稱（沒多也沒少，只是位置錯了），瀏覽器沒有噴 `SyntaxError`，而是所有新函式變成巢狀宣告在 `testRouteNumber()` 內部（不是全域函式），導致 `pages` 物件在初始化時找不到 `renderSystemExtensions`，噴 `ReferenceError`，一樣整頁掛掉。
3. **第三次修正時**只做了「刪除多餘的 `}`」，沒做「補回 `testRouteNumber` 缺的 `}`」，變成整個 `<script>` 少一個 `}`，`node --check` 直接回報 `Unexpected end of input`。

**最終修法**：在 `testRouteNumber()` 的 `catch` 區塊結尾補上函式本身的收尾 `}`，新程式碼區塊完整接在其後。改完用 `node --check` 實際跑過語法確認再交付，避免再靠肉眼數括號。

**經驗**：往單一大型 `<script>` 手動插入程式碼時，括號位置錯誤不一定會立刻噴語法錯誤（可能只是把函式關到別的作用域裡），肉眼很難抓，**交付前一定要實際跑語法檢查（`node --check`）**，不能只靠人工核對。

### 測試結果

✅ 網頁測試通過（點 Tab → 67 筆列表 → 展開/收合原始 XML → 搜尋過濾），使用者於 2026-07-01 確認。

---

## 五、實作進度總覽（更新）

| 功能 | 類型 | 狀態 |
|---|---|---|
| 外撥路由規則表單 CRUD | 類型一 | ✅ |
| reloadxml 驗證 + 自動 rollback | 類型一 | ✅（已重構抽到 `dialplan_common.py`） |
| 共用機制抽取（`dialplan_common.py`） | 通用 | ✅ |
| 系統內建 Extension 唯讀列表＋說明 | 類型二 | ✅ |
| 「查看原始 XML」摺疊區塊 | 類型二 | ✅ |
| 模板選擇 → 填空式 XML 編輯器 | 類型三 | 🔲 規劃中 |
| XML 語法驗證（類型三儲存前） | 類型三 | 🔲（機制已在 `dialplan_common.py` 就緒，待接入） |

---

## 六、相關檔案

| 檔案 | 說明 |
|---|---|
| `dialplan_common.py` | 新檔：ESL 注入、reload/rollback、備份，供類型一/二/三共用 |
| `dialplan_routes.py` | 類型一主模組，改用 `dialplan_common` 共用機制 |
| `dialplan_system_extensions.py` | 新檔：類型二後端，唯讀解析 default.xml/public.xml |
| `dialplan-system-extensions-ui.js` | 新檔：類型二前端 UI |
| `index.html` | 整合類型二前端（nav + pages + script 三處插入） |
| `server.py` | 掛載 `dialplan_system_extensions.router`（2 行） |
| `dialplan-routing-rule-20260701.md` | 類型一/二/三原始規劃文件（本次修正了範例表兩處號碼錯誤） |
