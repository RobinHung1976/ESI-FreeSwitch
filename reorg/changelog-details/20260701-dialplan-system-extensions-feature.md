# Dialplan 類型二（系統內建 Extension）開發總結 — 2026-07-01

> 原始來源：`dialplan-system-extensions-feature-20260701.md`；現況已併入 `feature-dialplan-system-extensions.md`、`feature-dialplan.md`（共用機制部分）

## `dialplan_common.py` 抽取（重構）

`_reload_and_verify()`、ESL 注入等機制原本寫在 `dialplan_routes.py`（類型一專屬模組）裡。類型三要用到同一套機制時，若直接 `from dialplan_routes import _reload_and_verify` 形同「向兄弟模組借私有函式」，長期會讓模組間互相牽連。因此抽成 `dialplan_common.py`，作為類型一/二/三共用的基礎設施層。`dialplan_routes.py` 改為 `from dialplan_common import ...`，`init_esl` 同名重新匯出，`server.py` 既有呼叫完全不用修改。

**驗證方式**：`py_compile` 語法檢查 + 實際 `import`+`TestClient` 端到端測試：create/update/toggle 正常流程 + 三種 reload 失敗時的 rollback 情境，全部通過，行為與重構前一致。

## 類型二：系統內建 Extension（唯讀檢視）

解析 `default.xml`/`public.xml` 只挑有 `destination_number` 條件的 extension，67 筆全部覆蓋（含 6 筆原本沒對照到的，及兩個保底 catch-all）。

## 發現並修正的規劃文件落差

`dialplan-routing-rule-20260701.md` 第三節範例表跟實際 `default.xml` 對不上：文件寫 `9999`→`hold_music`，實際是 `9664`；文件寫 `9699`→`eavesdrop`，實際 `eavesdrop` 對應 `88xxxx`/`*0...`/`779`，沒有 `9699` 這個號碼。`DEFAULT_EXT_DESCRIPTIONS` 已依實際解析結果修正。

## 部署踩到的坑

手動貼程式碼進 `index.html` 時發生兩次疊代錯誤，都是手動貼上時漏補/多刪大括號：

1. 第一次把 `dialplan_system_extensions.py`（Python 檔）整段貼進 `<script>` 裡，`"""` 這類 Python 語法讓整個 `<script>` 直接 `SyntaxError`
2. 第二次改貼對檔案（JS），但既有函式缺少的收尾 `}` 沒有補在正確位置，括號數量對稱（沒多也沒少，只是位置錯了）不會噴 `SyntaxError`，但新函式變成巢狀宣告在舊函式內部（不是全域函式），導致 `pages` 物件初始化時找不到對應 render 函式，噴 `ReferenceError`
3. 第三次修正只做了「刪除多餘的 `}`」，沒做「補回缺的 `}`」，變成整個 `<script>` 少一個 `}`，`node --check` 直接回報 `Unexpected end of input`

**經驗**：往單一大型 `<script>` 手動插入程式碼時，括號位置錯誤不一定會立刻噴語法錯誤（可能只是把函式關到別的作用域裡），肉眼很難抓，**交付前一定要實際跑語法檢查（`node --check`）**，不能只靠人工核對括號。

**測試結果**：✅ 網頁測試通過（Tab → 67 筆列表 → 展開/收合原始 XML → 搜尋過濾），使用者於 2026-07-01 確認。
