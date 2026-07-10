# FreeSwitch Dashboard — 資料夾重整部署指南

本次改動：**只搬檔案位置、拆分程式碼結構，沒有改變任何 API 路徑或前端行為**。
已用自動化測試逐一比對過拆分前後的 74 個 API 路徑與 HTTP method，完全一致；
JS 拆分後也逐一比對過所有函式/變數清單，完全一致。

## 部署前請先確認

- `server.py` 內的 `app.mount("/static", StaticFiles(directory="static"))` 這行
  代表**整個新資料夾結構都要放在同一層**，不能只丟 `server.py` 進去。
- 原本 `requirements.txt` 缺了 `python-multipart` 和 `lxml`
  （程式碼其實一直有在用，可能是您那台機器早就手動裝過，這次一併補上避免新機器部署漏裝）。

## 部署步驟（建議先在測試路徑跑過一次再換上線）

1. **備份現有機器**：先用 Dashboard 本身的「備份管理」功能跑一次「立即備份 → 設定」，
   或直接 `cp -r /opt/fs-dashboard /opt/fs-dashboard.bak-$(date +%Y%m%d)`。

2. **確認 `settings.json` 的即時設定**：您機器上目前的 `settings.json`
   （含 ESL 密碼、備份路徑等）務必保留，不要被這次上傳的版本覆蓋過去。
   本次交付的 `settings.json` 只是原樣複製一份，若您機器上的版本內容不同，
   部署時用您機器上現有的那份即可，不需要用這次的。

3. **停止服務**：
   ```bash
   sudo systemctl stop fs-dashboard   # 依實際 service 名稱調整
   ```

4. **替換整個資料夾**（保留 `settings.json` 與 `backups/`）：
   ```bash
   cd /opt/fs-dashboard
   cp settings.json /tmp/settings.json.bak   # 保險起見先備份現有設定
   # 清空舊檔（保留 backups/ 目錄，若有的話）
   find . -maxdepth 1 ! -name backups ! -name . -exec rm -rf {} +
   # 解壓新結構進來
   unzip /path/to/fs-dashboard-restructured.zip -d .
   # 用回原本機器上的 settings.json（除非您要用新版預設值）
   cp /tmp/settings.json.bak settings.json
   ```

5. **安裝套件**：
   ```bash
   pip install -r requirements.txt --break-system-packages
   ```

6. **重新啟動**：
   ```bash
   sudo systemctl start fs-dashboard
   sudo systemctl status fs-dashboard   # 確認沒有 import 錯誤
   ```

7. **驗證**：
   - 瀏覽器開 Dashboard 首頁，確認畫面正常、側邊欄可以收合
   - 隨便測幾個功能：分機管理、Dialplan 路由設定（新的三合一頁面）、ESL 終端機的「常用重載指令」
   - 檢查 `journalctl -u fs-dashboard -f` 或您原本的 log 位置，確認沒有 500 錯誤

## 如果要回滾

直接把步驟 4 備份的舊資料夾整個換回來、重啟服務即可，`settings.json` 格式沒有變動，
新舊版本互相相容。

## 之後想繼續維護的話

- 新增一個 API 端點：去對應領域的 `routers/*.py` 加一個 `@router.get/post/...`，
  不用再去改 3000+ 行的 `server.py`。
- 新增一個前端頁面：在 `static/js/` 新增一個檔案，`static/index.html` 最後面補一行
  `<script src="/static/js/xxx.js"></script>`（記得放在 `init.js` **之前**，
  因為 `init.js` 會呼叫 `switchPage('overview')`，必須等其他頁面都定義好才能跑）。
- 兩個 router 需要互相呼叫對方的函式是正常的（例如 `numbers.py` 需要
  `groups.py` 的 `_read_group_meta`），這是刻意設計；但要避免「互相 import」
  造成循環依賴——如果 A 要 import B，B 就不能反過來 import A，
  真的需要共用的東西請放進 `core/constants.py` 或 `core/state.py`。
