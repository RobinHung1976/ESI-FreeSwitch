# Server 環境需求

## 系統架構

```
瀏覽器 (static/index.html)
    ↕ HTTP REST API (port 3000) / WebSocket (port 8080) / SSE
後端 (Python FastAPI) — /opt/fs-dashboard/
    ├── server.py        # 主程式，掛載所有 routers（必須位於根目錄，不可放進 routers/）
    ├── core/            # 共用模組（狀態、常數、ESL client、WS manager、backup、cdr_db、auth_db、auth、runtime、permissions）
    ├── routers/          # 依領域拆分的 20+ 個 APIRouter
    └── static/           # 前端骨架 + css + js
    ↕ ESL TCP port 8055（兩條獨立 socket：一條 API、一條事件監聽）
FreeSwitch 1.11.1 on Debian（版本以實際機器為準）
  ESL Port: 8055（密碼見 settings.json 的 esl_password，不同環境不同，請勿沿用文件中出現過的範例值）
```

## 服務管理

```bash
systemctl start/stop/restart fs-dashboard
# /etc/systemd/system/fs-dashboard.service
# After=freeswitch.service
# WorkingDirectory=/opt/fs-dashboard
# ExecStart=uvicorn server:app --host 0.0.0.0 --port 3000

# 手動啟動（除錯用）
cd /opt/fs-dashboard
source /opt/myapp/venv/bin/activate
uvicorn server:app --host 0.0.0.0 --port 3000 --reload
```

**⚠️ `server.py` 必須位於專案根目錄 `/opt/fs-dashboard/server.py`，不可放進 `routers/`**——曾發生部署時誤放進 `routers/server.py`，導致 `ModuleNotFoundError: No module named 'server'`（見 `changelog-details/20260702-registration-status-and-deploy-path-bugs.md`）。`journalctl` 摘要不含完整 traceback，排查時應先手動執行 `cd /opt/fs-dashboard && /opt/myapp/venv/bin/python -c "import server"` 取得真正錯誤原因。

## Python 環境

虛擬環境：`/opt/myapp/venv/`

套件：`fastapi`、`uvicorn`、`websockets`（鎖版本區間 `>=14,<17`，見下方提醒）、`lxml`、`python-multipart`

```bash
/opt/myapp/venv/bin/pip install -r requirements.txt --break-system-packages
```

**⚠️ `websockets` 套件需鎖版本區間**：v14 起 asyncio 版伺服器實作改用 `ServerConnection` 取代 `WebSocketServerProtocol`，拿掉了 `.path` 屬性。若環境重建時未鎖版本，`pip install` 可能抓到更新的大版本，導致 WebSocket handler 崩潰（連線狀態燈紅燈但服務本身 `systemctl status` 仍顯示正常，因為只是個別連線 handler 崩潰，不影響主 process）。詳見 `changelog-details/20260710-ws-path-attribute-fix.md`。

## 完整目錄路徑對照表

| 用途 | 路徑 |
|---|---|
| 專案目錄 | `/opt/fs-dashboard/` |
| 後端進入點 | `/opt/fs-dashboard/server.py` |
| 後端設定檔（含密碼/金鑰，不進 git） | `/opt/fs-dashboard/settings.json` |
| 使用者/權限 SQLite（不進 git） | `/opt/fs-dashboard/data/auth.db` |
| CDR SQLite DB | `/opt/fs-dashboard/data/cdr.db` |
| 錄音索引 SQLite | `/var/lib/freeswitch/recordings/.rec_index.db` |
| 備份輸出目錄（不進 git） | `/opt/fs-dashboard/backups/` |
| IVR Lua 引擎 | `/usr/share/freeswitch/scripts/ivr_runner.lua` |
| FreeSwitch 設定根目錄 | `/etc/freeswitch/` |
| 全域變數 | `/etc/freeswitch/vars.xml` |
| 分機目錄 | `/etc/freeswitch/directory/default/` |
| Dialplan | `/etc/freeswitch/dialplan/` |
| 群組 XML | `/etc/freeswitch/dialplan/default/00_group_*.xml` |
| IVR Dialplan XML | `/etc/freeswitch/dialplan/default/00_ivr_*.xml` |
| IVR JSON 設定 | `/etc/freeswitch/ivr-menus/*.json` |
| Gateway XML | `/etc/freeswitch/sip_profiles/external/` |
| ACL 設定 | `/etc/freeswitch/autoload_configs/acl.conf.xml` |
| CDR CSV（即時/歸檔） | `/var/log/freeswitch/cdr-csv/Master.csv` / `cdr-YYYY-MM-DD.csv` |
| 系統日誌（即時/歷史） | `/var/log/freeswitch/freeswitch.log` / `freeswitch-YYYY-MM-DD.log` |
| 錄音 | `/var/lib/freeswitch/recordings/YYYYMMDD/`，mono 合併 `.mono/`，刪除暫存 `.trash/` |
| 自定義語音檔 | `/var/lib/freeswitch/sounds/custom/` |
| 系統內建語音檔 | `/usr/share/freeswitch/sounds/{en,es,fr,pt,ru,music}/` |

## 完整後端 API Router 清單

| Router | 前綴 |
|---|---|
| `routers/auth.py` | `/api/auth/*` |
| `routers/users.py` | `/api/users*` |
| `routers/perm_groups.py` | `/api/perm-groups*` |
| `routers/calls.py` | `/api/calls*` |
| `routers/extensions.py` | `/api/extensions*`、`/api/ext/status` |
| `routers/groups.py` | `/api/groups*` |
| `routers/ivr.py` | `/api/ivr/*` |
| `routers/numbers.py` | `/api/numbers` |
| `routers/cdr.py` | `/api/cdr*` |
| `routers/recordings.py` | `/api/recordings*` |
| `routers/sounds.py` | `/api/sounds/*` |
| `routers/gateway.py` | `/api/gateway*` |
| `routers/dialplan_routes.py` | `/api/dialplan/routes*` |
| `routers/dialplan_system_extensions.py` | `/api/dialplan/system-extensions` |
| `routers/dialplan_custom.py` | `/api/dialplan/custom*` |
| `routers/dialplan_files.py` | `/api/dialplan`、`/api/dialplan/file`、`/api/dialplan/create`、`/api/download` |
| `routers/vars.py` | `/api/vars` |
| `routers/settings.py` | `/api/settings` |
| `routers/backup.py` | `/api/backup/*` |
| `routers/logs.py` | `/api/logs/*` |
| `routers/sip_profile.py` | `/api/sip-profile*` |
| `routers/acl.py` | `/api/acl/*` |

各 router 完整端點清單見對應 `features/feature-*.md`。

## 已知目前未加驗證的既有模組

除了 `feature-permissions-auth.md` 已完成 HTTP 層 JWT 驗證的部分，其餘既有 20 個模組的後端 API 目前仍未加 `require_permission` 驗證，屬分階段規劃的一部分，非遺漏。
