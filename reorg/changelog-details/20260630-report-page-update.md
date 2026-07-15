# 通話統計報表更新 — 2026-06-30

> 原始來源：`dashboard-update-20260630.md`、`FreeSwitch-Project-V2-20260630.md`（通知設定移除段落）

## 一、頁面結構調整

- 改名：「監控 Dashboard」→「通話即時狀態」（只保留使用者即時狀態表）
- 新增頁面：「通話統計報表」(report)，原本的每小時通話量、通話排行從即時狀態頁搬移至此

## 二、通話統計報表新功能

| 功能 | 說明 |
|---|---|
| 日期快捷按鈕 | 今天 / 昨天 / 本週 / 本月，一鍵切換查詢範圍 |
| 摘要卡片 | 總通話數、已接通（含平均時長）、未接通（含忙線數）、接通率（含進度條） |
| 每小時/每日通話量圖表 | 單日顯示 24 小時柱狀圖；本週/本月顯示每日柱狀圖，皆支援 hover tooltip |
| 通話排行圓餅圖 | Top 5 分機 + 其他，donut 樣式 |
| 未接通明細 | 列出 NO ANSWER / BUSY 通話，含時間、來源、目的、原因 |
| 匯出 CSV | 含 BOM，Excel 開啟不亂碼，檔名含日期與分機 |

## 三、後端調整（`server.py`）

`/api/cdr/stats` 新增 `date_to` 參數，支援日期範圍查詢：
- 單日模式（不傳 `date_to`）：回傳 24 小時分佈，行為與原本一致
- 範圍模式（傳 `date_to`）：回傳每日總量分佈，供本週/本月圖表使用
- 回傳新增 `is_range` 欄位標示目前模式

## 四、過程中修復的 Bug

- CSS 誤植 `<script>` 區塊：曾因編輯造成 `switchPage is not defined`，已修正回 `<style>`
- `server.py` 縮排錯誤：`for` 迴圈後續無內容導致 `IndentationError`
- `dateTo` 重複宣告：`loadReportData()` 內變數重複 `let`，導致整支 JS 解析失敗
- 滑鼠移動覆蓋圖表：本週/本月 hover 時誤呼叫單日繪圖函式，顯示 `null:00`，已改為依模式判斷呼叫正確的繪圖函式
- 標題文字未隨模式切換：新增 `id="rp-chart-title"`，依 `_rpDateMode` 動態顯示「每小時／每日通話量」
- 本月柱狀圖溢出：圖表寬度改為動態計算（天數 × 最小柱寬），容器加上橫向捲動

**影響檔案**：`index.html`（前端 UI、JS 邏輯）、`server.py`（`/api/cdr/stats` API），部署時兩個檔案需同時更新並 `systemctl restart fs-dashboard`。

---

## 通知設定 Tab 整體移除

**原因**：「通話統計報表」已提供明確的未接來電明細，此功能重複。

**移除範圍**：
- CSS：`#missed-toast-container`、`.missed-toast` 系列樣式、`toastIn` 動畫
- HTML：側欄 `nav-missed-badge` 計數徽章、頁面底部 toast 容器
- JS：`handleWSEvent` 中未接來電偵測邏輯（`_seenCallUUIDs`/`_answeredUUIDs`）、`showMissedToast`/`updateMissedBadge`/`clearMissedBadge`/`requestNotifyPermission` 等函式
- 設定樹：「通知設定」節點與其渲染內容
- `SETTINGS_DEFAULTS` 中的 `notify_missed`、`notify_maxcalls`

**附帶發現**：原本的未接來電判斷邏輯本身也有 bug——`CHANNEL_DESTROY` 事件固定顯示主叫方號碼，不分方向，導致「1126 撥給 1210，1210 未接」卻顯示「1126 未接」的誤報。此功能已直接移除，問題隨之解決。
