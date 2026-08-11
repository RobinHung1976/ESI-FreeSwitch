# 系統日誌（Logs）

> 對應頁面：系統 → 系統日誌｜前端：`static/js/logs.js`｜後端：`routers/logs.py`
> 演變歷史：[20260626 系統日誌功能](../changelog-details/20260626-system-log-feature.md)

## 四 Tab 架構

| Tab | 功能 |
|---|---|
| 📡 即時日誌 | SSE 串流 `tail -n 500 -f freeswitch.log`，分頁瀏覽（緩衝 5000 筆，每頁 100/200/500/1000 行），等級過濾：ALL/ERR/WARN/NOTICE/INFO/DEBUG/📞通話/🔐登錄 |
| 📅 歷史日誌 | 日期下拉、等級篩選、關鍵字搜尋（後端）、分頁、下載 |
| 🔐 登錄記錄 | ESL `REGISTER`/`UNREGISTER` 事件捕捉，SQLite 持久化（服務重啟不歸零），自動過濾分機定期刷新註冊造成的重複記錄，僅記錄首次登入/重新登入/換 IP 或協定 |
| 🗂 日誌管理 | 歷史日誌檔案列表、🔄 立即輪轉 |

## 每日自動排程（00:00:30）

1. 日誌歸檔 → `freeswitch-YYYY-MM-DD.log`
2. 日誌清理（超過 `log_retain_days` 天）
3. CDR 歸檔 → `cdr-YYYY-MM-DD.csv`（CDR 現況已改 SQLite，見 `feature-cdr.md`）
4. CDR 清理（超過 `cdr_retain_days` 天）

## Log/CDR 合併輪轉（2026-08-11 起，`core/runtime.py: _rotate_log_and_cdr_now()`）

FreeSwitch 的 `logfile.conf.xml`／`cdr_csv.conf.xml` 皆設定 `rotate-on-hup=true`，代表
`mod_logfile`／`mod_cdr_csv` 只有收到 `SIGHUP` 訊號才會重新開啟檔案、重置寫入 offset；單純
truncate 檔案內容不會通知 FreeSwitch。因為 `SIGHUP` 是 process 層級訊號、log 與 CDR 兩個
模組會同時反應，rotate 邏輯改為：log 與 CDR 各自完成「複製＋truncate」後，才統一送出**一次**
HUP，避免其中一邊尚未安全歸檔時被另一邊的 HUP 意外搬走內容（FreeSwitch 自己的 rotate-on-hup
邏輯會把「當下的檔案」rename 成它自己的命名格式）。

**行為變更**：「🔄 立即輪轉」（本頁「日誌管理」Tab）與 CDR 頁面的「立即歸檔」按鈕互相連動，
按下其中一個會連帶安全歸檔另一邊，這是為了資料安全必須接受的副作用。詳見
`changelog-details/20260811-log-rotate-hup-fix.md`。

## 後端 API

| Method | Endpoint | 說明 |
|---|---|---|
| `GET` | `/api/logs/stream` | SSE 即時串流 |
| `GET` | `/api/logs/list` | 歷史檔案列表 |
| `GET` | `/api/logs/history?date&level&keyword&page&per_page` | 歷史分頁搜尋 |
| `GET` | `/api/logs/download?date=` | 下載指定日期日誌 |
| `GET` | `/api/logs/grep?keyword=&lines=` | 關鍵字搜尋 |
| `POST` | `/api/logs/rotate` | 手動立即輪轉（2026-08-11 起連帶安全歸檔 CDR，見上方說明） |

## 已知限制

（無：登錄記錄已於 2026-07-15 完成 SQLite 持久化、2026-07-16 完成去重，見 `changelog-details/20260715-reg-log-persistence.md`、`changelog-details/20260716-reg-log-dedup-feature.md`。log rotate 缺少 SIGHUP 導致長期資料遺失的問題已於 2026-08-11 修復，見 `changelog-details/20260811-log-rotate-hup-fix.md`）
