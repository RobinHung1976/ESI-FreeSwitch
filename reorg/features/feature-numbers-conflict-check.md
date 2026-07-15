# 號碼衝突檢查（Numbers · Conflict Check）

> 子功能，依附於 `feature-numbers.md` 的號碼目錄資料｜前端：`numbers.js` 的 `numCheckConflict()`
> 演變歷史：[20260626 號碼衝突檢查](../changelog-details/20260626-number-conflict-check-feature.md)

## 功能概述

分機、群組、IVR、Dialplan 路由規則新增/變更號碼時，即時比對號碼目錄（含 FreeSwitch 保留號碼），避免撞號導致 `NORMAL_TEMPORARY_FAILURE` 等難以排查的錯誤。

## 呼叫方式

```javascript
async function numCheckConflict(inputId, conflictDivId, number, selfType)
```

`selfType` 為 `'extension'|'group'|'ivr'`，編輯模式會依 `dataset.original` 排除自身，不誤判為衝突。

## 觸發時機

- 分機/IVR 號碼輸入欄 `oninput` 即時檢查
- 群組「🔄 變更號碼」confirm 之前
- `saveGroup()` 新增模式儲存之前
- Dialplan 路由規則的號碼樣式（400ms debounce，見 `feature-dialplan-routing-rule.md`）

## 顯示狀態

| 狀態 | 顯示 |
|---|---|
| 空白 | 無提示 |
| 可用 | `✓ 號碼可用`（綠色） |
| 衝突 | `⚠️ 號碼 XXXX 已被 🔒 FreeSwitch 內建「Conference Bridge」佔用`（紅色，列出實際佔用者類型與名稱） |

## 快取

```javascript
let _numCache = null;   // 30 秒 TTL，減少重複打 /api/numbers
function numClearCache()  // 新增/刪除後手動清除
```

## 與 Dialplan 路由規則衝突檢查的關係

Dialplan 路由規則（`feature-dialplan-routing-rule.md`）的衝突檢查是**獨立的後端端點**（`POST /api/dialplan/routes/check-conflict`），比對的是路由樣式間的正規式重疊（prefix/exact/custom_regex），跟這裡的「單一號碼是否已被佔用」是不同層級的檢查，兩者互不取代。
