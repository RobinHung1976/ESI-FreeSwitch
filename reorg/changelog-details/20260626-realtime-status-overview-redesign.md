# 使用者即時狀態總覽重構 — 2026-06-26

> 原始來源：`dashboard-update-20260626.md`

## 背景問題

原本 Dashboard 分為兩個獨立面板：
- **分機即時狀態**：卡片式方格，只顯示狀態，無通話細節
- **即時通話**：以「來源 → 目的地」為中心，同一通話雙方各顯一列，造成重複，且無法辨別是哪個使用者

## 架構重設計：以「人」為中心

合併為單一「使用者即時狀態表」，核心原則是「一列 = 一個人，通話資訊附掛在人的後面」：

```
分機     │ 狀態      │ 方向     │ 對象號碼 │ 時長
─────────┼───────────┼──────────┼──────────┼──────
1200     │ 🔊 通話中 │ → 出撥  │  9900    │ 0:21
         │ 📞 響鈴中 │ ← 來電  │  1126    │ 0:13   ← 第二通（子列）
1126     │ 📞 響鈴中 │ ⇄ 內線  │  1200    │ 0:13
1300     │ ✅ 待機   │          │          │
```

## 關鍵實作

**1. 多通話支援（rowspan 子列）**：同一分機有多通電話時，第一通在主列，後續各佔子列，分機欄用 rowspan 合併。

**2. A/B leg 去重（核心修正）**：FreeSWITCH `show calls as json` 對每通電話同時回傳 A leg 和 B leg，`_ucGetCallsForExt` 採雙保險策略去重：
- 策略 1（`b_uuid` 封鎖）：API 資料有 `b_uuid` 時，採用 A leg，同時把 `b_uuid` 加入 `seenUUIDs`，B leg 進來直接跳過
- 策略 2（pair key fallback）：WS 事件寫入的輕量物件無 `b_uuid` 時，以 `sort([cid_num, dest]).join('|')` 為 key，同一對只保留第一筆

**3. 排序錯亂修正（先過濾再排序）**：切換「顯示離線」時，改為先過濾、再對剩餘分機排序，避免離線分機佔用排序位置後被過濾導致上線分機被推到後面。

**4. 方向顏色語意**：
| 標籤 | 顏色 | 意義 |
|---|---|---|
| ⇄ 內線 | 紫色 | 雙方均為內部短碼（3-6 位數字） |
| → 出撥 | 藍色 | 此分機主動撥出 |
| ← 來電 | 綠色 | 此分機接收來電 |

**5. DOM 局部更新策略**：WS 推播時不重繪整表，只對受影響的分機執行：移除舊列群組 → `DocumentFragment` 批次插入新的主列 + 子列 → 依狀態排序找插入位置。

## 新增函式一覽

| 函式 | 職責 |
|---|---|
| `_ucGetCallsForExt(extId)` | 從 `_liveCalls` 取出此分機的去重通話清單 |
| `_ucBuildRows(ext)` | 建立一個分機的所有列 HTML（主列 + 子列） |
| `_ucDirBadge(direction, peer)` | 建立方向標籤 HTML |
| `_ucCallType(direction, peer)` | 判斷 internal / out / in |
| `_ucRenderTable()` | 完整重繪（初始化 / 切換離線時用） |
| `_ucUpdateRow(extId)` | WS 推播後局部更新單一分機的所有列 |
| `_ucUpdateBadge()` | 更新 header 通話計數 badge |
| `ucToggleOffline(btn)` | 切換顯示離線分機 |
| `_renderLiveCalls()` | WS 通話事件入口，收集受影響分機逐一更新 |

---

## 監控 Dashboard 合併功能

**修改檔案**：`index.html`（僅前端，`server.py`/`esl_client.py` 無需變動）

將「監控」區段下的兩個頁面（總覽 Overview、即時通話）合併為單一「監控 Dashboard」頁面：

```
監控
  └── 監控 Dashboard
        統計卡 + 圖表 + 分機即時狀態板 + 即時通話列表
```

### 變更項目

1. **Sidebar 導覽**：移除「即時通話」nav 項目，通話數/未接來電 badge 移至「監控 Dashboard」，標題改為「監控 Dashboard」
2. **`renderOverview()` 重構**：HTML 骨架新增兩個 Section
   - Section A：📡 分機即時狀態板（Grid 佈局，只顯示非 offline 分機）
   - Section B：📞 即時通話列表（來源、目的地、狀態、時長 4 欄）
3. **`applyExtStatusUpdate()` 擴充**：同時更新監控板的 `.monitor-ext-card`，分機狀態變更更新 badge/peer/計時器，離線移除、上線動態插入；同時修正原有 Bug（card 為 null 時 crash）
4. **即時通話改為前端自維護 `_liveCalls`**：
   - 舊架構：`CHANNEL_*` 事件 → `_refreshMonitorCallsTable()` → `GET /api/calls`（有時序延遲問題）
   - 新架構：`CHANNEL_CREATE/ANSWER/DESTROY/HOLD` 直接操作 `_liveCalls` 物件 → `_renderLiveCalls()`（事件直驅，0 延遲）
   - 頁面初次載入時仍打一次 `/api/calls` 初始化 `_liveCalls`

### callstate 顯示對照

| callstate | 顯示文字 | 顏色 |
|---|---|---|
| CS_RINGING | 📞 響鈴中 | 黃色 |
| CS_ROUTING | ⏳ 撥號中 | 黃色 |
| CS_ACTIVE / CS_EXECUTE | 🔊 通話中 | 綠色 |
| CS_HOLD | ⏸ 保留中 | 橘色 |
| CS_PARK | 🅿 停車中 | 藍色 |

### 更新後導覽架構

```
監控
  └── 監控 Dashboard
        ├── 統計卡（已登錄分機、今日通話量）
        ├── 每小時通話量圖表
        ├── 今日通話排行 Top 10
        ├── 📡 分機即時狀態板（只顯示上線分機）
        └── 📞 即時通話列表（事件驅動，0 延遲）
管理
  ├── 分機管理 / 分機群組 / IVR 管理 / 通話記錄 CDR / 錄音管理 / Gateway
系統
  ├── 號碼目錄 / ESL 終端機 / 系統日誌 / 設定
```
