## 除錯

### ✅ 版控匯入後發現孤兒/誤複製檔案，以及 `calls.router` 重複掛載（2026-07-10）

**背景**：`/opt/fs-dashboard` 首次導入 git 版控（ESI-FreeSwitch repo）時，將現有程式碼原封不動 commit 作為基準點。比對 `fs-dashboard-snapshot.zip` 快照與程式碼實際 import 關係後，發現 3 個孤兒/誤複製檔案，以及 `server.py` 一處既有的重複掛載，詳見 `server-snapshot-audit-20260710.md`。

**現象**：

- `routers/` 目錄下存在 `runtime.py`、`cdr_db.py`、`migrate_cdr_backfill.py` 三支檔案，但專案中**沒有任何地方 import 這三支**
- `server.py` 的 `app.include_router(calls.router)` 出現兩次

**根本原因**：

1. **`routers/runtime.py`**：是 WebSocket JWT token 驗證修復（見 `Bug-Fix-Notes-20260710.md` 的 `ServerConnection` 修復記錄）過程中產生的**舊版半成品**，修復完成後正確版本進了 `core/runtime.py`（`server.py` 實際 `from core.runtime import (...)`），但 `routers/runtime.py` 這份舊版忘了刪除，變成孤兒檔案。
2. **`routers/cdr_db.py`**、**`routers/migrate_cdr_backfill.py`**：分別與 `core/cdr_db.py`、根目錄 `migrate_cdr_backfill.py` 逐字元相同（`md5sum` 比對確認），是複製到錯資料夾的誤操作殘留。
3. **`calls.router` 重複掛載**：`server.py` 掛載路由清單維護時手動複製貼上造成的既有 bug，`include_router` 對同一個 router 呼叫兩次雖不會讓服務崩潰，但屬冗餘程式碼。

**排查方式**：

```bash
# 確認 server.py 實際 import 來源
grep -n "^from routers\|^from core\|include_router" server.py

# 用內容雜湊找出所有跨資料夾同名/同內容檔案
find . -type f \( -name "*.py" -o -name "*.js" -o -name "*.html" \) -exec md5sum {} \; \
  | sort | awk '{print $1}' | uniq -c | sort -rn | awk '$1>1'

# 確認可疑檔案是否真的與正確版本逐字元相同
diff routers/cdr_db.py core/cdr_db.py
diff routers/migrate_cdr_backfill.py migrate_cdr_backfill.py
diff routers/runtime.py core/runtime.py   # 此組有差異，確認是舊版孤兒檔而非誤判

# 確認重複掛載
grep -c "include_router(calls.router)" server.py
```

**修復**（`update2.sh`，含前置驗證：核對孤兒檔案內容雜湊與稽核報告記錄一致才動手，對不上就中止不寫入任何檔案）：

```bash
git rm routers/runtime.py
git rm routers/cdr_db.py
git rm routers/migrate_cdr_backfill.py
```

```python
# server.py 精確字串取代（python heredoc，比對次數需剛好 1 次才執行）
old = "app.include_router(calls.router)\napp.include_router(calls.router)\n"
new = "app.include_router(calls.router)\n"
```

**驗證方式**：

```bash
git status --porcelain                 # 乾淨
ls routers/runtime.py routers/cdr_db.py routers/migrate_cdr_backfill.py  # 三個皆 No such file
grep -c "include_router(calls.router)" server.py                        # 回傳 1
python3 -m py_compile server.py        # 語法正確
grep -rn "routers.runtime\|routers\.cdr_db\|routers\.migrate_cdr_backfill" --include="*.py" .  # 無殘留 import
```

部署後 `journalctl -u fs-dashboard -n 50 --no-pager` 確認：

- `Application startup complete`，ESL / WebSocket 皆正常連線
- 實測登入：`POST /api/auth/login HTTP/1.1" 200 OK`，後續 `/api/registrations`、`/api/calls`、`/api/ext/status` 等請求皆 200
- `settings.json`（ESL 密碼、CORS 白名單等）與 `data/auth.db`（45056 bytes）皆維持部署前版本，未被覆蓋或清空
- 瀏覽器實測登入頁（`login.html`）顯示與登入流程皆正常

**提醒**：

- 這三支孤兒檔案本來就沒有被 import，刪除前務必先確認「無任何地方引用」再動手，不能只憑檔名判斷，要交叉比對 `diff`/`md5sum` 結果，避免誤刪還在用的版本
- `include_router` 重複呼叫同一個 router 不會讓 FastAPI 啟動失敗，這類冗餘程式碼容易被 `systemctl status` 正常掩蓋，建議之後新增 router 掛載時養成核對清單的習慣

---

**測試結果**：已通過完整測試驗證，`update2.sh` 於 production 環境實際執行並 `git push` + `deploy.sh` 部署成功，服務狀態、登入功能、既有資料（`settings.json`/`auth.db`）皆確認正常無異常。
