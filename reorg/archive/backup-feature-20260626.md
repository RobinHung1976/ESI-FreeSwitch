# 備份管理功能 — 開發文件

> 更新日期：2026-06-25
> 適用版本：FreeSwitch Dashboard V2（Debian 13）

---

## 1. 功能概述

新增獨立的「備份管理」頁面，提供兩種備份類型：

| 備份類型 | 說明 | 預估大小 |
|----------|------|----------|
| **Dashboard 設定備份** | FreeSwitch 設定檔 + Dashboard 程式 + 還原腳本 | 數 MB |
| **FreeSwitch 套件備份** | 已安裝的所有 `freeswitch-*` `.deb` 套件（版本完全一致） | 150–250 MB |

---

## 2. 新增檔案

| 檔案 | 部署路徑 | 說明 |
|------|----------|------|
| `backup_manager.py` | `/opt/fs-dashboard/backup_manager.py` | 備份/還原核心邏輯模組 |
| `server_backup_api.py` | 整合進 `server.py` | 備份相關 API endpoints |
| `index.html` | `/opt/fs-dashboard/index.html` | 前端備份管理頁面 |

---

## 3. 部署步驟

```bash
# 1. 複製新模組
cp backup_manager.py /opt/fs-dashboard/

# 2. 整合 server.py
#    a. 頂部 import 區新增：
from backup_manager import (
    backup_dashboard_config, backup_freeswitch_packages,
    restore_dashboard_config, list_backups, delete_backup,
    cleanup_old_backups, get_backup_dir,
)

#    b. 結尾貼上 server_backup_api.py 所有 @app.xxx routes

#    c. _log_rotate_scheduler() Step 4 之後加入：
#       # 5. 備份自動清理（超過保留天數）
#       deleted_backups = cleanup_old_backups()
#       if deleted_backups:
#           print(f"[backup-cleanup] 已刪除 {len(deleted_backups)} 個舊備份")

# 3. 更新前端
cp index.html /opt/fs-dashboard/

# 4. 重啟服務
systemctl restart fs-dashboard
```

---

## 4. 後端 API

### 備份操作

```
POST   /api/backup/run              觸發備份
GET    /api/backup/list             列出所有備份
GET    /api/backup/download         下載指定備份檔
DELETE /api/backup/{filename}       刪除指定備份檔
POST   /api/backup/restore          上傳還原（情境A：Server 運行中）
```

### POST /api/backup/run

```json
// Request body
{ "type": "config" }       // Dashboard 設定備份
{ "type": "packages" }     // FreeSwitch 套件備份（含 .deb，耗時 1–5 分鐘）
{ "type": "both" }         // 兩者同時備份

// Response
{
  "ok": true,
  "results": {
    "config": {
      "ok": true,
      "filename": "fs-dashboard-config-2026-06-25_14-30-00.tar.gz",
      "size": 2048000,
      "errors": []
    }
  }
}
```

### GET /api/backup/list

```json
{
  "backups": [
    {
      "filename": "fs-dashboard-config-2026-06-25_14-30-00.tar.gz",
      "type": "config",
      "path": "/opt/fs-dashboard/backups/...",
      "size": 2048000,
      "size_mb": 1.95,
      "mtime": "2026-06-25 14:30:00"
    }
  ],
  "total": 2
}
```

---

## 5. 備份包內容

### 📦 fs-dashboard-config-YYYY-MM-DD_HH-MM-SS.tar.gz

```
fs-dashboard-config/
├── manifest.json              # 備份資訊（類型、時間、主機名稱）
├── restore_dashboard.sh       # 新機還原腳本（Step 2）
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
│   ├── sip_profiles/external/*.xml
│   └── ivr-menus/*.json
├── sounds-custom/             # /var/lib/freeswitch/sounds/custom/
├── scripts/                   # /usr/share/freeswitch/scripts/
│   └── ivr_runner.lua
└── systemd/
    └── fs-dashboard.service
```

### 📦 freeswitch-packages-YYYY-MM-DD_HH-MM-SS.tar.gz

```
freeswitch-packages/
├── manifest.json              # 套件清單、版本資訊、deb 數量
├── restore_freeswitch.sh      # 新機還原腳本（Step 1）
├── packages.txt               # dpkg --get-selections 完整輸出
├── freeswitch-version.txt     # 原機 freeswitch -version 輸出
└── debs/
    └── *.deb                  # 所有 freeswitch-* 套件原始 .deb 檔
```

---

## 6. 設定項目

### settings.json 新增欄位

```json
{
  "backup_path":         "/opt/fs-dashboard/backups",
  "backup_retain_days":  30,
  "backup_auto_enabled": false
}
```

