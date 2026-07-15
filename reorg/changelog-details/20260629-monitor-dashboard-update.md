# 監控 Dashboard 更新總結 — 2026-06-29

> 原始來源：`dashboard-update-20260629.md`

**修改檔案**：`index.html`（前端 UI 與邏輯）、`server.py`（`/api/cdr/stats` endpoint）

## 一、版面重構

- 刪除「已登錄分機」與「今日通話總量」兩張獨立 stat-card，分別整合至「使用者即時狀態」與「通話統計」panel header 的 badge pill
- 「每小時通話量」與「今日通話排行」兩個獨立 panel 合併為單一「📊 通話統計」卡片，版面由 Grid 改為 Flex（`flex:1 min-width:0` + `width:260px flex-shrink:0`），避免 canvas reflow 觸發 grid 重算跑版

## 二、每小時通話量（柱狀圖）

全面改用 Canvas 渲染，解決 CSS `height:%` 在 flex/grid 容器中高度計算不一致的問題。

| 層級 | 顯示條件 | 內容 |
|---|---|---|
| 主標籤 | 每 3 小時 | `HH:00`，bold 10px 深藍色 |
| 次刻度 | 每小時 | 短刻度線，無文字 |
| Hover tooltip | 滑鼠移到任何柱子 | `HH:00 — N 通` 浮層 |

互動：hover 高亮背景欄 + tooltip；`AbortController` 管理 event listener，每次重繪自動清除舊 listener。

## 三、今日通話排行（Donut 圓餅圖）

Pure Canvas，無外部依賴。Top 5 分機各一切片，其餘合併「其他」，中心顯示今日總通話數，下方 pill 圖例（分機號 + 通話數 + 佔比%），點擊 pill 篩選柱狀圖（再點一次切回全部）。

## 四、分機篩選邏輯修正

**問題根源**：`_selectedUser` 全域變數與 `select.value` 各自為政，互相覆蓋，造成選全部跳回舊分機、點圓餅無反應。

**修法**：`select` 是唯一 source of truth：
```javascript
// updateOvChart() 開頭第一行
if (sel) _selectedUser = sel.value;  // 立即同步，不管舊值
```
並移除重建 select 前的 `sel.onchange = null`（重建完後重掛），加入 `_ovChartPending` flag 防止同時多個 `updateOvChart` 執行，HTML 移除 `onchange` attribute 統一由 JS 管理。

## 五、後端效能修正（`server.py`）

**問題**：選單一分機時前端呼叫 `/api/cdr?limit=9999` 拉全量資料前端重算，資料量大時需數分鐘。

**修法**：`/api/cdr/stats` 新增 `user` 參數，後端在單次 CSV 掃描中同時計算全體與指定分機的每小時分佈：
```
GET /api/cdr/stats?date_str=2026-06-29&user=1126
```

性能對比：修改前 2 次 API（stats + cdr?limit=9999）；修改後 1 次 API，O(n) 單次掃描。

**歷史日期資料修正**：`/api/cdr/stats` 原本只讀 `Master.csv`（當日），歷史日期改讀歸檔 `cdr-YYYY-MM-DD.csv`：
```python
if target_date == today:
    csv_path = CDR_CSV          # Master.csv
else:
    csv_path = f"cdr-{target_date}.csv"  # 歸檔
```

---

## 分機即時狀態卡片微調（同日）

- 表頭欄位字體加大（`.uc-table thead th`：10px → 13px）
- 新增「錄音」欄位：`ext.recording_enabled && hasCall` 時顯示紅色圓圈脈衝動畫圖示，待機/離線不亮
- 方向欄改為單一方向（移除雙向符號 ⇄），純依 `direction` 判斷：`outbound` → ▶ 撥出（藍色）、`inbound` → ◀ 來電（綠色）
- 新增「通話類型」欄位：新增 `_ucIsInternal(peer)` 判斷對象號碼是否為 3–6 位純數字，`_ucTypeBadge(peer)` 顯示 ↔ 內線（紫色）或 🌐 外線（橘色）
- Bug Fix：CSS 誤植進 `<script>` 區塊導致 `switchPage is not defined`，已修正至正確的 `<style>` 區塊

## 部署

```bash
cp index.html /opt/fs-dashboard/
cp server.py  /opt/fs-dashboard/
systemctl restart fs-dashboard
```

> ⚠ `server.py` 有修改（`/api/cdr/stats` 新增 `user` 參數），必須同時更新兩個檔案。
