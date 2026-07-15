# 登錄記錄（reg_log）SQLite 持久化 — 2026-07-15

## 背景 / 問題

`PROJECT-OVERVIEW.md` 中優先待辦「登錄記錄(reg_log)持久化」。`core/state.py` 的
`reg_log` 原本是純記憶體 list（上限 `REG_LOG_MAX` 500 筆），服務每次重啟（部署、
排程重啟、意外崩潰）都會全部歸零，無法回溯查詢分機登入/登出歷史。

（注意：CDR 已於 2026-07-02 完成 SQLite 化，但 `reg_log` 是獨立的另一件事，兩者
不可混淆，見 `changelog-details/20260702-cdr-sqlite-migration.md`。）

## 解法：獨立 SQLite（core/reg_log_db.py）

沿用 `core/cdr_db.py` 的 `_conn()` pattern，但只有單層（`reg_log` 是輕量事件記
錄，不像 CDR 需要「明細 vs 每日彙總」兩層拆分）。

| 項目 | 內容 |
|---|---|
| DB 路徑 | `/opt/fs-dashboard/data/reg_log.db` |
| Table | `reg_log`（`ext`/`event`/`ip`/`proto`/`ts_ms`/`time_str`/`date_str`，index：`ts_ms`/`date_str`/`ext`） |
| 保留策略 | `reg_log_retain_days`（新設定，預設 90 天），每日 00:00:30 排程自動清理 |

**運作流程**：
1. ESL `REGISTER`/`UNREGISTER` 事件觸發 → `core/runtime.py` 的 `write_reg_log()` → `reg_log_db.insert_log()`
2. 每日 00:00:30 排程：`_cleanup_old_reg_logs()` 依 `reg_log_retain_days` 清除過舊記錄
3. `GET /api/reg/log` 改查 SQLite，支援日期區間/分機/事件篩選 + 分頁

## 修改檔案清單

| 檔案 | 異動類型 | 說明 |
|---|---|---|
| `core/reg_log_db.py` | 新增 | SQLite 儲存層：`init_db`/`insert_log`/`query_logs`/`purge_before` |
| `core/state.py` | 修改 | 移除 `reg_log`/`REG_LOG_MAX` 記憶體 list |
| `core/runtime.py` | 修改 | `write_reg_log()` 改寫進 SQLite；新增 `reg_log_retain_days` 預設值（90 天）+ `_cleanup_old_reg_logs()`，掛進每日排程 |
| `server.py` | 修改 | lifespan 新增 `reg_log_db.init_db()` 建表 |
| `routers/calls.py` | 修改 | `GET /api/reg/log` 改查 SQLite，擴充分頁 + 日期/分機/事件篩選，回應格式改為 `{total, page, per_page, total_pages, rows}`，並套用 `scope=own` 權限限制（比照 `get_calls()`） |
| `static/js/settings-vars.js` | 修改 | 設定頁「日誌保留設定」新增「登錄記錄保留天數」欄位 |
| `static/js/logs.js` | 修改 | 登錄記錄 Tab 新增日期/分機/事件篩選列 + 分頁 UI，`loadRegLog()` 改讀新回應格式 |

## 已知取捨

- 不像 CDR SQLite 化那次，本次**沒有搬遷腳本**：舊資料本來就只在記憶體，服務
  重啟必歸零，沒有歷史資料可搬。部署後登錄記錄從當下開始持久化累積。
- `reg_log_retain_days` 預設 90 天（比 `log_retain_days`/`cdr_retain_days` 的
  30 天長一些），因為單筆記錄很輕量，SQLite 檔案成長速度慢，可以保留更久。

## 部署（`update17.sh`）

```bash
python3 -m py_compile core/reg_log_db.py core/runtime.py core/state.py server.py routers/calls.py
sudo systemctl restart fs-dashboard
```

## 測試結果

- ✅ `py_compile` 全部通過，`node --check` 前端兩支 JS 語法通過
- ✅ 手動於 venv 直接呼叫 `reg_log_db.insert_log()` 驗證寫入正常
- ✅ 實機測試：分機 `1210`/`1126` 登入/登出事件正確寫入 SQLite
  （`SELECT COUNT(*) FROM reg_log` 確認筆數與內容正確）
- ✅ **重啟服務後記錄仍在，不再歸零**（本次功能的核心驗證點）
- ✅ 瀏覽器「系統 → 系統日誌 → 🔐 登錄記錄」Tab 顯示正常，篩選（日期/分機/
  事件）與分頁功能正常
- ✅ 於 production server（`debian-freeswitch`）實際部署並逐項驗證通過（2026-07-15）

## 附帶說明：`sqlite3` CLI 工具

驗證過程中額外在 server 上用 `apt-get install -y sqlite3` 裝了 `sqlite3` 指令列
工具，方便手動下 SQL 查詢除錯。這是**系統層級套件**，跟 Python 標準函式庫內建
的 `sqlite3` 模組（`core/reg_log_db.py`/`cdr_db.py`/`auth_db.py` 實際用的那個）
是兩回事，**不需要**、也不應該寫進 `requirements.txt`。詳見
`ops/ops-server-requirements.md`。
