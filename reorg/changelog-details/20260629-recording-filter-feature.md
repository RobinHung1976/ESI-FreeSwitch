# 錄音管理篩選功能實作總結 — 2026-06-29

> 原始來源：`recording-filter-feature-20260629.md`（實作過程記錄；現況已併入 `feature-recordings.md`）

## 功能描述

錄音管理頁面新增 SQLite 索引、依分機篩選（可搜尋下拉）、依時間範圍篩選（日曆 picker）。

## 架構設計

| 層級 | 方案 | 說明 |
|---|---|---|
| 索引 | SQLite | 不存音檔本體，只存 metadata，支援大量資料 |
| API | Query Params 篩選 | 後端查 DB，不做全量 `os.walk` |
| 前端 | 篩選 UI | 可搜尋分機下拉 + 時間範圍選擇 |
| 同步 | 雙保險 | API 查詢時即時同步 + 背景每 5 分鐘全量掃描 |

## 新增函式（`server.py`）

| 函式 | 說明 |
|---|---|
| `_rec_db()` | 取得 SQLite 連線，自動建表與索引 |
| `_parse_rec_filename(fname)` | 從檔名 Regex 解析 caller/callee/date/time |
| `_upsert_file_to_db(conn, fpath)` | 單檔 upsert，size 不變則跳過 |
| `sync_recordings_to_db()` | 全量掃描目錄並同步 DB，清除已刪除檔案的記錄 |
| `_start_rec_sync_scheduler()` | 背景執行緒，每 300 秒呼叫一次同步 |

## Bug 修復記錄

| 問題 | 原因 | 修復 |
|---|---|---|
| `TabError: inconsistent use of tabs and spaces` | 貼上代碼時 tab/空格混用 | 用 Python `expandtabs(4)` 全檔修正 + 手動修正縮排 |
| 分機下拉只顯示「全部分機」無其他選項 | API 路徑錯誤，用了不存在的 `/api/extensions`，正確路徑為 `/api/extensions/list` | 修正 `apiFetch` 呼叫路徑 |

## 運作流程

```
使用者進入錄音管理頁
  → renderRecordings() 載入分機清單 (/api/extensions/list)
  → 渲染可搜尋分機下拉 + 開始/結束時間篩選
  → loadRecordings() 呼叫 GET /api/recordings
      → sync_recordings_to_db()（快速同步新檔）
      → SQLite 查詢（extension / rec_dt 範圍 / filename LIKE）
      → 回傳分頁結果
  → buildRecRow() 渲染每筆錄音

背景執行緒（每 5 分鐘）
  → sync_recordings_to_db()
      → os.walk 掃描目錄
      → upsert 新檔 / 清除已刪除記錄
      → commit
```

---

**測試結果**：功能實作完成並驗證通過。
