RVIEW.md


# FreeSwitch Dashboard — 專案總覽
 
本文件是專案文件的**入口**,取代 `FreeSwitch-Project-V2-20260630.md`/`FreeSwitch-Project-v3-20260702.md`。想知道「現在系統長什麼樣子」,從這裡開始找對應的 `feature-*.md`;想知道「什麼時候改了什麼」,看 `CHANGELOG.md`。
 
> ⚠️ 本文件目前是**整理骨架階段**產出:文件結構、開發慣例、環境資訊、CHANGELOG 已就緒;`features/` 底下各功能現況文件仍在後續批次陸續建立中(見下方「文件索引」的完成狀態標記)。
 
## 一、文件分類與記錄規則
 
| 類型 | 位置 | 內容原則 | 更新方式 |
|---|---|---|---|
| 總覽入口 | `PROJECT-OVERVIEW.md`(本文件) | 環境資訊、開發慣例、文件索引 | 原地更新 |
| 變更索引 | `CHANGELOG.md` | 一行式索引 + 連結,只保留最近 2 個月 | 新增條目,每滿 2 個月輪替封存 |
| 變更詳情 | `changelog-details/*.md` | 每次變更完整細節(現象/原因/修復/驗證) | **永久保留,不搬動,只增不減** |
| 索引封存 | `changelog-archive/CHANGELOG-<年>-H<半年>.md` | 超過 2 個月的 `CHANGELOG.md` 索引 | 半年封存一次,封存後不再變動 |
| 功能現況 | `features/feature-*.md` | 只寫「現在長什麼樣子」,不寫演變過程 | **原地覆蓋更新**,永遠只有一份 |
| 維運文件 | `ops/ops-*.md` | server 環境、部署、GitHub 連線 | 原地更新 |
| 外部參考 | `reference/*.md` | 不隨專案演變 | 不需維護 |
| 已合併原始檔 | `archive/*.md` | 被合併掉的原始檔案,保留供回溯對照 | 不刪除、不編輯 |
 
## 二、未來記錄規則(動手改東西前先看這裡)
 
1. 改到現有功能 → 直接編輯對應的 `feature-*.md`,更新成新現況;同時在 `CHANGELOG.md` 加一行索引,細節寫成獨立檔案放 `changelog-details/日期-關鍵字.md`
2. 修 bug → 細節寫進 `changelog-details/`(格式比照現有 Bug-Fix-Notes 的「現象/原因/修復/驗證」),`CHANGELOG.md` 加一行索引;如果修完後行為跟文件描述的不一樣了,才回頭同步 `feature-*.md`
3. 新功能 → 新增一份 `feature-<名稱>.md`,並在本文件「文件索引」章節加一行連結
4. 檔名不帶日期(`feature-*.md` 一律不帶日期;`changelog-details/` 檔名帶日期是例外,因為它本質就是時間序記錄)
5. 舊檔案不刪除,搬進 `archive/` 保留
6. `CHANGELOG.md` 每滿 2 個月做一次輪替:把最舊的月份剪下,貼進 `changelog-archive/CHANGELOG-<年>-H<半年>.md`
7. `changelog-details/` 底下的檔案永久保留、不搬動,確保索引裡的連結永遠有效
8. 有子分類的功能(如 Dialplan、號碼目錄),命名採「主檔名不加後綴當總覽、子頁用主檔名-子類型」,方便 `ls` 排序自動群組
9. 新增 API 端點 → 去對應領域的 `routers/*.py` 加一個 route,不用改 `server.py`
10. 新增前端頁面 → `static/js/` 新增檔案,`static/index.html` 補一行 `<script>`,**務必放在 `init.js` 之前**(`init.js` 會組裝 `pages` 物件並呼叫 `switchPage`,必須等其他頁面函式都定義完成才能執行)
11. 兩個 router 互相呼叫是正常設計,但避免「互相 import」造成循環依賴;真的要共用的常數/狀態放進 `core/constants.py` 或 `core/state.py`
12. `server.py` 或任何 `routers/*.py`/`core/*.py` 更新(尤其新增 Pydantic 欄位)必須 `systemctl restart fs-dashboard`,否則新欄位會被靜默忽略。純前端檔案(`static/` 底下)不需要重啟,瀏覽器強制重新整理即可
13. 版控/部署走 `updateN.sh`/`deploy.sh` 慣例(前置驗證 + 精確比對/整份覆寫 + 自動歸檔 + 驗證清單),細節見 `ops/ops-github-workflow.md`
## 三、環境資訊速查
 
| 用途 | 路徑 |
|---|---|
| 專案目錄 | `/opt/fs-dashboard/` |
| 後端進入點 | `/opt/fs-dashboard/server.py`(**必須位於根目錄**,不可放進 `routers/`) |
| 後端共用模組 | `/opt/fs-dashboard/core/` |
| 後端 API router | `/opt/fs-dashboard/routers/` |
| 前端骨架 | `/opt/fs-dashboard/static/index.html` |
| 前端樣式 | `/opt/fs-dashboard/static/css/style.css` |
| 前端 JS 模組 | `/opt/fs-dashboard/static/js/` |
| 後端設定檔 | `/opt/fs-dashboard/settings.json`(**含密碼/金鑰,不進 git**) |
| 使用者/權限 SQLite | `/opt/fs-dashboard/data/auth.db`(**不進 git**) |
| CDR SQLite DB | `/opt/fs-dashboard/data/cdr.db` |
| 備份輸出目錄 | `/opt/fs-dashboard/backups/`(**不進 git**) |
| IVR Lua 引擎 | `/usr/share/freeswitch/scripts/ivr_runner.lua` |
| FreeSwitch 設定根目錄 | `/etc/freeswitch/` |
| Dialplan | `/etc/freeswitch/dialplan/` |
| CDR CSV(即時/歸檔) | `/var/log/freeswitch/cdr-csv/Master.csv` / `cdr-YYYY-MM-DD.csv` |
| 系統日誌(即時/歷史) | `/var/log/freeswitch/freeswitch.log` / `freeswitch-YYYY-MM-DD.log` |
| 錄音 | `/var/lib/freeswitch/recordings/YYYYMMDD/` |
| 自定義語音檔 | `/var/lib/freeswitch/sounds/custom/` |
 
