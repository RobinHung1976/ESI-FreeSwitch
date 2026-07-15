##IVR 管理

### 架構說明

> ⚠ 此版本 FreeSwitch（1.11.1-dev / Debian 13）**沒有 `freeswitch-mod-ivr` 套件**，改用 `mod_lua` 實作。

```
撥打 IVR 入口號碼（如 9900）
  → Dialplan: answer + lua(ivr_runner.lua ESIAA)
  → ivr_runner.lua 讀取 /etc/freeswitch/ivr-menus/ESIAA.json
  → 播放語音、等待按鍵、時段路由、遞迴子選單
```

### 檔案結構

| 檔案 | 說明 |
|------|------|
| `/etc/freeswitch/dialplan/default/00_ivr_<id>.xml` | Dialplan 入口（含 DASHBOARD_IVR_META 註解） |
| `/etc/freeswitch/ivr-menus/<id>.json` | IVR 設定（Lua 讀取） |
| `/usr/share/freeswitch/scripts/ivr_runner.lua` | 通用 Lua 執行引擎 |
| `/var/lib/freeswitch/sounds/custom/` | 自定義語音檔上傳目錄 |

### JSON 設定格式（完整，含 2026-06-25 新增欄位）

```json
{
  "id": "ESIAA",
  "name": "主選單",
  "number": "9900",
  "greeting": "/var/lib/freeswitch/sounds/custom/welcome.wav",
  "menu_sound": "/var/lib/freeswitch/sounds/custom/menu.wav",
  "invalid_sound": "/var/lib/freeswitch/sounds/custom/invalid.wav",
  "exit_sound": "/var/lib/freeswitch/sounds/custom/exit.wav",
  "timeout": 10,
  "retries": 3,
  "inter_digit_timeout": 2000,
  "digit_len": 1,
  "invalid_retries": 2,
  "invalid_final_sound": "/var/lib/freeswitch/sounds/custom/final_invalid.wav",
  "timeout_retries": 2,
  "timeout_final_sound": "/var/lib/freeswitch/sounds/custom/final_timeout.wav",
  "keys": {
    "1": {"action_type": "extension", "target": "1001"},
    "2": {"action_type": "group",     "target": "7001"},
    "0": {"action_type": "ivr",       "target": "sub_menu"},
    "i": {"action_type": "hangup",    "target": ""},
    "t": {"action_type": "hangup",    "target": ""}
  },
  "schedule": {
    "enabled": true,
    "work_start": "08:00",
    "work_end": "18:00",
    "work_days": [1,2,3,4,5],
    "work_target": "",
    "offhour_target": "hangup",
    "offhour_sound": "/var/lib/freeswitch/sounds/custom/offwork.wav",
    "holiday_dates": ["2026-01-01"],
    "holiday_target": ""
  },
  "context": "default",
  "parent_id": ""
}
```

### 按鍵動作類型（action_type）

| 類型 | 說明 | target |
|------|------|--------|
| `extension` | 轉接分機 | 分機號碼（如 `1001`） |
| `group` | 轉接群組 | 群組號碼（如 `7001`） |
| `ivr` | 子選單（遞迴，不限層數） | IVR ID |
| `voicemail` | 語音信箱 | 分機號碼 |
| `playback` | 播放後掛斷 | 音檔完整路徑 |
| `hangup` | 直接掛斷 | 空 |

特殊按鍵：`t`（超時）、`i`（無效鍵）— 在「無效鍵/超時行為設定」整合卡片裡設定，不在一般按鍵清單顯示。

### 無效鍵 / 超時重播控制（2026-06-25 新增）

`invalid_retries` / `timeout_retries`：設定第幾次觸發才執行最終行為。

| 次數 | 無效鍵行為 | 超時行為 |
|------|-----------|---------|
| 前 N-1 次 | 播 `invalid_sound` → 重播 `menu_sound` | 播 `exit_sound` → 重播 `menu_sound` |
| 第 N 次（最後） | ~~invalid_sound~~ → 播 `invalid_final_sound` → 執行 `keys["i"]` | ~~exit_sound~~ → 播 `timeout_final_sound` → 執行 `keys["t"]` |