| 欄位 | 預設值 | 說明 |
|------|--------|------|
| `backup_path` | `/opt/fs-dashboard/backups` | 備份存放路徑（支援 NAS 掛載點） |
| `backup_retain_days` | `30` | 超過天數的備份自動刪除 |
| `backup_auto_enabled` | `false` | 每日 00:01 自動執行 Dashboard 設定備份 |

> ⚠ NAS 路徑需先在 OS 層執行 `mount`，再填入掛載點路徑。

---

## 7. 前端 UI 架構

備份管理從「系統設定」獨立出來，成為側邊欄獨立項目。

### 側邊欄新增

```
系統
  ☎ 號碼目錄
  ›_ ESL 終端機
  ⊡ 系統日誌
  ⚙ 設定
  🗄 備份管理    ← 新增
```

### 雙欄佈局（與設定頁相同）

```
左欄（220px）          右欄（剩餘）
────────────────       ────────────────────────────────────
⚙ 備份設定       →    備份路徑 / 保留天數 / 自動備份開關
                       立即備份：設定 / 套件 / 兩者
                       上傳還原（Server 運行中）

🗄 備份清單       →    ⚙ Dashboard 設定備份（獨立表格）
                       📦 FreeSwitch 套件備份（獨立表格）
                       每個分類各有「+ 立即備份」快捷按鈕
```

### JS 函式

| 函式 | 說明 |
|------|------|
| `renderBackupPage(node)` | 渲染備份管理頁（雙欄佈局） |
| `backupPageContent(node, cfg)` | 依節點回傳右欄 HTML |
| `backupSaveSettings()` | 儲存備份設定到 localStorage + 後端 |
| `backupRun(type)` | 觸發備份（config / packages / both） |
| `backupDownload(filename)` | 下載備份檔 |
| `backupDelete(filename, btn)` | 刪除備份（含確認對話框） |
| `backupRestoreUpload(input)` | 上傳備份檔執行還原 |
| `_backupToast(msg, type)` | 右下角 toast 通知（備份清單頁專用） |

---

## 8. 還原流程

### 情境 A：Server 仍在運行（設定搞亂）

1. 開啟備份管理 → 備份設定
2. 點擊「選擇備份檔上傳還原」
3. 上傳 `fs-dashboard-config-*.tar.gz`
4. 後端自動解壓、備份現有設定、覆蓋還原、執行 `reloadxml`

> ⚠ ESL 連線設定（`esl_host` / `esl_port` / `esl_password`）不會從備份覆蓋，保留目前值避免斷線。

### 情境 B：整台 Server 損毀（新機重建）

```bash
# Step 1：還原 FreeSwitch（在新機 Debian 執行）
tar xzf freeswitch-packages-2026-06-25_14-30-00.tar.gz
bash freeswitch-packages/restore_freeswitch.sh

# 確認 FreeSwitch 正常後繼續
fs_cli -H 127.0.0.1 -P 8055 -p FSPyAdmin -x "status"

# Step 2：還原 Dashboard 設定
tar xzf fs-dashboard-config-2026-06-25_14-30-00.tar.gz
bash fs-dashboard-config/restore_dashboard.sh

# Step 3：驗證
systemctl status freeswitch fs-dashboard
curl http://localhost:3000/api/settings
curl http://localhost:3000/api/extensions/list
```

### restore_freeswitch.sh 執行內容

1. 安裝前置依賴（`libssl3`、`libcurl4` 等）
2. 從 `debs/*.deb` 安裝所有 FreeSwitch 套件（版本與原機完全一致）
3. `systemctl enable && start freeswitch`
4. 提示執行 Step 2

### restore_dashboard.sh 執行內容

1. 建立 Python 虛擬環境 `/opt/myapp/venv/`
2. 安裝 pip 套件（`pip-requirements.txt`）
3. 複製 Dashboard 程式到 `/opt/fs-dashboard/`
4. 還原 `/etc/freeswitch/`（原設定自動備份為 `/etc/freeswitch.pre-restore.TIMESTAMP`）
5. 還原自訂語音 `/var/lib/freeswitch/sounds/custom/`
6. 還原 Lua 腳本 `/usr/share/freeswitch/scripts/`
7. 安裝 systemd service
8. `systemctl restart freeswitch fs-dashboard`

---

## 9. 自動排程

整合進現有 `_log_rotate_scheduler()`，每日 `00:00:30` 執行：

```
Step 1  日誌歸檔（freeswitch.log → freeswitch-YYYY-MM-DD.log）
Step 2  日誌清理（超過 log_retain_days）
Step 3  CDR 歸檔（Master.csv → cdr-YYYY-MM-DD.csv）
Step 4  CDR 清理（超過 cdr_retain_days）
Step 5  備份清理（超過 backup_retain_days）← 新增
```
每日自動備份（`backup_auto_enabled: true`）在 `00:01:00` 執行 config 備份。

