# 部署流程

## 整體部署方式：整包資料夾，非單檔

`server.py` 的 `app.mount("/static", StaticFiles(directory="static"))` 代表整個資料夾結構都要放在同一層，不能只丟 `server.py` 進去。

## 標準部署步驟（資料夾整包替換）

```bash
# 1. 先備份現有機器（用 Dashboard 本身的「備份管理」功能，或直接複製整個資料夾）
cp -r /opt/fs-dashboard /opt/fs-dashboard.bak-$(date +%Y%m%d)

# 2. 保留 settings.json（含 ESL 密碼、備份路徑等即時設定，務必不被新版覆蓋）
cd /opt/fs-dashboard
cp settings.json /tmp/settings.json.bak

# 3. 停止服務
sudo systemctl stop fs-dashboard

# 4. 替換整個資料夾（保留 backups/ 目錄）
find . -maxdepth 1 ! -name backups ! -name . -exec rm -rf {} +
unzip /path/to/fs-dashboard-restructured.zip -d .
cp /tmp/settings.json.bak settings.json

# 5. 安裝套件
pip install -r requirements.txt --break-system-packages

# 6. 重新啟動並驗證
sudo systemctl start fs-dashboard
sudo systemctl status fs-dashboard
journalctl -u fs-dashboard -f   # 確認無 import 錯誤 / 500
```

## 驗證清單

- 瀏覽器開 Dashboard 首頁，確認畫面正常、側邊欄可以收合
- 隨便測幾個功能：分機管理、Dialplan 路由設定、ESL 終端機的常用重載指令
- 檢查 `journalctl -u fs-dashboard -f`，確認無 500 錯誤

## 如果要回滾

直接把備份的舊資料夾整個換回來、重啟服務即可，`settings.json` 格式沒有變動，新舊版本互相相容。

## 基於 Git 的部署（`update1.sh`+ 之後的 updateN.sh / `deploy.sh`）

自 ESI-FreeSwitch repo 建立版控後，改用 `updateN.sh`（套用單次功能異動的腳本）+ `deploy.sh`（從 GitHub 拉取最新版本部署）這一組工具，取代整包資料夾替換。完整流程、前置驗證/自動歸檔慣例見 `ops-github-workflow.md`。

### `deploy.sh` 核心邏輯

1. 檢查工作目錄狀態（`git status --porcelain`），有未追蹤/未提交的變動先警告，可選擇取消
2. 備份現有 `settings.json`
3. 停止服務
4. `git fetch` + `git reset --hard origin/<branch>`
5. 還原剛才備份的 `settings.json`（**repo 裡的版本不該覆蓋 server 上的即時密碼/金鑰**）
6. `pip install -r requirements.txt`
7. 重啟服務 + 健康檢查（`curl` 確認首頁 200）
8. 印出部署前後 commit hash，供回滾用（`git reset --hard <commit>`）

## 全新環境首次啟動的額外步驟（含使用者權限系統）

全新環境部署完成、服務首次啟動後，**必須手動呼叫一次** bootstrap 端點，才會建立內建權限群組與範例帳號，否則沒有任何帳號能登入：

```bash
curl -X POST http://localhost:3000/api/auth/bootstrap
```

詳見 `features/feature-permissions-auth.md`。這點過去沒有任何文件記錄，是稽核過程中發現的重要缺口。

## 新機從零開始重建（FreeSwitch + Dashboard 都要重裝）

見 `features/feature-backup.md` 的「情境 B：整台 Server 損毀」段落，使用備份管理功能產生的 `freeswitch-packages-*.tar.gz` + `fs-dashboard-config-*.tar.gz` 兩個備份包配合 `restore_freeswitch.sh`/`restore_dashboard.sh` 腳本執行。

## 之後想繼續維護的話

- 新增 API 端點 → 去對應領域的 `routers/*.py` 加一個 route，不用再改 `server.py`
- 新增前端頁面 → `static/js/` 新增檔案，`static/index.html` 補一行 `<script>`，**務必放在 `init.js` 之前**（`init.js` 會組裝 `pages` 物件並呼叫 `switchPage`）
- 兩個 router 互相呼叫是正常設計，但避免「互相 import」造成循環依賴——真的需要共用的東西放進 `core/constants.py` 或 `core/state.py`
- `server.py` 或任何 router/core 模組更新（尤其新增 Pydantic 欄位）必須 `systemctl restart fs-dashboard`，否則新欄位會被靜默忽略
