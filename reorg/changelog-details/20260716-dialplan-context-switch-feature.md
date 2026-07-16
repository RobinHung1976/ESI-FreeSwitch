# Dialplan Context 切換 UI（2026-07-16）

> 對應 `PROJECT-OVERVIEW.md` 中優先待辦「Dialplan Context 切換 UI」（已知待處理事項第 3 點）。
> 上層功能文件：[`feature-dialplan-routing-rule.md`](../features/feature-dialplan-routing-rule.md)、
> [`feature-dialplan-custom.md`](../features/feature-dialplan-custom.md)

## 背景

`RouteRule` 的 `context` 欄位早就存在，但**實際檔案永遠寫死進 `/etc/freeswitch/dialplan/default/`**（`ROUTE_DIR` 常數寫死），`context` 欄位只是存進 meta JSON，沒有真的決定檔案位置；前端也完全沒有對應的選單。等於「有欄位但沒生效」。

## 設計決策

| 項目 | 決定 | 原因 |
|---|---|---|
| context 資料夾對應 | 一個 context = `/etc/freeswitch/dialplan/` 底下一個子資料夾 | 對齊 FreeSwitch 本身的 context/include 機制 |
| context 清單來源 | 動態掃描 `/etc/freeswitch/dialplan/` 底下實際存在的子資料夾（`GET /api/dialplan/contexts`），不開放自由輸入 | 避免打錯字造成「這個 context 永遠不會被撥打到」的規則 |
| 建立新 context 的入口 | 只放在「自定義 Dialplan」頁面（`POST /api/dialplan/contexts`，純 mkdir） | 路由規則頁面新增規則時只該選「已確定會生效」的 context；自定義 Dialplan 頁面本來就是使用者主動撰寫 XML 內容的地方，建立 context 後緊接著就會填入第一份內容，資料夾不會長時間空著 |
| 建立資料夾的風險提示 | 建立時強制顯示警語：純 mkdir 不會自動生效，需另外到 SIP Profile 或其他 dialplan 設定讓某個來源指向這個 context | 避免使用者誤以為建立資料夾＝功能立即生效 |
| 衝突檢查分組 | 同 context 才視為真衝突（阻擋儲存，409）；跨 context 的號碼樣式重疊只回傳 `other_context_matches` 當參考資訊，不阻擋 | FreeSwitch 是先進 context 再比對 pattern，不同 context 的規則本來就不會互相衝突 |
| 列表呈現 | 單一 context 沿用原本平面表格（零改動、零額外點擊）；篩選選到「全部 context」才切換成卡片總覽，點卡片下鑽進去看該 context 的規則，上方顯示麵包屑可返回 | 多次討論後選定卡片＋下鑽＋麵包屑，取代最初提案的手風琴摺疊表格，避免多 context 混在一起看不清楚，同時不影響現有單一 context（多數安裝情境）的操作路徑 |
| 現有規則遷移 | 不需任何搬移／回填 | 前端過去從未送出 `context` 欄位，後端一律套用預設值 `"default"`；現有規則的檔案本來就已經物理上放在 `default/` 資料夾，meta 記錄的 context 也已經是 `"default"`，兩者本來就一致 |

## 修改的檔案

### 後端 `routers/dialplan_routes.py`

- 新增 `DIALPLAN_ROOT`、`_route_dir(context)`、`list_contexts()`、`create_context_dir(context)`
- `_route_filepath(route_id, context=None)`：提供 `context` 時直接組出目標路徑（新增/搬移用）；不提供則跨所有 context 資料夾掃描既有檔案（更新/刪除/查詢/toggle 用）
- `_load_all_routes()`、`_legacy_scan_dirs()`：改為掃描所有 context 資料夾，不再只看 `default`/`public`
- `_parse_legacy_route_file()`：legacy 檔案的 context 改用實際所在資料夾名稱推斷（原本寫死 `"default" if "/default/" in filepath else "public"`）
- `find_conflicts()`：回傳值從 `List[dict]` 改為 `{"same_context": [...], "other_context": [...]}`，新增 `context` 參數決定分組依據
- `update_route()`：若 `context` 有變更，檔案要從舊資料夾搬到新資料夾——先在新位置寫入並 `reload_and_verify` 成功，才刪除舊檔案（`make_backup(old_filepath, suffix="bak.moved")`），失敗則 `rollback_new_file()` 清掉剛寫的新檔，維持升級前狀態
- 新增 `GET /api/dialplan/contexts`、`POST /api/dialplan/contexts`（後者只給自定義 Dialplan 頁面呼叫）
- `check_conflict` 端點新增 `context` 參數，回傳新增 `other_context_matches`

### 前端 `static/js/dialplan.js`

**路由規則 Tab**：
- 新增 context 篩選下拉（`_routeFilterSelectHtml()`）：預設選中規則數最多的 context（單一 context 時行為與改版前完全一致）；選「🗂 全部 context」切換成卡片總覽（`_routeOverviewCardsHtml()`），點卡片下鑽（`_routeDrillIntoContext()`）進入該 context 的平面表格並顯示麵包屑（`_routeFlatTableHtml()`），可點「← 返回總覽」（`_routeBackToOverview()`）
- 表單新增 Context 選單（`_routeContextOptionsHtml()`），新增規則時預設帶入目前篩選的 context
- 衝突警告分兩個區塊：同 context 紅色阻擋、跨 context 藍色參考資訊（`_checkRouteConflict()`）
- 規則表格新增 Context 欄位

**自定義 Dialplan Tab**：
- `dc-context`（範本模式）、`dc-manual-context`（手動模式）兩個選單改成動態讀取 `/api/dialplan/contexts`，並加「+ 建立新 context...」選項（`_dcPromptNewContext()`／`_dcCreateNewContext()`），成功後自動選取新建立的 context

## 已知限制

- 建立新 context 資料夾後，仍需要使用者自行到 SIP Profile 或其他 dialplan 設定讓某個來源指向這個 context 名稱，通話才會真正進入——這是刻意設計（避免把高風險的 SIP Profile 綁定邏輯做進這次改動），已在建立當下顯示警語

## 相關修復（同一輪測試中一併發現並修復）

- `custom_regex` 對 `custom_regex` 衝突檢查失效，見 [`20260716-custom-regex-conflict-detection-fix.md`](20260716-custom-regex-conflict-detection-fix.md)
- 全站寫入操作缺少 `Authorization` header（與本功能無關的既有 bug，測試過程中順帶發現），見 [`20260716-auth-header-missing-fix.md`](20260716-auth-header-missing-fix.md)

## 驗證方式

```bash
curl -s http://127.0.0.1:3000/api/dialplan/contexts -H "Authorization: Bearer <token>"
python3 -m py_compile routers/dialplan_routes.py
node --check static/js/dialplan.js   # 若 server 有裝 node
```

瀏覽器實測：
- 路由規則 Tab：context 篩選（單一/全部總覽/下鑽/麵包屑返回）、新增/編輯規則的 Context 選單、同 context 衝突阻擋、跨 context 僅供參考
- 自定義 Dialplan Tab：建立新 context（含警語顯示）、建立後立即可在下拉選單選到
- 編輯既有規則變更 context：確認檔案從舊資料夾搬到新資料夾（`.bak.moved.*` 備份保留舊檔內容）、reloadxml 後撥號行為正常

**測試結果**：已於 production server（`debian-freeswitch`）實際部署（`update19.sh`）並經多輪瀏覽器實測驗證通過，含 context 篩選/總覽/下鑽/麵包屑、建立新 context、規則搬移 context 等情境。