> 最後一次會**跳過**每次提示音，只播最終語音，避免兩個音檔重疊。

### 時段路由（2026-06-25 更新）

- `offhour_sound`：下班/假日時段接通後先播放的語音（選填），播完後再執行 `offhour_target`
- `check_schedule()` 回傳 `{target, sound}` table，`run_ivr` 先播語音再路由

```lua
-- Lua 時段判斷回傳格式
return { target = "hangup", sound = "/path/to/offwork.wav" }
```

###IVR 直撥分機功能 — 新增與修改總結 (2026-06-26 新增)

功能說明
來電者撥入 IVR 後，可直接輸入完整分機號碼（如 1001）轉接，不需要預先在按鍵選單中逐一定義每個分機。單鍵選單與直撥並存，按鍵比對優先。

修改檔案總覽
檔案修改內容ivr_runner.lua核心執行邏輯server.pyAPI schema 與 JSON 寫入index.htmlDashboard UI 與儲存邏輯

各檔案修改細節
ivr_runner.lua
1. 新變數讀取（第 253 行附近）

dlen 改為依 direct_ext_dialing 動態決定位數
新增讀取 direct_ext_dialing、direct_ext_digits、direct_ext_prefix

2. playAndGetDigits min_digits 改為 1（第 289 行）

原本 min=dlen，改為 min=1
讓單鍵選單可即時響應，多位數等 inter_digit_timeout 逾時或 # 結束

3. 按鍵比對新增 elseif direct_dial（第 305 行）

keys[digit] 未命中時，判斷是否符合直撥條件
前綴與位數都符合 → transfer digit XML default
不符合 → 繼續走原有無效鍵邏輯


server.py
IVRData dataclass 新增 3 個欄位：
pythondirect_ext_dialing: bool = False
direct_ext_digits:  int  = 4
direct_ext_prefix:  str  = ''
_ivr_meta_dict() 同步寫入，確保這 3 個欄位存進 JSON 供 Lua 讀取。

index.html
_ivrNewObj() 工廠函式 加入 3 個欄位預設值。
_ivrEdit() 相容舊資料，載入舊版 IVR 時自動補齊缺少的欄位預設值。
_ivrRenderEditor() 新增「直撥分機」設定卡片：

Toggle 開關：啟用／停用直撥
分機位數輸入（預設 4 位）
限定前綴輸入（選填，空=不限）

_ivrToggleDirectDial() 新函式，控制設定面板顯示與 _ivrEditing 同步。
_ivrSave() 讀取並寫入 3 個新欄位至 payload。

JSON 設定格式新增欄位
json{
  "direct_ext_dialing": true,
  "direct_ext_digits": 4,
  "direct_ext_prefix": "1"
}
欄位說明direct_ext_dialing是否啟用直撥分機direct_ext_digits等待幾位數後觸發（2-6）direct_ext_prefix限定前綴，空字串=不限

除錯過程
部署後發生通話立即被掛斷，透過 log 定位到：
mod_lua.cpp:202 ivr_runner.lua:330: end expected (to close while at line 273) near else
根因：elseif direct_dial then 區塊多加了一個 end，導致後續 else（無效鍵邏輯）變成孤立語句，Lua 解析失敗。刪除多餘的 end 後恢復正常。

### 直接轉接功能 — 新增與修改總結 (20260626 新增)
功能說明
功能觸發時機說明直接轉接 (auto_transfer)電話接通後，時段路由通過即轉完全跳過語音播放與按鍵等待播後轉接 (post_greeting_transfer)播完 greeting 後自動轉語音完整播完才轉，不等按鍵下班直轉 (offhour_action)時段路由判斷為下班/假日原本只能填 IVR ID，現在支援所有 action_type假日直轉 (holiday_action)時段路由判斷為特定假日同上
所有轉接動作統一支援：📞 轉分機 / 👥 轉群組 / 🎛 IVR選單 / 📬 語音信箱 / 📵 掛斷

