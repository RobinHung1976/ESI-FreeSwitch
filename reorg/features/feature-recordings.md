# 錄音管理（Recordings）

> 本文件描述**目前現況**，不記錄演變過程。演變歷史與踩坑記錄見對應的 changelog-details：
> [20260629 錄音功能實作](../changelog-details/20260629-recording-feature.md) ·
> [20260629 錄音篩選功能](../changelog-details/20260629-recording-filter-feature.md) ·
> [20260629 錄音介面優化](../changelog-details/20260629-recording-ui-feature.md) ·
> [20260702 播放器捲動修復](../changelog-details/20260702-recording-ui-scroll-player-fix.md)

## 功能概述

針對個別分機設定是否自動錄音，啟用後該分機的所有通話自動錄音並儲存於伺服器，可在 Dashboard 錄音管理頁面依分機/時間篩選、線上播放（立體聲/單聲道切換）、下載、刪除。

## 錄音觸發機制

| 項目 | 說明 |
|---|---|
| 觸發條件 | 分機設定頁勾選「啟用此分機自動錄音」（`recording_enabled` 欄位） |
| 觸發時機 | 通話建立時（不需等待接通） |
| 錄音模式 | 立體聲（`RECORD_STEREO=true`，主被叫各一聲道） |
| 轉接跟隨 | 是（`recording_follow_transfer=true`） |
| 實作位置 | `/etc/freeswitch/dialplan/default.xml` 的 `global` extension（`continue="true"`），透過 `user_data()` 讀取分機的 `recording_enabled` 變數 |

**分機設定端**（`server.py` / `static/index.html`）：
- `ExtensionData` 模型含 `recording_enabled: bool = False`
- `write_extension_xml()` 寫入分機 XML 的 `<variable name="recording_enabled" value="true/false"/>`
- `list_extensions()` 回傳值含 `recording_enabled` 欄位，供前端分機管理頁勾選框與監控板紅點動畫使用

## 儲存與檔名規則

| 項目 | 說明 |
|---|---|
| 儲存路徑 | `/var/lib/freeswitch/recordings/YYYYMMDD/`（每日子目錄，通話建立時自動 `mkdir -p`） |
| 檔名格式 | `{主叫}_{被叫}_{YYYYMMDD}_{HHMMSS}_{uuid}.wav` |
| Mono 合併檔 | `/var/lib/freeswitch/recordings/.mono/`，用 Python 標準庫 `wave` + `array` 將立體聲左右聲道平均混成單聲道（**免安裝 ffmpeg**），入庫時自動產生，已存在且來源未更新則跳過 |
| 刪除暫存區 | `/var/lib/freeswitch/recordings/.trash/`（刪除是移動，非直接抹除） |
| 檔名解析正則 | `^(?P<caller>\+?\d+)_(?P<callee>\+?\d+)_(?P<date>\d{8})_(?P<time>\d{6})_(?P<uuid>[^.]+)\.\w+$`（開頭數字段落允許選填 `+`，支援外線來電號碼格式） |

## 索引架構（SQLite）

不做全量 `os.walk` 掃描回應每次查詢，改用 SQLite 索引：

| 項目 | 說明 |
|---|---|
| DB 路徑 | `/var/lib/freeswitch/recordings/.rec_index.db` |
| 資料表 | `recordings`：`id`/`filename`/`path`(UNIQUE)/`caller`/`callee`/`rec_date`/`rec_time`/`rec_dt`/`size`/`duration_est`/`mono_path`/`mtime`/`created_at` |
| 索引 | `idx_caller`、`idx_callee`、`idx_rec_dt`、`idx_rec_date` |
| 同步機制（雙保險） | ① 每次 API 查詢前先做增量同步（快速）；② 背景執行緒每 5 分鐘全量 `os.walk` 掃描一次，upsert 新檔、清除已刪除檔案的記錄（跳過 `.mono` 目錄，避免 mono 檔被誤索引進主表） |
| 手動同步 | `POST /api/recordings/sync`，回傳已索引總數 |

## 後端 API（更新）

