# 系統日誌（Logs）

> 對應頁面：系統 → 系統日誌｜前端：`static/js/logs.js`｜後端：`routers/logs.py`
> 演變歷史：[20260626 系統日誌功能](../changelog-details/20260626-system-log-feature.md)

## 四 Tab 架構

| Tab | 功能 |
|---|---|
| 📡 即時日誌 | SSE 串流 `tail -n 500 -f freeswitch.log`，分頁瀏覽（緩衝 5000 筆，每頁 100/200/500/1000 行），等級過濾：ALL/ERR/WARN/NOTICE/INFO/DEBUG/📞通話/🔐登錄 |
| 📅 歷史日誌 | 日期下拉、等級篩選、關鍵字搜尋（後端）、分頁、下載 |
| 🔐 登錄記錄 | ESL `REGISTER`/`UNREGISTER` 事件捕捉，最多 200 筆（記憶體保存，服務重啟歸零） |
| 🗂 日誌管理 | 歷史日誌檔案列表、🔄 立即輪轉 |

## 每日自動排程（00:00:30）

1. 日誌歸檔 → `freeswitch-YYYY-MM-DD.log`
2. 日誌清理（超過 `log_retain_days` 天）
3. CDR 歸檔 → `cdr-YYYY-MM-DD.csv`（CDR 現況已改 SQLite，見 `feature-cdr.md`）
4. CDR 清理（超過 `cdr_retain_days` 天）

## 後端 API

| Method | Endpoint | 說明 |
|---|---|---|
| `GET` | `/api/logs/stream` | SSE 即時串流 |
| `GET` | `/api/logs/list` | 歷史檔案列表 |
| `GET` | `/api/logs/history?date&level&keyword&page&per_page` | 歷史分頁搜尋 |
| `GET` | `/api/logs/download?date=` | 下載指定日期日誌 |
| `GET` | `/api/logs/grep?keyword=&lines=` | 關鍵字搜尋 |
| `POST` | `/api/logs/rotate` | 手動立即輪轉 |

## 已知限制

登錄記錄（`reg_log`）目前僅存在記憶體，服務重啟後歸零，尚未持久化（見 `PROJECT-OVERVIEW.md` 已知待處理事項）。
