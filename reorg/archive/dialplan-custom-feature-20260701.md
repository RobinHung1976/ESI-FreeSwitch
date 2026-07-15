# FreeSwitch Dashboard — Dialplan 類型三（自定義：範本＋XML 編輯器）開發總結

**日期**：2026-07-01
**涵蓋範圍**：`dialplan_common.py` 擴充、`dialplan_custom.py`（新檔）、`dialplan-custom-ui.js`（新檔）、`server.py` / `index.html` 整合
**狀態**：✅ 已完成，測試通過

---

## 一、背景

延續 `dialplan-routing-rule-20260701.md` 的規劃與 `dialplan-system-extensions-feature-20260701.md` 完成的類型二，本次完成三種 dialplan 管理類型中最後一塊：**類型三（自定義）**。

```
Dialplan 管理頁面
├── Tab：路由規則（Outbound Routing）  ← 類型一，表單式 ✅
├── Tab：系統內建（System Extensions） ← 類型二，唯讀+說明 ✅
└── Tab：自定義（Custom）              ← 類型三，範本+XML 編輯器 ✅ 本次完成
```

類型三的定位：凡不是 `00_route_*.xml`（路由規則）、`00_group_*.xml`（群組）、`00_ivr_*.xml`（IVR）、`default.xml`／`public.xml`（系統內建）的 dialplan 檔案，都屬於類型三管理範圍，提供兩種編輯模式：

| 模式 | 說明 |
|---|---|
| 範本模式 | 選範本 → 填表單 → 依 schema 自動產生 XML，欄位驗證＋即時預覽，可回填編輯 |
| 手動模式 | 沿用既有的 raw textarea 編輯器，儲存前自動驗證語法＋備份原檔 |

---

## 二、`dialplan_common.py`（擴充）

新增共用 XML 語法驗證函式，供手動模式與範本產生器共用同一套驗證邏輯：

```python
def validate_xml(content: str) -> None:
    """共用 XML 語法驗證，raw editor 與範本產生器都呼叫這支，不要各自 try/except。"""
    try:
        etree.fromstring(content.encode("utf-8"))
    except Exception as xe:
        raise HTTPException(status_code=400, detail=f"XML 語法錯誤：{xe}")
```

同時在檔案開頭 import 區塊新增 `from lxml import etree`。`HTTPException` 沿用原本已有的 import，不需重複加。

> 此前規劃文件裡「XML 語法驗證機制已在 `dialplan_common.py` 就緒，待接入」的待辦，本次正式接入。

---

## 三、`dialplan_custom.py`（新檔，後端主模組）

### Schema 驅動的範本設計

刻意不做成純字串樣板，而是每個範本自帶欄位 schema（`TemplateField`：key / label / type / required / options / placeholder / help），前端依 schema 動態產生表單，未來新增範本只需要在 `TEMPLATES` dict 裡加一筆 `fields` + `generator`，不需要改動路由或前端框架程式碼。

### 已實作的範本

| 範本 id | 說明 | 產生的 dialplan 行為 |
|---|---|---|
| `time_route` | 時段路由（上班／非上班時間分流） | 依 `wday`/`hour` 條件轉接不同目標，`break="on-false"` 確保非上班時間才往下比對 |
| `blacklist` | 黑名單（封鎖來電） | `caller_id_number` 命中即 `hangup` `CALL_REJECTED`，不進入其他 dialplan |

兩個範本的 generator 都內建欄位驗證（號碼格式、時間格式 `HH:MM`、轉接目標字元限制等），驗證失敗回傳 400 附帶明確錯誤訊息，而非讓錯誤內容流入產生的 XML。

### META 回填機制

範本產生的檔案會在檔頭內嵌：
```xml
<!-- DASHBOARD_CUSTOM_META: {"template_id":"time_route","values":{...}} -->
```
編輯時透過 `GET /api/dialplan/custom/file?path=...` 解析此註解，若能解析則回傳 `editable_as_template: true` 並附上 `template_id` / `values`，前端據此把使用者導回表單而非退回 raw 編輯器；無法解析（手動建立的檔案）則 `editable_as_template: false`，前端自動退回手動模式。

### API 端點

