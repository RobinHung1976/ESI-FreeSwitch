# 🆕 新機 FreeSwitch 完整還原指南

> 適用情境：整台 Server 損毀或更換新機，從備份包完整重建 FreeSwitch + Dashboard。

---

## 📋 前置條件

你需要準備 **2 個備份檔**（從舊機 Dashboard 下載）：

| 檔案 | 用途 |
|------|------|
| `freeswitch-packages-YYYY-MM-DD_HH-MM-SS.tar.gz` | FreeSwitch 程式本體（.deb 套件） |
| `fs-dashboard-config-YYYY-MM-DD_HH-MM-SS.tar.gz` | 設定檔 + Dashboard 程式（含 `data/` 底下的使用者/權限、CDR、登錄記錄等 SQLite 資料庫，見本文件末尾「備份包內容說明」） |

> ⚠️ **架構前提（2026-07-15 起）**：現行架構是瀏覽器 → **Nginx（443, HTTPS）** → 反向代理到本機 `127.0.0.1:3000`（REST/SSE）與 `127.0.0.1:8080`（WebSocket），後端服務**不再直接對外開放** 3000/8080 port。本指南 STEP 4 已包含還原 Nginx 的步驟；若你的備份包是 2026-07-15 之前產生的舊版（服務仍 bind `0.0.0.0`），還原腳本會自動偵測並略過 Nginx 設定，此時沿用舊版 `http://<新機IP>:3000` 的存取方式即可。詳見 `changelog-details/20260715-nginx-https-feature.md`。

---

## STEP 0 — 準備新機（Debian 系統）

新機需要是 **Debian 11 或 12**，確認可以 SSH 進去後執行：

```bash
# 確認系統版本
cat /etc/os-release

# 更新套件清單
apt-get update
```

---

## STEP 1 — 上傳備份檔到新機

在你的**本機電腦**（Windows / Mac）打開終端機，執行：

```bash
# 把兩個備份檔上傳到新機的 /tmp 目錄（IP 換成你的新機 IP）
scp freeswitch-packages-*.tar.gz root@<新機IP>:/tmp/
scp fs-dashboard-config-*.tar.gz root@<新機IP>:/tmp/
```

