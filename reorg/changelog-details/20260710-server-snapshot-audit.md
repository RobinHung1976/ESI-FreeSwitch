# Server 實際現況稽核(對照 fs-dashboard-snapshot.zip vs 現有 md 文件)

建立日期:2026-07-10
資料來源:使用者上傳的 `/opt/fs-dashboard` 現況快照(已排除 `settings.json`/`data/`/`backups/`/`.git`)
稽核方式:唯讀比對,未修改任何檔案

## 零、結論先講

1. **上一輪產出的 `update1.sh` 正式作廢**,不要執行——它是基於較舊、較不完整的版本寫的
2. **`permission-feature-summary-20260703.md` 已過時,需要用本次新增的 `permission-feature-actual-20260710.md` 取代參考**
3. **其餘 md 文件本次沒有發現不一致之處**,不做全面重寫(理由見第三節)
4. 使用者最初的問題「是不是沒有可以管理帳號的頁面」——**現在答案仍然是「是」**,後端 API 都做好了,但前端**沒有任何頁面**可以管理使用者/權限群組(見第四節)

---

## 一、完整檔案盤點

| 分類 | 檔案 | 行數 | 備註 |
|---|---|---|---|
| 認證核心 | `core/auth.py` | 116 | HS256 JWT、`HTTPBearer`、`require_permission()`、`apply_scope()` |
| 認證核心 | `core/auth_db.py` | 402 | SQLite CRUD、JWT 金鑰存 `auth_meta` 表 |
| 認證核心 | `core/permissions.py` | 162 | **19 個模組**(含新增的 `sip_profile`、`acl`) |
| 認證核心 | `core/ws_manager.py` | 57 | WebSocket 連線管理 + **依 scope/owned_ext 過濾推播內容** |
| API router | `routers/auth.py` | 72 | `/api/auth/login`、`/me`、`/change-password`、`/bootstrap` |
| API router | `routers/users.py` | 69 | `/api/users*` CRUD |
| API router | `routers/perm_groups.py` | 69 | `/api/perm-groups*` CRUD(獨立檔案,非 `users.py` 內) |
| API router | `routers/sip_profile.py` | 315 | 已由 `sip-profile-acl-feature-20260703.md` 記錄,現況相符 |
| API router | `routers/acl.py` | 190 | 同上 |
| 前端 | `static/login.html` | 171 | **獨立靜態頁面**,非 JS 覆蓋層 |
| 前端 | `static/change-password.html` | 164 | 獨立靜態頁面 |
| 前端 | `static/js/common.js` | 433 | 已含 `getToken()`/`isTokenValid()`/401 攔截/WS token 帶入 |
| 測試 | `test_permissions.sh` | — | 5 組內建帳號的權限矩陣驗證腳本,密碼 `ChangeMe!2026` |
| ⚠️ 孤兒/重複檔案 | `routers/runtime.py` | 555 | **與 `core/runtime.py` 內容不同,是較舊版本，已無人 import，可安全刪除** |
| ⚠️ 孤兒/重複檔案 | `routers/cdr_db.py` | 422 | 與 `core/cdr_db.py` **逐字元相同**,複製到錯資料夾 |
| ⚠️ 孤兒/重複檔案 | `routers/migrate_cdr_backfill.py` | 51 | 與根目錄 `migrate_cdr_backfill.py` **逐字元相同**,複製到錯資料夾 |

---

## 二、關鍵設計差異(相較上一輪我做的版本)

| 項目 | 我上一輪的版本 | Server 實際版本 |
|---|---|---|
| Token 有效期 | 12 小時 | **30 分鐘**(`ACCESS_TOKEN_EXPIRE_MINUTES = 30`) |
| JWT 金鑰存放 | `settings.json` | SQLite `auth_meta` 表(`get_or_create_jwt_secret()`) |
| `scope="own"` 實際限制 | 只寫進 JWT,CRUD 端沒真的過濾 | **`apply_scope()` 真的會鎖定/拒絕**,且 **WebSocket 推播內容也依 `owned_ext` 過濾**(`ws_manager.py` 的 `broadcast(ext=...)`) |
| 登入 UI | JS 動態覆蓋層(`login.js`) | **獨立靜態頁** `static/login.html`、`static/change-password.html` |
| 初始帳號建立時機 | server 啟動時自動 seed | **手動觸發**:`POST /api/auth/bootstrap`,且僅能在 `count_users()==0` 時呼叫一次 |
| 權限群組 CRUD | 併在 `users.py` 內 | 獨立檔案 `routers/perm_groups.py`,路由是 `/api/perm-groups` + `/api/perm-groups/{id}/permissions`(注意:PUT 路徑多帶 `/permissions` 後綴,跟我上一輪的 `PUT /api/perm-groups/{id}` 路徑不同) |

### 更正我上一輪的一個誤判

