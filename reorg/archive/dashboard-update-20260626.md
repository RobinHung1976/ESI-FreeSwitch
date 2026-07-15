# Dashboard 更新總結 — 2026-06-26

### 功能重構總結：使用者即時狀態總覽, 修改日期：2026-06-26
背景問題
原本 Dashboard 分為兩個獨立面板：

分機即時狀態：卡片式方格，只顯示狀態，無通話細節
即時通話：以「來源 → 目的地」為中心，同一通話雙方各顯一列，造成重複，且無法辨別是哪個使用者


架構重設計：以「人」為中心
將兩個面板合併為單一使用者即時狀態表，核心原則是「一列 = 一個人，通話資訊附掛在人的後面」。
分機     │ 狀態      │ 方向     │ 對象號碼 │ 時長
─────────┼───────────┼──────────┼──────────┼──────
1200     │ 🔊 通話中 │ → 出撥  │  9900    │ 0:21
         │ 📞 響鈴中 │ ← 來電  │  1126    │ 0:13   ← 第二通（子列）
1126     │ 📞 響鈴中 │ ⇄ 內線  │  1200    │ 0:13
1300     │ ✅ 待機   │          │          │

關鍵實作
1. 多通話支援（rowspan 子列）
同一分機有多通電話時，第一通在主列，後續各佔子列，分機欄用 rowspan 合併，視覺上屬於同一人。
2. A/B leg 去重（修正重複顯示的核心）
FreeSWITCH show calls as json 對每通電話同時回傳 A leg 和 B leg，_ucGetCallsForExt 採雙保險策略去重：
策略 1（b_uuid 封鎖）：API 資料有 b_uuid 時
  採用 A leg → 同時把 b_uuid 加入 seenUUIDs → B leg 進來直接跳過

策略 2（pair key fallback）：WS 事件寫入的輕量物件無 b_uuid
  以 sort([cid_num, dest]).join('|') 為 key → 同一對只保留第一筆
3. 排序錯亂修正（先過濾再排序）
切換「顯示離線」時舊邏輯先排序再過濾，離線分機（order=5）佔了排序位置後被 _ucBuildRows 過濾掉輸出空字串，導致上線分機被推到後面。改為先過濾、再對剩餘分機排序，確保順序永遠正確。
4. 方向顏色語意
標籤顏色意義⇄ 內線紫色雙方均為內部短碼（3-6 位數字）→ 出撥藍色此分機主動撥出← 來電綠色此分機接收來電
5. DOM 局部更新策略
WS 推播時不重繪整表，只對受影響的分機執行：移除舊列群組 → DocumentFragment 批次插入新的主列 + 子列 → 依狀態排序找插入位置。計時器（setInterval 掃描 .ext-timer[data-since]）自動 pick up 新插入的列，不需額外處理。

新增函式一覽
函式職責_ucGetCallsForExt(extId)從 _liveCalls 取出此分機的去重通話清單_ucBuildRows(ext)建立一個分機的所有列 HTML（主列 + 子列）_ucDirBadge(direction, peer)建立方向標籤 HTML_ucCallType(direction, peer)判斷 internal / out / in_ucRenderTable()完整重繪（初始化 / 切換離線時用）_ucUpdateRow(extId)WS 推播後局部更新單一分機的所有列_ucUpdateBadge()更新 header 通話計數 badgeucToggleOffline(btn)切換顯示離線分機_renderLiveCalls()WS 通話事件入口，收集受影響分機逐一更新

### 監控 Dashboard 合併功能 — 修改總結 修改日期：2026-06-26

修改檔案：index.html（僅前端，server.py / esl_client.py 無需變動）

一、功能說明
將原本「監控」區段下的兩個頁面：
監控
  ├── 總覽 Overview        ← 統計卡 + 圖表
  └── 即時通話             ← 通話列表
合併為單一頁面：
監控
  └── 監控 Dashboard       ← 統計卡 + 圖表 + 分機即時狀態板 + 即時通話列表

二、變更項目
1. Sidebar 導覽（行 876–883）

移除「即時通話」nav 項目
將通話數 badge 和未接來電 badge 移至「監控 Dashboard」項目
標題由「總覽 Overview」改為「監控 Dashboard」


2. renderOverview() 函式重構
HTML 骨架新增兩個 Section，接在統計圖表下方：
Section A：📡 分機即時狀態板

Grid 佈局（auto-fill, minmax(155px, 1fr)）
每張卡片顯示：分機號碼、顯示名稱、狀態 Badge、通話對象（peer）、通話計時器
只顯示非 offline 分機

