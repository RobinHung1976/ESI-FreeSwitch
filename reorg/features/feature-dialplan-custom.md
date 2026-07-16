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

已實作範本：時段路由（time_route）、黑名單（blacklist）。

## Context 選單（2026-07-16）

範本模式（`dc-context`）與手動模式（`dc-manual-context`）的 Context 選單改為動態讀取 `/api/dialplan/contexts`，並加入「+ 建立新 context...」選項——選取後彈出命名輸入框，呼叫 `POST /api/dialplan/contexts` 建立空資料夾並顯示警語（純 mkdir，仍需另外到 SIP Profile 或其他 dialplan 設定讓某個來源指向這個 context 才會生效），成功後自動選取新建立的 context。這是全站唯一能建立新 context 的入口，詳見 [`20260716-dialplan-context-switch-feature.md`](../changelog-details/20260716-dialplan-context-switch-feature.md)。

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
| `GET` | `/api/dialplan/custom/list` | 檔案列表 |
| `GET` | `/api/dialplan/custom/file?path=` | 讀取單一檔案（含 `editable_as_template` 判斷） |
| `POST` | `/api/dialplan/custom` | 範本模式新增 |
| `PUT` | `/api/dialplan/custom/{id}` | 範本模式更新 |
| `POST` | `/api/dialplan/custom/preview` | 表單即時預覽 XML |
| `GET` | `/api/dialplan/contexts` | 取得目前存在的 context 清單（與類型一共用） |
| `POST` | `/api/dialplan/contexts` | 建立新 context 資料夾（純 mkdir；只有本頁面開放此功能，類型一路由規則頁面只能選不能建） |

手動模式沿用既有的 `/api/dialplan/file`（`routers/dialplan_files.py`）。

## 待辦

- 遷移既有 raw editor：`dialplan_files.py` 的 `save_dialplan_file` 目前 reload 失敗沒有自動 rollback，跟類型一/二/三共用機制不一致
- `time_route`/`blacklist` 範本的號碼欄位尚未接 `numCheckConflict()`
- 架構已就緒，新增範本只需擴充 `TEMPLATES` dict
