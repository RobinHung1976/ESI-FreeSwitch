# CHANGELOG

只放「最近 2 個月」的一行式索引，詳細內容請點連結進 `changelog-details/`。超過 2 個月的索引會依半年封存進 `changelog-archive/`（規則見 `PROJECT-OVERVIEW.md` 開發慣例章節）。

## 2026-07

- 07-16 fix: 登錄記錄（reg_log）去重，分機定期自動刷新註冊不再視為新登入重複寫入 → [詳情](changelog-details/20260716-reg-log-dedup-feature.md)
- 07-16 test: 導覽列權限隱藏全面驗證完成（19 模組 × 5 內建群組，靜態比對 + 5 帳號實機測試皆通過），副產物發現 `calls`/`acl` 模組缺少前端頁面 → [詳情](changelog-details/20260716-nav-permission-audit.md)
- 07-16 feat: Dialplan Context 切換 UI（context 篩選/全部總覽下鑽 + 自定義 Dialplan 建立新 context，衝突檢查依 context 分組） → [詳情](changelog-details/20260716-dialplan-context-switch-feature.md)
- 07-16 fix: custom_regex 對 custom_regex 衝突檢查因取樣比對法限制永遠偵測不到重疊，補上規則字串完全相同時強制判定衝突 → [詳情](changelog-details/20260716-custom-regex-conflict-detection-fix.md)
- 07-16 fix: 全站 10 支前端檔案共約 39 處寫入操作缺少 Authorization header，導致新增/編輯/刪除一律 401（既有 bug，非本次功能造成） → [詳情](changelog-details/20260716-auth-header-missing-fix.md)
- 07-15 feat: 登錄記錄（reg_log）SQLite 持久化，取代原本服務重啟即歸零的記憶體 list，新增保留天數設定與每日自動清理 → [詳情](changelog-details/20260715-reg-log-persistence.md)
- 07-15 fix: reorg/ 文件目錄（PROJECT-OVERVIEW.md/CHANGELOG.md/changelog-details/archive/features/ops/reference）稽核發現從未被 git 追蹤，全數補進版控 → [詳情](changelog-details/20260715-reorg-git-tracking-fix.md)

- 07-15 feat: Nginx reverse proxy + HTTPS 上線（自簽憑證、REST/WebSocket/SSE 統一走 443、login.html/change-password.html mixed content 修正、nginx 設定納入 git 版控、後端服務改 bind 127.0.0.1） → [詳情](changelog-details/20260715-nginx-https-feature.md)

- 07-15 fix: `updateN.sh` 自動歸檔固定寫法誤用當次腳本編號建立資料夾（`update8.sh` 誤建 `update8/`），修正為統一固定使用 `updateN/` 資料夾 → [詳情](changelog-details/20260715-updaten-archive-folder-fix.md)
- 07-15 feat: 使用者密碼管理工具新增（`userpwreset.sh` 平時重設密碼 / `admin-recover.py` 忘記所有 admin 密碼緊急救援）+ reset-password API 開放 `force_change` 可選參數 → [詳情](changelog-details/20260715-user-password-management-tools.md)
- 07-13 feat: 使用者管理 + 權限群組管理前端頁面上線（單頁雙 Tab，內建群組唯讀）+ 導覽列依權限隱藏 + 登入身分/登出 UI，含 4 輪測試回饋修正 → [詳情](changelog-details/20260713-user-management-feature.md)
- 07-10 fix: 清理孤兒/重複檔案（`routers/runtime.py`/`cdr_db.py`/`migrate_cdr_backfill.py`）+ `calls.router` 重複掛載 → [詳情](changelog-details/20260710-orphan-file-cleanup.md)
- 07-10 audit: Server 現況稽核，發現孤兒檔案、`calls.router` 重複掛載、WS 驗證缺口等 → [詳情](changelog-details/20260710-server-snapshot-audit.md)
- 07-10 fix: WebSocket `ServerConnection` 無 `.path` 屬性（`websockets` v14+ 升級後連線狀態燈紅燈） → [詳情](changelog-details/20260710-ws-path-attribute-fix.md)
- 07-03 feat: SIP Profile 進階設定 / 信任 SBC 清單 + 除錯記錄 → [詳情](changelog-details/20260703-sip-profile-acl-feature.md)
- 07-03 feat: 使用者權限系統初版設計決策記錄（現況已由 `feature-permissions-auth.md` 取代） → [詳情](changelog-details/20260703-permission-feature-summary.md)
- 07-02 fix: 錄音管理頁面無法捲動、播放器改固定頂部、殘留 HTML 造成 JS 語法錯誤 → [詳情](changelog-details/20260702-recording-ui-scroll-player-fix.md)
- 07-02 migrate: CDR 統計報表 SQLite 化（原本掃 CSV 改為兩層 SQLite 儲存，解決歷史查詢因保留天數靜默回傳空結果的問題） → [詳情](changelog-details/20260702-cdr-sqlite-migration.md)
- 07-02 fix: 外線轉分機 1210 全套除錯（`public.xml` 範圍未同步、Codec 不相容誤轉語音信箱、`external` profile STUN IP 誤用致 30 秒斷線、錄音檔名解析不支援 `+` 號） → [詳情](changelog-details/20260702-call-routing-1210.md)
- 07-02 fix: 導覽列「通話即時狀態」badge 計數與實際不符、WebSocket 重連未校正 → [詳情](changelog-details/20260702-nav-badge-count-fix.md)
- 07-02 fix: 分機登入/登出無法即時更新（函式名稱/命名空間錯誤致 `NameError` 被靜默吞掉）+ 部署路徑錯誤致服務無法啟動 → [詳情](changelog-details/20260702-registration-status-and-deploy-path-bugs.md)
- 07-01 feat: Dialplan 類型三（自定義：範本＋XML編輯器）完成 → [詳情](changelog-details/20260701-dialplan-custom-feature.md)
- 07-01 feat: Dialplan 類型二（系統內建 Extension 唯讀）完成 + `dialplan_common.py` 共用機制抽取 → [詳情](changelog-details/20260701-dialplan-system-extensions-feature.md)
- 07-01 feat: Dialplan 管理功能總覽與三類型架構規劃 → [詳情](changelog-details/20260701-dialplan-management-overview.md)
- 07-01 refactor: `server.py`/`index.html` 模組化重整（拆分 core/routers/static 結構）+ Dialplan UI 三合一整合 + 正式部署 → [詳情](changelog-details/20260701-restructure-summary.md)

