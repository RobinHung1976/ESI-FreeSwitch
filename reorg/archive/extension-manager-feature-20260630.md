# 分機管理功能總結

> 對應頁面：管理 → 分機管理（`extensions`）  
> 前端函式：`renderExtensions()` / `openExtEditor()` / `saveExt()` / `deleteExt()` / `changeExtNumber()`  
> 後端 API：`/api/extensions/*`  
> 檔案路徑：`/etc/freeswitch/directory/default/<id>.xml`

---

## 1. 頁面佈局

頁面分為兩個切換面板：

| 面板 ID | 說明 |
|---------|------|
| `ext-list-panel` | 分機總覽（卡片列表） |
| `ext-editor-panel` | 新增 / 編輯分機表單（預設隱藏） |

列表頂部 Header 顯示：
- 目前分機總數 badge
- 已登錄分機數 badge（來自 `/api/registrations`）
- `↺ 刷新` 按鈕
- `+ 新增分機` 按鈕

---

## 2. 分機卡片（Card Grid）

每張卡片顯示：

| 項目 | 來源 |
|------|------|
| 分機號碼（大字） | `e.id` |
| 顯示名稱 | `e.caller_id_name` |
| 登錄 IP / 協定 | ESL `registrations` 資料（`network_ip · PROTO`，未登錄顯示 `—`） |
| 狀態 Badge | `extStatus(e.id)` |
| 通話對象 | `st.peer`（通話中時顯示） |
| 通話計時器 | `<div class="ext-timer" data-since="...">` |
| 所屬群組 | `e.callgroup` |
| ✏ 編輯按鈕 | `openExtEditor(id)` |
| ✕ 刪除按鈕 | `deleteExt(id)` |

### 卡片排序規則

按「狀態優先級」升序排列，同狀態內以分機號碼字典序排列：

| 優先級 | 狀態 | Badge 文字 | 背景色 |
|--------|------|-----------|--------|
| 1 | `talking` | 🔊 通話 | 淡綠（深綠框） |
| 2 | `ringing` | 📞 響鈴 | 淡黃 |
| 3 | `holding` | ⏸ 保留 | 淡橘 |
| 4 | `parked` | 🅿 停車 | 淡藍 |
| 5 | `idle` | ✓ 上線 | 淡綠（淡框） |
| 6 | `offline` | ✕ 離線 | 淡灰 |

---

## 3. 即時狀態系統（事件驅動）

**完全無輪詢**，狀態更新由 WebSocket 事件推播驅動：

```
FreeSwitch ESL 事件
  → esl_client.py 解析 CHANNEL_* 事件
  → WebSocket 推播 EXT_STATUS_UPDATE
  → 前端 applyExtStatusUpdate(ext, st)
  → 局部更新單一卡片 DOM（不重繪整頁）
```

**初始快照**：頁面載入時，若 `extStatusCache` 缺少資料，呼叫 `loadExtStatusSnapshot()` → `GET /api/ext/status` 補齊。

```javascript
extStatusCache[ext]            // 全域快取，key = 分機號碼
applyExtStatusUpdate(ext, st)  // 局部更新卡片 DOM
loadExtStatusSnapshot()        // 初始快照載入
```

---

## 4. 新增 / 編輯分機表單

### 表單欄位

| 欄位 | 說明 | 預設值 |
|------|------|--------|
| 分機號碼 * | 唯一識別，新增可編輯；編輯模式唯讀 | — |
| 顯示名稱 | `caller_id_name` | — |
| SIP 密碼 | `password`，留空使用 FreeSwitch 預設密碼 `$${default_password}` | `$${default_password}` |
| 語音信箱密碼 | `vm_password`，留空同分機號碼 | 同分機號碼 |
| 通話群組 | `callgroup`，用於 Pickup Group | `default` |
| 撥出權限 | `toll_allow`：全部 / 國內+本地 / 僅本地 / 無限制 | 全部 |
| Context | SIP context | `default` |

### 號碼衝突即時檢查

號碼輸入欄位綁定 `oninput` + `onblur`，呼叫 `numCheckConflict('ext-id', 'ext-id-conflict', value, 'extension')`：

- 查詢 `/api/numbers`（30 秒 TTL 快取）
- 編輯模式自動排除自身（以 `dataset.original` 辨識）
- 結果顯示於 `#ext-id-conflict`：

| 狀態 | 顯示 |
|------|------|
| 空白 | 無提示 |
| 可用 | `✓ 號碼可用`（綠色） |
| 衝突 | `⚠️ 號碼 XXXX 已被 🔒 FreeSwitch 內建「XXX」佔用`（紅色） |

### 儲存行為

