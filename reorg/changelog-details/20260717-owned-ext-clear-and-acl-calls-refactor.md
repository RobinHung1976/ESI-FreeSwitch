# `owned_ext` 明確清空 + `calls`/`acl` 前端頁面重構 — 2026-07-17

> 對應 `PROJECT-OVERVIEW.md` 已知待處理事項第 6 點、第 10 點
> 對應腳本：`update29.sh`～`update34.sh`（已於 production server `debian-freeswitch` 執行成功並部署）

## 一、`owned_ext` 支援明確清空（`update29.sh`）

### 背景

`core/auth_db.py` 的 `update_user()` 把 `owned_ext=None` 定義成「不變更」（刻意設計，避免前端表單漏填就把舊值洗掉），代價是完全沒有路徑可以「有意清空」已設定的專屬分機。

### 修改內容

- `core/auth_db.py`：`update_user()` 新增 `clear_owned_ext: bool = False` 參數。`True` 時無視 `owned_ext` 傳了什麼，一律寫入 `NULL`；`False`（預設）維持原本「`None`=不變更」的向下相容行為
- `routers/users.py`：`UpdateUserRequest` 新增 `clear_owned_ext: bool = False` 欄位，並轉傳給 `auth_db.update_user()`
- `static/js/users-management.js`：編輯使用者表單新增「清空專屬分機」勾選框；勾選後自動停用並清空上方輸入框（避免同時填新值又勾清空造成語意衝突），送出時額外帶 `clear_owned_ext: true`

### 驗證結果

實機測試 `user1001`（`owned_ext=1001`）：
- 不勾選、上方欄位留空 → 儲存 → `owned_ext` 維持 `1001`（向下相容確認無誤）
- 勾選「清空專屬分機」→ 儲存 → `GET /api/users` 確認該使用者 `owned_ext` 變為 `null` ✅

### 過程中的插曲

- `update29.sh` 因 server 環境沒有安裝 `node`，`node --check` 導致腳本中止在 commit 之前，但 3 個檔案的修改已寫入磁碟。重跑改良版（`node` 不存在時改印警告略過）後正確完成 commit。

## 二、`calls`/`acl` 前端頁面重構（`update30.sh`～`update33.sh`）

### 背景

`PROJECT-OVERVIEW.md` 待處理事項第 10 點記載：`calls` 模組有 render 函式（`static/js/calls.js` 的 `renderCalls()`）但側邊欄無入口；`acl` 後端 API（`routers/acl.py`）已存在但當時被認為「完全沒有對應前端頁面」。

### 深入排查後發現的實際狀況（與待辦描述有出入）

1. **`calls`**：`static/js/calls.js` 除了頂部的 `renderCalls()`（舊版簡易通話列表，含掛斷/保留/轉接操作按鈕）外，下半部還定義了一整組 `_uc*` 系列共用函式（`_ucBuildRows`、`_ucGetCallsForExt`、`_ucRenderTable` 等）。經比對 `changelog-details/20260626-realtime-status-overview-redesign.md`，這組函式正是 2026-06-26「使用者即時狀態總覽重構」合併進 `overview.js`（現「通話即時狀態」頁面）的核心邏輯——**`overview.js` 的 `renderOverview()` 實際上呼叫的就是 `calls.js` 定義的這組函式**。也就是說 `calls.js` 不是完全沒用的孤兒檔案，只有最上層的 `renderCalls()` 獨立頁面函式才是 2026-06-26 重構後真正沒有入口、也沒被清理掉的舊程式碼。

2. **`acl`**：`static/js/sip-profile.js` 其實早就實作了 ACL 信任清單管理（Tab 2「信任 SBC 清單」），只是掛在「SIP Profile 進階設定」頁面底下、依 `sip_profile` 模組權限決定可見性，但後端 `routers/acl.py` 檢查的是 `Module.ACL` 權限。對照權限矩陣，`Technical Support` 群組有 `sip_profile` 讀寫、但 `acl` 是 `none`——會出現「看得到頁籤，點進去打 API 卻吃 403」的情況，這才是待辦事項描述「任何群組皆無法從 UI 操作 ACL」的真正成因，而非完全沒有程式碼。

### 第一階段（`update30.sh`）：先各自補齊入口

- `static/index.html`：側邊欄「監控」分類補上 `data-page="calls"`（即時通話監控）；「系統」分類補上 `data-page="acl"`（ACL 信任清單）獨立頁面入口
- `static/js/init.js`：`pages{}` 新增 `acl` 頁面項目（`calls` 頁面項目原本就存在）
- `static/js/acl.js`（新檔案）：獨立的 ACL 信任清單管理頁面，函式全部用 `aclPage` 前綴命名，避免跟 `sip-profile.js` 既有的同類函式撞名；不重用 `sip-profile.js` 內的函式，因為那組函式的刷新邏輯綁死在 SIP Profile 頁面的 Hub 版面，直接呼叫在獨立頁面會找不到對應 DOM 而失效

### 第二階段（討論後決定，`update31.sh`～`update33.sh`）：確認重複後精簡

