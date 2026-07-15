# 系統日誌功能 — 2026-06-26

> 原始來源：`system-log-feature-20260626.md`；現況已併入 `feature-logs.md`

初版四 Tab 架構：即時日誌（SSE 串流）、歷史日誌（日期/等級/關鍵字篩選）、登錄記錄（ESL REGISTER/UNREGISTER 事件捕捉）、日誌管理（歷史檔案列表、立即輪轉）。每日自動排程（00:00:30）同時處理日誌與 CDR 的歸檔與清理（CDR 現況已改 SQLite，見 `feature-cdr.md`）。詳細規格已完整併入 `feature-logs.md`。
