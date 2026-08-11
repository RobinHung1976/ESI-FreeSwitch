# 新機還原指南補上 Nginx/HTTPS 缺口（2026-08-11）

## 現象

`PROJECT-OVERVIEW.md` 文件索引標記 `freeswitch-restore-guide.md` 為 🔲（原檔搬進 `ops/`、未重新產出）。回頭核對後發現這份文件產出於 2026-06-25，之後專案的多項架構變更都未回頭同步進去，其中 Nginx reverse proxy + HTTPS（2026-07-15 上線）是會直接導致「照著指南操作、新機還原完成後瀏覽器完全連不到 Dashboard」的功能性缺口，不只是文件過時而已。

## 排查

對照 `backup_manager.py` 原始碼與 `changelog-details/20260715-nginx-https-feature.md`：

1. **`data/` 資料夾（`auth.db`／`cdr.db`／`reg_log.db`）疑慮已排除**：`backup_dashboard_config()` 用 `shutil.copytree(DASHBOARD_DIR, ..., ignore=shutil.ignore_patterns("backups", "__pycache__", "*.pyc"))` 複製整個 `/opt/fs-dashboard/`，沒有排除 `data/`，所以帳號/權限/CDR/登錄記錄都會完整備份還原，不需要額外處理。指南裡的備份包結構圖只是畫得不完整（只列了 5 個檔案），沒有反映實際完整複本的範圍。
2. **Nginx 完全沒有被納入備份或還原流程**：`backup_manager.py` 全檔案搜尋 `nginx` 關鍵字零命中，`restore_dashboard.sh` 內嵌腳本原本只做 venv → 複製程式 → FreeSwitch 設定 → 語音檔 → Lua 腳本 → 安裝 `fs-dashboard.service` → 重啟，完全沒有安裝/設定 Nginx、生成憑證的步驟。而 `fs-dashboard.service` 現在是 `--host 127.0.0.1`（服務檔本身有隨備份還原，這點沒問題），代表新機還原完成後後端只能本機存取，瀏覽器連不到。
3. **STEP 5 驗證指令過時**：原本寫 `curl http://localhost:3000/api/settings` 與瀏覽器開 `http://<新機IP>:3000`，前者在權限系統上線後未帶 token 應為 401（不是失敗，但指南沒說明預期行為），後者在 Nginx 架構下瀏覽器完全連不到。

## 修復

同步修改兩處：

1. **`backup_manager.py`** 內嵌的 `_restore_dashboard_sh()`：
   - 安裝 `fs-dashboard.service` 後偵測其 `--host` 綁定，判斷是否需要設定 Nginx（`NEEDS_NGINX` 旗標，向下相容舊版備份）
   - 新增 Step 6.5：安裝 nginx → 連結 repo 內的 `deploy/nginx/fs-dashboard.conf` → 若無既有憑證則自動產生自簽憑證（`hostname -I` 抓新機 IP 當 CN/SAN）→ `nginx -t` 驗證並啟用
   - 更新驗證清單：改成 `https://<新機IP>/`、WebSocket 101 檢查、`curl 127.0.0.1:3000` 預期 401 說明、`data/auth.db` 已還原則不需重跑 bootstrap 的說明
   - docstring 補充 `data/`、`deploy/nginx/` 已包含在 `dashboard/` 完整複本範圍內的說明，避免文件與程式碼再次脫節
2. **`freeswitch-restore-guide.md`**：
   - 前置條件加註現行 Nginx + HTTPS 架構前提，並說明舊版備份包會自動 fallback 成直連 3000 port
   - STEP 4 腳本說明新增 Nginx 還原步驟
   - STEP 5 依「現行架構」/「2026-07-15 前的舊版架構」分兩種情境給驗證方式
   - 注意事項表新增「瀏覽器連不到 HTTPS」「憑證 CN/SAN 不符」兩列
   - 常見問題排查新增 `journalctl -u nginx`、`nginx -t`、sites-enabled symlink 檢查
   - 備份包內容結構圖改成反映現行分層架構（`core/`/`routers/`/`static/`/`data/`/`deploy/nginx/`），並註明憑證/私鑰不在備份範圍內

## 驗證方式

尚未在實機執行（本次僅為文件與腳本模板修正，未部署）。下次實際新機重建或找測試機演練時，應驗證：

```bash
# 還原後確認 Nginx 分支有正確觸發
grep -q "Step 6.5" /opt/fs-dashboard/../restore_dashboard.sh 2>/dev/null   # 依實際還原包路徑調整
systemctl status nginx
nginx -t
curl -k -s -o /dev/null -w "%{http_code}\n" https://<新機IP>/   # 預期 200
ls -la /etc/nginx/sites-enabled/fs-dashboard.conf                # 應為 symlink
ls -lh /tmp/fs-dashboard-config/dashboard/data/                  # 確認三個 db 都在
```

## 待辦

- `PROJECT-OVERVIEW.md` 文件索引 `freeswitch-restore-guide.md` 狀態由 🔲 改為 ✅
- 建議下次有實機新機重建機會時，實際跑一次 `restore_dashboard.sh` 驗證 Step 6.5 邏輯（本次未在 production server 或測試機上執行，純程式碼/文件層面修正）
