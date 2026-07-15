# ESI 易通科技 FreeSwitch Dashboard — 專案總結

> 最後更新：2026-06-25
> 供下次接續開發時快速掌握現況；官方手冊索引請另見本文件第 17 節。

---

## 1. 系統架構

```
瀏覽器 (index.html)
    ↕ HTTP REST API (port 3000) / WebSocket (port 8080) / SSE
後端 (Python FastAPI) — /opt/fs-dashboard/
    ├── server.py        # 主程式、所有 API endpoints
    ├── esl_client.py    # FreeSwitch ESL TCP 連線（純 socket，不用 greenswitch）
    ├── ws_manager.py    # WebSocket 推播管理
    └── ivr_runner.lua   # IVR Lua 執行引擎（→ /usr/share/freeswitch/scripts/）
    ↕ ESL TCP port 8055（兩條獨立 socket：一條 API、一條事件監聽）
FreeSwitch 1.11.1 on Debian 13
  IP: 192.168.100.209
  ESL Port: 8055 / Password: FSPyAdmin
```

> ⚠ ESL 連線正確值為 **port 8055 / 密碼 FSPyAdmin**（`esl_client.py` 內硬編碼）。
> 手動除錯：`fs_cli -H 127.0.0.1 -P 8055 -p FSPyAdmin`

### 服務管理
```bash
systemctl start/stop/restart fs-dashboard
# /etc/systemd/system/fs-dashboard.service，After=freeswitch.service

# 手動啟動
cd /opt/fs-dashboard
source /opt/myapp/venv/bin/activate
uvicorn server:app --host 0.0.0.0 --port 3000 --reload
```

### Python 環境
虛擬環境：`/opt/myapp/venv/`
套件：`fastapi`、`uvicorn`、`websockets`、`lxml`、`python-multipart`

```bash
# 完整安裝指令（新環境部署用）
/opt/myapp/venv/bin/pip install fastapi uvicorn websockets lxml python-multipart
```

### 部署方式
```bash
cp server.py esl_client.py index.html /opt/fs-dashboard/
cp ivr_runner.lua /usr/share/freeswitch/scripts/
systemctl restart fs-dashboard   # server.py 更新必須重啟
# index.html 不需重啟，直接 cp 即生效
```

> ⚠ **重要**：`server.py` 更新（尤其是新增 Pydantic 欄位）必須重啟服務，否則新欄位會被靜默忽略。

### 檔案路徑對照

| 用途 | 路徑 |
|------|------|
| 專案目錄 | `/opt/fs-dashboard/` |
| 後端設定檔 | `/opt/fs-dashboard/settings.json` |
| IVR Lua 引擎 | `/usr/share/freeswitch/scripts/ivr_runner.lua` |
| FreeSwitch 設定根目錄 | `/etc/freeswitch/` |
| 全域變數 | `/etc/freeswitch/vars.xml` |
| 分機目錄 | `/etc/freeswitch/directory/default/` |
| Dialplan | `/etc/freeswitch/dialplan/` |
| 群組 XML | `/etc/freeswitch/dialplan/default/00_group_*.xml` |
| IVR Dialplan XML | `/etc/freeswitch/dialplan/default/00_ivr_*.xml` |
| IVR JSON 設定 | `/etc/freeswitch/ivr-menus/*.json` |
| Gateway XML | `/etc/freeswitch/sip_profiles/external/` |
| CDR CSV（即時） | `/var/log/freeswitch/cdr-csv/Master.csv` |
| CDR CSV（歸檔） | `/var/log/freeswitch/cdr-csv/cdr-YYYY-MM-DD.csv` |
| 系統日誌（即時） | `/var/log/freeswitch/freeswitch.log` |
| 系統日誌（歷史） | `/var/log/freeswitch/freeswitch-YYYY-MM-DD.log` |
| 錄音 | `/var/lib/freeswitch/recordings/` |
| 自定義語音檔 | `/var/lib/freeswitch/sounds/custom/` |

---

## 2. 已完成功能總覽

