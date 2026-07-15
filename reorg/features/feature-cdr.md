# 通話記錄 CDR

> 對應頁面：管理 → 通話記錄 CDR｜前端：`static/js/cdr.js`｜後端：`routers/cdr.py` + `core/cdr_db.py`
> 演變歷史：[20260626 CDR 功能](../changelog-details/20260626-cdr-feature.md) · [20260702 SQLite 化](../changelog-details/20260702-cdr-sqlite-migration.md)

## 雙 Tab 架構

**📞 即時 CDR**：`/api/cdr`，關鍵字搜尋、狀態篩選、分頁、CSV 匯出
**📋 歷史 CDR**：日期下拉選單 `/api/cdr/archives`，前端解析、搜尋篩選分頁匯出

## 儲存架構（SQLite 雙層）

原本直接掃 CSV，因保留天數到期後歷史查詢會靜默回傳空結果，2026-07-02 起改為兩層 SQLite：

| Table | 內容 | 保留天數設定 |
|---|---|---|
| `cdr` | 逐通明細 | `cdr_retain_days`（可調整，不再受限於磁碟考量而設太短） |
| `cdr_daily_summary` | 每日彙總（總量/接通率/24小時分佈/Top10） | `cdr_summary_retain_days`（預設 730 天，佔用空間極小） |

超過 `cdr_retain_days` 的日期：報表卡片/趨勢圖仍準確（來自彙總表），但逐通未接通清單無法還原（明細已刪）。`query_stats` 自動 fallback 到彙總資料，回傳 `summary_fallback_used` 供前端顯示提示。

## CDR 方向判斷（`_cdr_direction()`）

| context | caller_num | destination | 結果 |
|---|---|---|---|
| `public` | 任意 | 任意 | `inbound`（來電） |
| `default` | ≤4 位數字 | ≤4 位數字 | `internal`（內線） |
| `default` | ≤4 位數字 | 其他 | `outbound`（出撥） |
| 其他 | 任意 | 任意 | `inbound`（來電） |

## 狀態判斷（`cdrStatus()`）

| hangup_cause | billsec | 結果 |
|---|---|---|
| `NORMAL_CLEARING`/`NORMAL_UNSPECIFIED` | >0 | ANSWERED |
| 同上 | =0 | NO ANSWER |
| `ORIGINATOR_CANCEL`/`NO_ANSWER` | — | NO ANSWER |
| `USER_BUSY` | — | BUSY |

## 後端 API

| Method | Endpoint | 說明 |
|---|---|---|
| `GET` | `/api/cdr` | 即時 CDR 列表 |
| `GET` | `/api/cdr/stats` | 統計（`date_str`/`date_to`/`user` 參數；單日回 24 小時分佈，範圍回每日分佈） |
| `GET` | `/api/cdr/archives` | 歷史歸檔日期清單 |
| `POST` | `/api/cdr/rotate` | 立即歸檔今日 CDR |

## 每日自動排程（00:00:30）

1. 同步今日 CSV 進 `cdr` table
2. 建立當日 `cdr_daily_summary`
3. 封存 CSV → `cdr-YYYY-MM-DD.csv`
4. 清空 `Master.csv`
5. 依保留天數清理 `cdr`/`cdr_daily_summary`

## 一次性搬遷腳本

`migrate_cdr_backfill.py`：匯入既有 `Master.csv` + 所有歸檔 CSV 進 SQLite，並為每個歷史日期建立彙總（冪等，可重複執行）。
