# 使用者登入與權限系統 — 實際版本記錄(取代 permission-feature-summary-20260703.md)

建立日期:2026-07-10
最後更新:2026-07-13(第六節「前端」、第十節「後續規劃」更新，反映使用者管理前端頁面已上線)
狀態:對照 `/opt/fs-dashboard` 實機快照逐一核對,本文件內容為**實際運作版本**,非設計草案
取代文件:`permission-feature-summary-20260703.md`(該文件僅為初版設計決策,與此版本已有實質差異)

## 一、整體架構

- 儲存:`core/auth_db.py`(SQLite,沿用 `cdr_db.py` 的 `_conn()` pattern),路徑 `/opt/fs-dashboard/data/auth.db`
- 認證:JWT(HS256,stdlib `hmac`/`hashlib` 手刻,未引入 PyJWT),`Authorization: Bearer <token>`
- **Token 有效期 30 分鐘**(`core/auth.py` 的 `ACCESS_TOKEN_EXPIRE_MINUTES = 30`)——比一般設計短,前端需要處理過期後導回登入頁的流程(已實作,見第五節)
- JWT 簽章金鑰存在 SQLite 的 `auth_meta` 表(`get_or_create_jwt_secret()`),**不是**存在 `settings.json`
- 權限改變不即時生效(JWT payload 直接快取整份權限矩陣,`require_permission()` 只讀 token,不查 DB),需要重新登入才更新
- 群組(Role)與通話群組(callgroup)是不同概念:`perm_groups` 資料表 / `groups.py` 的 callgroup 功能,命名刻意分開

## 二、權限模型

- 四個獨立布林旗標:`read / create / update / delete`
- `scope` 定義在**群組**層級(`all` / `own`),`owned_ext` 定義在**使用者**層級
- **`scope="own"` 的實際限制方式**(這是與初版設計文件最大的差異):
  - `core/auth.py` 的 `apply_scope(user, requested_ext, module)`:非 own 群組直接放行;是 own 群組則強制把查詢範圍鎖死成 `user["owned_ext"]`,且如果該模組不在 `SCOPABLE_MODULES` 內直接 403
  - **WebSocket 層也做了範圍過濾**:`core/ws_manager.py` 的 `broadcast(data, ext=...)`,`scope="own"` 的連線只會收到 `owned_ext` 相符的即時事件,不是「能連上但前端自己過濾」,是**伺服器端就不推播**

## 三、19 個功能模組(比初版多 2 個)

`overview, report, extensions, groups, ivr, numbers, calls, cdr, recordings, sounds, gateway, dialplan, esl, logs, settings, backup, users, sip_profile, acl`

三個分類:

| 分類 | 模組 |
|---|---|
| Dashboard | overview, report |
| Operational | extensions, groups, ivr, numbers, calls, cdr, recordings, sounds, **sip_profile** |
| System | gateway, dialplan, esl, logs, **acl**, settings, backup, users |

`sip_profile`、`acl` 是 2026-07-03 的 `sip-profile-acl-feature-20260703.md` 功能加進來的,權限系統這邊同步補上對應模組。

## 四、最終權限矩陣(5 個內建群組,與初版設計文件一致,未變動)

| 模組分類 | System Admin | System Viewer | Technical Support Admin | Technical Support | User |
|---|---|---|---|---|---|
| Dashboard | RCUD | R | RCUD | RCU | R(own) |
| Operational(含 sip_profile) | RCUD | R | RCUD | RCUD | R(own:僅 cdr/recordings/calls) |
| System(含 acl) | RCUD | R | RCU(不可 D) | none | none |

- `scope`:僅 `User` 群組為 `own`,其餘皆 `all`
- 5 個內建群組皆 `is_builtin=True`,群組本身不可刪除/改名(建立自訂群組時可指定 scope,但同樣建立後不可再改)

## 五、API 端點清單(實際檔案)

### `routers/auth.py`(`/api/auth` 前綴)

```
POST /api/auth/bootstrap          # 僅能在 count_users()==0 時呼叫一次，建立內建群組+範例帳號
POST /api/auth/login              # 回傳 access_token / expires_in(30分鐘) / must_change_password
GET  /api/auth/me                 # 需 Bearer token，回傳目前身分與權限矩陣
POST /api/auth/change-password    # 需舊密碼驗證
```

**⚠️ 全新環境部署重要提醒**:`server.py` 只呼叫 `auth_db.init_db()` 建表,**不會自動 seed**。全新環境第一次啟動後,必須手動呼叫一次 `POST /api/auth/bootstrap`,否則沒有任何帳號能登入。詳見 `server-snapshot-audit-20260710.md` 第三節。

**JWT payload 實際欄位**(`create_access_token()` 存入的 claim,前端 `getTokenPayload()` 解出來後可直接用):`sub`(使用者名稱,**不是** `username`)、`user_id`、`group_id`、`group_name`、`scope`、`owned_ext`、`permissions`(19 模組矩陣)、`iat`、`exp`。曾經因為前端誤猜成 `username` 導致登入身分文字空白,見 `changelog-details/20260713-user-management-feature.md` 第二節第 6 點。

### `routers/users.py`(`/api/users` 前綴)

```
GET    /api/users
POST   /api/users
PUT    /api/users/{id}
POST   /api/users/{id}/reset-password
DELETE /api/users/{id}
```

`update_user()` 的 `owned_ext` 參數語意是「`None` = 不變更」,不是「清空」——目前無法透過這支 API 把已設定的 `owned_ext` 清空,前端表單留空送出實際上會保留舊值。

### `routers/perm_groups.py`(`/api/perm-groups` 前綴,獨立檔案,非併在 users.py)