| 頁面 | 核心功能 |
|------|----------|
| 總覽 Overview | 統計卡 x4、每小時通話量圖表（可選日期/分機）、Top 10 排行、即時通話表 |
| 即時通話 Calls | `/api/calls` 真實通話列表、掛斷/保留、即時時長計算 |
| 分機管理 Extensions | CRUD（自動備份 `.bak`）、🔄 變更號碼、即時分機狀態（WebSocket 事件驅動）、通話計時器、狀態顏色 Badge、上線優先排序 |
| 分機群組 Groups | 同時/依序響鈴群組 CRUD、成員多選 chip、無人接聽 fallback、🔄 變更號碼 ( 見 extension-manager md 檔)（含號碼衝突告警, 號碼衝突見 number-conflict-check-feature md 檔） |
| **IVR 管理** | 全新功能，ivr-feature md 檔 |
| 通話記錄 CDR | 雙 Tab：📞 即時 CDR / 📋 歷史 CDR（見 cdr-feature md 檔） |
| Gateway / SIP Trunk | CRUD、`sofia status` 解析、reloadxml + rescan |
| 錄音管理 Recordings | 列表（遞迴掃描）、線上播放（Range Request）、下載、刪除（移至 `.trash`） |
| ESL 終端機 | 任意 ESL 指令、快捷按鈕；白底大字輸出；捲動分頁 |
| 系統日誌 Logs | 四 Tab：即時串流 / 歷史分頁搜尋 / 登錄記錄 / 日誌管理 |
| **號碼目錄** | 全新功能，number-directory-feature md 檔 |
| 設定 Settings | 連線/通知/CDR（含歸檔管理）/日誌保留/介面設定、Dialplan XML 編輯器 |
| 未接來電通知 | WebSocket 偵測、Toast、側邊 badge、瀏覽器 Notification API |

### 導覽架構
```
監控
  ├── 總覽 Overview
  └── 即時通話
管理
  ├── 分機管理
  ├── 分機群組
  ├── IVR 管理     ← 新增
  ├── 通話記錄 CDR
  ├── 錄音管理
  └── Gateway / SIP Trunk
系統
  ├── 號碼目錄     ← 新增
  ├── ESL 終端機
  ├── 系統日誌
  └── 設定
```

---

## 3. 頁面更新機制（純事件驅動）

所有頁面狀態由 **WebSocket 事件即時推播**，完全移除 `setInterval` 輪詢。

| 頁面 | 觸發條件 | 更新方式 |
|------|----------|----------|
| 分機管理 | `EXT_STATUS_UPDATE` WebSocket 事件 | `applyExtStatusUpdate()` 局部更新單一 card DOM |
| 總覽 / 即時通話 | `CHANNEL_*` 事件 | `switchPage()` 重繪整頁 |
| 左側通話 badge | 同上 | `updateNavBadge()` |
| 號碼目錄搜尋/篩選 | 使用者操作 | 局部更新 tbody/filter-bar，搜尋欄焦點不丟失 |

---

## 4. 分機即時狀態系統

| 狀態 | Badge 文字 | 卡片背景色 | 排序優先級 |
|------|-----------|-----------|----------|
| `talking` | 🔊 通話 | 淡綠（深綠框） | 1（最優先） |
| `ringing` | 📞 響鈴 | 淡黃 | 2 |
| `holding` | ⏸ 保留 | 淡橘 | 3 |
| `parked` | 🅿 停車 | 淡藍 | 4 |
| `idle` | ✓ 上線 | 淡綠（淡框） | 5 |
| `offline` | ✕ 離線 | 淡灰 | 6（最後） |

```javascript
extStatusCache[ext]           // 全域快取
applyExtStatusUpdate(ext, st) // WebSocket 推播後局部更新 card DOM
loadExtStatusSnapshot()        // 初始載入快照
```

---

## 5. 設定系統

### 前端設定（localStorage）
```javascript
const SETTINGS_DEFAULTS = {
  fs_host: '192.168.100.209', fs_port: '8055', fs_password: 'FSPyAdmin',
  notify_missed: true, notify_maxcalls: '40',
  cdr_path: '/var/log/freeswitch/cdr-csv/Master.csv',
  cdr_retain_days: '30', log_retain_days: '30', ui_language: 'zh-TW',
};
```

### 後端設定（`/opt/fs-dashboard/settings.json`）
```json
{ "log_retain_days": 30, "cdr_retain_days": 30 }
```

### 設定頁樹狀選單節點
`connection` / `notify` / `cdr` / `log_retain` / `ui` / `dialplan`

---

## 6. ESL 連線即時套用