###每日自動備份時間 — 功能修改總結
FreeSwitch Dashboard V2 — 備份功能修改（每日自動備份時間可手動設定）
修改內容
```
index.html — 3 處

SETTINGS_DEFAULTS 新增預設值：

backup_auto_time: '00:01',

備份設定 UI（backup_settings 區塊）

在 toggle 開關後新增 type="time" 輸入欄：

<input class="settings-input" data-setting="backup_auto_time" type="time"
  value="${cfg.backup_auto_time || '00:01'}"
  style="width:140px;margin-left:8px" />

寬度從原本 max-width:100px 改為 width:180px，修正 12 小時制下顯示截斷的 bug。
  
backupSaveSettings() 加入同步至後端：

backup_auto_time: cfg.backup_auto_time || '00:01',

server.py — _log_rotate_scheduler() 重構
改為雙事件架構，每次迴圈動態讀取 settings.json：
觸發時間執行內容00:00:30（固定）Log/CDR rotate + 清理 + 備份清理backup_auto_time（使用者設定）自動備份 Dashboard 設定（backup_auto_enabled: true 時）

容許 ±90 秒誤差觸發，避免兩事件時間重疊時衝突
時間變更後下一個週期即生效，不需重啟服務

settings.json 新增欄位

"backup_auto_time": "00:01"
```
狀態
✅ 功能測試通過

---

## 10. 檔案安全性

- 備份檔名格式驗證（regex）：`^(fs-dashboard-config|freeswitch-packages)-\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}\.tar\.gz$`
- 還原解壓前檢查路徑安全（防止 path traversal：不允許 `/` 開頭或含 `..`）
- 還原前自動備份現有設定（`/etc/freeswitch.restore-bak.TIMESTAMP`）
- 下載 API 限制檔名格式，不接受任意路徑

---

## 11. 已知限制

| 項目 | 說明 |
|------|------|
| NAS 遠端路徑 | 僅支援已掛載的本機路徑，不支援直接填 SFTP / S3 / SMB UNC 路徑 |
| 自動備份範圍 | 每日自動備份僅執行 config 備份；套件備份（較大）需手動觸發 |
| 套件備份容量 | FreeSwitch .deb 約 150–250 MB，請確認備份路徑有足夠空間 |

---

## 12. 套件備份 .deb 收集策略（`_collect_debs`）

`backup_freeswitch_packages()` 採三層 fallback 策略收集 `.deb`，避免因 apt repo 失效導致備份空殼：

| 層級 | 方法 | 說明 |
|------|------|------|
| **Layer 1** | 從 `/var/cache/apt/archives/` 直接複製 | 最快，無需網路；apt 安裝後通常有完整快取 |
| **Layer 2** | `apt-get download` | 補 cache 沒有的套件；需要 apt repo 可用 |
| **Layer 3** | `dpkg-repack` 重打包已安裝二進位 | 最後手段；不依賴網路，100% 版本一致 |

> ⚠ 若機器安裝 FreeSwitch 後曾執行 `apt-get clean` 清除 cache，且 apt repo 也無法連線，Layer 3 會自動安裝 `dpkg-repack` 並重打包。備份時間會較長（每個套件約 5–10 秒）。

### manifest.json 欄位說明

```json
{
  "type":           "freeswitch-packages",
  "created_at":     "2026-06-25T15:09:13.399424",
  "hostname":       "debian-freeswitch",
  "fs_version":     "FreeSWITCH version: 1.11.1-dev-...",
  "packages_count": 254,
  "debs_count":     121,
  "packages":       ["freeswitch", "freeswitch-mod-lua", "..."],
  "errors":         []
}
```

> `debs_count` 應與 `packages_count` 接近（部分 meta/virtual 套件無實體 .deb 屬正常）。若 `debs_count` 為 `0` 且 `errors` 非空，代表備份失敗，需排查原因。

---

## 13. 前端 Toast 通知行為（備份清單頁）

備份清單頁無內嵌進度容器，改用右下角 toast 顯示狀態：

| 狀態 | 顏色 | 消失時機 |
|------|------|----------|
| 執行中（info） | 灰色 | 備份完成或失敗時由程式主動移除 |
| 成功（ok） | 綠色 | 5 秒後自動消失 |
| 失敗（error） | 紅色 | 5 秒後自動消失 |

- 同時只會顯示一個 toast（新的出現前自動移除舊的）
- 所有備份結果（含多個 type）合併成單一 toast，不會重複閃現
