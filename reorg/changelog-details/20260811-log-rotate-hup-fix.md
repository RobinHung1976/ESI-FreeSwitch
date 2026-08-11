# 【資料遺失事故】log/CDR rotate 缺少 SIGHUP，通話記錄與系統日誌持續遺失約 5 週（2026-08-11）

> ⚠️ 這是一次**資料遺失事故**的完整記錄，非單純功能缺陷。原本 `PROJECT-OVERVIEW.md` 已知
> 待處理事項第 5 點記錄的「USER_NOT_REGISTERED 警告」是這次排查的起點，但根因與影響範圍
> 完全不同，該點記錄已證實為誤判，本篇取代其內容。

## 一、觸發排查的現象

原始需求：查證 `PROJECT-OVERVIEW.md` 已知待處理事項第 5 點記載的「`USER_NOT_REGISTERED`
警告，`mod_sofia` 內部查詢順序造成，不影響通話品質，可忽略」。

排查時 `grep "USER_NOT_REGISTERED" freeswitch.log` 完全零命中，往下追查才發現這不是「問題
已消失」，而是**整個系統日誌從近幾天起完全沒有新內容寫入**，進一步牽出 CDR（通話記錄）也
中了同樣的 bug、且影響範圍長達 5 週。

## 二、根因

### 2.1 表面現象

- `/var/log/freeswitch/freeswitch.log`：0 bytes，但 `freeswitch` 服務已連續執行超過一個月
  未重啟（自 2026-07-03 起）
- `/var/log/freeswitch/cdr-csv/Master.csv`：同樣 0 bytes
- `freeswitch-2026-08-09.log`、`freeswitch-2026-08-10.log`、`cdr-2026-08-09.csv`、
  `cdr-2026-08-10.csv` 等排程歸檔出來的每日檔案全部是 0 bytes
- `stat`/`fdinfo` 診斷：FreeSwitch 手上的 `freeswitch.log` file descriptor（fd 7）自
  **2026-07-06** 起就沒有被重新開啟過；`Master.csv` 的 fd 顯示最後一次重新開啟是
  **2026-07-20 14:00**

### 2.2 根本原因

`core/runtime.py` 的 `_rotate_log_now()`／`_rotate_cdr_now()`（每日 00:00:30 排程執行，
初版設計於 2026-06-26 上線第一天就存在，非後續改壞）：

```python
shutil.copy2(FS_LOG_FILE, dest_path)      # 複製內容到日期檔
with open(FS_LOG_FILE, "w") as f:
    f.truncate(0)                          # 原地清空
```

原始註解寫「清空原始 log（truncate，不刪檔，讓 FreeSwitch 的 fd 繼續有效）」——這個假設只
對了一半：fd 本身確實沒有失效（不會拋出 IOError），但 FreeSwitch 的 `logfile.conf.xml` 與
`cdr_csv.conf.xml` 都明確設定：

```xml
<!-- true to auto rotate on HUP, false to open/close -->
<param name="rotate-on-hup" value="true"/>
```

代表 `mod_logfile`／`mod_cdr_csv` **只有收到 `SIGHUP` 訊號才會重新整理寫入狀態**（關閉舊 fd、
重新開啟檔案、offset 歸零）。單純從外部 truncate 檔案內容完全不會通知 FreeSwitch，它手上的
file descriptor 會繼續沿用 truncate 前記住的寫入位置（file offset）——POSIX 語意下，外部把
檔案清空不會重置其他 process 手上 fd 的寫入位置。新內容實質上寫不進使用者看得到的檔案，等同
每天的 rotate 動作都在悄悄破壞當天的資料。

