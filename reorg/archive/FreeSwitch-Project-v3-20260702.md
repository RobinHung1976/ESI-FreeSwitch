# ESI 易通科技 FreeSwitch Dashboard — 專案總結 v3

> 最後更新：2026-07-02
> 供下次接續開發時快速掌握現況；官方手冊索引請另見 `FreeSWITCH_Official_Documentation_Quick_Index.md`。
> 本版重點：2026-07-01 後端/前端模組化重整、CDR SQLite 化、07-02 部署與即時狀態 bug 修復。

---

## 1. 系統架構

```
瀏覽器 (static/index.html)
    ↕ HTTP REST API (port 3000) / WebSocket (port 8080) / SSE
後端 (Python FastAPI) — /opt/fs-dashboard/
    ├── server.py            # 進入點：app 建立、middleware、mount、router 掛載、lifespan
    ├── core/
    │   ├── esl_client.py    # FreeSwitch ESL TCP 連線（純 socket，不用 greenswitch）
    │   ├── state.py         # 跨 router 共用狀態（ext_status、reg_log 等）
    │   ├── constants.py     # 跨 router 共用常數
    │   ├── runtime.py       # ESL 事件回調、log/CDR 排程、WebSocket 啟動
    │   ├── ws_manager.py    # WebSocket 推播管理
    │   ├── backup_manager.py
    │   ├── dialplan_common.py
    │   └── cdr_db.py        # ← 07-02 新增，SQLite CDR 儲存層
    ├── routers/             # 18 個 APIRouter，依領域拆分（見第 9 節）
    ├── static/
    │   ├── index.html
    │   ├── style.css
    │   └── js/*.js          # 14 個模組檔，common.js 最先載入、init.js 最後載入
    ├── data/cdr.db          # ← 07-02 新增
    └── ivr_runner.lua → /usr/share/freeswitch/scripts/（IVR Lua 執行引擎，屬 FreeSwitch 本身，非 Dashboard app）
    ↕ ESL TCP port 8055（兩條獨立 socket：一條 API、一條事件監聽）
FreeSwitch 1.11.1 on Debian 13
  IP: 192.168.100.209
  ESL Port: 8055 / Password: FSPyAdmin
```

> ⚠ ESL 連線正確值為 **port 8055 / 密碼 FSPyAdmin**（`core/esl_client.py` 內硬編碼）。
> 手動除錯：`fs_cli -H 127.0.0.1 -P 8055 -p FSPyAdmin`

### 1.1 後端路徑重整說明（2026-07-01，v2 → v3 主要差異）

舊版 `server.py`（3,470 行、約 70 個 API 端點）與 `index.html`（10,634 行、293 個函式）皆為單一巨石檔案，難以維護，已拆分為上述模組化結構：

| 舊路徑（v2） | 新路徑（v3） |
|---|---|
| `/opt/fs-dashboard/server.py`（全部邏輯） | `/opt/fs-dashboard/server.py`（僅 app/middleware/mount/router/lifespan） |
| （無） | `/opt/fs-dashboard/core/*.py`（共用狀態、常數、背景排程） |
| （無） | `/opt/fs-dashboard/routers/*.py`（18 個領域 API） |
| `/opt/fs-dashboard/esl_client.py` | `/opt/fs-dashboard/core/esl_client.py` |
| `/opt/fs-dashboard/ws_manager.py` | `/opt/fs-dashboard/core/ws_manager.py` |
| `/opt/fs-dashboard/index.html` | `/opt/fs-dashboard/static/index.html` |
| （單一 `<script>`） | `/opt/fs-dashboard/static/js/*.js`（14 檔，依模組拆分） |
| （無） | `/opt/fs-dashboard/static/css/style.css`（獨立出來，原內嵌於 index.html） |

**驗證方式**：拆分前後以 `TestClient` 打 `/openapi.json` 比對所有路徑與 HTTP method → **74 條路由完全一致**；前端所有頂層函式/變數宣告排序後 diff → **297 個函式、107 個變數完全一致**。

