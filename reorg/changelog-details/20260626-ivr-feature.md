# IVR 功能與直撥分機 — 2026-06-25 ~ 2026-06-26

> 原始來源：`ivr-feature-20260626.md`；現況已併入 `feature-ivr.md`

## 無效鍵 / 超時重播控制（2026-06-25 新增）

原始設計問題：`invalid_retries`/`timeout_retries` 用來設定第幾次觸發才執行最終行為，需區分「前 N-1 次」與「第 N 次（最後一次）」的播音邏輯，避免最後一次同時播放一般提示音與最終語音造成重疊。詳細行為表已併入 `feature-ivr.md`。

## 時段路由（2026-06-25 更新）

新增 `offhour_sound`：下班/假日時段接通後先播放的語音（選填），播完後再執行 `offhour_target`。`check_schedule()` 回傳 `{target, sound}` table，`run_ivr` 先播語音再路由。

## IVR 直撥分機功能（2026-06-26 新增與修改）

**功能說明**：來電者撥入 IVR 後可直接輸入完整分機號碼轉接，不需預先在按鍵選單逐一定義每個分機，單鍵選單與直撥並存，按鍵比對優先。

**修改檔案**：`ivr_runner.lua`（`playAndGetDigits` 的 `min_digits` 改為 1，讓單鍵選單可即時響應，多位數等 `inter_digit_timeout` 逾時或 `#` 結束）、`server.py`（新增 `IVRTransferAction` model：`auto_transfer`/`post_greeting_transfer`）、`index.html`（新增直接轉接/播後轉接的設定卡片、流程圖新節點）。

**除錯過程**：儲存後選擇恢復空白的根本原因是 `server.py` 未定義新欄位，Pydantic 解析時靜默丟棄前端傳入的 `auto_transfer`/`post_greeting_transfer`，寫入 JSON 時這兩個欄位不存在，讀回 Dashboard 後 UI 自然空白。新增 model 並在 `IVRData` 與 `_ivr_meta_dict()` 補齊後解決。

## IVR 選擇器改善：Searchable Select（2026-06-26）

**問題**：分機/群組/IVR 子選單選擇器用原生 `<select>`，超過 20 項後難以找到目標選項。
**解法**：自製可搜尋下拉（`_ivrSearchableSelect()`），純原生 HTML/CSS/JS，不依賴外部套件，取代原生 `<select>`。

---

**測試結果**：以上功能皆已測試通過，詳細現況已完整併入 `feature-ivr.md`。