```
POST /api/config/reload
Body: { "host": "127.0.0.1", "port": 8055, "password": "FSPyAdmin" }
```

1. 前端設定頁填入新值 → `POST /api/config/reload`
2. 後端 `esl.reconnect()` 執行緒安全地重建連線
3. 設定持久化到 `settings.json`，下次啟動自動套用

---

## 7. esl_client.py 重要說明

- `read_packet()`：`Content-Type: text/event-plain` 時把 body 再解析一次
- CUSTOM 事件 remap：`sofia%3A%3Aregister` → `REGISTER`
- **datetime import**：一律使用 `from datetime import datetime, timedelta, date`，絕不混用 `import datetime`（module）

---

## 8. FreeSwitch 環境資訊

```
版本：FreeSWITCH 1.11.1 -dev-25527665241-7fbfe11d01 64bit
作業系統：Debian 13
IP：192.168.100.209
ESL Port：8055 / Password：FSPyAdmin
已登錄分機：1001 (192.168.100.107), 1002 (192.168.100.105)
Gateway 檔案：AC220.xml, example.xml → /etc/freeswitch/sip_profiles/external/
預設密碼：$${default_password} = user8976（vars.xml）
sip_profiles/internal.xml 已停用 ext-sip-ip / ext-rtp-ip
FreeSwitch loglevel：INFO（REGISTER 訊息為 DEBUG，改由 ESL 事件捕捉）
mod_ivr：未安裝（套件不存在），IVR 改用 mod_lua 實作
Lua JSON 函式庫：無 cjson，改用 ivr_runner.lua 內建純 Lua 解析器
```

### 品牌 CSS 變數（亮色系）
```css
--bg:#eef4fb       --panel:#ffffff      --panel2:#f4f8fd   --border:#c8d9ee
--accent:#0277bd   --accent-bright:#0288d1  --accent2:#c62828
--green:#00897b    --red:#c62828        --yellow:#e65100
--text:#0a1929     --muted:#3a5a7a      --label:#1e3d5c
```

---

## 9. 後端 API 端點完整清單

### ESL & 即時狀態
```
POST /api/esl                body: {command}
GET  /api/calls
GET  /api/channels
GET  /api/registrations
POST /api/calls/hangup       body: {uuid}
POST /api/calls/hold         body: {uuid}
POST /api/calls/transfer     body: {uuid, destination}
GET  /api/ext/status
GET  /api/reg/log            ?limit=200
POST /api/config/reload      body: {host, port, password}
```

### 通話記錄
```
GET  /api/cdr                ?limit=100&offset=0
GET  /api/cdr/stats          ?date_str=YYYY-MM-DD
GET  /api/cdr/archives
GET  /api/cdr/archive/download  ?filename=cdr-YYYY-MM-DD.csv
POST /api/cdr/rotate
DELETE /api/cdr/archive/{filename}
```

### 分機管理
```
GET    /api/extensions/list
POST   /api/extensions
PUT    /api/extensions/{id}
DELETE /api/extensions/{id}
```

### Gateway 管理
```
GET    /api/gateway/list
POST   /api/gateway
PUT    /api/gateway/{name}
DELETE /api/gateway/{name}
```

### 分機群組管理
```
GET    /api/groups/list
POST   /api/groups
PUT    /api/groups/{id}
DELETE /api/groups/{id}
```

### IVR 管理
```
GET    /api/ivr/list
GET    /api/ivr/{id}
POST   /api/ivr                              建立（生成 Dialplan XML + JSON）
PUT    /api/ivr/{id}                         更新（自動備份，相容舊 .xml 選單）
DELETE /api/ivr/{id}                         刪除（備份後移除）
GET    /api/ivr/lua/status                   確認 ivr_runner.lua 是否部署
POST   /api/ivr/lua/deploy                   部署 ivr_runner.lua 到 scripts 目錄
GET    /api/ivr/sounds/list                  列出可用語音檔（自定義 + 內建）
POST   /api/ivr/sounds/upload                上傳 WAV/MP3/OGG/GSM
DELETE /api/ivr/sounds/{filename}            刪除自定義語音檔
GET    /api/ivr/sounds/stream   ?path=...    瀏覽器預覽播放
```

### 號碼目錄
```
GET  /api/numbers                            整合所有號碼來源
```