| 方法 | 路徑 | 說明 |
|---|---|---|
| GET | `/api/dialplan/custom/templates` | 列出所有範本的 schema |
| GET | `/api/dialplan/custom/files` | 列出所有類型三管理範圍內的檔案（自動排除類型一/二/群組/IVR 管理的檔案），含來源標記（範本/手動） |
| GET | `/api/dialplan/custom/file?path=` | 讀取單一檔案並嘗試反解 META |
| POST | `/api/dialplan/custom/preview` | 不寫檔，依 `template_id`+`values` 回傳產生的 XML，供表單即時預覽 |
| POST | `/api/dialplan/custom/create` | 依範本新增檔案（檔名衝突回 409，寫入失敗自動 rollback） |
| PUT | `/api/dialplan/custom/file` | 依範本重新產生 XML 並覆寫既有檔案（自動備份，reload 失敗自動還原） |

手動模式的新增／編輯／刪除**刻意不重複實作**，直接沿用 `server.py` 既有的 `GET/POST/DELETE /api/dialplan/file`、`POST /api/dialplan/create`，`dialplan_custom.py` 只在列表 API 裡把這些檔案一併列出並標記為「手動」來源。

### 安全機制

- `_assert_allowed_path()`：限制只能存取 `/etc/freeswitch/dialplan/` 底下路徑
- `_assert_not_managed()`：擋掉 `00_route_`/`00_group_`/`00_ivr_` 前綴與 `default.xml`/`public.xml`，避免類型三誤改其他頁面管理的檔案，回 403 並提示應到對應頁面操作
- 寫入前一律先 `validate_xml()`，新增失敗走 `rollback_new_file()`，更新失敗走 `reload_and_verify()` 內建的備份還原機制

---

## 四、`dialplan-custom-ui.js`（新檔，前端模組）

### 頁面結構

三種畫面模式（`_dcMode`）：`list`（檔案列表）／`pick`（範本卡片選擇）／`form`（動態表單＋即時預覽）。

- **列表面板**：顯示所有類型三檔案，標示來源（🧩 範本名稱 / ✎ 手動），可編輯／刪除
- **範本選擇面板**：卡片式選擇，點擊進入對應表單
- **表單面板**：依 `fields` schema 動態渲染 `text`/`number`/`select`/`time` 四種輸入類型，輸入時 300ms debounce 呼叫 `/preview` 更新「進階 XML 預覽」摺疊區塊，風格比照類型一的路由規則表單

### 與既有全域函式的關係

- 重用 `_dpModalHtml()` / `dpCloseModal()`（純外觀 modal 元件，無頁面耦合，安全共用）
- **刻意不重用** `dpEditFile()` / `dpNewFile()` / `dpDeleteFile()`：這幾支既有函式的成功回呼寫死呼叫 `renderNumbers()`（號碼目錄頁刷新），若在類型三頁面直接呼叫，存檔後會跳轉到號碼目錄頁而非留在自定義頁。因此手動模式改寫成 `dc` 前綴的獨立函式（`dcOpenManualNew` / `dcManualNewSave` / `dcOpenManualEdit` / `dcManualEditSave` / `dcDeleteFile`），內部呼叫的後端端點相同，只是成功後導回 `switchPage('dialplan_custom')`

### 編輯流程判斷

`dcEditFile(path)` 先呼叫 `/api/dialplan/custom/file` 取得 `editable_as_template`：
- `true` → 帶入 `template_id` + `values` 進表單面板（範本模式編輯，走 `PUT`）
- `false` → 退回 `dcOpenManualEdit()`（raw textarea，走既有 `/api/dialplan/file` POST）

---

## 五、部署整合

### `server.py`

**第 16-18 行**：
```python
import shutil
from lxml import etree
from datetime import datetime
```

**第 645-648 行**（`dialplan_system_extensions` 掛載之後）：
```python
import dialplan_custom
app.include_router(dialplan_custom.router)
```

`dialplan_custom` 不需要呼叫 `init_esl`，透過 `dialplan_common` 共用已注入的同一顆 ESL 連線。

### `index.html`

