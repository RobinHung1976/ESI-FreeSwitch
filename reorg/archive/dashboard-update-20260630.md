# Dashboard 更新總結 — 2026-06-30

## 更新總結 2026-06-30 更新
一、頁面結構調整

改名：「監控 Dashboard」→「通話即時狀態」（只保留使用者即時狀態表）
新增頁面：「通話統計報表」(report)，原本的每小時通話量、通話排行從即時狀態頁搬移至此

二、通話統計報表新功能
功能說明日期快捷按鈕今天 / 昨天 / 本週 / 本月，一鍵切換查詢範圍摘要卡片總通話數、已接通（含平均時長）、未接通（含忙線數）、接通率（含進度條）每小時/每日通話量圖表單日顯示 24 小時柱狀圖；本週/本月顯示每日柱狀圖，皆支援 hover tooltip通話排行圓餅圖Top 5 分機 + 其他，donut 樣式未接通明細列出 NO ANSWER / BUSY 通話，含時間、來源、目的、原因匯出 CSV含 BOM，Excel 開啟不亂碼，檔名含日期與分機
三、後端調整（server.py）
/api/cdr/stats 新增 date_to 參數，支援日期範圍查詢：

單日模式（不傳 date_to）：回傳 24 小時分佈，行為與原本一致
範圍模式（傳 date_to）：回傳每日總量分佈，供本週/本月圖表使用
回傳新增 is_range 欄位標示目前模式

四、過程中修復的 Bug

CSS 誤植 <script> 區塊：曾因編輯造成 switchPage is not defined，已修正回 <style>
server.py 縮排錯誤：for 迴圈後續無內容導致 IndentationError，已修正
dateTo 重複宣告：loadReportData() 內變數重複 let，導致整支 JS 解析失敗
滑鼠移動覆蓋圖表：本週/本月 hover 時誤呼叫單日繪圖函式，顯示 null:00，已改為依模式判斷呼叫正確的繪圖函式
標題文字未隨模式切換：新增 id="rp-chart-title"，依 _rpDateMode 動態顯示「每小時／每日通話量」
本月柱狀圖溢出：圖表寬度改為動態計算（天數 × 最小柱寬），容器加上橫向捲動，避免天數多時擠壓變形

影響檔案

index.html（前端 UI、JS 邏輯）
server.py（/api/cdr/stats API）

部署時兩個檔案需同時更新，並執行 systemctl restart fs-dashboard。