Section B：📞 即時通話列表

欄位：來源、目的地、狀態、時長（4 欄，移除方向和操作欄）
id="monitor-calls-tbody" 供局部更新

資料載入順序（同一個 async 函式內）：

統計卡：/api/registrations + /api/cdr/stats
渲染圖表 / Top 10
分機板：同時打 /api/extensions/list + /api/ext/status（解決時序問題）
即時通話：_refreshMonitorCallsTable()


3. applyExtStatusUpdate() 函式擴充
原本只更新分機管理頁的 .ext-card，現在同時更新監控板的 .monitor-ext-card：
情況行為分機狀態變更（非 offline）更新 badge、peer 文字、計時器分機變為 offline從 Grid 移除該卡片分機從 offline 變為 online動態插入新卡片到 Grid
同時修正原有 Bug：card 為 null 時（分機管理頁不在畫面中）不再 crash，改為 if (card) {} 包覆，確保後續監控卡更新正常執行。

4. 即時通話：改為前端自維護 _liveCalls
舊架構（有時序問題）：
CHANNEL_* 事件 → _refreshMonitorCallsTable() → GET /api/calls → 渲染
/api/calls API 有時序延遲：響鈴時 channel 還未建立、掛斷後 channel 還沒清除，導致顯示不即時。
新架構（事件直驅）：
CHANNEL_CREATE  → _liveCalls[uuid] = { callstate:'CS_RINGING', ... } → 立即渲染
CHANNEL_ANSWER  → _liveCalls[uuid].callstate = 'CS_ACTIVE'           → 立即渲染
CHANNEL_DESTROY → delete _liveCalls[uuid]                            → 立即渲染
CHANNEL_HOLD    → _liveCalls[uuid].callstate = 'CS_HOLD'             → 立即渲染
頁面初次載入時仍打一次 /api/calls 初始化 _liveCalls（同步已存在的通話）。
狀態顯示對照：
callstate顯示文字顏色CS_RINGING📞 響鈴中黃色CS_ROUTING⏳ 撥號中黃色CS_ACTIVE / CS_EXECUTE🔊 通話中綠色CS_HOLD⏸ 保留中橘色CS_PARK🅿 停車中藍色

5. 雙 leg 顯示規則
1126 撥給 1200 時，FreeSwitch 產生兩個 uuid（caller leg + callee leg），兩筆各自顯示：
UUIDcid_numdest狀態uuid-A11261200響鈴中 / 通話中uuid-B12001126響鈴中 / 通話中

6. pages 物件
javascript// 舊
overview: { render: renderOverview, title: '總覽 Overview' },
calls:    { render: renderCalls,    title: '即時通話監控' },

// 新（calls 保留但不掛 nav）
overview: { render: renderOverview, title: '監控 Dashboard' },
calls:    { render: renderCalls,    title: '即時通話監控' },

三、新增函式
函式說明buildMonitorExtCard(ext)產生監控板單一分機卡片 HTMLbuildMonitorCallRows(rows)產生即時通話表格列 HTML_refreshMonitorCallsTable()打 /api/calls 初始化 _liveCalls 快取並渲染_renderLiveCalls()純前端渲染，直接讀 _liveCalls 不打 API

四、更新後導覽架構
監控
  └── 監控 Dashboard
        ├── 統計卡（已登錄分機、今日通話量）
        ├── 每小時通話量圖表
        ├── 今日通話排行 Top 10
        ├── 📡 分機即時狀態板（只顯示上線分機）
        └── 📞 即時通話列表（事件驅動，0 延遲）
管理
  ├── 分機管理
  ├── 分機群組
  ├── IVR 管理
  ├── 通話記錄 CDR
  ├── 錄音管理
  └── Gateway / SIP Trunk
系統
  ├── 號碼目錄
  ├── ESL 終端機
  ├── 系統日誌
  └── 設定

五、頁面更新機制（更新後）
頁面 / 元件觸發條件更新方式分機即時狀態板EXT_STATUS_UPDATEapplyExtStatusUpdate() 局部更新單一卡片 DOM，offline 移除、新上線插入即時通話列表CHANNEL_CREATE/ANSWER/DESTROY/HOLD直接操作 _liveCalls 物件 → _renderLiveCalls()左側通話 badge同上updateNavBadge()分機管理卡片EXT_STATUS_UPDATE原有 applyExtStatusUpdate() 邏輯不變