| 插入點 | 內容 |
|---|---|
| nav 選單（`dialplan_routes` 項目後） | `<div class="nav-item" data-page="dialplan_custom" onclick="switchPage('dialplan_custom')"><span class="nav-icon">📋</span> Dialplan 自定義</div>` |
| `pages` 物件（`dialplan_routes:` 那行後） | `dialplan_custom: { render: renderDialplanCustom, title: 'Dialplan 自定義' },` |
| `<script>` 主體結尾前 | 整段貼上 `dialplan-custom-ui.js` |

### `dialplan_common.py`

**第 16-18 行** import 區塊加 `from lxml import etree`。
**第 42-45 行**（`make_backup()` 結尾與 `reload_and_verify()` 開頭之間）新增 `validate_xml()` 函式。

---

## 六、測試結果

✅ `dialplan_custom.py`：`python3 -m py_compile` 語法檢查通過
✅ `dialplan-custom-ui.js`：`node --check` 語法檢查通過
✅ 部署整合後實測：範本選擇 → 動態表單 → XML 即時預覽 → 儲存（含 reloadxml）→ 檔案列表顯示正常，使用者於 2026-07-01 確認測試結果正常

---

## 七、實作進度總覽（更新）

| 功能 | 類型 | 狀態 |
|---|---|---|
| 外撥路由規則表單 CRUD | 類型一 | ✅ |
| 系統內建 Extension 唯讀列表＋說明 | 類型二 | ✅ |
| 共用機制抽取（`dialplan_common.py`） | 通用 | ✅ |
| XML 語法驗證共用函式（`validate_xml`） | 通用 | ✅（本次接入） |
| 範本選擇 → 填空式 XML 編輯器 | 類型三 | ✅ |
| 範本：時段路由 | 類型三 | ✅ |
| 範本：黑名單 | 類型三 | ✅ |
| XML 語法驗證（類型三儲存前） | 類型三 | ✅ |
| META 回填機制（範本檔案可回到表單編輯） | 類型三 | ✅ |
| 手動模式 raw 編輯器（沿用既有端點） | 類型三 | ✅ |
| 既有 raw editor（`server.py`）遷移至 `dialplan_custom.py` 並改用 `reload_and_verify` | 類型三 | 🔲（可選，尚未執行，目前 `server.py` 的 `save_dialplan_file` 仍是獨立實作，reload 失敗不會自動 rollback） |
| 刪除二次確認 | 通用 | ✅（各刪除操作皆有 `confirm()`） |
| Context 切換 UI | 通用 | 🔲 |
| 備份歷史列表與一鍵還原 | 通用 | 🔲 |

---

## 八、相關檔案

| 檔案 | 說明 |
|---|---|
| `dialplan_common.py` | 新增 `validate_xml()`，供類型三共用 XML 驗證邏輯 |
| `dialplan_custom.py` | 新檔：類型三後端，範本 schema、preview/create/update/list/parse API |
| `dialplan-custom-ui.js` | 新檔：類型三前端 UI，範本卡片、動態表單、即時預覽、檔案列表 |
| `server.py` | 掛載 `dialplan_custom.router`（2 行），import `lxml.etree`（既有） |
| `index.html` | 整合類型三前端（nav + pages + script 三處插入） |
| `dialplan-routing-rule-20260701.md` | 類型一/二/三原始規劃文件 |
| `dialplan-system-extensions-feature-20260701.md` | 類型二開發總結，`dialplan_common.py` 首次抽取 |
| `dialplan-custom-feature-20260701.md` | 本文件（類型三開發總結） |

---

## 九、待辦與後續建議

1. **遷移既有 raw editor**：`server.py` 第 1168-1269 行的 `get_dialplan_file` / `save_dialplan_file` / `create_dialplan_file` / `delete_dialplan_file` 目前仍是獨立實作，`save_dialplan_file` 的 reload 失敗沒有自動 rollback，跟類型一/二/三共用機制不一致，建議之後整支搬進 `dialplan_custom.py` 並改用 `make_backup`/`reload_and_verify`。
2. **號碼衝突檢查**：`time_route` 範本的 `number` 欄位、`blacklist` 範本目前沒有接 `numCheckConflict()`，建議比照類型一即時檢查，避免與既有分機/群組/IVR/路由號碼衝突。
3. **更多範本**：架構已就緒，新增範本只需在 `TEMPLATES` dict 擴充 `fields` + `generator`，可視需求擴充白名單、時間更細緻的排班規則等範本。
