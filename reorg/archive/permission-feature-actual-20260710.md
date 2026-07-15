# 使用者登入與權限系統 — 實際版本記錄(取代 permission-feature-summary-20260703.md)

建立日期:2026-07-10
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
- 5 個內建群組皆 `is_builtin=True`,群組本身不可刪除/改名

## 五、API 端點清單(實際檔案)

### `routers/auth.py`(`/api/auth` 前綴)

```
POST /api/auth/bootstrap          # 僅能在 count_users()==0 時呼叫一次，建立內建群組+範例帳號
POST /api/auth/login              # 回傳 access_token / expires_in(30分鐘) / must_change_password
GET  /api/auth/me                 # 需 Bearer token，回傳目前身分與權限矩陣
POST /api/auth/change-password    # 需舊密碼驗證
```

**⚠️ 全新環境部署重要提醒**:`server.py` 只呼叫 `auth_db.init_db()` 建表,**不會自動 seed**。全新環境第一次啟動後,必須手動呼叫一次 `POST /api/auth/bootstrap`,否則沒有任何帳號能登入。詳見 `server-snapshot-audit-20260710.md` 第三節。

### `routers/users.py`(`/api/users` 前綴)

```
GET    /api/users
POST   /api/users
PUT    /api/users/{id}
POST   /api/users/{id}/reset-password
DELETE /api/users/{id}
```

### `routers/perm_groups.py`(`/api/perm-groups` 前綴,獨立檔案,非併在 users.py)

```
GET    /api/perm-groups
POST   /api/perm-groups
PUT    /api/perm-groups/{id}/permissions   # 注意路徑帶 /permissions 後綴，只能改權限矩陣，name/scope 固定不可改
DELETE /api/perm-groups/{id}
```

## 六、前端(獨立靜態頁,非 JS 覆蓋層)

| 檔案 | 用途 |
|---|---|
| `static/login.html` | 獨立登入頁,`server.py` 有對應 `GET /login.html` route |
| `static/change-password.html` | 獨立改密碼頁,`GET /change-password.html` route |
| `static/js/common.js` | `getToken()`/`isTokenValid()`(前端自行解 JWT payload 判斷是否過期)/401 攔截自動導回登入頁/WS 連線帶 `?token=` |

**⚠️ 目前沒有「使用者管理」/「權限群組」的前端頁面**——`static/js/init.js` 的 `pages{}` 與 `static/index.html` 的導覽列都沒有對應項目。後端 API 齊全,但只能用 `curl` 操作(參考 `test_permissions.sh`),沒有網頁介面可以新增使用者、調整權限矩陣。這是目前最主要的功能缺口。

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

詳見 `server-snapshot-audit-20260710.md` 第五節:`routers/runtime.py`、`routers/cdr_db.py`、`routers/migrate_cdr_backfill.py` 三個孤兒/重複檔案待刪除,`server.py` 有一處 `calls.router` 重複掛載的既有 bug。

## 十、後續規劃(尚未進行,待使用者排序)

1. 補上「使用者管理」/「權限群組」前端頁面(對應第六節的缺口,也是本次系列討論最初的需求)
2. 清理孤兒檔案(第九節)
3. 修正 `calls.router` 重複掛載
4. `FreeSwitch-Project-v3-20260702.md` 補上認證/權限系統 + SIP Profile/ACL 章節