> ⚠ **重要（2026-07-02 事故記錄）**：曾發生部署時 `server.py` 誤放進 `routers/` 子目錄（`/opt/fs-dashboard/routers/server.py`），導致 `systemctl restart fs-dashboard` 後 crash-loop、`ERROR: Could not import module "server"`。
> 排查法：`journalctl` 摘要不含完整 traceback，應先手動執行 `cd /opt/fs-dashboard && /opt/myapp/venv/bin/python -c "import server"` 取得真正錯誤原因（語法/匯入/檔案位置）。
> **`server.py` 必須位於專案根目錄** `/opt/fs-dashboard/server.py`，不可放進 `routers/`。

### 服務管理
```bash
systemctl start/stop/restart fs-dashboard
# /etc/systemd/system/fs-dashboard.service，After=freeswitch.service
# WorkingDirectory=/opt/fs-dashboard，ExecStart=uvicorn server:app（在根目錄找 server.py）

# 手動啟動
cd /opt/fs-dashboard
source /opt/myapp/venv/bin/activate
uvicorn server:app --host 0.0.0.0 --port 3000 --reload
```

### Python 環境
虛擬環境：`/opt/myapp/venv/`
套件：`fastapi`、`uvicorn`、`websockets`、`lxml`、`python-multipart`（07-01 重整時發現 `requirements.txt` 原本漏列 `python-multipart`、`lxml`，已補上）

```bash
/opt/myapp/venv/bin/pip install -r requirements.txt --break-system-packages
```

### 部署方式（整包資料夾，非單檔）
```bash
# 新增 API 端點 → 改 routers/*.py，不用再改 server.py
# 新增前端頁面 → static/js/ 新檔案，static/index.html 補 <script src="/static/js/xxx.js">
#                （務必放在 init.js 之前，因 init.js 會組裝 pages 物件並呼叫 switchPage）

# 部署整個資料夾（保留 settings.json 與 backups/）
cd /opt/fs-dashboard
cp settings.json /tmp/settings.json.bak
find . -maxdepth 1 ! -name backups ! -name . -exec rm -rf {} +
unzip /path/to/fs-dashboard-restructured.zip -d .
cp /tmp/settings.json.bak settings.json
pip install -r requirements.txt --break-system-packages
systemctl restart fs-dashboard
```

> ⚠ **重要**：`server.py` 或任何 `routers/*.py` / `core/*.py` 更新（尤其新增 Pydantic 欄位）必須 `systemctl restart fs-dashboard`，否則新欄位會被靜默忽略。
> ⚠ `app.mount("/static", StaticFiles(directory="static"))` 代表整個新資料夾結構要放同一層，不能只丟 `server.py` 進去。

### 檔案路徑對照

| 用途 | 路徑 |
|------|------|
| 專案目錄 | `/opt/fs-dashboard/` |
| 後端進入點 | `/opt/fs-dashboard/server.py` |
| 後端共用模組 | `/opt/fs-dashboard/core/` |
| 後端 API router | `/opt/fs-dashboard/routers/` |
| 前端骨架 | `/opt/fs-dashboard/static/index.html` |
| 前端樣式 | `/opt/fs-dashboard/static/css/style.css` |
| 前端 JS 模組 | `/opt/fs-dashboard/static/js/` |
| 後端設定檔 | `/opt/fs-dashboard/settings.json` |
| CDR SQLite DB | `/opt/fs-dashboard/data/cdr.db` |
| 備份輸出目錄 | `/opt/fs-dashboard/backups/` |
| IVR Lua 引擎 | `/usr/share/freeswitch/scripts/ivr_runner.lua` |
| FreeSwitch 設定根目錄 | `/etc/freeswitch/` |
| 全域變數 | `/etc/freeswitch/vars.xml` |
| 分機目錄 | `/etc/freeswitch/directory/default/` |
| Dialplan | `/etc/freeswitch/dialplan/` |
| 群組 XML | `/etc/freeswitch/dialplan/default/00_group_*.xml` |
| IVR Dialplan XML | `/etc/freeswitch/dialplan/default/00_ivr_*.xml` |
| Dialplan 路由規則 XML | `/etc/freeswitch/dialplan/default/00_route_*.xml` |
| IVR JSON 設定 | `/etc/freeswitch/ivr-menus/*.json` |
| Gateway XML | `/etc/freeswitch/sip_profiles/external/` |
| CDR CSV（即時） | `/var/log/freeswitch/cdr-csv/Master.csv` |
| CDR CSV（歸檔） | `/var/log/freeswitch/cdr-csv/cdr-YYYY-MM-DD.csv` |
| 系統日誌（即時） | `/var/log/freeswitch/freeswitch.log` |
| 系統日誌（歷史） | `/var/log/freeswitch/freeswitch-YYYY-MM-DD.log` |
| 錄音（依日期分資料夾） | `/var/lib/freeswitch/recordings/YYYYMMDD/` |
| 錄音 mono 合併檔 | `/var/lib/freeswitch/recordings/.mono/` |
| 錄音刪除暫存區 | `/var/lib/freeswitch/recordings/.trash/` |
| 錄音索引 SQLite | `/var/lib/freeswitch/recordings/.rec_index.db` |
| 自定義語音檔 | `/var/lib/freeswitch/sounds/custom/` |
| 內建語音檔根目錄 | `/usr/share/freeswitch/sounds/{en,es,fr,pt,ru,music}/` |

