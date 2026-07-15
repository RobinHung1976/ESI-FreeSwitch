# 號碼衝突檢查功能 — 2026-06-26

> 原始來源：`number-conflict-check-feature-20260626.md`；現況已併入 `feature-numbers-conflict-check.md`

新增 `numCheckConflict(inputId, conflictDivId, number, selfType)` 共用函式，供分機/群組/IVR 新增變更號碼時即時比對號碼目錄（含 FreeSwitch 保留號碼），30 秒 TTL 快取（`_numCache`），編輯模式排除自身。此需求的起因是曾發生群組號碼誤用 `5001` 撞上 FreeSwitch 內建 Conference Bridge 導致 `NORMAL_TEMPORARY_FAILURE`（見累積除錯批次 `20260618-20260630-bug-fixes-batch.md`）。詳細觸發時機與顯示狀態已完整併入 `feature-numbers-conflict-check.md`。