- **新增**：`POST /api/extensions`，後端生成 XML 並寫入 `/etc/freeswitch/directory/default/<id>.xml`
- **編輯**：`PUT /api/extensions/{id}`，後端覆寫 XML
- 儲存後自動執行 `reloadxml`，無需重啟 FreeSwitch
- 刪除前自動備份原始 XML 為 `<id>.xml.bak`

---

## 5. 🔄 變更號碼功能

> 編輯模式專用，按鈕 ID：`ext-change-num-btn`

因 FreeSwitch directory XML 以分機號碼為檔名，**無法原地 rename**，故採三步驟原子操作：

```
Step 1：POST /api/extensions  ← 用新號碼建立新分機（複製現有設定）
Step 2：DELETE /api/extensions/{oldId}  ← 刪除舊分機（原檔備份為 .bak）
Step 3：reloadxml（由 Step 1 / Step 2 後端自動觸發）
```

流程含確認 dialog，提示：
> 變更分機號碼需要：1. 建立新分機 `<new>` 2. 刪除舊分機 `<old>` 3. 執行 reloadxml

成功後 1 秒跳回列表頁。

---

## 6. 刪除分機

```javascript
async function deleteExt(id)
```

- 彈出確認 dialog：`確定要刪除分機 ${id}？（原檔案會備份保留）`
- `DELETE /api/extensions/{id}`
- 後端備份原始 XML 後刪除，執行 `reloadxml`
- 成功後重新載入列表頁

---

## 7. 後端 API 端點

| Method | Endpoint | 說明 |
|--------|----------|------|
| `GET` | `/api/extensions/list` | 列出所有分機（解析 XML directory） |
| `POST` | `/api/extensions` | 新增分機 |
| `PUT` | `/api/extensions/{id}` | 更新分機設定 |
| `DELETE` | `/api/extensions/{id}` | 刪除分機（自動備份） |
| `GET` | `/api/ext/status` | 快照所有分機即時狀態 |

### POST / PUT Payload

```json
{
  "id":               "1010",
  "caller_id_name":   "王小明",
  "password":         "1234",
  "vm_password":      "1010",
  "callgroup":        "default",
  "toll_allow":       "domestic,international,local",
  "context":          "default",
  "caller_id_number": "1010"
}
```

---

## 8. 相關全域狀態

```javascript
let _editingExtId = null;          // 目前編輯中的分機號碼（null = 新增模式）
const extStatusCache = {};         // { "1010": { status, label, badge, peer, since } }
```

---

## 9. 技術備註

- XML 檔案路徑：`/etc/freeswitch/directory/default/<id>.xml`
- 備份路徑：`/etc/freeswitch/directory/default/<id>.xml.bak`
- 所有寫入操作後均自動呼叫 `reloadxml`（透過 ESL `api reloadxml`）
- 分機登錄狀態來源：ESL `list_registrations` 指令解析結果
- 通話計時器：`<div class="ext-timer" data-since="<ISO timestamp>">` 由 CSS / JS 週期性計算秒數更新 DOM


### 11.功能更新摘要：分機語音信箱開關 2026-06-30 新增修改
需求
分機管理編輯分機時，可設定該分機是否啟用語音信箱（voicemail）。
修改檔案
1. server.py

ExtensionData model 新增欄位：

python  voicemail_enabled: bool = True

write_extension_xml() 寫入 FreeSWITCH 原生變數：

python  vm_enabled_val = "true" if data.voicemail_enabled else "false"
  # ...
  <variable name="voicemail_enabled" value="{vm_enabled_val}"/>

list_extensions() 讀取時補上解析（舊分機無此欄位時預設 true，向下相容）：

python  'voicemail_enabled': variables.get('voicemail_enabled','true') == 'true',
2. index.html

分機編輯表單新增勾選框 #ext-vm-enabled（語音信箱密碼欄位下方）
編輯既有分機時回填勾選狀態
新增分機時預設勾選（啟用）
saveExt() 與 changeExtNumber() 的 payload 都加入 voicemail_enabled 欄位

技術原理
voicemail_enabled 是 FreeSWITCH mod_voicemail 原生辨識的 directory 變數，不需修改 dialplan 或 Lua 腳本即可生效。
過程中排除的問題

第一次測試出現 Unexpected token 'I', "Internal S"...（500 錯誤）
根因：write_extension_xml() 中遺漏 vm_enabled_val = "true" if data.voicemail_enabled else "false" 這行賦值，導致 f-string 引用未定義變數，觸發 NameError
修正後重啟 fs-dashboard 服務解決

實測結果 ✅

勾選關閉語音信箱 → 儲存成功
實際撥打測試：無人接聽時會播放問候語，但跳過錄音，符合預期行為

功能狀態：已完成並驗證通過