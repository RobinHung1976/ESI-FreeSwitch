# Dashboard 更新總結 — 2026-06-29

### 使用者即時狀態表 UI 修改總結 修改日期：2026-06-29　修改檔案：index.html

1. 欄位字體加大
項目	修改
.uc-table thead th CSS	font-size: 10px → 13px
2. 新增「錄音」欄位
表頭新增 <th>錄音</th>
_ucBuildRows() 新增 recCell，使用 rowspan 與分機欄對齊
顯示邏輯：ext.recording_enabled && hasCall — 僅在分機已啟用錄音 + 通話中時，才顯示 🔴 脈衝動畫圖示；待機/離線不亮
新增 CSS .uc-rec-badge（紅色圓圈 + pulse 動畫）
3. 方向欄改為單一方向
移除雙向符號 ⇄
_ucDirBadge() 改為純依 direction 判斷：
outbound → ▶ 撥出（藍色）
inbound → ◀ 來電（綠色）
4. 新增「通話類型」欄位
表頭新增 <th>通話類型</th>（置於方向欄右側）
新增 _ucIsInternal(peer) — 判斷對象號碼是否為 3–6 位純數字
新增 _ucTypeBadge(peer) — 依此判斷顯示：
3–6 位數字 → ↔ 內線（紫色）
其他 → 🌐 外線（橘色）
新增 CSS .uc-dir-ext
5. Bug Fix：CSS 誤植 script 區塊
修改過程中 .uc-dir-ext CSS 被插入 <script> 而非 <style>，導致整個 JS 解析失敗（switchPage is not defined）
已修正至正確的 <style> 區塊
最終欄位結構
分機	狀態	錄音	方向	通話類型	對象號碼	時長
1126	🔊 通話中	🔴	▶ 撥出	↔ 內線	1200	0:03
1200	🔊 通話中		◀ 來電	↔ 內線	1126	0:03

# 監控 Dashboard 更新總結 — 2026-06-29

## 修改檔案
- `index.html` — 前端 Dashboard UI 與邏輯
- `server.py` — 後端 `/api/cdr/stats` endpoint

---

## 一、版面重構

### 移除獨立統計卡片
- 刪除「已登錄分機」與「今日通話總量」兩張 stat-card
- **已登錄分機數**整合至「👤 使用者即時狀態」panel header，以 badge pill 顯示
- **今日通話總量**整合至「📊 通話統計」panel header，日期切換後同步更新

### 兩圖合一卡片
原本兩個獨立 panel（每小時 + 排行）合併為單一「📊 通話統計」卡片：

```
┌──────────────────────────────────────────────────────────────┐
│ 📊 通話統計   LIVE  今日N通  [分機下拉]  [日期選擇]         │
│                                                              │
│  每小時通話量（Canvas 柱狀圖）  │  今日通話排行（Donut 圓餅）│
│  ────────── flex:1 ──────────  │  ── width:260px fixed ──  │
└──────────────────────────────────────────────────────────────┘
┌──────────────────────────────────────────────────────────────┐
│ 👤 使用者即時狀態（全寬，LIVE · N通通話中  N支已登錄）       │
└──────────────────────────────────────────────────────────────┘
```

**版面技術選擇**：Grid → Flex（`flex:1 min-width:0` + `width:260px flex-shrink:0`），
避免 canvas reflow 觸發 grid 重算造成版面跑掉。

---

## 二、每小時通話量（柱狀圖）

### 全面改用 Canvas 渲染
- 徹底解決 CSS `height:%` 在 flex/grid 容器中高度計算不一致的問題
- 底線、柱體、時間刻度、tooltip 全部在同一個 Canvas 內繪製

### 時間刻度
| 層級 | 顯示條件 | 內容 |
|------|---------|------|
| 主標籤 | 每 3 小時（0/3/6/9...21） | `HH:00`，bold 10px 深藍色 |
| 次刻度 | 每小時 | 短刻度線，無文字 |
| Hover tooltip | 滑鼠移到任何柱子 | `HH:00 — N 通` 浮層 |

### 互動
- hover 高亮背景欄 + tooltip
- `AbortController` 管理 event listener，每次重繪自動清除舊 listener

---

## 三、今日通話排行（Donut 圓餅圖）

- Pure Canvas，無外部依賴
- Top 5 分機各一切片，其餘合併「其他」
- 中心顯示今日總通話數
- 下方 pill 圖例：分機號 + 通話數 + 佔比%
- 點擊 pill → 篩選柱狀圖；再點一次 → 切回全部
- 已選中的 pill 加粗邊框 + 深色背景，視覺回饋明確

---

## 四、分機篩選邏輯修正

### 問題根源
`_selectedUser` 全域變數與 `select.value` 各自為政，互相覆蓋，
造成：選全部 → 跳回舊分機、點圓餅 → 無反應。

### 修法：select 是唯一 source of truth
```
updateOvChart() 開頭第一行：
  if (sel) _selectedUser = sel.value;  ← 立即同步，不管舊值
```

### 防止連鎖觸發
- 重建 select 前 `sel.onchange = null`，重建完後重掛
- `_ovChartPending` flag：同時只允許一個 `updateOvChart` 執行
- HTML 移除 `onchange` attribute，所有 listener 統一由 JS 管理

---

## 五、後端效能修正（server.py）

### 問題
選單一分機時，前端呼叫 `/api/cdr?limit=9999` 拉全量資料前端重算，
資料量大時需要數分鐘。

### 修法：server-side filtering
`/api/cdr/stats` 新增 `user` 參數：

```
GET /api/cdr/stats?date_str=2026-06-29&user=1126
```

後端在單次 CSV 掃描中同時計算全體與指定分機的每小時分佈，
前端完全不需要第二次 API 呼叫。

**性能對比**：
- 修改前：2 次 API（stats + cdr?limit=9999）
- 修改後：1 次 API（stats?user=N），O(n) 單次掃描

### 歷史日期資料修正
`/api/cdr/stats` 原本只讀 `Master.csv`（當日），
歷史日期改讀歸檔 `cdr-YYYY-MM-DD.csv`：

```python
if target_date == today:
    csv_path = CDR_CSV          # Master.csv
else:
    csv_path = f"cdr-{target_date}.csv"  # 歸檔
```

---

## 六、部署

```bash
# 更新檔案
cp index.html /opt/fs-dashboard/
cp server.py  /opt/fs-dashboard/

# 重啟服務
systemctl restart fs-dashboard
```

> ⚠ `server.py` 有修改（`/api/cdr/stats` 新增 `user` 參數），**必須同時更新兩個檔案**。
