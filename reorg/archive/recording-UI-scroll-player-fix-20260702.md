## 除錯

### ✅ 錄音管理頁面無法捲動，篩選 39 筆只顯示部分（2026-07-02）

**現象**：篩選結果顯示「39 筆」，但表格實際只看得到約 14 筆，看不到分頁按鈕，畫面無法往下捲動。

**根本原因**：外層 `.panel { overflow: hidden; }`，但 `.rec-table-wrap` 只設了 `overflow-x: auto`，沒有 `flex:1 + overflow-y:auto` 撐出獨立捲軸。表格超出可視範圍的部分被 `.panel` 的 `overflow:hidden` 直接裁掉、無法捲動，並非資料真的少了。

**修復**（`style.css`）：
```css
/* 修改前 */
.rec-table-wrap { overflow-x: auto; }

/* 修改後：改用 flex 版面，讓表格區自己捲動 */
.rec-panel {
  display: flex;
  flex-direction: column;
  max-height: calc(100vh - 140px);
}
.rec-panel .panel-header { flex-shrink: 0; }
.rec-table-wrap { flex: 1; overflow-y: auto; overflow-x: auto; min-height: 0; }
.rec-pager { flex-shrink: 0; }
```
外層 `<div class="panel">` 加上 `rec-panel` class，撐出固定外框高度，篩選列/分頁列固定不動，只有表格區域內部捲動。

**驗證方式**：篩選 39 筆時可捲動看完全部列表，並可看到「上一頁／下一頁」分頁按鈕。

---

### ✅ 播放器位置比照音檔庫，改為固定於頂部（2026-07-02）

**現象**：播放器原本內嵌在表格 `</table>` 之後，被大量資料列往下推，且每次 `loadRecordings()` 重繪表格時會整個銷毀重建，切換篩選/分頁會中斷正在播放的音檔。

**根本原因**：`wrap.innerHTML` 同時包含 `<table>` 與 `<div id="rec-player-bar">`，兩者綁在同一個重繪區塊裡。

**修復**（`recordings.js`）：
- 播放器 HTML 搬到 `renderRecordings()` 的固定骨架中（僅建立一次），位置在篩選列下方、表格上方，比照音檔庫「🎧 試聽播放器」的版面配置
- `loadRecordings()` 的 `wrap.innerHTML` 只重繪 `<table>`，不再包含播放器
- `_recPlay()` 移除 `bar.style.display = 'flex'` 的顯示切換，播放器元素固定存在，只更新 `audio.src` 與標籤文字

**驗證方式**：切換篩選、翻頁時播放器不再被重建/中斷，播放列固定顯示在頂部。

---

### ✅ 修改過程中殘留舊 HTML 導致 JS 語法錯誤（2026-07-02）

**現象**：套用修改後瀏覽器 console 出現：
```
Uncaught SyntaxError: Unexpected token '<'   recordings.js:235
Uncaught ReferenceError: renderRecordings is not defined
Uncaught ReferenceError: Cannot access 'pages' before initialization
```

**根本原因**：`loadRecordings()` 內新版 `wrap.innerHTML` 樣板字串已在 `</table>\`;` 結尾，但舊版播放器 `<div class="rec-player-bar">...</div>` 區塊沒刪乾淨，殘留在樣板字串外面，變成裸露的 HTML 語法，導致整支 `recordings.js` parse 失敗；連帶讓 `init.js` 抓不到 `renderRecordings`、`pages` 也未初始化完成。

**修復**：刪除第 235–242 行殘留的舊播放器區塊，確認 `</table>\`;` 後直接接 `if (pager) {`。

**提醒**：改樣板字串（template literal）時，若舊程式碼原本橫跨多個 `` ` `` 區塊，刪減/搬移後務必確認反引號收尾位置正確，避免半段 HTML 掉在 JS 語句層級。`Unexpected token '<'` 幾乎都是這種「HTML 漏在字串外」的訊號。

---

**測試結果**：以上三項修改已通過測試驗證 —— 篩選 39 筆可完整捲動顯示、分頁按鈕正常顯示、播放器固定於頂部且切換篩選/翻頁不中斷播放。
