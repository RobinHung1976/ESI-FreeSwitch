# Dialplan 路由設定 — 類型三：自定義（範本 + XML 編輯器）

> 上層總覽：[`feature-dialplan.md`](feature-dialplan.md)｜後端：`dialplan_custom.py`
> 演變歷史：[20260701 Dialplan 自定義功能](../changelog-details/20260701-dialplan-custom-feature.md)

## 功能概述

管理範圍：凡不屬於 `00_route_*.xml`（路由規則）、`00_group_*.xml`（群組）、`00_ivr_*.xml`（IVR）、`default.xml`/`public.xml`（系統內建）的 dialplan 檔案，提供兩種編輯模式：

| 模式 | 說明 |
|---|---|
| 範本模式 | 選範本 → 填表單 → 依 schema 自動產生 XML，欄位驗證 + 即時預覽，可回填編輯 |
| 手動模式 | 沿用既有 raw textarea 編輯器，儲存前自動驗證語法 + 備份原檔 |

## Schema 驅動的範本設計

每個範本自帶欄位 schema（`TemplateField`：key/label/type/required/options/placeholder/help），前端依 schema 動態產生表單。新增範本只需在 `TEMPLATES` dict 加一筆 `fields` + `generator`，不需改動路由或前端框架程式碼。

已實作範本：時段路由（time_route）、黑名單（blacklist）、內線互撥（internal_extension，2026-08-11 新增，見下方說明）。

`dynamic_multiselect`（2026-08-11 新增）：選項需向後端即時抓取的欄位型別（目前僅「內線互撥」範本的分機勾選使用，`source="extensions"`），前端表單框架擴充支援非同步載入 + 搜尋篩選 + 全選/清除，且渲染時改用獨立直向版型（標籤/欄位/說明文字各自一行），避免跟一般欄位共用的單行三欄版型互相擠壓變窄。

## 內線互撥範本（2026-08-11）

讓勾選的分機可以在指定 context 內互相直撥。刻意不比照 `default.xml` 的 `Local_Extension` 寫死開放整段號碼區間（`^(1[0-9]{3})$`），而是只開放使用者明確勾選的分機清單，避免在自訂 context（如 `TC-ACSBC`）意外開放不該讓這個來源撥打的分機。「找不到人時」可選擇掛斷或轉語音信箱。分機清單即時從 `GET /api/dialplan/custom/extension-options` 抓取——刻意不重用 `/api/extensions/list`（那支 API 會明碼回傳 SIP／語音信箱密碼），改用只回傳 `id`＋顯示名稱的輕量端點，掛在 `Module.DIALPLAN` 權限底下，避免操作 Dialplan 頁面的人需要額外具備 Extensions 模組讀取權限、也避免密碼被不必要地下載到前端。

「通話逾時秒數」欄位新增 `TemplateField.default`（真正的預設值，非僅 placeholder），新增時自動帶入 `30`，不需手動填即可通過必填驗證。

背景與完整除錯過程見 [`20260811-internal-extension-template.md`](../changelog-details/20260811-internal-extension-template.md)。

## 修復：範本模式原本無法寫入 default/public 以外的 context（2026-08-11）

`TemplateCreateRequest.context` 原本寫死 `Literal["default", "public"]`，與前端「Context 選單支援任意既有 context」的實際行為互相矛盾——選了 `default`/`public` 以外的 context 送出去會直接被 Pydantic 擋在門口（422），範本模式因此實質上只能用在這兩個系統內建 context。已修復為驗證「是否為真實存在的 context」（同時要求資料夾＋頂層 `<context name>` 定義都存在，呼應 [`20260811-dialplan-context-orphan-fix.md`](../changelog-details/20260811-dialplan-context-orphan-fix.md) 的教訓）。`list_custom_files()` 同步修正，改掃描所有真實存在的 context，不再寫死只掃 `default`/`public` 兩個資料夾。

## Context 選單（2026-07-16 上線，2026-08-11 修復建立邏輯）

範本模式（`dc-context`）與手動模式（`dc-manual-context`）的 Context 選單改為動態讀取 `/api/dialplan/contexts`，並加入「+ 建立新 context...」選項——選取後彈出命名輸入框，呼叫 `POST /api/dialplan/contexts` 建立，成功後自動選取新建立的 context。這是全站唯一能建立新 context 的入口，詳見 [`20260716-dialplan-context-switch-feature.md`](../changelog-details/20260716-dialplan-context-switch-feature.md)。