上一輪我猜測 `routers/users.py` 跟 `routers/perm_groups.py` 可能**路由前綴衝突**——**這是錯的**,已確認 `routers/users.py` 的 `prefix="/api/users"` 完全沒有定義任何 `/api/perm-groups*` 路由,兩支檔案分工清楚、沒有衝突。特此更正。

---

## 三、⚠️ 重要發現:全新環境部署有一個容易漏掉的步驟

`server.py` 的 lifespan 只呼叫 `auth_db.init_db()`(建表),**沒有**呼叫 `seed_builtin_groups_and_users()`。程式碼註解寫:

> 過渡期讓 auth.db 保持「無使用者」即可全面放行，避免整合測試被鎖外

**但實際檢查後,這個「全面放行」的邏輯根本沒有被實作**——`core/auth.py` 的 `get_current_user()` 一律要求合法 JWT,沒有任何「`count_users()==0` 就跳過驗證」的程式碼路徑。也就是說目前的真實行為是:

> **全新部署後,在手動呼叫 `POST /api/auth/bootstrap` 之前,沒有任何帳號存在,任何人都無法登入(而不是註解說的「誰都能先進去」)。**

這其實是**更安全**的結果(留空比全開安全),但**註解描述的意圖跟實際行為不一致**,容易誤導之後維護的人以為系統會在無帳號時自動放行。

**對未來部署的實務影響**:任何全新環境(例如未來真的要在 ESI-FreeSwitch repo 上重新部署一次)第一次啟動後,必須手動呼叫一次:

```bash
curl -X POST http://localhost:3000/api/auth/bootstrap
```

才會建立 5 個內建群組 + 5 個範例帳號(密碼統一 `ChangeMe!2026`)。這點目前**沒有任何文件記錄**,建議寫進部署文件。

---

## 四、回到最初的問題:「是不是沒有可以管理帳號的頁面?」—— 答案仍然是「是」

檢查 `static/js/init.js` 的 `pages{}` 和 `static/index.html` 的 nav-item 清單,**目前 18 個導覽頁面裡沒有「使用者管理」或「權限群組」**。後端 `routers/users.py`、`routers/perm_groups.py` 功能都齊全,但:

- 沒有前端頁面可以新增/停用使用者
- 沒有前端頁面可以調整權限矩陣
- 唯一能操作的方式是 `curl`(如 `test_permissions.sh` 示範的方式)

這代表**這條對話一開始的原始需求,實際上還沒有被滿足**——即使 server 上這套系統比我上一輪做的更完整,前端管理頁面這塊仍是空的。

---

## 五、待清理項目(對應優先順序清單的第 2 項)

| 檔案 | 建議動作 | 原因 |
|---|---|---|
| `routers/runtime.py` | **刪除** | 較舊版本、無人 import,純孤兒檔案 |
| `routers/cdr_db.py` | **刪除** | 與 `core/cdr_db.py` 逐字元相同,複製錯資料夾 |
| `routers/migrate_cdr_backfill.py` | **刪除** | 與根目錄檔案逐字元相同,複製錯資料夾 |
| `server.py` 第 130、131 行 `include_router(calls.router)` | **移除重複的一行** | 既有 bug,與本次功能無關,重複掛載雖不會壞掉但沒必要 |

---

## 六、既有 md 文件比對結果

| 文件 | 狀態 | 說明 |
|---|---|---|
| `permission-feature-summary-20260703.md` | ❌ **過時,已被取代** | 只記錄了初版設計決策,跟本次稽核的實際版本差異很大(見第二節),請改參考 `permission-feature-actual-20260710.md` |
| `sip-profile-acl-feature-20260703.md` | ✅ 準確 | 逐項核對 `routers/sip_profile.py`、`routers/acl.py`、白名單/黑名單參數,內容與現況相符 |
| `FreeSwitch-Project-v3-20260702.md` | ⚠️ 部分過時 | 這份是 2026-07-02 的整體架構總覽,寫於 auth/permission 功能與 sip_profile/acl 功能**之前**,目錄結構、API 清單、導覽頁面清單都還沒反映這兩塊,但其餘既有功能(CDR/IVR/錄音/dialplan 等)的描述本次沒有發現不準確之處 |
| 其餘 30+ 份 feature/bug-fix md(IVR、CDR、錄音、dialplan、backup 等) | ✅ 本次未發現不一致 | 這些模組本次沒有被觸碰,稽核範圍內沒有證據顯示需要修正,**不建議機械式全部重寫**——沒問題的文件重寫反而增加出錯風險,且沒有實質效益 |

**關於「重新製作所有的 md 檔」**:比對後只有 1 份文件(`permission-feature-summary-20260703.md`)確實過時到需要整份取代,另有 1 份(`FreeSwitch-Project-v3`)建議之後找時間補一個「認證/權限系統」+「SIP Profile/ACL」的章節,但不需要整份重寫。如果您還是希望我把其餘 30+ 份逐一重新產出,請告訴我,但目前沒有發現需要這麼做的具體理由。