---

## 2. 已完成功能總覽

| 頁面 | 核心功能 |
|------|----------|
| 通話即時狀態 | 統計卡整合進 panel header、使用者即時狀態表（A/B leg 去重、rowspan 多通話、錄音/方向/通話類型 badge） |
| 通話統計報表 | 日期快捷（今天/昨天/本週/本月）、摘要卡、每小時/每日圖表、Top5 排行圓餅圖、未接通明細、CSV 匯出 |
| 分機管理 Extensions | CRUD（自動備份 `.bak`）、🔄 變更號碼、即時分機狀態（WebSocket 事件驅動）、通話計時器、狀態顏色 Badge、上線優先排序、**自動錄音開關** |
| 分機群組 Groups | 同時/依序響鈴群組 CRUD、成員多選 chip、無人接聽 fallback、🔄 變更號碼（含號碼衝突告警） |
| IVR 管理 | 按鍵選單、直撥分機、時段路由（含 offhour 語音）、無效鍵/超時重播次數控制 |
| 通話記錄 CDR | 雙 Tab：📞 即時 CDR / 📋 歷史 CDR，**改為 SQLite 雙層架構**（明細 + 每日彙總，見第 11 節） |
| Gateway / SIP Trunk | CRUD、`sofia status` 解析、reloadxml + rescan |
| 錄音管理 Recordings | SQLite 索引、依分機/時間篩選、立體聲/單聲道切換播放與下載、共用播放器、刪除（移至 `.trash`） |
| Dialplan 路由設定 | 三合一頁面（路由規則 CRUD + 衝突檢查 + 測試工具 ／ 系統內建唯讀 ／ 自定義範本+XML 編輯器） |
| 音檔庫 | 自訂音檔（上傳/刪除/試聽）+ 內建音檔（1016 筆，分頁載入）統一管理，IVR 共用同一組 API |
| 全域變數 | `vars.xml` 白名單編輯（8 個安全變數），寫入自動備份 + reloadxml 立即套用 |
| 備份管理 | Dashboard 設定 / FreeSwitch 套件雙軌備份、上傳還原、每日自動排程（可設定時間） |
| ESL 終端機 | 任意 ESL 指令、快捷按鈕（含原「重載指令」搬移過來）；白底大字輸出；捲動分頁 |
| 系統日誌 Logs | 四 Tab：即時串流 / 歷史分頁搜尋 / 登錄記錄 / 日誌管理 |
| 號碼目錄 | 整合所有號碼來源 |
| 設定 Settings | 連線 / CDR（含歸檔管理）/ 日誌保留 / 介面設定 / 全域變數 / 檔案路徑 |

> ❌ V2 的「未接來電通知」功能已於 2026-06-30 整組移除（見第 10 節）。

