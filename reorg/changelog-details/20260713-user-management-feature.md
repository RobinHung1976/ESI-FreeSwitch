# 使用者管理 + 權限群組管理前端頁面上線

日期:2026-07-13
對應腳本:`update3.sh` ~ `update7.sh`（皆已在 production server `debian-freeswitch` 執行成功）
背景:`feature-permissions-auth.md` 第六節記錄的功能缺口——後端 `routers/users.py`/`routers/perm_groups.py` API 齊全，但前端一直沒有對應頁面，只能用 `curl`/`test_permissions.sh` 操作。本次補上前端頁面，並在測試過程中一併修掉數個既有小問題。

## 一、實作內容

新增 `static/js/users-management.js`，側邊欄「系統」分類新增「使用者管理」項目，單頁雙 Tab：

- **使用者 Tab**：列表（帳號/權限群組/專屬分機/狀態/待改密碼），新增、編輯（權限群組/專屬分機/停用）、重設密碼、刪除
- **權限群組 Tab**：列表（名稱/scope/內建標籤），5 個內建群組**完全唯讀**（僅「檢視矩陣」，無編輯/刪除，前端主動限制，後端 `PUT .../permissions` 本身不擋 is_builtin）；自訂群組可編輯 19 個模組的權限矩陣、可刪除

對應 API：`GET/POST /api/users`、`PUT/DELETE /api/users/{id}`、`POST /api/users/{id}/reset-password`、`GET/POST /api/perm-groups`、`PUT /api/perm-groups/{id}/permissions`、`DELETE /api/perm-groups/{id}`。欄位對應已對照 `core/auth_db.py` 逐一核對過，`list_users()`/`list_groups()` 回傳欄位與前端假設一致。

## 二、測試發現的問題與修復

### 1. 導覽列未依權限矩陣隱藏（`update4.sh`）

- **現象**：建立一個「Taichung_IT_Support」自訂群組、取消勾選「使用者管理」讀取權限，該群組的使用者登入後側邊欄仍看得到「使用者管理」
- **原因**：整個系統的側邊欄一直是純靜態顯示，只靠後端 403 擋，從未依權限矩陣隱藏過任何 nav-item（不是這次新功能才有的缺口，只是這次才第一次用到非管理員權限測試）
- **修復**：`common.js` 新增 `getTokenPayload()` 直接解出 JWT payload（不需額外打 `/api/auth/me`）；`init.js` 新增 `applyAuthUI()`，登入後依 `payload.permissions` 隱藏無讀取權限的 nav-item（`data-page` 對應 `core/permissions.py` 的 Module 常數，Dialplan 三個子頁共用 `dialplan` 模組）
- **驗證**：`Taichung_IT_Support` 群組帳號登入後「使用者管理」nav-item 消失，其餘沒勾權限的模組同樣消失

### 2. 使用者列表帳號欄文字看不到（`update4.sh`）

- **現象**：使用者 Tab 的帳號欄要反白才看得到文字
- **原因**：白字（`color:#fff`）誤用在亮色主題（`--bg:#eef4fb`，白底深藍字）上
- **修復**：改用 `var(--text)`
- **驗證**：帳號欄文字正常可讀，不需反白

### 3. 群組名稱長字被裁切（`update4.sh`）

- **現象**：自訂群組「Taichung_IT_Support」的 `g` 只顯示一半
- **原因**：`style.css` 的 `.panel { overflow:hidden }` 搭配 `.panel-title` 用 `Syne` 展示字體，預設行高沒留夠空間給下伸筆畫（g/y/p/q）
- **修復**：群組卡片與編輯面板標題的 `.panel-title` 加 `line-height:1.6;display:inline-block`
- **驗證**：長名稱含下伸筆畫的字母完整顯示

### 4. 沒有登出功能（`update4.sh` → `update5.sh` → `update6.sh`，共三次調整）

