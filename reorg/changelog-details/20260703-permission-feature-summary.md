# 使用者權限系統 — 初版設計決策脈絡（2026-07-03）

> 原始來源：`permission-feature-summary-20260703.md`
> **狀態**：本文件為當時的設計草案脈絡，僅供追溯「當初為什麼這樣設計」。
> **現況以 `feature-permissions-auth.md`（原 `permission-feature-actual-20260710.md`）為準**——2026-07-10 稽核發現 server 實際版本已與本文件描述有實質差異（token 有效期、JWT 金鑰存放位置、`scope="own"` 實際限制方式、前端登入 UI 形式等），詳見該份文件與 `20260710-server-snapshot-audit.md`。

## 保留本文件的原因

當初的決策脈絡（為何選擇手刻 JWT、為何權限矩陣設計成模組 × 動作、為何分 5 個內建群組等）仍有參考價值，即使後續實作版本已經演進，這些設計理由大多延續下來，故保留當歷史紀錄，不隨現況版本一起被覆蓋。

## 摘要

- **不引入 PyJWT/python-jose**：手刻 HS256（stdlib `hmac`/`hashlib`），理由是專案 `requirements.txt` 精簡策略，避免為單一功能新增依賴（比照 `auth_db.py` 密碼雜湊使用 stdlib `pbkdf2_hmac` 而非 `bcrypt`/`passlib` 的同一套邏輯）
- **權限模型**：四個獨立布林旗標（`read`/`create`/`update`/`delete`），`scope`（`all`/`own`）定義在群組層級，`owned_ext` 定義在使用者層級
- **5 個內建群組**：System Admin / System Viewer / Technical Support Admin / Technical Support / User，`is_builtin=True` 禁止刪除/改名，權限內容可由 System Admin 調整
- **權限改變不即時生效**（設計決議）：JWT payload 直接快取整份權限矩陣，`require_permission()` 只讀 token 不查 DB，換取效能，代價是需要重新登入才會反映異動——**此決策延續到後續實際版本，未改變**

## 後續實作與本文件的差異（詳見 `feature-permissions-auth.md`）

| 項目 | 本文件（初版設計） | 後續實際版本 |
|---|---|---|
| Token 有效期 | 12 小時 | 30 分鐘 |
| JWT 金鑰存放 | `settings.json` | SQLite `auth_meta` 表 |
| `scope="own"` 實際限制 | 僅寫入 JWT，未實作 CRUD 端過濾 | `apply_scope()` 真正鎖定/拒絕，WebSocket 推播亦依 `owned_ext` 過濾 |
| 前端登入 UI | JS 動態覆蓋層 | 獨立靜態頁 `login.html`/`change-password.html` |
| 初始帳號建立時機 | 啟動時自動 seed | 手動觸發 `POST /api/auth/bootstrap` |