**Python 環境**:虛擬環境 `/opt/myapp/venv/`;`pip install -r requirements.txt --break-system-packages`
 
**服務管理**:
```bash
systemctl start/stop/restart fs-dashboard
# /etc/systemd/system/fs-dashboard.service，After=freeswitch.service
# WorkingDirectory=/opt/fs-dashboard，ExecStart=uvicorn server:app
 
# 手動啟動排查（journalctl 摘要不含完整 traceback 時）
cd /opt/fs-dashboard
/opt/myapp/venv/bin/python -c "import server"
```
 
完整部署流程、GitHub 連線設定、`updateN.sh`/`deploy.sh` 慣例,見 `ops/ops-deployment.md`、`ops/ops-github-workflow.md`。除錯指令速查見 `ops/ops-troubleshooting-commands.md`。
 
## 四、文件索引
 
### Features(現況文件,✅ = 已建立)
 
| 檔案 | 狀態 |
|---|---|
| `feature-extensions.md` | ✅ |
| `feature-groups.md` | ✅ |
| `feature-ivr.md` | ✅ |
| `feature-numbers.md` | ✅ |
| `feature-numbers-conflict-check.md` | ✅ |
| `feature-cdr.md` | ✅ |
| `feature-recordings.md` | ✅ |
| `feature-sounds.md` | ✅ |
| `feature-gateway.md` | ✅ |
| `feature-dialplan.md` + `feature-dialplan-routing-rule.md` + `feature-dialplan-system-extensions.md` + `feature-dialplan-custom.md` | ✅ |
| `feature-logs.md` | ✅ |
| `feature-backup.md` | ✅ |
| `feature-vars.md` | ✅ |
| `feature-sip-profile-acl.md` | ✅ |
| `feature-permissions-auth.md` | ✅(2026-07-13 更新:使用者管理前端頁面已上線) |
 
### Ops
 
| 檔案 | 狀態 |
|---|---|
| `ops-server-requirements.md` | ✅ |
| `ops-deployment.md` | ✅ |
| `ops-troubleshooting-commands.md` | ✅ |
| `ops-github-workflow.md` | ✅ |
| `freeswitch-restore-guide.md` | 🔲 原檔搬進 `ops/` 即可,內容未改動,未重新產出(本次未讀取原始內容,建議直接複製移動) |
 
### Reference
 
- `reference/FreeSWITCH_Official_Documentation_Quick_Index.md`(原檔搬移,內容不變,未重新產出)
## 五、已知待處理事項(截至 2026-07-13)
 
1. **全新環境部署需手動觸發帳號建立**:`server.py` 只呼叫 `auth_db.init_db()` 建表,不會自動 seed,需手動呼叫一次 `POST /api/auth/bootstrap`。詳見 `feature-permissions-auth.md`。
2. **登錄記錄(`reg_log`)尚未持久化**:目前仍在記憶體,服務重啟後歸零(注意:CDR 已 SQLite 化,但 `reg_log` 尚未,兩者不同,不可混淆)。
3. **Dialplan Context 切換 UI**:後端 `RouteRule` 已有 `context` 欄位,前端加選單即可。
4. ~~**Nginx reverse proxy + HTTPS**：尚未導入。~~ → 已於 2026-07-15 完成，見 `changelog-details/20260715-nginx-https-feature.md`。
5. USER_NOT_REGISTERED 警告:每通電話出現的無害 NOTICE,`mod_sofia` 內部查詢順序造成,不影響通話品質,可忽略。
6. **`owned_ext` 無法透過編輯使用者清空**:`auth_db.update_user()` 的 `owned_ext=None` 語意是「不變更」而非「清空」,目前只能改資料庫層,或未來補一支專門的清空端點。詳見 `feature-permissions-auth.md` 第五節。
7. **導覽列權限隱藏尚未全面驗證**:2026-07-13 新增的 `applyAuthUI()` 是全站性邏輯,但只針對「使用者管理」測試過,其餘既有 18 個頁面的模組名稱對應建議找時間補測。
## 六、下一步開發(優先順序,截至 2026-07-13)
 
**高優先**
- [x] 登入驗證 + 權限管控(已完成)
- [x] 使用者管理前端頁面(已完成,2026-07-13,見 `feature-permissions-auth.md` 第六節)
- [x] Nginx reverse proxy + HTTPS（已完成，2026-07-15，見 `changelog-details/20260715-nginx-https-feature.md`）
**中優先**
- [ ] 登錄記錄(`reg_log`)持久化
- [ ] Dialplan Context 切換 UI
- [ ] 導覽列權限隱藏全面驗證(見已知待處理事項第 7 點)
**低優先**
- [ ] 多租戶支援
- [ ] 錄音 `.trash` 自動清理
- [ ] Dialplan 備份歷史列表與一鍵還原
- [ ] 分機/語音信箱問候語串接音檔庫選擇器(目前僅 IVR 已串接)
- [ ] `owned_ext` 清空端點設計(見已知待處理事項第 6 點)
 