| Method | Endpoint | 說明 |
|---|---|---|
| `GET` | `/api/recordings` | 列表，query params：`extension`（同時比對 caller **或** callee）、`start_dt`/`end_dt`（`YYYY-MM-DDTHH:MM`，轉換為 `rec_dt` 範圍比對）、`search`（檔名關鍵字）、`limit`/`offset`（分頁，預設每頁 200） |
| `POST` | `/api/recordings/sync` | 手動觸發全量索引同步 |
| `DELETE` | `/api/recordings` | 移至 `.trash` 並同步從 DB 刪除對應記錄 |
| `GET` | `/api/recordings/stream` | 串流播放立體聲原始檔（Range Request）。**認證**：`<audio src>` 無法自訂 header，改採 header 或 `?token=<JWT>` query string 兩者擇一（`require_permission_media`），函式內部做 `scope='own'` 過濾的 `Depends` 也統一改用 `get_current_user_media` |
| `GET` | `/api/recordings/stream_mono` | 串流播放 mono 合併音檔，DB 記錄缺失時即時補建。認證方式同上 |
| `GET` | `/api/download` | 下載（`path` 參數指定立體聲或 mono 檔）。**認證**：依路徑前綴對應模組權限（`/recordings/`→RECORDINGS），見 `feature-backup.md`／`changelog-details/20260720-download-endpoint-auth-fix.md` |

## 已知限制 / 待擴充（更新）

- 分機篩選採 `caller = ? OR callee = ?`，僅支援單一分機精確比對，不支援多選
- Mono 合併僅支援 WAV 來源
- 音檔庫（`feature-sounds.md`）目前僅 IVR 已串接選檔器，分機/語音信箱問候語尚未串接
- （已修復）2026-07-20 前 `stream`/`stream_mono` 函式簽名內殘留 header-only 的 `get_current_user`（用於 `scope='own'` 過濾），與 decorator 認證機制不一致，導致帶 query token 的 `<audio src>` 播放仍 401，見 `changelog-details/20260720-download-endpoint-auth-fix.md`




## 前端頁面（`static/js/recordings.js`）

### 篩選區

- 可搜尋分機下拉選單（復用 IVR 既有的 `_ivrSearchableSelect()`），比對 caller 或 callee
- 時間範圍：日期用 `type="date"` 日曆選擇 + 上午/下午切換按鈕 + 時/分獨立數字輸入框（**不使用 `datetime-local`**，因中文系統顯示格式問題已於 2026-06-29 改版）
- 進入頁面自動帶入預設值：開始 = 當下時間，結束 = 當天 23:59
- `✕ 清除` 重置篩選；`🔄 同步` 呼叫 `POST /api/recordings/sync` 手動重建索引

### 表格與版面

- 表格樣式（非卡片式），欄位：主叫（藍）/ 被叫（綠）/ 開始時間 / 結束時間 / 時長 / 大小 / 播放 / 下載
- 外層 `.rec-panel` 用 flex 版面固定外框高度（`max-height: calc(100vh - 140px)`），篩選列/分頁列固定不動，僅表格區域（`.rec-table-wrap { flex:1; overflow-y:auto }`）內部捲動
- 表頭 `position: sticky` 固定於捲動區頂部
- 分頁：預設每頁 200 筆，可手動輸入 10～1000；切頁後自動捲回頂部

### 共用播放器

- 播放器固定於篩選列下方、表格上方（比照音檔庫版面），只建立一次，**不隨表格重繪而重建**——切換篩選/翻頁不會中斷正在播放的音檔
- 立體聲／單聲道切換按鈕（`mono_path` 為空時自動 disabled）
- 連動邏輯：**播放**切換聲道會連動下載；**下載**切換聲道只改下載，不影響播放
- URL 一律存於 JS Map（`_recUrlMap`），不放進 DOM attribute（避免 `&` 等字元被截斷）；每筆錄音的 uid 使用完整 `btoa()` 字串（不截短，避免碰撞）

## 已知限制 / 待擴充

- 分機篩選採 `caller = ? OR callee = ?`，僅支援單一分機精確比對，不支援多選
- Mono 合併僅支援 WAV 來源
- 音檔庫（`feature-sounds.md`）目前僅 IVR 已串接選檔器，分機/語音信箱問候語尚未串接
