錄音管理介面優化總結
實作日期：2026-06-29

修改檔案：server.py
1. 新增 Mono 合併音檔功能
新增常數：
pythonREC_MONO_DIR = "/var/lib/freeswitch/recordings/.mono"
新增函式 _merge_stereo_to_mono()： 使用 Python 標準庫 wave + array，將立體聲 WAV 左右聲道平均混成 mono，無需安裝 ffmpeg。輸出至 .mono/ 目錄，已存在且來源未更新則跳過。
2. _rec_db() 新增欄位與索引

新增 mono_path 欄位儲存 mono 檔路徑
新增 idx_callee 索引
自動 ALTER TABLE 補欄位（舊版 DB 升級相容）

3. _upsert_file_to_db() 修正

Bug 修正： 原本 size 不變就直接 return，導致 mono 永遠不產生。改為：size 不變但 mono_path 為空時仍執行混音
WAV 入庫後自動呼叫 _merge_stereo_to_mono() 並更新 mono_path

4. sync_recordings_to_db() 修正

掃描時跳過 .mono 目錄，避免 mono 檔被索引進主表

5. GET /api/recordings 修正

分機篩選改為 (caller = ? OR callee = ?)，避免被叫方錄音找不到
預設每頁筆數從 50 改為 200
回傳新增 mono_path 欄位
修正原有 tab/空格混用的縮排 bug

6. 新增 GET /api/recordings/stream_mono
串流播放 mono 合併音檔，若 DB 記錄缺失則即時補建

修改檔案：index.html
1. CSS 調整

舊卡片樣式（.rec-card、.rec-grid 等）改為表格樣式（.rec-table）
新增 .rec-ch-btn（聲道切換按鈕）、.rec-player-bar（共用播放器）樣式

2. 表格欄位重新設計
舊欄位新欄位卡片顯示主叫（藍）/ 被叫（綠）/ 開始時間（藍）/ 結束時間（紅）/ 時長 / 大小 / 播放 / 下載單一下載按鈕立體音 / 單聲道 切換後播放或下載個別播放器共用播放器（頁面底部，支援拖拉進度）
3. 時間篩選 UI 重新設計

原 datetime-local（中文系統顯示上午/下午）改為：日期用 type="date" 日曆選擇 + 上午/下午切換按鈕 + 時/分獨立數字輸入框
進入頁面時自動帶入預設值：開始 = 當下時間，結束 = 當天 23:59

4. 分頁設定

每頁筆數預設 200，可手動輸入（10～1000）
切換分頁後自動捲回頂部

5. 聲道切換連動邏輯

播放切換聲道 → 永遠連動下載
下載切換聲道 → 只改下載，不影響播放
mono 尚未產生時按鈕自動 disabled

6. Bug 修正記錄
Bug原因修正合併播放一直顯示「處理中」size 不變時直接 return，跳過混音補判斷 mono_path 是否為空所有筆數都播放第一筆URL 含 & 寫進 HTML attribute 被截斷URL 改存 JS Map，完全不放 DOM attributeuid 重複導致按鈕無反應btoa().slice(0,16) 太短造成衝突移除 .slice()，使用完整 base64 字串分機篩選漏掉被叫方錄音只查 caller，未查 callee改為 (caller = ? OR callee = ?)網頁開不了手動修改時 buildRecRow 函式缺少結尾 }補上 }