### 導覽架構（現況）
```
監控                              ← 可收合 accordion，狀態存 localStorage
  ├── 通話即時狀態                ← V2「總覽+即時通話」合併重構
  └── 通話統計報表                ← 新增（07-01 從即時狀態頁拆出）
管理
  ├── 分機管理
  ├── 分機群組
  ├── IVR 管理
  ├── 通話記錄 CDR
  ├── 錄音管理
  ├── Gateway / SIP Trunk
  ├── Dialplan 路由設定           ← 新增（合併原 3 個獨立項目）
  └── 音檔庫                      ← 新增（06-30）
系統
  ├── 號碼目錄
  ├── ESL 終端機
  ├── 系統日誌
  ├── 設定（含全域變數子節點）
  └── 備份管理                    ← 新增（06-26，從系統設定獨立出來）
```

---

## 3. 頁面更新機制（純事件驅動）

所有頁面狀態由 **WebSocket 事件即時推播**，完全移除 `setInterval` 輪詢。

| 頁面 / 元件 | 觸發條件 | 更新方式 |
|------|----------|----------|
| 分機管理 卡片 | `EXT_STATUS_UPDATE` WebSocket 事件 | `applyExtStatusUpdate()` 局部更新單一 card DOM（同時更新監控板） |
| 使用者即時狀態表 | `CHANNEL_CREATE/ANSWER/DESTROY/HOLD` | 直接操作前端 `_liveCalls` 物件 → `_renderLiveCalls()`，不重繪整表，DocumentFragment 局部插入 |
| 左側通話 badge (nav) | 同上 | `updateNavBadge()`，07-02 改為直讀 `_liveCalls`（見第 12 節） |
| Header badge | 同上 | `_ucUpdateBadge()`，切頁時打 `/api/calls` 校正 |
| 號碼目錄搜尋/篩選 | 使用者操作 | 局部更新 tbody/filter-bar，搜尋欄焦點不丟失 |
| 音檔庫搜尋 | 使用者操作 | debounce 300ms 後局部重繪，焦點與游標還原 |

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

### 使用者即時狀態表（A/B leg 去重，07-01 前重構）
- 一列 = 一個人，通話資訊附掛在人後面（rowspan 子列支援多通話）
- 去重策略：優先用 `b_uuid` 封鎖對向 leg；WS 輕量物件無 `b_uuid` 時 fallback 用 `sort([cid_num, dest]).join('|')` 當 pair key
- 方向 Badge：`▶ 撥出`（藍）／`◀ 來電`（綠）；通話類型 Badge：`↔ 內線`（3–6 位數字，紫）／`🌐 外線`（橘）
- 錄音 Badge：`ext.recording_enabled && hasCall` 時顯示 🔴 脈衝動畫

---

## 5. 設定系統

### 前端設定（localStorage）
```javascript
const SETTINGS_DEFAULTS = {
  fs_host: '192.168.100.209', fs_port: '8055', fs_password: 'FSPyAdmin',
  cdr_path: '/var/log/freeswitch/cdr-csv/Master.csv',
  cdr_retain_days: '30', cdr_summary_retain_days: '730',   // ← 07-02 新增
  log_retain_days: '30', ui_language: 'zh-TW',
  backup_path: '/opt/fs-dashboard/backups', backup_retain_days: '30',
  backup_auto_enabled: false, backup_auto_time: '00:01',
};
```
> `notify_missed` / `notify_maxcalls` 已於 06-30 隨「通知設定」功能整組移除。

### 後端設定（`/opt/fs-dashboard/settings.json`）
```json
{
  "log_retain_days": 30,
  "cdr_retain_days": 30,
  "cdr_summary_retain_days": 730,
  "backup_path": "/opt/fs-dashboard/backups",
  "backup_retain_days": 30,
  "backup_auto_enabled": false,
  "backup_auto_time": "00:01"
}
```