### 錄音管理
```
GET    /api/recordings        ?search=&limit=50&offset=0
GET    /api/recordings/stream ?path=...
GET    /api/recordings/download ?path=...
DELETE /api/recordings        body: {path}
```

### 系統日誌
```
GET  /api/logs/stream
GET  /api/logs/list
GET  /api/logs/history       ?date&level&keyword&page&per_page
GET  /api/logs/download      ?date=YYYY-MM-DD
GET  /api/logs/grep          ?keyword=xxx&lines=100
POST /api/logs/rotate
```

### 設定
```
GET  /api/settings
POST /api/settings
```

### 檔案操作（Dialplan 編輯器）
```
GET    /api/dialplan
GET    /api/dialplan/file       ?path=...           讀取 XML
POST   /api/dialplan/file       body:{path,content} 儲存（驗證語法 + 備份 + reloadxml）
POST   /api/dialplan/create     body:{filename,context,content}  新增（驗證語法 + reloadxml）
DELETE /api/dialplan/file       body:{path}         刪除（備份 + reloadxml，禁止刪 Dashboard 管理檔）
GET    /api/download            ?path=...
```

---

### 設定 > 檔案路徑 — 功能修改總結 修改日期：2026-06-26

修改檔案：index.html（僅前端，server.py 無需變動）

變更 1：所有 XML 檔案支援直接網頁編輯
問題：原本只有 vars.xml 有「✏ 編輯」按鈕，其他 XML 只能下載。
原因：渲染邏輯已存在（item.editable 陣列），但其他項目未設定該屬性。
修改：在 dialplan_paths 資料定義中，為以下兩個群組加上 editable 陣列：
群組新增可編輯檔案Dialplan XMLdefault.xml、public.xmlGateway 設定internal.xml、external.xml
點擊「✏ 編輯」後跳轉至 dialplan_list 頁面的 XML 編輯器，支援語法驗證、格式化、自動備份、儲存後自動 reloadxml。

後端 /api/dialplan/file 的白名單已是 /etc/freeswitch/ 整個目錄，無需修改。


變更 2：移除無效的「瀏覽目錄」按鈕
問題：files 為空的項目（分機目錄、錄音檔案、音樂保留）會顯示「📂 瀏覽目錄」按鈕，但點擊後實際無法瀏覽。
修改：移除兩處：

按鈕的條件渲染邏輯（!item.files || item.files.length === 0 判斷）
目錄瀏覽面板 HTML（id="dir-browser" 的 div）

 

## 10. 已知問題 / 待開發

### 已知問題

| # | 問題 | 說明 |
|---|------|------|
| 1 | USER_NOT_REGISTERED 警告 | 每通電話出現的無害 NOTICE，mod_sofia 內部查詢順序造成，不影響通話品質 |
| 2 | 登錄記錄重啟後清空 | `reg_log` 存於記憶體，server 重啟後歸零；待改為 SQLite 持久化 |

### 下一步開發（優先順序）

**高優先**
- [ ] **登入驗證 + 權限管控**（三角色：admin / operator / viewer）
  - 錄音權限：viewer 只能看自己分機的錄音
- [ ] Nginx reverse proxy + HTTPS

**中優先**
- [ ] 登錄記錄持久化（SQLite）
- [ ] 通話統計圖表（週/月報表）

**低優先**
- [ ] 多租戶支援
- [ ] 錄音 `.trash` 自動清理

---


### 11. 通知設定 Tab 整體移除 2026-06-30 更新
原因：「通話統計報表」已提供明確的未接來電明細，此功能重複。
移除範圍：

CSS：#missed-toast-container、.missed-toast 系列樣式、toastIn 動畫
HTML：側欄 nav-missed-badge 計數徽章、頁面底部 toast 容器
JS：handleWSEvent 中未接來電偵測邏輯（_seenCallUUIDs/_answeredUUIDs）、showMissedToast/updateMissedBadge/clearMissedBadge/requestNotifyPermission 等函式
設定樹：「通知設定」節點與其渲染內容（未接來電警示開關、通話數量警示、通知權限申請）
SETTINGS_DEFAULTS 中的 notify_missed、notify_maxcalls

附帶發現：原本的未接來電判斷邏輯本身也有 bug——CHANNEL_DESTROY 事件固定顯示主叫方號碼，不分方向，導致「1126 撥給 1210，1210 未接」卻顯示「1126 未接」的誤報。此功能已直接移除，問題隨之解決。`
