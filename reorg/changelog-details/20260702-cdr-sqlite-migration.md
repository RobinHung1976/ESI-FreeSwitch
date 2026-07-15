# CDR 統計報表 SQLite 化 — 2026-07-02

> 原始來源：`cdr-sqlite-migration-20260702.md`（架構遷移過程細節；現況已併入 `feature-cdr.md`）

## 背景 / 問題

通話統計報表原本直接掃描 CDR CSV（當日讀 `Master.csv`，歷史日期讀歸檔的 `cdr-YYYY-MM-DD.csv`）。由於 `cdr_retain_days`（CDR 明細保留天數）設定為 3 天，歸檔 CSV 超過 3 天即被排程自動刪除，導致：
- 報表查詢 3 天前的日期／區間 → 對應 CSV 已被刪除 → API 靜默回傳空結果
- 使用者無法得知是「保留期限」造成資料消失，容易誤以為系統異常
- 明細保留天數（受磁碟空間限制，需短）與統計可查詢天數（報表需求，應該長）被綁在同一設定上

## 解法：兩層資料儲存架構（SQLite）

| Table | 內容 | 保留天數設定 | 用途 |
|---|---|---|---|
| `cdr` | 逐通明細（raw） | `cdr_retain_days`（預設 30，可依需求調整） | `/api/cdr` 明細列表、未接通清單、CSV 匯出 |
| `cdr_daily_summary` | 每日彙總統計（總量/接通率/24小時分佈/Top 10 分機） | `cdr_summary_retain_days`（新設定，預設 730 天） | `/api/cdr/stats` 長區間報表趨勢圖 |

**運作流程**：
1. FreeSwitch `mod_cdr_csv` 持續寫入 `Master.csv`（不受影響，維持原樣）
2. 每次呼叫 `/api/cdr` 或 `/api/cdr/stats` 前，先把當天 `Master.csv` 增量同步進 `cdr` table（以 `uuid` 去重，`INSERT OR IGNORE`，冪等）
3. 每日 00:00:30 排程 rotate 時：同步今日資料進 DB → 建立當日 `cdr_daily_summary` → 封存 CSV → 清空 `Master.csv`
4. 每日 cleanup 排程：依 `cdr_retain_days` 清除 `cdr` table 中過舊的 raw 明細；依 `cdr_summary_retain_days` 清除過舊的彙總（預設很久，通常不會觸發）

**查詢邏輯**（`/api/cdr/stats`）：查詢區間內若某日 raw 明細仍在保留期內 → 即時從 `cdr` table 精確聚合；若某日 raw 已被 purge 但 `cdr_daily_summary` 仍在 → 自動 fallback 讀取彙總資料；回傳新增 `summary_fallback_used` 欄位，前端據此顯示「⚠ 含歷史彙總資料」提示。

## 已知取捨（架構本質限制，非 bug）

- 超過 `cdr_retain_days` 的日期：報表卡片（總量/接通率/平均時長/趨勢圖）**仍準確**，因為來自彙總表
- 但該日的逐通未接通清單無法還原，因為明細已被實際刪除
- 混合區間查詢時，「依分機篩選」對已 purge 日期的每小時分佈無法還原，只有整體加總能還原

## 修改檔案清單

| 檔案 | 異動類型 | 說明 |
|---|---|---|
| `core/cdr_db.py` | 新增 | SQLite 儲存層：`init_db`/`import_csv_file`/`sync_today`/`build_daily_summary`/`purge_raw_before`/`purge_summary_before`/`query_rows`/`query_stats` |
| `routers/cdr.py` | 覆蓋 | `/api/cdr`、`/api/cdr/stats` 改走 `cdr_db`，歸檔管理 API 維持不變 |
| `core/runtime.py` | 修改 | 新增 `cdr_summary_retain_days` 預設值；`_rotate_cdr_now()` 於封存前同步 DB + 建彙總；`_cleanup_old_cdrs()` 新增 SQLite raw/summary 兩層清理 |
| `server.py` | 修改 | `lifespan` 啟動時呼叫 `cdr_db.init_db()` 建表 |
| `static/js/overview-report.js` | 修改 | 日期選擇改為「開始日期～結束日期」；摘要卡片改用後端合計數字；`summary_fallback_used` 時顯示提示 |
| `static/js/settings-vars.js` | 修改 | 設定頁新增「CDR 統計彙總保留天數」欄位，原欄位標籤改為「CDR 明細保留天數」 |
| `migrate_cdr_backfill.py` | 新增 | 一次性搬遷腳本：匯入既有 `Master.csv` + 所有歸檔 CSV 進 SQLite，並為每個歷史日期建立彙總 |

## 部署步驟

```bash
cd /opt/fs-dashboard
python3 migrate_cdr_backfill.py    # 一次性搬遷既有 CSV 進 SQLite（冪等，可重複執行）
systemctl restart fs-dashboard
sqlite3 /opt/fs-dashboard/data/cdr.db "SELECT COUNT(*) FROM cdr; SELECT COUNT(*) FROM cdr_daily_summary;"
```

## 測試結果

- ✅ `migrate_cdr_backfill.py` 實測匯入 Master.csv + 歷史歸檔檔案，成功建立 `cdr` 與 `cdr_daily_summary` 兩張表
- ✅ 沙箱以合成 CDR 資料驗證 `cdr_db.py` 全部函式：匯入去重（重跑 0 新增）、`purge_raw_before` 後 `query_stats` 正確 fallback 到彙總、單日／範圍兩種模式回傳格式正確
- ✅ 前端 JS 以 `node --check` 通過語法檢查，後端 Python 以 `py_compile` 通過語法檢查
- ✅ 使用者於實機部署後測試通過（2026-07-02）

## 後續建議

- `cdr_retain_days` 可視磁碟空間調整（例如拉長到 30～90 天），因為長期報表已不再依賴它
- `cdr_summary_retain_days`（預設 730 天）幾乎不佔空間，可視需求設更長甚至永久保留
- 若未來需要「已 purge 日期＋依分機篩選」的每小時分佈，需改為在 `cdr_daily_summary` 額外存每分機每小時的細分資料