### 設定頁樹狀選單節點
`connection` / `cdr` / `log_retain` / `ui` / `vars`（← 新增，全域變數）/ `dialplan_paths`（檔案路徑）
> `notify` 節點已移除；原「Dialplan 設定」整組移除（Context 清單砍掉、檔案路徑拉平、重載指令搬到 ESL 終端機頁）。

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

## 7. core/esl_client.py 重要說明

- `read_packet()`：`Content-Type: text/event-plain` 時把 body 再解析一次
- CUSTOM 事件 remap：`sofia%3A%3Aregister` → `REGISTER`
- **datetime import**：一律使用 `from datetime import datetime, timedelta, date`，絕不混用 `import datetime`（module）
- `_status_callback` 呼叫端包在 `try/except` 內，僅印 log 不中斷；07-02 曾因此吞掉 `NameError` 導致狀態推播靜默失效（見第 12 節）

---

## 8. FreeSwitch 環境資訊

```
版本：FreeSWITCH 1.11.1 -dev-25527665241-7fbfe11d01 64bit
作業系統：Debian 13
IP：192.168.100.209
ESL Port：8055 / Password：FSPyAdmin
Gateway 檔案：AC220.xml, example.xml → /etc/freeswitch/sip_profiles/external/
預設密碼：$${default_password} = user8976（vars.xml，可於「全域變數」頁修改）
sip_profiles/internal.xml 已停用 ext-sip-ip / ext-rtp-ip
FreeSwitch loglevel：INFO（REGISTER 訊息為 DEBUG，改由 ESL 事件捕捉）
mod_ivr：未安裝（套件不存在），IVR 改用 mod_lua 實作
Lua JSON 函式庫：無 cjson，改用 ivr_runner.lua 內建純 Lua 解析器
```

### 品牌 CSS 變數（亮色系，未變動）
```css
--bg:#eef4fb       --panel:#ffffff      --panel2:#f4f8fd   --border:#c8d9ee
--accent:#0277bd   --accent-bright:#0288d1  --accent2:#c62828
--green:#00897b    --red:#c62828        --yellow:#e65100
--text:#0a1929     --muted:#3a5a7a      --label:#1e3d5c
```

---

## 9. 後端 API 端點（74 條，18 個 router）

### routers/calls.py — ESL & 即時狀態
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

### routers/cdr.py — 通話記錄（07-02 改走 SQLite，見第 11 節）
```
GET  /api/cdr                ?limit=100&offset=0
GET  /api/cdr/stats          ?date_str=YYYY-MM-DD&date_to=&user=
GET  /api/cdr/archives
GET  /api/cdr/archive/download  ?filename=cdr-YYYY-MM-DD.csv
POST /api/cdr/rotate
DELETE /api/cdr/archive/{filename}
```

### routers/extensions.py
```
GET    /api/extensions/list
POST   /api/extensions
PUT    /api/extensions/{id}
DELETE /api/extensions/{id}
```

### routers/gateway.py
```
GET    /api/gateway/list
POST   /api/gateway
PUT    /api/gateway/{name}
DELETE /api/gateway/{name}
```

### routers/groups.py
```
GET    /api/groups/list
POST   /api/groups
PUT    /api/groups/{id}
DELETE /api/groups/{id}
```

### routers/ivr.py
```
GET    /api/ivr/list
GET    /api/ivr/{id}
POST   /api/ivr
PUT    /api/ivr/{id}
DELETE /api/ivr/{id}
GET    /api/ivr/lua/status
POST   /api/ivr/lua/deploy
GET    /api/ivr/sounds/list        # 向下相容，內部委派 routers/sounds.py
POST   /api/ivr/sounds/upload      # 同上
DELETE /api/ivr/sounds/{filename}  # 同上
GET    /api/ivr/sounds/stream      # 同上
```

### routers/sounds.py — ← 06-30 新增（音檔庫）
```
GET    /api/sounds/list        ?category=
POST   /api/sounds/upload
DELETE /api/sounds/{filename}  ?force=
GET    /api/sounds/usage       ?filename=
GET    /api/sounds/stream      ?path=
```

### routers/numbers.py
```
GET  /api/numbers
```

