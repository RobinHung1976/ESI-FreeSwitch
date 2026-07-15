# Dialplan 路由設定 — 類型二：系統內建 Extension（唯讀）

> 上層總覽：[`feature-dialplan.md`](feature-dialplan.md)｜後端：`routers/dialplan_system_extensions.py`
> 演變歷史：[20260701 Dialplan 系統內建功能](../changelog-details/20260701-dialplan-system-extensions-feature.md)

## 功能概述

解析 `default.xml`/`public.xml` 中**有 `destination_number` 條件**的 extension，唯讀展示 + 白話說明，供維運人員理解系統既有的內建路由邏輯（例如 hold_music、eavesdrop、Conference Bridge 等），不提供任何寫入 API，是防止誤改系統內建 extension 的第一道防線。

## 解析範圍

只挑出有 `destination_number` 條件的 extension，沒有的（如 `unloop`、`global` 等系統內部保護機制）直接略過，因為那些不是使用者會撥打的號碼。目前解析出 67 筆，涵蓋所有有意義的號碼/正規式功能碼（含 `global-intercept`、`group-intercept`、`intercept-ext`、`redial` 等，以及兩個保底 catch-all `enum`/`acknowledge_call`）。

`DEFAULT_EXT_DESCRIPTIONS` 白話說明對照表的 key 用 extension 的 `name` 屬性（不是號碼——很多 extension 對應的是號碼範圍或正規式功能碼，單一號碼無法涵蓋）。

## 前端

- Table + 搜尋框 + 每列「▾ 原始 XML」摺疊按鈕
- 搜尋跟展開/收合都只局部更新 tbody，搜尋框輸入焦點不丟失
- 展開狀態用 `Set` 存 index，不依賴 DOM
- 純唯讀：沒有任何編輯/刪除按鈕

## 後端 API

| Method | Endpoint | 說明 |
|---|---|---|
| `GET` | `/api/dialplan/system-extensions` | 唯一端點，回傳解析後的 67 筆內建 extension（含 `raw_xml` 原始片段） |

不需要呼叫 `init_esl`（純唯讀，沒有 reload/rollback 需求）。
