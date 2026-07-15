# Dialplan 路由設定 — 類型一：路由規則（Outbound Routing）

> 上層總覽：[`feature-dialplan.md`](feature-dialplan.md)｜後端：`routers/dialplan_routes.py`
> 演變歷史：[20260701 Dialplan 管理總覽](../changelog-details/20260701-dialplan-management-overview.md)

## 功能概述

外撥路由規則的表單式 CRUD，取代直接手寫 dialplan XML。號碼樣式支援 4 種比對類型，自動偵測既有手寫檔案並可一鍵升級成 Dashboard 管理格式。

## 號碼樣式類型（pattern_type）

| 類型 | 說明 | 產生的正規式範例 |
|---|---|---|
| `any` | 任意號碼 | 無限制 |
| `exact` | 完全符合的號碼 | `^12345$` |
| `prefix` | 開頭數字（可多個，逗號分隔） | 單字元開頭合併字元集 `^[67](\d*)$`；長度不一致用 alternation |
| `custom_regex` | 自訂正規式 | 直接使用（儲存前驗證語法） |

## 舊有手寫檔案處理

| 功能 | 說明 |
|---|---|
| 自動偵測 | 掃描時識別非 Dashboard 管理格式的既有路由檔案，標記 `legacy` |
| 反解析 | 從 legacy XML 反推 `pattern_type`/`pattern_value`/`gateway_name`（含 IP→gateway 名稱還原）/`toll_allow` |
| 一鍵升級 | `POST /api/dialplan/routes/legacy/upgrade`，轉換成 `00_route_*.xml` 標準格式 |
| 讀取限制 | legacy 規則禁止直接 `PUT`/`DELETE`/`toggle`，只能走升級流程（400） |
| 仍參與檢查 | legacy 規則會參與衝突檢查與路由測試（`test-number`），不會被忽略 |

## 號碼樣式衝突檢查

新增/編輯時雙向取樣比對（`generate_sample_numbers()` 產生代表性樣本互相測試對方正規式），重疊回傳 409 並列出衝突清單（名稱/優先序/啟用狀態）。表單 400ms debounce 自動觸發（`onRoutePatternInput()`），編輯模式排除自身（`self_id`）。

## 路由測試工具

`POST /api/dialplan/routes/test-number`：輸入任意號碼，回傳實際會命中的規則（含 legacy），以及 `all_checked` 列出所有已啟用規則的檢查結果，無命中則回傳 `null`。全域測試工具 + 表單內即時版本共用同一端點。

## Dashboard 管理檔案保護

掃描時排除 `00_group_*`、`00_ivr_*`、`default.xml`、`public.xml`，避免路由規則清單誤把其他管理頁面的檔案也列進來。

## 安全機制

- 所有寫入操作自動備份（`make_backup`）
- `reloadxml` 驗證 + 失敗自動 rollback（`reload_and_verify`，共用機制見 `feature-dialplan.md`）

## 後端 API

| Method | Endpoint | 說明 |
|---|---|---|
| `GET` | `/api/dialplan/routes` | 列表（含 legacy） |
| `GET` | `/api/dialplan/routes/{id}` | 讀取單一（支援 `legacy:` 前綴） |
| `POST` | `/api/dialplan/routes` | 新增 |
| `PUT` | `/api/dialplan/routes/{id}` | 更新 |
| `DELETE` | `/api/dialplan/routes/{id}` | 刪除（備份後刪） |
| `PATCH` | `/api/dialplan/routes/{id}/toggle` | 啟用/停用 |
| `POST` | `/api/dialplan/routes/check-conflict` | 衝突檢查（不寫檔） |
| `POST` | `/api/dialplan/routes/test-number` | 路由測試 |
| `POST` | `/api/dialplan/routes/legacy/upgrade` | 升級舊有手寫檔案 |

## 進階功能

- 進階 XML 預覽：表單內容即時生成對應的 dialplan XML 供檢視
- 測試腳本 `test_dialplan_routes.py`：19 組測試，含 rollback 模擬（create/update/delete 三種 reload 失敗情境）