### routers/recordings.py
```
GET    /api/recordings        ?extension=&start_dt=&end_dt=&search=&limit=&offset=
GET    /api/recordings/stream       ?path=...
GET    /api/recordings/stream_mono  ?path=...   # ← 06-29 新增
GET    /api/recordings/download     ?path=...
POST   /api/recordings/sync
DELETE /api/recordings        body: {path}
```

### routers/logs.py
```
GET  /api/logs/stream
GET  /api/logs/list
GET  /api/logs/history       ?date&level&keyword&page&per_page
GET  /api/logs/download      ?date=YYYY-MM-DD
GET  /api/logs/grep          ?keyword=xxx&lines=100
POST /api/logs/rotate
```

### routers/settings.py
```
GET  /api/settings
POST /api/settings
```

### routers/vars.py — ← 06-30 新增（全域變數）
```
GET  /api/vars
POST /api/vars
```

### routers/backup.py — ← 06-26 新增
```
GET    /api/backup/list
POST   /api/backup/run          body: {type: config|packages|both}
GET    /api/backup/download     ?filename=
DELETE /api/backup/{filename}
POST   /api/backup/restore      （上傳還原）
```

### routers/dialplan_files.py — Dialplan 檔案編輯器
```
GET    /api/dialplan
GET    /api/dialplan/file       ?path=...
POST   /api/dialplan/file       body:{path,content}
POST   /api/dialplan/create     body:{filename,context,content}
DELETE /api/dialplan/file       body:{path}
GET    /api/download            ?path=...
```

### routers/dialplan_routes.py — 類型一：路由規則
```
GET    /api/dialplan/routes
GET    /api/dialplan/routes/{id}
POST   /api/dialplan/routes
PUT    /api/dialplan/routes/{id}
DELETE /api/dialplan/routes/{id}
PATCH  /api/dialplan/routes/{id}/toggle
POST   /api/dialplan/routes/check-conflict
POST   /api/dialplan/routes/test-number
POST   /api/dialplan/routes/legacy/upgrade
```

### routers/dialplan_system_extensions.py — 類型二：系統內建（唯讀）
```
GET  /api/dialplan/system-extensions
```

### routers/dialplan_custom.py — 類型三：自定義
```
GET    /api/dialplan/custom/list
GET    /api/dialplan/custom/file    ?path=...
POST   /api/dialplan/custom         （範本模式新增）
PUT    /api/dialplan/custom/{id}    （範本模式更新）
POST   /api/dialplan/custom/preview
```

> 完整白名單/欄位定義、各 router 詳細規格請見對應功能文件（`dialplan-*-20260701.md`、`vars-config-feature-20260630.md`、`audio-library-feature-20260630.md`、`backup-feature-20260626.md`、`recording-*-20260629.md`）。

---

## 10. 已移除功能

### 通知設定 Tab 整體移除（2026-06-30）
原因：「通話統計報表」已提供明確的未接來電明細，此功能重複。
移除範圍：CSS（`.missed-toast` 系列）、HTML（nav badge、toast 容器）、JS（`showMissedToast`/`updateMissedBadge` 等）、設定樹「通知設定」節點、`notify_missed`/`notify_maxcalls`。
附帶發現：原未接來電判斷邏輯有 bug（`CHANNEL_DESTROY` 固定顯示主叫方號碼，不分方向），隨功能移除問題一併解決。

---

## 11. CDR 統計報表 SQLite 化（2026-07-02，重大架構變更）

### 問題
CDR 報表原本直接掃描 CSV（`Master.csv` / 歸檔 `cdr-YYYY-MM-DD.csv`）。`cdr_retain_days` 設 3 天時，超過 3 天的歸檔即被排程刪除，導致查詢 3 天前日期靜默回傳空結果，且明細保留天數（受磁碟限制，需短）與統計可查詢天數（報表需求，應該長）被綁死在同一設定。

### 解法：兩層 SQLite 儲存架構

