# 備份管理（Backup）

> 對應頁面：系統 → 備份管理｜前端：`static/js/backup.js`｜後端：`routers/backup.py` + `core/backup_manager.py`
> 演變歷史：[20260626 備份管理功能](../changelog-details/20260626-backup-feature.md)

## 兩種備份類型

| 類型 | 說明 | 預估大小 |
|---|---|---|
| Dashboard 設定備份 | FreeSwitch 設定檔 + Dashboard 程式 + 還原腳本 | 數 MB |
| FreeSwitch 套件備份 | 已安裝的所有 `freeswitch-*` `.deb`（版本完全一致） | 150–250 MB |

## 後端 API

| Method | Endpoint | 說明 |
|---|---|---|
| `POST` | `/api/backup/run` | 觸發備份，body `{type: config\|packages\|both}` |
| `GET` | `/api/backup/list` | 列出所有備份（含 size/mtime） |
| `GET` | `/api/backup/download?filename=` | 下載 |
| `DELETE` | `/api/backup/{filename}` | 刪除 |
| `POST` | `/api/backup/restore` | 上傳還原（Server 運行中情境） |

## 設定（`settings.json`）

```json
{
  "backup_path": "/opt/fs-dashboard/backups",
  "backup_retain_days": 30,
  "backup_auto_enabled": false,
  "backup_auto_time": "00:01"
}
```

`backup_auto_time` 可手動調整每日自動備份的觸發時間（僅執行 config 備份），與 log/CDR rotate 的固定 `00:00:30` 是獨立的雙事件排程，各自每次迴圈動態讀取 `settings.json`，容許 ±90 秒誤差避免重疊，變更時間後下個週期即生效，不需重啟服務。

## 還原流程

### 情境 A：Server 仍在運行

上傳 `fs-dashboard-config-*.tar.gz` → 後端自動解壓、備份現有設定、覆蓋還原、`reloadxml`。ESL 連線設定（`esl_host`/`esl_port`/`esl_password`）**不會**被備份覆蓋，保留目前值避免斷線。

### 情境 B：整台 Server 損毀（新機重建）

```bash
# Step 1：還原 FreeSwitch（新機執行）
tar xzf freeswitch-packages-*.tar.gz && bash restore_freeswitch.sh
# Step 2：還原 Dashboard 設定
tar xzf fs-dashboard-config-*.tar.gz && bash restore_dashboard.sh
# Step 3：驗證
systemctl status freeswitch fs-dashboard
```

`restore_freeswitch.sh`：安裝前置依賴 → 從 `debs/*.deb` 安裝（版本與原機一致）→ enable+start freeswitch。
`restore_dashboard.sh`：建立 venv → 安裝 pip 套件 → 複製 Dashboard 程式 → 還原 `/etc/freeswitch/`（原設定自動備份為 `.pre-restore.TIMESTAMP`）→ 還原自訂語音/Lua 腳本 → 安裝 systemd service → 重啟兩個服務。

## 備份包內容

```
fs-dashboard-config-*.tar.gz/
├── manifest.json、restore_dashboard.sh、pip-requirements.txt
├── dashboard/（/opt/fs-dashboard 完整複本）
├── freeswitch-config/（/etc/freeswitch 完整複本）
├── sounds-custom/、scripts/（ivr_runner.lua）、systemd/

freeswitch-packages-*.tar.gz/
├── manifest.json、restore_freeswitch.sh、packages.txt、freeswitch-version.txt
└── debs/*.deb
```

## 套件備份 .deb 收集策略（三層 fallback）

| 層級 | 方法 |
|---|---|
| Layer 1 | 從 `/var/cache/apt/archives/` 直接複製 |
| Layer 2 | `apt-get download` 補齊 |
| Layer 3 | `dpkg-repack` 重打包已安裝二進位（不依賴網路，最後手段） |

`manifest.json` 的 `debs_count` 應接近 `packages_count`；若為 0 且 `errors` 非空代表備份失敗。

## 安全性

- 備份檔名格式驗證（regex），還原解壓前檢查路徑安全（防 path traversal）
- 還原前自動備份現有設定
- 下載 API 限制檔名格式

## 每日自動排程整合

```
00:00:30  Log/CDR rotate + 清理 + 備份清理（超過 backup_retain_days）
backup_auto_time（可設定）  自動備份 Dashboard 設定（backup_auto_enabled=true 時）
```

## 已知限制

| 項目 | 說明 |
|---|---|
| NAS 遠端路徑 | 僅支援已掛載本機路徑，不支援直接填 SFTP/S3/SMB UNC |
| 自動備份範圍 | 每日自動僅 config 備份，套件備份需手動觸發 |