這是官方文件記載的標準行為與標準修復方式（
[mod_logfile 官方文件](https://developer.signalwire.com/freeswitch/FreeSWITCH-Explained/Modules/mod_logfile_1048990)
：`kill -HUP <freeswitch pid>`），並非 FreeSwitch 的異常，是本專案的 rotate 實作從一開始
就沒有考慮到這個前提。

### 2.3 為什麼一直沒被發現

- 平常沒人盯著 log/CDR 檔案大小
- 「即時日誌」Tab 用 `tail -f` 讀取，短期內即使卡在舊 offset 畫面也未必馬上異常
- CDR 查詢 API（`/api/cdr`）會做 `sync_today()` 增量同步，但同步來源（`Master.csv`）本身
  也是空的，查詢介面本身不會報錯，只是安靜地回傳越來越少的資料，容易被誤認為「今天通話量
  剛好比較少」
- 只有像這次「主動去查某個字串卻完全查不到」才會意外揭露

## 三、資料損失範圍確認

用 `sqlite3 data/cdr.db "SELECT * FROM cdr_daily_summary ORDER BY 1 DESC LIMIT 40;"` 查每
日彙總筆數，確認：

| 期間 | 狀況 |
|---|---|
| 2026-07-02 | 29 通（CDR SQLite 化上線當天，含一次性回填舊資料） |
| 2026-07-03 | 4 通 |
| 2026-07-04 ～ 2026-07-19 | **連續 16 天，完全 0 筆** |
| 2026-07-20 | 2 通（唯一一次 fd 意外被重置，推測是某次操作間接觸發） |
| 2026-07-21 ～ 2026-08-11（修復當天） | **連續 22 天，完全 0 筆** |

即自 2026-07-02 CDR SQLite 化上線以來的 5 週多，**除了 7/3、7/20 兩天各自捕捉到個位數筆數
外，幾乎沒有任何一天的通話記錄被完整保存**。`freeswitch.log` 的受損起點更早（fd 顯示自
2026-07-06 起未重新開啟），實際影響時間可能還要往前推。

### 3.1 資料能否救回

評估結論：**無法從系統內部救回**。

- `mod_cdr_csv`／`mod_logfile` 每通電話/每筆訊息即時寫入，寫入位置卡在舊 offset 之後，資料
  並非「寫到別的地方」，而是實質上從未真正落地到任何使用者看得到的檔案，沒有可回收的中間態
- 曾評估用 `freeswitch.log` 交叉比對還原基本通話資訊，但 log 的損壞時間窗（7/6 之後）與 CDR
  的損壞時間窗（7/4~7/19、7/21~8/11）高度重疊，此路不通
- 若需要這段期間的通話明細（尤其計費相關），建議向 SIP Trunk / 電信商調閱其自留的通話記錄
  （多數電信商基於計費考量會留存 3-6 個月），可取得對外通話的計費依據，但不會有 Dashboard
  這邊的內部分機互打細節

## 四、修復內容

### 4.1 新增 `_send_freeswitch_hup()`（`core/runtime.py`）

找到 FreeSwitch 主 process PID（`pgrep -f 'bin/freeswitch'`），送出 `SIGHUP`；等待
`mod_logfile`／`mod_cdr_csv` 完成各自的 rename 動作後，清掉它們產生的 0 bytes 空殘留檔
（`freeswitch.log.*`、`Master.csv.*` 底下大小為 0 的檔案）。

### 4.2 跨模組耦合風險與對應設計

`SIGHUP` 是 **FreeSwitch process 層級**訊號，`mod_logfile`／`mod_cdr_csv` 會**同時**反應。
若只針對其中一個檔案 truncate 完就送出 HUP，另一個尚未被程式碼安全複製走的檔案內容，會被
FreeSwitch 自己的 rotate-on-hup 邏輯搬進 Dashboard 完全不認識的孤兒檔案——等於在修一個資料
遺失 bug 的同時，製造出一個新的資料遺失 bug。

因此新增 `_rotate_log_and_cdr_now(cdr_use_today, primary)` 合併函式：

1. 依序完成 log 與 CDR 各自的「複製＋truncate」
2. 只有在**兩邊都確認安全**（這次真的有 truncate 到，或者檔案本來就是空的、沒東西可丟）時，
   才統一送出**一次** HUP
3. 特別處理「今日已歸檔過」的 no-op 邊界情況：如果按鈕重複點擊、其中一邊回傳「今日已歸檔，
   略過」，但該檔案這期間已經有新資料累積（非空），則整批**略過送出 HUP**，避免把累積中的
   新資料意外搬給 FreeSwitch 自己的孤兒檔案邏輯

### 4.3 呼叫點調整

- `core/runtime.py` 的 `log_rotate_scheduler()`（每日 00:00:30 排程）：改呼叫
  `_rotate_log_and_cdr_now(cdr_use_today=False, primary='log')`
- `routers/logs.py` 的 `POST /api/logs/rotate`：改呼叫
  `_rotate_log_and_cdr_now(cdr_use_today=True, primary='log')`
- `routers/cdr.py` 的 `POST /api/cdr/rotate`：改呼叫
  `_rotate_log_and_cdr_now(cdr_use_today=True, primary='cdr')`

### 4.4 行為變更（刻意）

「系統日誌」頁面的「🔄 立即輪轉」與「CDR」頁面的「立即歸檔」**兩個按鈕現在互相連動**：按下
其中一個，另一邊也會被安全歸檔一次。這是為了資料安全必須接受的副作用，根因是 HUP 訊號本身
就無法只影響單一模組，兩個按鈕原本各自獨立的行為在技術上已經不可能維持，只能選擇「連動保護」
或「維持獨立但接受孤兒檔案風險」，選擇前者。

## 五、驗證方式

實機於 production server（`debian-freeswitch`）驗證，非測試環境：

```bash
# 1. 部署（update45.sh，含前置驗證 + 語法檢查 + 自動歸檔）
./update45.sh
systemctl restart fs-dashboard

# 2. 手動觸發一次輪轉（Dashboard 系統日誌頁面「立即輪轉」按鈕，或呼叫 API）
# 觀察排程/手動觸發日誌：
journalctl -u fs-dashboard -n 30 --no-pager | grep -i "rotate\|hup"

# 3. 撥測試電話後確認新內容寫入
tail -5 /var/log/freeswitch/freeswitch.log
tail -5 /var/log/freeswitch/cdr-csv/Master.csv

# 4. 確認 CDR 查詢 API 與 SQLite 同步正常
curl -s "http://127.0.0.1:3000/api/cdr?limit=5" -H "Authorization: Bearer <token>"
```

**驗證結果**：

- `freeswitch.log` 於 `12:47:30` 起可見新寫入的 IVR 相關訊息（此前已卡死超過一個月）
- `Master.csv` 完整記錄下 3 通測試電話（1 通接通 11 秒、2 通因路由問題未接通），欄位內容
  正確（caller/destination/context/hangup_cause 等皆正確）
- `GET /api/cdr` 查詢確認 `total: 6`，SQLite 同步機制（`sync_today()`）正常運作
- 排程日誌看到 `[cdr-rotate] .../cdr-2026-08-11.csv (0 bytes)` 與
  `POST /api/logs/rotate" 200 OK`，合併輪轉邏輯執行無誤
- 未產生異常的 0 bytes 孤兒殘留檔（FreeSwitch 原生產生的 `freeswitch.log.1` 為 238 bytes
  正常內容檔，非清理對象）

## 六、後續待辦

- `PROJECT-OVERVIEW.md` 已知待處理事項第 5 點（原「`USER_NOT_REGISTERED`...可忽略」）已
  改寫為本次事故的正確記錄與結案狀態
- `feature-logs.md`／`feature-cdr.md` 同步更新「已知限制」反映修復後現況
- 建議評估是否需要對這 5 週的資料損失，額外建立一份對外或對稽核用的說明文件（本記錄目前
  僅止於技術層面的現象/根因/修復/驗證）
- 建議未來新增任何「truncate 檔案供外部長駐 process 繼續寫入」的類似設計時，優先查證該
  process 的 log/檔案模組是否有 `rotate-on-hup` 或等效機制，不能只假設「fd 不報錯＝寫入正常」