| Table | 內容 | 保留設定 | 用途 |
|---|---|---|---|
| `cdr` | 逐通明細（raw） | `cdr_retain_days`（預設 30） | `/api/cdr` 明細列表、未接通清單、CSV 匯出 |
| `cdr_daily_summary` | 每日彙總（總量/接通率/24h分佈/Top10） | `cdr_summary_retain_days`（新增，預設 730） | `/api/cdr/stats` 長區間報表趨勢圖 |

**流程**：`mod_cdr_csv` 持續寫 `Master.csv`（不變）→ 每次 API 呼叫前增量同步進 `cdr` table（`uuid` 去重、`INSERT OR IGNORE`，冪等）→ 每日 00:00:30 排程：同步 → 建當日彙總 → 封存 CSV → 清空 `Master.csv` → cleanup 排程依兩個保留天數分別清理。

**查詢 fallback**：raw 明細在保留期內 → 精確聚合；已 purge 但彙總仍在 → 自動 fallback 讀彙總，回傳 `summary_fallback_used` 供前端提示「⚠ 含歷史彙總資料」。

**已知限制**：超過 `cdr_retain_days` 的日期，逐通未接通清單無法還原（明細已實際刪除）；混合區間查詢時，已 purge 日期的「依分機篩選每小時分佈」無法還原（彙總表未存逐通明細）。

**修改檔案**：`core/cdr_db.py`（新增）、`routers/cdr.py`（改走 cdr_db）、`core/runtime.py`（新增 `cdr_summary_retain_days` 預設值、排程整合）、`server.py`（`lifespan` 呼叫 `cdr_db.init_db()`）、`static/js/overview-report.js`、`static/js/settings-vars.js`、`migrate_cdr_backfill.py`（新增，一次性搬遷腳本）。

---

## 12. 2026-07-02 Bug 修復記錄

| # | 問題 | 根本原因 | 修復 |
|---|------|---------|------|
| 1 | 分機登入/登出無法即時更新（需重整才顯示） | `core/runtime.py` 呼叫 `_write_reg_log(...)` 但實際函式名為 `write_reg_log(...)`（無底線）→ `NameError`；且用了未匯入的裸名 `REG_LOG_MAX`（應為 `state.REG_LOG_MAX`）。兩者皆被 `esl_client.py` 的 `try/except` 靜默吞掉，`broadcast_ext_status()` 從未執行到 | 修正函式名稱與命名空間引用 |
| 2 | 部署後服務 crash-loop，`Could not import module "server"` | `server.py` 誤放進 `/opt/fs-dashboard/routers/` 而非根目錄 | 搬回 `/opt/fs-dashboard/server.py`，並建議用 `python -c "import server"` 直接排查 import 錯誤 |
| 3 | 左側 nav「通話即時狀態」badge 計數與實際不符，卡在舊值 | `updateNavBadge()` 獨立打 `/api/calls` 取未去重的 `row_count`，且只靠 WebSocket 事件觸發、無校正機制，漏接 `CHANNEL_DESTROY` 即永久飄移 | 改為直讀已去重的 `_liveCalls`；`initWebSocket()` 的 `onopen` 新增 `_refreshMonitorCallsTable()` 於連線/重連時強制校正 |

---

## 13. 官方文件索引

見 `FreeSWITCH_Official_Documentation_Quick_Index.md`（獨立檔案，未變動）。

---

## 14. 下一步開發（優先順序）

**高優先**
- [ ] 登入驗證 + 權限管控（三角色：admin / operator / viewer；錄音權限：viewer 只能看自己分機）
- [ ] Nginx reverse proxy + HTTPS

**中優先**
- [ ] 登錄記錄（`reg_log`）持久化（目前仍在記憶體，重啟歸零；注意：CDR 已 SQLite 化，但 reg_log 尚未，兩者不同，不可混淆）
- [ ] Dialplan Context 切換 UI（後端 `RouteRule` 已有 `context` 欄位，前端加選單即可）

**低優先**
- [ ] 多租戶支援
- [ ] 錄音 `.trash` 自動清理
- [ ] Dialplan 備份歷史列表與一鍵還原
- [ ] 分機/語音信箱問候語串接音檔庫選擇器（目前僅 IVR 已串接）
