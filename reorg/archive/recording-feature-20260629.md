# 錄音功能實作總結

**實作日期**：2026-06-29  
**功能描述**：針對個別分機設定是否自動錄音，勾選後該分機的所有通話將自動錄音並儲存至伺服器，可在 Dashboard 錄音管理頁面播放、下載、刪除。

---

## 修改檔案清單

### 1. `server.py` — 3 處修改

**修改 1：`ExtensionData` 新增欄位（第 1310 行後）**
```python
# 新增
recording_enabled: bool = False
```

**修改 2：`write_extension_xml` 寫入 XML variable**
```python
# 函數開頭新增
recording_val = "true" if data.recording_enabled else "false"

# 在 <variables> 區塊最後新增
<variable name="recording_enabled" value="{recording_val}"/>
```

**修改 3：`list_extensions` 回傳值新增欄位**
```python
# 在 result.append({}) 裡新增
'recording_enabled': variables.get('recording_enabled','false') == 'true',
```

---

### 2. `index.html` — 4 處修改

**修改 1：分機表單加入勾選框（Context 欄位後）**
```html
<div class="settings-row">
  <span class="settings-label">錄音</span>
  <label style="display:flex;align-items:center;gap:8px;cursor:pointer">
    <input type="checkbox" id="ext-recording"
           style="width:15px;height:15px;accent-color:var(--accent)">
    <span style="font-size:13px;color:var(--text)">啟用此分機自動錄音</span>
  </label>
</div>
```

**修改 2：`openExtEditor()` 載入現有資料時填入勾選狀態**
```javascript
const recEl = document.getElementById('ext-recording');
if (recEl) recEl.checked = !!ext.recording_enabled;
```

**修改 3：`saveExt()` payload 加入欄位**
```javascript
recording_enabled: document.getElementById('ext-recording')?.checked ?? false,
```

**修改 4：`changeExtNumber()` payload 加入欄位**
```javascript
recording_enabled: document.getElementById('ext-recording')?.checked ?? false,
```

---

### 3. `/etc/freeswitch/dialplan/default.xml` — 1 處修改

在 `global` extension（`continue="true"`）的最後一個 `<condition>` 結尾前插入錄音 condition：

```xml
<condition field="${user_data(${caller_id_number}@192.168.100.209 var recording_enabled)}" expression="^true$" break="never">
  <action application="set" data="RECORD_STEREO=true"/>
  <action application="set" data="recording_follow_transfer=true"/>
  <action application="system" data="mkdir -p /var/lib/freeswitch/recordings/${strftime(%Y%m%d)}"/>
  <action application="set" data="record_file=/var/lib/freeswitch/recordings/${strftime(%Y%m%d)}/${caller_id_number}_${destination_number}_${strftime(%Y%m%d_%H%M%S)}_${uuid}.wav"/>
  <action application="record_session" data="${record_file}"/>
</condition>
```

> **插入位置**：`global` extension 最後一個空 `<condition>` 的 `</condition>` 之前，`</extension>` 之前。  
> **修改方式**：用 Python 腳本直接字串替換，避免 `sed` 處理 tab/空格混用問題。

---

## 錄音檔案規則

| 項目 | 說明 |
|------|------|
| 儲存路徑 | `/var/lib/freeswitch/recordings/YYYYMMDD/` |
| 檔名格式 | `{主叫}_{被叫}_{日期時間}_{UUID}.wav` |
| 觸發條件 | 主叫分機的 `recording_enabled = true` |
| 觸發時機 | 通話建立時（不需等待接通） |
| 立體聲 | 是（`RECORD_STEREO=true`，主被叫各一聲道） |
| 轉接跟隨 | 是（`recording_follow_transfer=true`） |
| 目錄建立 | 每通電話前自動執行 `mkdir -p` |

---

## 運作流程

```
1126 話機撥出
  → FreeSWITCH 收到 INVITE
  → 執行 default context dialplan
  → global extension (continue="true")
      → user_data(1126@192.168.100.209 var recording_enabled) = "true"
      → set RECORD_STEREO=true
      → mkdir -p /var/lib/freeswitch/recordings/YYYYMMDD/
      → set record_file=...
      → record_session 開始錄音
  → 繼續執行分機撥號 extension（bridge）
  → 通話結束，錄音自動儲存
  → Dashboard 錄音管理頁可見、可播放、可下載、可刪除
```

---

## 踩坑記錄

| 問題 | 原因 | 解法 |
|------|------|------|
| `default/` 目錄的 XML 未載入 | `X-PRE-PROCESS` 在此版本重啟後不重新掃描目錄 | 直接修改 `default.xml` 本體 |
| Extension 順序問題 | 獨立的 `per_ext_recording` extension 被分機撥號 extension 搶先執行後不再繼續 | 改寫進 `global` extension 的 condition（`global` 有 `continue="true"`） |
| `user_data()` 兩段 condition 方式失敗 | `rec_check` set 後無法跨 extension 使用，第二個 condition 永遠不會到達 | 合併為單一 condition，直接在 `field` 屬性呼叫 `user_data()` |
| `record_session` 執行但無檔案產生 | `RECORD_BRIDGE_REQ=true` 要求必須 bridge 後才寫檔，IVR/未接通通話不 bridge | 移除 `RECORD_BRIDGE_REQ` 設定 |
| 子目錄不存在導致寫入失敗 | `record_session` 不會自動建立日期子目錄 | 在 `record_session` 前加 `system` application 執行 `mkdir -p` |
| Python 腳本 pattern 不匹配 | 檔案內混用 tab 與空格，heredoc 方式難以精確比對 | 改用 `content.find()` 定位位置後直接切割字串插入 |

---

## FreeSWITCH ESL 診斷指令參考

```bash
# 確認分機 XML 變數
cat /etc/freeswitch/directory/default/1126.xml

# 確認 user_data 回傳值
fs_cli -H 127.0.0.1 -P 8055 -p FSPyAdmin -x "user_data 1126@192.168.100.209 var recording_enabled"

# 確認 domain 是否存在
fs_cli -H 127.0.0.1 -P 8055 -p FSPyAdmin -x "domain_exists 192.168.100.209"

# 確認目前登錄分機
fs_cli -H 127.0.0.1 -P 8055 -p FSPyAdmin -x "show registrations"

# reload dialplan
fs_cli -H 127.0.0.1 -P 8055 -p FSPyAdmin -x "reloadxml"

# 查看特定通話完整執行序
grep "<UUID>" /var/log/freeswitch/freeswitch.log | grep -v "CRIT"

# 確認錄音檔案
find /var/lib/freeswitch/recordings/ -type f
```
