# 全站瀏覽器原生機制缺 Authorization 稽核 + /api/download 資安缺口修復（2026-07-20）

> 承接 [20260720 即時日誌 SSE 認證修復](20260720-logs-stream-auth-fix.md)。該次修復後主動做了一次全站稽核，發現同一類問題還有多處，其中一處是資安缺口。本篇記錄 `update40.sh` ~ `update43.sh` 的完整過程。

## 起因

修完即時日誌 SSE 後，覆盤同一類問題:**凡是前端不透過 `fetch()`/`apiFetch()`、而是讓瀏覽器原生機制直接發送請求的地方，都無法帶 `Authorization` header**，包含 `EventSource`、`<audio src>`、`<a href>` 直接下載、`window.open()` 等。針對後端所有 `require_permission(...)` 端點與前端所有這類原生請求做交叉稽核。

## 稽核結果

### A. 資安缺口（最嚴重）：`/api/download` 完全無認證

`routers/files.py` 的 `download_file()` 原本連 `Depends(get_current_user)` 都沒有掛，任何人不用登入就能用 `?path=` 下載 `/etc/freeswitch/`、`/var/log/freeswitch/`、`/var/lib/freeswitch/recordings/`、`/usr/share/freeswitch/sounds/` 底下任意檔案。且路徑白名單只用字面字串 `path.startswith(d)` 比對，沒有先用 `os.path.realpath()` 正規化，存在路徑穿越風險（例如 `path=/etc/freeswitch/../passwd` 字面上仍以白名單前綴開頭）。

### B. 缺 `?token=` 的媒體/下載類請求

| 檔案 | 端點 | 觸發方式 |
|---|---|---|
| `static/js/ivr.js` | `/api/sounds/stream` | `<audio src>` |
| `static/js/settings-vars.js` | `/api/sounds/stream`、`/api/backup/download` | `audio.src`、`a.href` |
| `static/js/sounds.js` | `/api/sounds/stream` | `player.src` |
| `static/js/logs.js` | `/api/logs/download` | `a.href` |
| `static/js/backup.js` | `/api/download` | `a.href`（含錄音/備份共用下載端點）|
| `static/js/recordings.js` | `/api/recordings/stream`、`/stream_mono`、`/api/download` | `<audio src>`、下載連結 |

## 修復

### 認證機制設計決策

`/api/download` 橫跨 RECORDINGS/SOUNDS/LOGS/SETTINGS 四個模組，權限判斷方式討論後採**依路徑前綴對應各自模組權限**（較嚴謹的方案，非「只要求登入即可」的簡化版）。

### 後端

- **`core/auth.py`**：`require_permission_sse`/`get_current_user_sse`（20260720 SSE 修復時新增）更名為通用的 **`require_permission_media`/`get_current_user_media`**，不只 SSE，音檔/下載類端點都共用同一套（header 或 query token 兩者擇一皆可通過）
- **`routers/files.py`**：`/api/download` 補上認證 + 路徑正規化
  - 新增 `_DIR_MODULE_MAP`：依路徑前綴對應模組（`/recordings/`→RECORDINGS、`/sounds/`→SOUNDS、`/var/log/`→LOGS、其餘含 `/etc/freeswitch/`→SETTINGS）
  - `os.path.realpath()` 正規化路徑後才比對白名單，修掉路徑穿越風險
  - 依對應模組要求 `read` 權限
- **`routers/sounds.py`**、**`routers/backup.py`**、**`routers/recordings.py`**：`stream`/`stream_mono`/`download` 端點的 `dependencies` 從 `require_permission` 改為 `require_permission_media`
- **`routers/logs.py`**：`require_permission_sse` 同步更名為 `require_permission_media`（含 `/api/logs/download` 一併補上，先前只顧到 `/api/logs/stream`）

### 前端

上表 6 支檔案共 10 處，URL 統一補上 `&token=${encodeURIComponent(getToken())}`。

### 隱藏的第二層認證（額外踩到的坑）

`routers/recordings.py` 的 `stream_recording()`/`stream_mono_recording()` 函式簽名裡，除了 decorator 上的 `require_permission_media`，各自還獨立寫了 `user: dict = Depends(get_current_user)`（header-only）用來做 `scope='own'` 的錄音歸屬過濾。FastAPI 會把函式參數當成**另一個獨立的依賴**解析，跟 decorator 那層各自要求認證，等於同一支端點疊了兩層認證。只改 decorator、忘了改函式內部這層，導致補上 `?token=` 後錄音播放仍然 401。修法：兩處函式簽名的 `Depends(get_current_user)` 改成 `Depends(get_current_user_media)`，統一認證。

已順手確認 `sounds.py`/`backup.py`/`logs.py`/`files.py` 沒有同樣的函式層級殘留認證（`grep -n "Depends(get_current_user)"` 結果皆為空），這個雙層認證是 `recordings.py` 因 `scope='own'` 過濾邏輯而產生的特例。

`updateN.sh`：`update40.sh`（因 `routers/files.py` 空行位置與預期不符而中止，未寫入任何檔案）→ `update41.sh`（前置驗證邏輯誤判 `logs.js` 已改過而中止，未寫入任何檔案）→ `update42.sh`（成功套用 A/B 兩類修復）→ `update43.sh`（修復 `recordings.py` 的隱藏第二層認證）

## 驗證

```bash
# 資安缺口：未帶 token 應 401（修復前是 200）
curl -o /dev/null -s -w "%{http_code}\n" "http://127.0.0.1:3000/api/download?path=/etc/freeswitch/vars.xml"

# 帶正確 token 應 200
curl -o /dev/null -s -w "%{http_code}\n" "http://127.0.0.1:3000/api/download?path=/etc/freeswitch/vars.xml&token=${TOKEN}"

# 路徑穿越防護應 403（不是意外的 200）
curl -o /dev/null -s -w "%{http_code}\n" "http://127.0.0.1:3000/api/download?path=/etc/freeswitch/../passwd&token=${TOKEN}"

# 錄音串流（曾因隱藏第二層認證卡在 401，修復後應 200）
curl -G -o /tmp/test-stereo.wav --data-urlencode "path=<真實錄音路徑>" --data-urlencode "token=${TOKEN}" "http://127.0.0.1:3000/api/recordings/stream"
```

**實測結果**：四項驗證皆通過。瀏覽器實測音檔庫試聽、IVR 音檔試聽、全域變數問候語試聽、系統日誌歷史下載、備份下載（設定頁+備份頁）、錄音下載、錄音播放（立體聲/單聲道切換）全部正常。

已於 production server（`debian-freeswitch`）實際部署並驗證通過。

## 延伸澄清（非 bug）

驗證過程中曾誤以為錄音「立體聲/單聲道播放內容對調」，經 `ffprobe`/Python `wave` 模組確認聲道數與前端 URL 對應皆正確，實為對 FreeSWITCH `RECORD_STEREO=true` 分軌錄音特性的誤解（左右聲道各錄一方通話者、非左右耳皆聽到混合音），非程式邏輯錯誤，未做任何修改。
