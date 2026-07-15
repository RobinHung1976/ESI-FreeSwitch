# 通話記錄 CDR 功能 — 2026-06-26

> 原始來源：`cdr-feature-20260626.md`；現況已併入 `feature-cdr.md`（注意：儲存架構已於 2026-07-02 改為 SQLite，見 `20260702-cdr-sqlite-migration.md`）

初版雙 Tab 架構：📞 即時 CDR（讀取 `Master.csv`）、📋 歷史 CDR（日期下拉選單 + 前端解析歸檔 CSV）。後端 `_cdr_direction()` 依 context/號碼長度判斷來電/內線/出撥方向。詳細判斷邏輯表已完整併入 `feature-cdr.md`。
