# 分機管理 Context 欄位改為下拉選單（2026-07-16）

> 對應 `feature-extensions.md` 的表單欄位；重用 [`20260716-dialplan-context-switch-feature.md`](20260716-dialplan-context-switch-feature.md) 建立的 `GET /api/dialplan/contexts`。

## 背景

分機管理新增/編輯表單的 Context 欄位原本是純文字輸入框，需要手動打字，容易打錯字造成分機的 SIP context 對不到任何實際存在的 dialplan 資料夾（等於這個分機永遠無法正確路由）。後端沒有對應校驗，錯字不會被攔下來。

## 修復

### 前端共用重構（`static/js/common.js`）

新增 `loadDialplanContexts()`（30 秒快取）取代原本 `dialplan.js` 兩處（路由規則 Tab 的 `_routeContextCache`、自定義 Dialplan Tab 的 `_dcContextsCache`）各自獨立呼叫 `GET /api/dialplan/contexts` 的作法，改成三個頁面（路由規則、自定義 Dialplan、分機管理）共用同一份快取。同時新增公開版本的 `escHtml()`/`escAttr()`（`dialplan.js` 原本已有私有版本 `_escHtml`/`_escAttr`，這次刻意不動它，避免大範圍改動既有程式碼，只是另外提供公開版本供其他頁面共用）。

自定義 Dialplan Tab 建立新 context 成功後，除了更新自己頁面的本地快取，也會呼叫新增的 `clearDialplanContextsCache()` 清除共用快取，讓分機管理／路由規則頁面下次載入時能立即抓到最新清單，不需要等 30 秒 TTL 過期。

### 分機管理表單（`static/js/extensions-groups.js`）

Context 欄位 `<input>` 改成 `<select>`，選項來源為 `loadDialplanContexts()`。**只能選現有 context，不提供就地建立**——呼應 Context 切換 UI 當初的設計原則：建立新 context 資料夾的入口只開放在「自定義 Dialplan」頁面。

編輯模式若目前值不在清單中（例如該 context 資料夾之後被移除），仍會把原值加進選項並標示「⚠️ 資料夾可能已不存在」，不會強迫使用者一開表單就被迫改成別的 context，避免非預期變更。

## 修改的檔案

- `static/js/common.js`：新增 `loadDialplanContexts()`/`clearDialplanContextsCache()`/`escHtml()`/`escAttr()`
- `static/js/dialplan.js`：路由規則 Tab、自定義 Dialplan Tab 改用共用函式；建立新 context 成功後清共用快取（3 處）
- `static/js/extensions-groups.js`：Context 欄位改為下拉選單，新增 `_extContextOptionsHtml()`（5 處）

（`update27.sh`）

## 驗證方式

純前端變動，瀏覽器強制重新整理（Ctrl+Shift+R）即生效，不需要 `systemctl restart`。

瀏覽器實測：
1. 分機管理新增/編輯分機，Context 欄位為下拉選單，預設/現有值正確帶入
2. 在「自定義 Dialplan」建立一個新 context，回到分機管理重新整理頁面，新增/編輯分機的 Context 下拉選單能立即選到新建的 context（驗證共用快取跨頁面即時失效）
3. 路由規則 Tab 的 Context 篩選/表單選單功能不受影響（確認重構沒有改壞原本行為）
4. 「🔄 變更號碼」流程一併測試，確認新分機的 context 正確帶到新號碼上

**測試結果**：已於 production server（`debian-freeswitch`）實際執行 `update27.sh`，依上述步驟測試通過，使用者確認功能正常。
