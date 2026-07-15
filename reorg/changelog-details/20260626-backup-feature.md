# 備份管理功能 — 2026-06-25/26

> 原始來源：`backup-feature-20260626.md`；現況已併入 `feature-backup.md`

新增獨立「備份管理」頁面，提供 Dashboard 設定備份與 FreeSwitch 套件備份兩種類型，含情境 A（Server 運行中還原）與情境 B（整台 Server 損毀新機重建）兩種還原流程，`restore_freeswitch.sh`/`restore_dashboard.sh` 兩支還原腳本。

## 每日自動備份時間可手動設定（後續修改）

`SETTINGS_DEFAULTS` 新增 `backup_auto_time` 預設 `'00:01'`；`server.py` 的 `_log_rotate_scheduler()` 重構為雙事件架構，每次迴圈動態讀取 `settings.json`，`00:00:30`（固定）處理 Log/CDR rotate + 清理 + 備份清理，`backup_auto_time`（使用者設定）處理自動備份 Dashboard 設定，容許 ±90 秒誤差觸發避免兩事件時間重疊，時間變更後下一週期即生效不需重啟服務。

**測試結果**：✅ 功能測試通過。

詳細 API、備份包內容結構、.deb 收集三層 fallback 策略、安全性機制已完整併入 `feature-backup.md`。
