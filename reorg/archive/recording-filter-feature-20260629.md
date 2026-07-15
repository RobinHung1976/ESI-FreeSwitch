# 錄音管理篩選功能實作總結

**實作日期**：2026-06-29
**功能描述**：錄音管理頁面新增 SQLite 索引、依分機篩選（可搜尋下拉）、依時間範圍篩選（日曆 picker）

---

## 架構設計

| 層級 | 方案 | 說明 |
|------|------|------|
| 索引 | SQLite（方案 D） | 不存音檔本體，只存 metadata，支援大量資料 |
| API | Query Params 篩選（方案 B） | 後端查 DB，不做全量 `os.walk` |
| 前端 | 篩選 UI（方案 C） | 可搜尋分機下拉 + datetime-local 範圍選擇 |
| 同步 | 雙保險 | API 查詢時即時同步 + 背景每 5 分鐘全量掃描 |

---

## 修改檔案

### 1. `server.py`

**修改位置**：第 1488 行 `# ── 錄音管理 ──` 區塊，完整替換至原 `delete_recording` 結尾

#### 新增常數與工具

```python
RECORDINGS_DIR = "/var/lib/freeswitch/recordings"
REC_DB_PATH    = "/var/lib/freeswitch/recordings/.rec_index.db"
_AUDIO_EXTS    = {'.wav', '.mp3', '.ogg', '.gsm'}

# 檔名解析 Regex：{caller}_{callee}_{YYYYMMDD}_{HHMMSS}_{uuid}.ext
_REC_FNAME_RE = re.compile(
    r'^(?P<caller>\d+)_(?P<callee>\d+)_(?P<date>\d{8})_(?P<time>\d{6})_(?P<uuid>[^.]+)\.\w+$'
)
```

#### SQLite DB 結構（`_rec_db()`）

```
recordings 表
├── id           INTEGER PK
├── filename     TEXT
├── path         TEXT UNIQUE
├── caller       TEXT  ← 主叫分機（篩選用）
├── callee       TEXT  ← 被叫分機
├── rec_date     TEXT  ← YYYYMMDD
├── rec_time     TEXT  ← HHMMSS
├── rec_dt       TEXT  ← YYYYMMDD_HHMMSS（排序/範圍篩選用）
├── size         INTEGER
├── duration_est REAL  ← 粗估秒數（size / 32000）
├── mtime        TEXT
└── created_at   TEXT

索引：idx_caller, idx_rec_dt, idx_rec_date
PRAGMA journal_mode=WAL（多讀安全）
```

#### 新增函式

| 函式 | 說明 |
|------|------|
| `_rec_db()` | 取得 SQLite 連線，自動建表與索引 |
| `_parse_rec_filename(fname)` | 從檔名 Regex 解析 caller/callee/date/time |
| `_upsert_file_to_db(conn, fpath)` | 單檔 upsert，size 不變則跳過 |
| `sync_recordings_to_db()` | 全量掃描目錄並同步 DB，清除已刪除檔案的記錄 |
| `_start_rec_sync_scheduler()` | 背景執行緒，每 300 秒呼叫一次 `sync_recordings_to_db()` |

#### 修改 API

**`GET /api/recordings`** — 新增 query params：

| 參數 | 說明 |
|------|------|
| `extension` | 主叫分機號碼（完全匹配） |
| `start_dt` | 開始時間，格式 `YYYY-MM-DDTHH:MM` |
| `end_dt` | 結束時間，格式 `YYYY-MM-DDTHH:MM` |
| `search` | 檔名關鍵字（向下相容） |
| `limit` / `offset` | 分頁 |

轉換邏輯：`start_dt` → `rec_dt >= YYYYMMDD_HHMM00`，`end_dt` → `rec_dt <= YYYYMMDD_HHMM59`

**`POST /api/recordings/sync`** — 手動觸發全量索引同步，回傳已索引總數

**`DELETE /api/recordings`** — 移至 `.trash` 後同步從 DB 刪除對應記錄

#### 新增 import

```python
import sqlite3
import re as _re
```

---

### 2. `index.html`

**修改位置**：第 5521 行 `// ── 錄音管理頁面 ──` 至 `deleteRecording` 函式結尾（原第 5634 行）

#### 篩選狀態物件

```javascript
const _recFilter = { extension: '', start_dt: '', end_dt: '' };
```

#### `renderRecordings()` 新增功能

1. 呼叫 `/api/extensions/list` 取得所有分機清單
2. 復用 IVR 既有的 `_ivrSearchableSelect()` 產生可搜尋分機下拉選單
3. 使用原生 `<input type="datetime-local">` 作為開始/結束時間選擇器（瀏覽器內建日曆，無需外部套件）
4. `✕ 清除` 按鈕重置所有篩選並重繪頁面
5. `🔄 同步` 按鈕呼叫 `POST /api/recordings/sync` 手動重建索引

#### `loadRecordings()` 修改

- 從 `_recFilter` 組裝 `URLSearchParams` 送給後端
- badge 顯示篩選中/總數量
- 空結果依是否有篩選顯示不同提示文字

#### `buildRecCard()` 新增顯示

- 顯示通話方向：`📞 {caller} → {callee}`（有解析到檔名才顯示）
- 時間顯示從 `rec_date` + `rec_time` 格式化，優先於 `mtime`

---

## Bug 修復記錄

| 問題 | 原因 | 修復 |
|------|------|------|
| `TabError: inconsistent use of tabs and spaces` 在第 1641 行 | 貼上代碼時 tab/空格混用 | 用 Python `expandtabs(4)` 全檔修正 + 手動修正 `except` 縮排錯誤 |
| 分機下拉只顯示「全部分機」無其他選項 | API 路徑錯誤，用了不存在的 `/api/extensions`，正確路徑為 `/api/extensions/list` | 修正 `apiFetch` 呼叫路徑 |

---

## 檔案路徑

| 項目 | 路徑 |
|------|------|
| SQLite 索引 DB | `/var/lib/freeswitch/recordings/.rec_index.db` |
| 錄音主目錄 | `/var/lib/freeswitch/recordings/YYYYMMDD/` |
| 刪除暫存區 | `/var/lib/freeswitch/recordings/.trash/` |
| Dashboard server | `/opt/fs-dashboard/server.py` |
| Dashboard 前端 | `/opt/fs-dashboard/index.html` |

---

## 運作流程

```
使用者進入錄音管理頁
  → renderRecordings() 載入分機清單 (/api/extensions/list)
  → 渲染可搜尋分機下拉 + datetime-local 開始/結束時間
  → loadRecordings() 呼叫 GET /api/recordings
      → sync_recordings_to_db()（快速同步新檔）
      → SQLite 查詢（extension / rec_dt 範圍 / filename LIKE）
      → 回傳分頁結果
  → buildRecCard() 渲染每筆錄音卡片

背景執行緒（每 5 分鐘）
  → sync_recordings_to_db()
      → os.walk 掃描目錄
      → upsert 新檔 / 清除已刪除記錄
      → commit
```
