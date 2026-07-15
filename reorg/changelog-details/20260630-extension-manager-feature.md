# 分機管理功能總結 — 2026-06-30

> 原始來源：`extension-manager-feature-20260630.md`；現況已併入 `feature-extensions.md`

涵蓋分機管理頁面完整開發規格：頁面雙面板佈局（`ext-list-panel`/`ext-editor-panel`）、卡片排序規則、WebSocket 事件驅動的即時狀態系統、表單欄位設計、🔄 變更號碼的三步驟原子操作、CRUD API 端點設計，詳細規格已完整併入 `feature-extensions.md`，不重複列出。

## 分機語音信箱開關（2026-06-30 新增）

**需求**：分機編輯時可設定該分機是否啟用語音信箱（`voicemail_enabled`）。

**修改**：`ExtensionData` 新增欄位、`write_extension_xml()` 寫入 FreeSWITCH 原生變數 `voicemail_enabled`（`mod_voicemail` 原生辨識的 directory 變數，不需修改 dialplan 或 Lua 腳本即可生效）、`list_extensions()` 讀取時舊分機無此欄位預設 `true` 向下相容。

**除錯**：第一次測試出現 500 錯誤（`Unexpected token 'I', "Internal S"`），根因是 `write_extension_xml()` 中遺漏 `vm_enabled_val = "true" if data.voicemail_enabled else "false"` 賦值，導致 f-string 引用未定義變數觸發 `NameError`。修正後重啟服務解決。

**測試結果**：✅ 已完成並驗證通過。勾選關閉語音信箱後儲存成功，實際撥打測試：無人接聽會播問候語但跳過錄音，符合預期。