修改檔案總覽
檔案修改內容ivr_runner.lua核心執行邏輯server.pyAPI schema 與 JSON 寫入index.htmlDashboard UI 與儲存邏輯

ivr_runner.lua
check_schedule() 重構
新增 resolve_action() 內部函式，統一處理新舊格式：
resolve_action(action_obj, target_str)
  ├─ action_obj.target 非空 → 回傳 {action_type, target}   ← 新式
  └─ fallback target_str   → "hangup" 或 {action_type="ivr"} ← 舊式相容
回傳格式從舊的 {target, sound} 擴充：

下班/假日 → { action = {action_type, target}, sound }
上班 work_target → { target, sound }（維持舊行為，不破壞現有設定）

run_ivr() 新增三個執行點
run_ivr()
  ├─ 時段路由
  │    ├─ sched_result.action 存在 → execute_action()        ← [NEW] 支援所有 action_type
  │    └─ sched_result.target 字串 → run_ivr() 遞迴          ← 舊式相容
  │
  ├─ [NEW] auto_transfer.enabled? → execute_action() → return
  │
  └─ while loop
       ├─ 首次播 greeting
       │    └─ [NEW] post_greeting_transfer.enabled?
       │           → playback(greeting) → execute_action() → return
       └─ 現有按鍵邏輯（含直撥分機）

server.py
新增 IVRTransferAction model（與 IVRKeyAction 的差異是多了 enabled 欄位）：
pythonclass IVRTransferAction(BaseModel):
    enabled:     bool = False
    action_type: str  = 'extension'
    target:      str  = ''
IVRSchedule 新增：
pythonoffhour_action: IVRKeyAction     # 下班直轉（優先於舊式 offhour_target）
holiday_action: IVRKeyAction     # 假日直轉（優先於舊式 holiday_target）
IVRData 新增：
pythonauto_transfer:          IVRTransferAction
post_greeting_transfer: IVRTransferAction
_ivr_meta_dict() 新增 _action() helper 統一序列化，確保所有新欄位寫入 JSON 供 Lua 讀取。
舊欄位 offhour_target / holiday_target 保留，Lua 的 resolve_action() 會自動 fallback，現有 IVR 設定不需重新儲存即可繼續運作。

index.html
新增函式
函式說明_ivrRenderActionSelector(idPrefix, obj, onChangeFn)共用 UI helper，渲染 action_type 下拉 + target 選擇器_ivrAutoTransferChange(val, field)auto_transfer onChange，action_type 改變時重渲染 target_ivrPgtChange(val, field)post_greeting_transfer 同上_ivrOffhourActionChange(val, field)offhour_action 同上_ivrHolidayActionChange(val, field)holiday_action 同上
修改函式

_ivrNewObj()：新增四個欄位預設值
_ivrEdit()：補齊舊版資料相容 fallback（讀取舊 IVR 時自動補齊缺少的欄位）
_ivrRenderEditor()：在直撥分機後新增「直接轉接」和「播後轉接」兩張設定卡片
_ivrRenderSchedule()：下班/假日導向改用 _ivrRenderActionSelector，移除舊的純 IVR <select>
_ivrSyncScheduleFromDOM()：讀取 ivr-oha-* / ivr-hda-*，移除舊的 offhour-target / holiday-target
_ivrSave()：讀取並寫入 auto_transfer、post_greeting_transfer 至 payload
_ivrRenderFlow() + _ivrRenderFlowLarge()：新增流程節點

流程圖新節點
節點圖示顏色直接轉接⚡品牌藍播後轉接🔊深青假日導向📅深橙紅下班導向🌙顯示實際 action_type icon