**2026-08-11 修復**：`create_context_dir()` 原本只做 `mkdir`，FreeSwitch 完全不認得這種「只有子資料夾、沒有頂層 `<context name="...">` 定義」的 context，選了必定 `Context not found`／`NO_ROUTE_DESTINATION`——已確認至少造成一起分機完全無法撥出的事故。修復後同時建立子資料夾＋頂層 XML 定義檔（比照 `default.xml` 骨架）＋立即 `reloadxml`，回應警語也改成「已建立可用的 context（含頂層定義，FreeSwitch 已可辨識並立即生效）。仍需自行到 SIP Profile 或其他 dialplan 設定中，讓某個來源實際指向這個 context 名稱，該來源的通話才會真正進入此 context」——明確區分「context 本身已可用」與「還要另外設定來源」是兩件獨立的事。`list_contexts()` 同步加上真偽校驗（`_context_has_definition()`），只有資料夾+頂層定義都存在的 context 才會出現在清單，避免任何來源造成的空殼被選中。`default`／`public` 兩個系統保留字禁止重複建立。詳見 [`20260811-dialplan-context-orphan-fix.md`](../changelog-details/20260811-dialplan-context-orphan-fix.md)。

## 前端三種畫面模式（`_dcMode`）

- `list`：檔案列表，標示來源（🧩 範本名稱 / ✎ 手動），可編輯/刪除
- `pick`：範本卡片選擇
- `form`：動態表單 + 即時預覽（`text`/`number`/`select`/`time` 四種輸入類型），輸入 300ms debounce 呼叫 `/preview`

## 編輯流程判斷

`dcEditFile(path)` 先呼叫 `/api/dialplan/custom/file` 取得 `editable_as_template`：
- `true` → 帶入 `template_id`+`values` 進表單面板（範本模式編輯，走 `PUT`）
- `false` → 退回手動模式（raw textarea，走既有 `/api/dialplan/file` POST）

## 與既有全域函式的關係

重用 `_dpModalHtml()`/`dpCloseModal()`（純外觀 modal，無頁面耦合）；**刻意不重用** `dpEditFile()`/`dpNewFile()`/`dpDeleteFile()`（這些函式成功回呼寫死跳轉號碼目錄頁），改用 `dc` 前綴獨立函式，成功後導回 `switchPage('dialplan_custom')`。

## 後端 API

| Method | Endpoint | 說明 |
|---|---|---|
| `GET` | `/api/dialplan/custom/templates` | 範本清單（含 schema） |
| `GET` | `/api/dialplan/custom/files` | 檔案列表 |
| `GET` | `/api/dialplan/custom/file?path=` | 讀取單一檔案（含 `editable_as_template` 判斷） |
| `POST` | `/api/dialplan/custom/create` | 範本模式新增 |
| `PUT` | `/api/dialplan/custom/file` | 範本模式更新 |
| `POST` | `/api/dialplan/custom/preview` | 表單即時預覽 XML |
| `GET` | `/api/dialplan/custom/extension-options` | 輕量分機清單（2026-08-11 新增，僅 id＋顯示名稱，不含密碼欄位，供「內線互撥」範本勾選用） |
| `GET` | `/api/dialplan/contexts` | 取得目前存在的 context 清單（與類型一共用） |
| `POST` | `/api/dialplan/contexts` | 建立新 context（子資料夾＋頂層 XML 定義＋立即 reload，2026-08-11 起；只有本頁面開放此功能，類型一路由規則頁面只能選不能建） |

> 2026-08-11 修正：本表原記載 `POST /api/dialplan/custom`／`PUT /api/dialplan/custom/{id}`，與實際程式碼路徑（`/api/dialplan/custom/create`、`/api/dialplan/custom/file`）不符，已一併修正。

手動模式沿用既有的 `/api/dialplan/file`（`routers/dialplan_files.py`）。

## 待辦

- 遷移既有 raw editor：`dialplan_files.py` 的 `save_dialplan_file` 目前 reload 失敗沒有自動 rollback，跟類型一/二/三共用機制不一致
- `time_route`/`blacklist` 範本的號碼欄位尚未接 `numCheckConflict()`
- 架構已就緒，新增範本只需擴充 `TEMPLATES` dict