> 💡 **Windows 用戶**可用 [WinSCP](https://winscp.net/) 拖放上傳，或在 PowerShell 執行上面指令。

---

## STEP 2 — SSH 進入新機

```bash
ssh root@<新機IP>
```

---

## STEP 3 — 還原 FreeSwitch 程式本體

```bash
# 進入 /tmp 目錄
cd /tmp

# 解壓套件備份（檔名換成你的實際檔名）
tar xzf freeswitch-packages-2026-06-25_14-30-00.tar.gz

# 進入解壓目錄
cd freeswitch-packages

# 執行還原腳本（會自動安裝所有 .deb 套件）
bash restore_freeswitch.sh
```

### 腳本自動執行內容

1. 安裝系統依賴（`libssl3`、`libcurl4` 等）
2. 從備份的 `debs/*.deb` 離線安裝 FreeSwitch（版本與原機完全相同）
3. 執行 `systemctl enable && start freeswitch`

### 驗證 FreeSwitch 是否正常

```bash
# 確認服務狀態（應看到 active (running)）
systemctl status freeswitch

# 測試 CLI 連線
fs_cli -H 127.0.0.1 -P 8021 -p ClueCon -x "status"
```

> ✅ 看到 `UP X days...` 代表成功，繼續下一步。

---

## STEP 4 — 還原 Dashboard 設定與設定檔

```bash
# 回到 /tmp
cd /tmp

# 解壓設定備份（檔名換成你的實際檔名）
tar xzf fs-dashboard-config-2026-06-25_14-30-00.tar.gz

# 進入解壓目錄
cd fs-dashboard-config

# 執行還原腳本
bash restore_dashboard.sh
```

### 腳本自動執行內容

1. 建立 Python 虛擬環境 `/opt/myapp/venv/`
2. 安裝所有 Python 套件（`pip-requirements.txt`）
3. 複製 Dashboard 程式到 `/opt/fs-dashboard/`（含 `data/` 底下的 `auth.db`／`cdr.db`／`reg_log.db`，使用者帳號、權限、CDR、登錄記錄會一併還原，**不需要**額外重建）
4. 還原 `/etc/freeswitch/`（分機、撥號計畫、SIP 設定）
   - 原有設定自動備份為 `/etc/freeswitch.pre-restore.TIMESTAMP`
5. 還原自訂語音檔 `/var/lib/freeswitch/sounds/custom/`
6. 還原 Lua IVR 腳本 `/usr/share/freeswitch/scripts/`
7. 安裝 `fs-dashboard.service` 並設定開機自動啟動
8. **偵測到服務設定為 `--host 127.0.0.1`（2026-07-15 起的 Nginx 架構）時，自動設定 Nginx**：
   - 安裝 `nginx`（若尚未安裝）
   - 連結 repo 內的 `deploy/nginx/fs-dashboard.conf` 到 `/etc/nginx/sites-available/`、`sites-enabled/`
   - 產生自簽憑證（`CN`/`SAN` = 還原腳本自動偵測到的新機 IP；若偵測結果與實際對外 IP 不同，或未來要換成受信任憑證，需依 `changelog-details/20260715-nginx-https-feature.md` 手動重新產生）
   - `nginx -t` 驗證設定並啟用服務
   - 若備份包是 2026-07-15 之前產生的舊版（服務仍 bind `0.0.0.0`），此步驟會自動略過
9. 執行 `systemctl restart freeswitch fs-dashboard`

---

## STEP 5 — 驗證還原結果

```bash
# 確認服務都在執行（有設定 Nginx 的話一併確認）
systemctl status freeswitch fs-dashboard nginx
```

**現行架構（2026-07-15 起，走 Nginx + HTTPS）：**

```bash
# 本機驗證後端存活（僅 loopback，瀏覽器連不到屬正常）
# 權限系統上線後 API 大多需要 JWT，未帶 token 預期 401；能收到 401 而非連線失敗，代表服務有在跑
curl -k -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:3000/api/settings

# nginx 對外是否正常（-k 略過自簽憑證驗證）
curl -k -s -o /dev/null -w "%{http_code}\n" https://<新機IP>/
```

**開啟瀏覽器確認：**

```
https://<新機IP>/
```

自簽憑證會跳出「不安全連線」警告，屬預期行為，選擇繼續即可。登入後用瀏覽器 F12 → Network 確認 WebSocket 走 `wss://<新機IP>/ws/?token=...`、狀態為 `101 Switching Protocols`；左下角「連線至 FreeSwitch」燈號應為綠燈。

若 `data/auth.db` 已隨備份還原，直接用舊機原本的帳號密碼登入即可，**不需要**再呼叫 `/api/auth/bootstrap`；只有在確認 `data/` 遺失、或刻意要重建成全新資料庫時，才需要：

```bash
curl -X POST https://<新機IP>/api/auth/bootstrap -k
```

**舊版架構（備份包產生於 2026-07-15 之前，服務直接對外開放 3000 port）：**

```bash
curl http://localhost:3000/api/settings
curl http://localhost:3000/api/extensions/list
```

瀏覽器開 `http://<新機IP>:3000`。

> ✅ 能看到 Dashboard 且分機資料正確 = 還原成功 🎉

---

## ⚠️ 注意事項

| 情況 | 處理方式 |
|------|---------|
| 新機 IP 與舊機不同 | 進 Dashboard → 設定 → 更新 ESL 連線設定的 IP |
| FreeSwitch 對外 IP 不同 | 修改 `/etc/freeswitch/vars.xml` 裡的 `external_rtp_ip` / `external_sip_ip`，再執行 `fs_cli -x "reloadxml"` |
| 舊設定保留位置 | `/etc/freeswitch.pre-restore.TIMESTAMP` |
| 套件安裝失敗 | 確認 Debian 版本與原機相同（Debian 11 或 12） |
| ESL 連線設定不覆蓋 | `esl_host` / `esl_port` / `esl_password` 保留目前新機設定，不從備份覆蓋 |
| 瀏覽器連不到 `https://<新機IP>/` | 先確認 `systemctl status nginx`、`nginx -t`；憑證/私鑰（`/etc/nginx/ssl/`）不在版控範圍內，不會隨備份還原，還原腳本會自動重新產生，若新機 IP 之後又變動需重新產生並更新 `deploy/nginx/fs-dashboard.conf` |
| 憑證 CN/SAN 與實際 IP 不符，瀏覽器警告異常嚴重 | 重新產生自簽憑證，`-subj "/CN=<實際IP>"` `-addext "subjectAltName=IP:<實際IP>"`，改完 `nginx -t && systemctl reload nginx` |

---

## 🆘 常見問題排查

```bash
# Dashboard 沒啟動？查看 log
journalctl -u fs-dashboard -n 50

# FreeSwitch 沒啟動？查看 log
journalctl -u freeswitch -n 50

# Nginx 沒啟動，或瀏覽器連不到？
journalctl -u nginx -n 50
nginx -t
ls -la /etc/nginx/sites-enabled/fs-dashboard.conf   # 應為指向 repo 的 symlink

# 手動重啟服務
systemctl restart freeswitch
systemctl restart fs-dashboard
systemctl restart nginx

# 確認備份解壓內容是否完整
ls -lh /tmp/freeswitch-packages/debs/
ls -lh /tmp/fs-dashboard-config/
ls -lh /tmp/fs-dashboard-config/dashboard/data/   # 確認 auth.db/cdr.db/reg_log.db 都在
```

---

## 📦 備份包內容說明（供參考）

### fs-dashboard-config-\*.tar.gz

```
fs-dashboard-config/
├── manifest.json              # 備份資訊（時間、主機名稱）
├── restore_dashboard.sh       # 本還原腳本（Step 4）
├── pip-requirements.txt       # Python 套件清單
├── dashboard/                 # /opt/fs-dashboard/ 完整複本（僅排除 backups/、__pycache__、*.pyc）
│   ├── server.py
│   ├── core/                  # 後端共用模組
│   ├── routers/                # 後端 API router
│   ├── static/                 # 前端骨架、樣式、JS 模組
│   ├── data/                   # ⚠️ SQLite 資料庫，還原後帳號/CDR/登錄記錄即自動復原
│   │   ├── auth.db             #    使用者/權限
│   │   ├── cdr.db               #    CDR
│   │   └── reg_log.db           #    登錄記錄（2026-07-15 起持久化）
│   ├── deploy/nginx/
│   │   └── fs-dashboard.conf   # Nginx 設定（2026-07-15 起，還原腳本會連結到 /etc/nginx/）
│   └── settings.json
├── freeswitch-config/         # /etc/freeswitch/ 完整複本
│   ├── vars.xml
│   ├── directory/default/*.xml
│   ├── dialplan/**/*.xml
│   └── sip_profiles/external/*.xml
├── sounds-custom/             # 自訂語音檔
├── scripts/                   # Lua IVR 腳本
│   └── ivr_runner.lua
└── systemd/
    └── fs-dashboard.service   # 備份當下的即時內容，含 --host 綁定設定
```

> ℹ️ Nginx 的 TLS 憑證與私鑰（`/etc/nginx/ssl/`）**不在**備份包內（不進 git，機敏檔案），還原腳本會在新機上自動重新產生自簽憑證。

### freeswitch-packages-\*.tar.gz

```
freeswitch-packages/
├── manifest.json              # 套件清單、版本資訊
├── restore_freeswitch.sh      # 本還原腳本（Step 3）
├── packages.txt               # dpkg --get-selections 輸出
├── freeswitch-version.txt     # 原機版本資訊
└── debs/
    └── *.deb                  # 所有 freeswitch-* 套件原始 .deb 檔
```

---

*文件產生日期：2026-06-25｜2026-08-11 更新：補上 Nginx reverse proxy + HTTPS 還原步驟（見 `changelog-details/20260715-nginx-https-feature.md`），修正過時的驗證網址/指令，澄清 `data/` 資料庫已含在備份包內*
