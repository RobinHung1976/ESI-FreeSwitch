## 除錯

### ✅ 左側導覽列「通話即時狀態」badge 計數與實際通話數不符（2026-07-02）

> 原始來源：`nav-badge-count-fix-20260702.md`

**現象**：畫面上「使用者即時狀態」表格顯示 0 通通話中（正確），但左側導覽列「通話即時狀態」旁的 badge 卻卡在 1，即使 FreeSWITCH 端已確認無任何通話（`show channels` / `show calls` 皆回傳 `0 total.`）。

**根本原因**：兩個 badge 使用不同資料源，且其中一個沒有自我校正機制：

1. **Header badge**（`_ucUpdateBadge()`）：讀取前端事件驅動、已做 A/B leg 去重的 `_liveCalls`。切換頁面時會呼叫 `_refreshMonitorCallsTable()` 重新打 `/api/calls` 校正快取，因此能自動修正回正確值。
2. **Nav badge**（`updateNavBadge()`）：每次都獨立呼叫 `/api/calls`，直接採用 FreeSWITCH `show calls as json` 的 `row_count`，未去重，且**只靠 `CHANNEL_*` WebSocket 事件觸發更新**，沒有任何校正機制。一旦 WebSocket 斷線期間漏接一次 `CHANNEL_DESTROY` 事件，計數就會永久卡在舊值。

**修復**：

1. **`common.js`** — `updateNavBadge()` 改為直接讀取已去重且會被定期校正的 `_liveCalls`，不再獨立打 API：
```javascript
// 修改前
async function updateNavBadge() {
  const data = await apiFetch('/api/calls');
  const count = (data && data.row_count) ? data.row_count : 0;
  const badge = document.getElementById('nav-calls-badge');
  if (badge) badge.textContent = count;
}

// 修改後
function updateNavBadge() {
  const badge = document.getElementById('nav-calls-badge');
  if (badge) badge.textContent = Object.keys(_liveCalls).length;
}
```

2. **`common.js`** — `initWebSocket()` 的 `ws.onopen` 內新增 `_refreshMonitorCallsTable()`，確保首次連線與每次斷線重連都會強制對齊 FreeSWITCH 實際通話狀態：
```javascript
ws.onopen = () => {
  console.log('WebSocket 已連線');
  setFsDot('var(--green)', true);
  setSysStatus('正在取得狀態...');
  loadSysStatus();
  loadExtStatusSnapshot();
  _refreshMonitorCallsTable();   // 新增：重連時強制校正 _liveCalls
};
```

**排查方式**：
```bash
fs_cli -H 127.0.0.1 -P 8055 -p FSPyAdmin -x "show channels"
fs_cli -H 127.0.0.1 -P 8055 -p FSPyAdmin -x "show calls"
# → 0 total.，確認 FreeSWITCH 端無殘留 channel，問題在前端計數邏輯
```

**驗證方式**：無通話時左側 badge 與 header badge 皆應顯示 0；手動斷開/重連 WebSocket 後兩者仍應維持一致，不再需要手動重新整理頁面才能校正。

---

**測試結果**：已通過測試驗證，修正後左側 badge 與 header badge 計數一致，且 WebSocket 斷線重連後可自動校正，不再飄移。
