# 全站寫入操作缺少 Authorization header，導致新增/編輯/刪除一律 401（2026-07-16）

> 於 [Dialplan Context 切換 UI](20260716-dialplan-context-switch-feature.md) 功能瀏覽器實測階段發現，
> 範圍與 Dialplan Context 功能無關，是既有 bug，一併修復。

## 現象

「Dialplan 路由設定」測試「新增路由規則」時，畫面顯示「缺少登入憑證」，儲存失敗。Network 分頁顯示 `POST /api/dialplan/routes` 401；但同一頁面的 `GET /api/dialplan/routes`/`/api/gateway/list`/`/api/dialplan/contexts` 都正常回 200。

排查過程中，用同一組登入狀態測試「Gateway / SIP Trunk」頁面新增 Gateway，也同樣 401（`gateway.js` 完全沒被這次改動碰過），確認是**全站性、跟這次功能開發無關**的既有問題。

## 根本原因

`static/js/common.js` 的 `apiFetch()` 有正確自動帶 `Authorization: Bearer <token>`：

```javascript
async function apiFetch(path, options = {}) {
  const token = getToken();
  const headers = { ...(options.headers || {}) };
  if (token) headers['Authorization'] = `Bearer ${token}`;
  ...
}
```

但專案中多支前端檔案的「新增/編輯/刪除」寫入操作**直接呼叫原生 `fetch()`**，完全沒有帶這個 header；GET 讀取類請求則多半有透過 `apiFetch()` 走，所以查詢正常、寫入卻 401。此問題自使用者權限系統上線（約 2026-07-10，見 `feature-permissions-auth.md`）之後就存在，只是先前的測試多集中在讀取類功能，這次才真正撞到。

用以下指令可以列出所有繞過 `apiFetch()` 直接呼叫 `fetch()` 的地方：

```bash
cd static/js
grep -n "await fetch(" *.js | grep -v "apiFetch\|common.js"
```

## 修復範圍（共 10 支檔案）

| 批次 | 檔案 | 處數 |
|---|---|---|
| `update20.sh` | `gateway.js` | 2（`saveGw`/`deleteGw`） |
| `update20.sh` | `dialplan.js` | 8（`saveRoute`/`deleteRoute`/`toggleRouteEnabled`/`testRouteNumber`/`_dcUpdatePreview`/`dcSaveTemplateForm`/`_checkRouteConflict`/`_dcCreateNewContext`） |
| `update21.sh` | `cdr.js` | 1（歸檔下載） |
| `update21.sh` | `extensions-groups.js` | 8（分機/群組的儲存/建立/刪除，含改號流程的雙步驟建立+刪除） |
| `update21.sh` | `ivr.js` | 3（音檔上傳/刪除/強制刪除） |
| `update21.sh` | `logs.js` | 4（歷史日期清單、歷史查詢、log rotate） |
| `update21.sh` | `recordings.js` | 1（刪除錄音） |
| `update21.sh` | `settings-vars.js` | 4（CDR 歸檔/刪除歸檔、Dialplan 手動編輯儲存、備份還原） |
| `update21.sh` | `sip-profile.js` | 5（參數更新、ACL 套用重啟、ACL 新增/刪除、NAT 精靈） |
| `update21.sh` | `sounds.js` | 3（音檔上傳/刪除/強制刪除） |

共約 39 處。修法一律是在原本的 `fetch()` 呼叫的 `headers` 裡補上：

```javascript
'Authorization': `Bearer ${getToken()}`
```

檔案上傳（`FormData` body，如 `sounds/upload`、`backup/restore`）刻意**不**加 `Content-Type`，只加 `Authorization`，避免蓋掉瀏覽器自動產生的 `multipart/form-data` boundary。

## 未涵蓋範圍

`static/js/` 底下若還有其他檔案（本次以外未列在上表的）也用同樣手法直接呼叫 `fetch()` 做寫入操作，理論上會有同樣問題，但截至本次修復尚未發現其他遺漏（已用上述 grep 指令排查過整個 `static/js/` 目錄）。之後新增前端檔案時，寫入操作應優先使用 `apiFetch()`，而不是直接呼叫 `fetch()`，避免重蹈覆轍。

## 修改的檔案

- `static/js/gateway.js`
- `static/js/dialplan.js`
- `static/js/cdr.js`
- `static/js/extensions-groups.js`
- `static/js/ivr.js`
- `static/js/logs.js`
- `static/js/recordings.js`
- `static/js/settings-vars.js`
- `static/js/sip-profile.js`
- `static/js/sounds.js`

## 驗證方式

純前端檔案改動，瀏覽器強制重新整理（Ctrl+Shift+R）即生效，不需要 `systemctl restart`。

```bash
cd static/js
grep -n "await fetch(" *.js | grep -v "apiFetch\|Authorization"   # 應無殘留漏補的寫入操作
```

瀏覽器逐項實測（每項都確認不再 401）：Gateway 新增、路由規則新增/編輯/刪除/啟停用/測試、CDR 歸檔下載、分機新增/改號/刪除、群組新增/改號/刪除、IVR 音檔上傳/刪除、系統日誌歷史查詢/rotate、錄音刪除、設定頁 CDR 歸檔/刪除/Dialplan 手動編輯/備份還原、SIP Profile 參數/ACL/NAT 精靈、音檔庫上傳/刪除。

**測試結果**：已於 production server（`debian-freeswitch`）實際執行 `update20.sh`/`update21.sh`，瀏覽器實測 Gateway 新增與路由規則存/刪/啟停用皆確認不再 401；其餘頁面因範圍較大，建議後續使用時留意是否仍有 401，若有請回報補測。