## 2026-06

- 06-30 feat: 「通話統計報表」頁面新增（日期快捷、摘要卡片、圖表、CSV 匯出），通知設定 Tab 整體移除 → [詳情](changelog-details/20260630-report-page-update.md)
- 06-30 feat: 全域變數設定（`vars.xml` 白名單編輯）新增 → [詳情](changelog-details/20260630-vars-config-feature.md)
- 06-30 feat: 音檔庫功能新增（自訂 + 內建音檔統一管理，IVR 共用 API） → [詳情](changelog-details/20260630-audio-library-feature.md)
- 06-30 feat: 分機管理功能總結 + 語音信箱開關 → [詳情](changelog-details/20260630-extension-manager-feature.md)
- 06-29 feat: 監控 Dashboard 版面重構（統計卡整合、Canvas 圖表、分機篩選邏輯修正、後端效能優化） → [詳情](changelog-details/20260629-monitor-dashboard-update.md)
- 06-29 feat: 錄音管理介面優化（Mono 合併音檔、表格化版面、聲道切換連動邏輯） → [詳情](changelog-details/20260629-recording-ui-feature.md)
- 06-29 feat: 錄音管理篩選功能（SQLite 索引、依分機/時間篩選） → [詳情](changelog-details/20260629-recording-filter-feature.md)
- 06-29 feat: 分機自動錄音功能（per-extension recording toggle + dialplan 整合） → [詳情](changelog-details/20260629-recording-feature.md)
- 06-26 refactor: 使用者即時狀態總覽重構（分機即時狀態 + 即時通話合併為單一「以人為中心」表格，A/B leg 去重） → [詳情](changelog-details/20260626-realtime-status-overview-redesign.md)
- 06-26 feat: 分機群組管理功能 → [詳情](changelog-details/20260626-extension-group-manager-feature.md)
- 06-26 feat: IVR 功能與直撥分機（含 Searchable Select 選擇器） → [詳情](changelog-details/20260626-ivr-feature.md)
- 06-26 feat: 號碼目錄功能 → [詳情](changelog-details/20260626-number-directory-feature.md)
- 06-26 feat: 號碼衝突檢查功能 → [詳情](changelog-details/20260626-number-conflict-check-feature.md)
- 06-26 feat: 通話記錄 CDR 功能（初版，CSV 架構） → [詳情](changelog-details/20260626-cdr-feature.md)
- 06-26 feat: 系統日誌功能（四 Tab 架構） → [詳情](changelog-details/20260626-system-log-feature.md)
- 06-25/26 feat: 備份管理功能（Dashboard 設定 + FreeSwitch 套件雙軌備份） → [詳情](changelog-details/20260626-backup-feature.md)
- 06-18 ~ 06-30 fix: 累積除錯批次（32 秒斷線、IVR 引擎與排程多項 bug、分機互打斷線、群組撥號失敗、CDR 方向判斷、自動備份排程等共 20+ 項） → [詳情](changelog-details/20260618-20260630-bug-fixes-batch.md)