與使用者確認：
- 「通話即時狀態」（`overview`）目前的監控表格沒有掛斷/保留/轉接按鈕（只能監看），使用者確認**不需要**這個操作能力，純監看即可
- 因此「即時通話監控」（`calls` 獨立頁面）與「通話即時狀態」功能完全重複，且前者的操作按鈕本來就用不到，直接移除獨立入口
- ACL 管理希望統一成一個入口，選擇保留新的獨立頁面，並要求改名為「**SIPTrunk ACL 信任清單**」

**`update31.sh`** 執行的改動：
- `static/index.html`：移除 `calls` nav-item；`acl` nav-item 標籤改名（此步驟因判斷邏輯錯誤未真正生效，見下方「腳本錯誤與修正」）
- `static/js/init.js`：移除 `pages.calls`；`pages.acl` 標題改名
- `static/js/acl.js`：更新說明文字，移除「與 sip-profile.js Tab2 同步」的描述
- `static/js/calls.js`：移除獨立頁面 `renderCalls()`，**保留**下方所有 `_uc*` 共用函式庫（`overview.js` 仍依賴）
- `static/js/sip-profile.js`：移除 Tab 2「信任 SBC 清單」，`SP_HUB_TREE` 從 3 個 Tab 精簡為 2 個（Profile 參數 / 新增 NAT Profile）

### 腳本錯誤與修正（`update32.sh`、`update33.sh`、`update34.sh`）

`update31.sh` 裡有兩處判斷邏輯寫錯：

1. **`update31.sh` 本身**：用 `grep -q '>ACL 信任清單<'` 判斷 acl nav-item 是否已改名，但實際 HTML 是「ACL 信任清單」後面接換行再接 `</div>`，不是緊接著 `<`，pattern 從未命中，誤判成「已改名」而跳過，導致標籤實際上沒有真的改名。`update32.sh` 用「檢查新名稱『SIPTrunk ACL 信任清單』是否已存在」的正確邏輯修正並補上這次改名。

2. **`update32.sh` 自己新增的「基本結構健檢」**：用 `'<div class="nav-item"'`（緊接雙引號）數 nav-item 數量，但「通話即時狀態」項目的 class 是 `class="nav-item active"`，多了 `active` 導致算少 1 個，跟 `switchPage` 呼叫次數對不上，觸發假警報。`set -e` 讓腳本在改名成功寫入磁碟「之後」但 commit「之前」中止。`update33.sh` 補做這次遺漏的 commit（不重複這個有 bug 的健檢邏輯）。

3. **連帶的 commit 分類問題**：`update33.sh` 開頭固定的「自動歸檔」步驟用 `git add -A`，把 `update32.sh` 留下的未 commit 殘留（index.html 的改名）一併掃進同一個 `chore` commit，導致這次的 `fix` 被錯誤分類成 `chore`。`update34.sh` 用 `git reset --soft HEAD~2` + 精確拆分重新 commit，並在動 git 歷史前做了兩層安全檢查（確認要拆分的 commit 內容符合預期、確認尚未 `git push`），拆成一筆乾淨的 `chore`（純歸檔）與一筆獨立的 `fix`（`SIPTrunk ACL 信任清單` 改名）。

### 最終驗證結果

- 側邊欄「監控」分類只剩「通話即時狀態」「通話統計報表」，「即時通話監控」入口已移除
- 側邊欄「系統」分類顯示「SIPTrunk ACL 信任清單」（獨立頁面），資料與後端 `/api/acl/trusted-sbc*` API 一致（新增/編輯/刪除/重啟套用皆測試通過，`journalctl` 確認無 403/500）
- 「SIP Profile 進階設定」頁面只剩「Profile 參數」「新增 NAT Profile」兩個 Tab，Tab 2 已完整移除
- git commit 歷史乾淨，`chore`/`fix`/`feat` 分類正確，`git status` 無殘留

### 影響檔案總覽

| 檔案 | 異動 |
|---|---|
| `core/auth_db.py` | `update_user()` 新增 `clear_owned_ext` 參數 |
| `routers/users.py` | `UpdateUserRequest` 新增 `clear_owned_ext` 欄位 |
| `static/js/users-management.js` | 編輯使用者表單新增「清空專屬分機」勾選框 |
| `static/index.html` | 移除 `calls` nav-item；`acl` nav-item 改名為「SIPTrunk ACL 信任清單」 |
| `static/js/init.js` | 移除 `pages.calls`；`pages.acl` 標題改名 |
| `static/js/acl.js` | 新增檔案（獨立 ACL 信任清單頁面） |
| `static/js/calls.js` | 移除 `renderCalls()` 獨立頁面，保留 `_uc*` 共用函式庫 |
| `static/js/sip-profile.js` | 移除 Tab 2「信任 SBC 清單」，精簡為兩分頁 |

`core/auth_db.py`、`routers/users.py` 兩個後端檔案異動後皆已 `systemctl restart fs-dashboard`；其餘皆為純前端檔案，瀏覽器重新整理即可生效。