JSON 設定格式（新增欄位）
json{
  "auto_transfer": {
    "enabled": true,
    "action_type": "extension",
    "target": "1001"
  },
  "post_greeting_transfer": {
    "enabled": true,
    "action_type": "ivr",
    "target": "sub_menu"
  },
  "schedule": {
    "offhour_action": { "action_type": "group",    "target": "7001" },
    "holiday_action": { "action_type": "voicemail", "target": "1001" }
  }
}
除錯過程
儲存後選擇恢復空白的根本原因：server.py 未定義新欄位，Pydantic 解析時靜默丟棄前端傳入的 auto_transfer / post_greeting_transfer，寫入 JSON 時這兩個欄位不存在，讀回 Dashboard 後 UI 自然空白。新增 IVRTransferAction model 並在 IVRData 與 _ivr_meta_dict() 補齊後解決。

### IVR 選擇器改善：Searchable Select 功能總結 (20260626 修改更新)
問題
IVR 管理中，選擇分機/群組/IVR子選單時使用原生 <select> 下拉選單，超過 20 項後難以找到目標選項。
解法
以自製 Searchable Select（可搜尋下拉） 取代原生 <select>，完全原生 HTML/CSS/JS，不依賴外部套件。

修改檔案：index.html
新增（插入於 _ivrRenderActionSelector 上方）
函式說明_ivrSearchableSelect()核心 helper，產生帶搜尋框的下拉 HTML_ivrSsToggle()開啟/關閉 popup，同時關閉其他已開啟的 popup_ivrSsFilter()即時過濾選項（大小寫不敏感）_ivrSsSelect()選取後更新 hidden input、label、樣式並觸發 callbackdocument.addEventListener('click')點擊選單外部時自動關閉所有 popup
CSS 新增（<style> 區塊內）
css.ivr-ss-opt:hover { background: var(--panel2); }
.ivr-ss-sel { background: var(--accent) !important; color: #fff; }
.ivr-ss-display { min-height: 32px; }
修改的三個位置
位置行號影響範圍_ivrBuildTargetHtml()5878–5917按鍵列表（0–9 每個按鍵）的 extension / group / ivr / voicemail 選擇器_ivrRenderActionSelector()6262–6273直接轉接、播後轉接、下班導向、假日導向的 target 選擇器_ivrRenderSchedule()6181–6185時段路由「上班時段導向」選擇器
保持不變

playback（音檔選擇）：維持原本 input + select 組合，因音檔數量通常少且需要手動輸入路徑
hangup：無需 target，維持 disabled input
_ivrSyncScheduleFromDOM()：work_target 讀值不需修改，因 searchable select 的值同樣存於 id="ivr-work-target" 的 <input type="hidden">，getElementById 讀法相同

### ivr_runner.lua 重要說明

- **不依賴 cjson**：此版本 FreeSwitch Lua 環境無 cjson 模組，腳本內建純 Lua JSON 解析器（約 80 行），支援字串/數字/布林/null/陣列/物件/轉義字元
- **`os.date()` 格式**：用字串格式 `os.date("%Y")` 等逐一取值，不用 `os.date("*t")` table（FreeSwitch Lua 環境欄位不一致）
- **迴圈控制**：`while session:ready()` + `safety_limit = 50`，`invalid_count`/`timeout_count` 各自獨立計數
- **遞迴上限**：`depth > 10` 強制掛斷，防止無限迴圈

### 前端 UI 特性（2026-06-25 更新）

- **左右分割**：左側 60%（`flex:3`）表單 + 右側 40%（`flex:2`，`max-width:480px`）SVG 流程圖
- **流程圖縮放**：SVG 用 `width:100%` + `viewBox` + `preserveAspectRatio="xMidYMin meet"` 自動 fit；節點 `130×48`
- **流程圖全螢幕**：右側標題列「⛶ 展開」按鈕，overlay 節點放大至 `200×64`，字體等比縮放
- **整合卡片**：無效鍵/超時不再是獨立按鍵行，改為包含「重播次數 + ① 先播放語音 + ② 然後執行」的統一卡片
- **語音欄位**：兩欄式 `flex` 佈局（左 input 輸入路徑 + 右下拉選音檔），下拉保持顯示已選檔名，input 手動輸入時 select 同步高亮