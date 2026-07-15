# 🆕 新機 FreeSwitch 完整還原指南

> 適用情境：整台 Server 損毀或更換新機，從備份包完整重建 FreeSwitch + Dashboard。

---

## 📋 前置條件

你需要準備 **2 個備份檔**（從舊機 Dashboard 下載）：

| 檔案 | 用途 |
|------|------|
| `freeswitch-packages-YYYY-MM-DD_HH-MM-SS.tar.gz` | FreeSwitch 程式本體（.deb 套件） |
| `fs-dashboard-config-YYYY-MM-DD_HH-MM-SS.tar.gz` | 設定檔 + Dashboard 程式 |

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
3. 複製 Dashboard 程式到 `/opt/fs-dashboard/`
4. 還原 `/etc/freeswitch/`（分機、撥號計畫、SIP 設定）
   - 原有設定自動備份為 `/etc/freeswitch.pre-restore.TIMESTAMP`
5. 還原自訂語音檔 `/var/lib/freeswitch/sounds/custom/`
6. 還原 Lua IVR 腳本 `/usr/share/freeswitch/scripts/`
7. 安裝 `fs-dashboard.service` 並設定開機自動啟動
8. 執行 `systemctl restart freeswitch fs-dashboard`

---

## STEP 5 — 驗證還原結果

```bash
# 確認兩個服務都在執行
systemctl status freeswitch fs-dashboard

# 測試 Dashboard API
curl http://localhost:3000/api/settings

# 測試分機清單是否有還原
curl http://localhost:3000/api/extensions/list
```

**開啟瀏覽器確認：**

```
http://<新機IP>:3000
```

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

---

## 🆘 常見問題排查

```bash
# Dashboard 沒啟動？查看 log
journalctl -u fs-dashboard -n 50

# FreeSwitch 沒啟動？查看 log
journalctl -u freeswitch -n 50

# 手動重啟兩個服務
systemctl restart freeswitch
systemctl restart fs-dashboard

# 確認備份解壓內容是否完整
ls -lh /tmp/freeswitch-packages/debs/
ls -lh /tmp/fs-dashboard-config/
```

---

## 📦 備份包內容說明（供參考）

### fs-dashboard-config-\*.tar.gz

```
fs-dashboard-config/
├── manifest.json              # 備份資訊（時間、主機名稱）
├── restore_dashboard.sh       # 本還原腳本（Step 4）
├── pip-requirements.txt       # Python 套件清單
├── dashboard/                 # /opt/fs-dashboard/ 完整複本
│   ├── server.py
│   ├── esl_client.py
│   ├── index.html
│   ├── backup_manager.py
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
    └── fs-dashboard.service
```

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

*文件產生日期：2026-06-25*