```
GET    /api/perm-groups
POST   /api/perm-groups
PUT    /api/perm-groups/{id}/permissions   # 注意路徑帶 /permissions 後綴，只能改權限矩陣，name/scope 固定不可改
DELETE /api/perm-groups/{id}
```

`PUT .../permissions` 這支 API 本身**不會**擋 `is_builtin` 群組(`auth_db.update_group_permissions()` 允許改內建群組的權限內容),前端「內建群組完全唯讀」是**刻意的前端限制**,不是後端規則。

## 六、前端

| 檔案 | 用途 |
|---|---|
| `static/login.html` | 獨立登入頁,`server.py` 有對應 `GET /login.html` route |
| `static/change-password.html` | 獨立改密碼頁,`GET /change-password.html` route |
| `static/js/common.js` | `getToken()`/`isTokenValid()`/`getTokenPayload()`(直接解出完整 JWT payload,供權限判斷與顯示登入身分用,不需額外打 API)/401 攔截自動導回登入頁/WS 連線帶 `?token=` |
| `static/js/init.js` | `applyAuthUI()`:登入後依 JWT payload 的 `permissions` 隱藏無讀取權限的側邊欄項目;並把 `payload.sub`(使用者名稱)+ `payload.group_name` 寫進 `.topbar` 的登入身分欄位 |
| `static/js/users-management.js` | 「使用者管理」頁面本體(見下方) |

### 使用者管理頁面(2026-07-13 上線,`data-page="users"`,側邊欄「系統」分類)

單頁雙 Tab:

- **使用者 Tab**:列表(帳號/權限群組/專屬分機/狀態/待改密碼標籤),可新增、編輯(權限群組/專屬分機/停用)、重設密碼、刪除
- **權限群組 Tab**:列表(名稱/scope/內建標籤),5 個內建群組**完全唯讀**(僅「檢視矩陣」,無編輯/刪除按鈕);自訂群組可編輯 19 個模組的權限矩陣、可刪除;新增自訂群組需指定 name/description/scope + 完整矩陣,建立後 name/scope 不可再改

導覽列會依登入者的 JWT 權限矩陣動態隱藏無讀取權限的項目(`applyAuthUI()`,對照 `data-page` → `core/permissions.py` 的 Module 常數,Dialplan 三個子頁共用 `dialplan` 模組)。這是全站導覽列**第一次**有權限判斷,過去所有頁面的導覽項目都是純靜態顯示、只靠後端 403 擋。

畫面最上方有 `.topbar`(`style.css` 原本就定義、但 07-01 模組化重整後沒接上的插槽):左側顯示目前頁面標題(`#pageTitle`,`switchPage()` 本來就有在寫,過去因為畫面沒有這個元素一直靜默失效),右側顯示「登入身分:帳號(群組名)」+ 登出按鈕。

**已知限制**:
- `owned_ext` 目前無法透過編輯使用者清空(見第五節說明)
- ESL 系統狀態列在帳號無 `esl` 讀取權限時顯示「無存取權限」,與真正斷線的「無法取得」區分
- 導覽列權限隱藏邏輯是全站性的,但目前只針對「使用者管理」新增這次做過完整測試,其餘既有頁面的模組名稱對應未逐一驗證過

詳細測試發現的問題與修復過程見 `changelog-details/20260713-user-management-feature.md`。

## 七、範例帳號(bootstrap 後建立,idempotent)

| username | 對應群組 | owned_ext |
|---|---|---|
| `admin` | System Admin | — |
| `viewer` | System Viewer | — |
| `admin_tech_support` | Technical Support Admin | — |
| `tech_support` | Technical Support | — |
| `user1001` | User | 1001 |

密碼統一為固定初始值(`_SEED_PASSWORD`,實際值請見 `core/auth_db.py`,已於 `test_permissions.sh` 中使用),搭配 `must_change_password` 欄位強制首次登入改密碼。

## 八、WebSocket 認證(獨立於 HTTP REST 驗證)

- 瀏覽器原生 WebSocket API 無法自訂 `Authorization` header,採用業界標準做法:token 走 query string `ws://host:8080/?token=<JWT>`
- `core/runtime.py` 的 `ws_handler()` 相容處理 `websockets` 套件新舊版本的路徑取得方式(`websocket.request.path` vs legacy `.path`)
- 缺 token 或驗證失敗:`websocket.close(code=4401, reason=...)`
- 通過驗證後 `manager.add(websocket, user_info)`,`user_info` 含 `scope`/`owned_ext`,供 `broadcast()` 做範圍過濾(見第二節)

## 九、已知待清理項目

`routers/runtime.py`、`routers/cdr_db.py`、`routers/migrate_cdr_backfill.py` 三個孤兒/重複檔案、`server.py` 的 `calls.router` 重複掛載——**已於 2026-07-10 由 `update2.sh` 清理完成**,詳見 `changelog-details/20260710-orphan-file-cleanup.md`。

## 十、後續規劃

1. ~~補上「使用者管理」/「權限群組」前端頁面~~ → **已完成**,見第六節(2026-07-13,`update3.sh`~`update7.sh`)
2. ~~清理孤兒檔案~~ → **已完成**(2026-07-10,`update2.sh`)
3. ~~修正 `calls.router` 重複掛載~~ → **已完成**(2026-07-10,`update2.sh`)
4. `FreeSwitch-Project-v3-20260702.md` 補上認證/權限系統 + SIP Profile/ACL 章節(尚未進行)
5. (新增)導覽列權限隱藏邏輯建議找時間用不同權限組合的帳號完整測一輪,確認全部 18 個既有頁面的 `data-page` 對應模組名稱都正確
6. (新增)`owned_ext` 清空限制——後端需要設計「明確清空」的參數語意或獨立端點,才能讓使用者管理頁面支援清空專屬分機