- **現象**：`common.js` 早有 `logout()` 函式，但畫面上從來沒有按鈕呼叫它
- **第一次修復（`update4.sh`）**：登出按鈕加在側邊欄最下方 → 使用者回報「要捲動頁面才看得到」
- **第二次修復（`update5.sh`）**：改成 `position:fixed` 浮動在畫面右上角 → 使用者回報「會擋住各頁面自己右上角的按鈕（例如分機管理的『+ 新增分機』）」
- **第三次修復（`update6.sh`）**：發現 `style.css` 其實原本就定義了 `.topbar`/`.page-title`/`.topbar-right`（高 54px 的獨立版面插槽），只是 07-01 模組化重整後沒接上、`init.js` 的 `switchPage()` 找的 `#pageTitle` 因此一直靜默失效。改用這組既有插槽：`.main` 內、`.content` 之前插入 `.topbar`，左側放頁面標題、右側放登入身分 + 登出按鈕。版面結構上獨立一列，不會疊在任何頁面內容上，附帶修好了頁面標題一直不顯示的問題
- **驗證**：登出按鈕固定在頂部橫列右側，不擋任何頁面按鈕，捲動任何頁面時橫列不會被捲走，點擊可正常登出

### 5. ESL 無權限時的狀態文字容易誤導（`update5.sh`）

- **現象**：`Taichung_IT_Support` 群組沒有 `esl` 讀取權限時，系統狀態顯示「無法取得」，容易誤以為是斷線
- **原因**：`loadSysStatus()` 對 403（`{"detail": "..."}` 格式，無 `.result`）沒有特別處理，跟真正的請求失敗混在一起
- **修復**：偵測到 `res.detail` 但沒有 `res.result` 時，顯示「系統狀態：無存取權限」
- **驗證**：無 ESL 權限的帳號登入後看到「無存取權限」，與真正斷線的文字區分開來

### 6. 登入身分文字一直是空白（`update7.sh`）

- **現象**：`.topbar` 右側的「登入身分：xxx（群組名）」一直是空的
- **原因**：`applyAuthUI()` 寫的時候還沒拿到 `core/auth.py`，用猜的欄位名稱 `payload.username`；實際上 `routers/auth.py` 的 `create_access_token()` 存的 claim 是 `"sub"`（JWT 標準慣例），不是 `username`，`group_name` 猜對了但 `sub` 猜錯，導致整行文字永遠是空字串
- **修復**：`payload.username` → `payload.sub`
- **驗證**：`.topbar` 正確顯示「登入身分：admin（System Admin）」等對應文字

## 三、已知限制

- **`owned_ext` 無法透過編輯使用者清空**：`auth_db.update_user()` 的參數語意是「`None` = 不變更」，不是「清空」；前端表單留空送出不會真的清掉舊值，UI 已加提示文字說明，但無法在前端繞過這個後端限制。如需支援清空，後端需要另外設計「明確清空」的參數語意或獨立端點
- **導覽列權限隱藏目前只驗證過新增的「使用者管理」項目**：`applyAuthUI()` 的邏輯是全站性的（掃描所有 `.nav-item[data-page]`），理論上其餘 18 個既有頁面也會一併套用，但這次測試沒有逐一驗證每個模組名稱對應是否正確，建議之後找時間用不同權限組合的帳號完整測一輪

## 四、對應腳本執行紀錄

| 腳本 | 內容 | Commit |
|---|---|---|
| `update3.sh` | 新增使用者管理 + 權限群組管理前端頁面 | `feat: 新增使用者管理 + 權限群組管理前端頁面...` |
| `update4.sh` | 修正權限隱藏導覽列/帳號白字/標題裁切/補登出按鈕（側邊欄底部版） | `fix: 使用者管理頁面 4 項測試回饋...` |
| `update5.sh` | 登出按鈕移到右上角浮動卡片 + ESL 無權限文字優化 | `fix: 登出按鈕移到右上角浮動卡片...` |
| `update6.sh` | 登出/使用者資訊改用既有 `.topbar` 插槽，避免擋住頁面按鈕 | `fix: 登出/使用者資訊改用既有 .topbar 插槽...` |
| `update7.sh` | 修正 JWT payload 欄位名稱錯誤（`username`→`sub`） | `fix: 登入身分文字改讀 JWT 的 sub claim...` |

所有腳本皆包含前置驗證（比對前一支腳本的特徵字串、冪等檢查避免重複套用）與精確字串比對／完整覆寫，執行紀錄與驗證清單皆已由使用者在 production server 上逐一確認通過。
