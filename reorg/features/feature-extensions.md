# 分機管理（Extensions）

> 對應頁面：管理 → 分機管理｜前端：`static/js/extensions-groups.js`｜後端：`routers/extensions.py`
> 演變歷史：[20260630 分機管理功能總結](../changelog-details/20260630-extension-manager-feature.md) · [20260626 分機群組管理](../changelog-details/20260626-extension-group-manager-feature.md)

## 頁面佈局

`ext-list-panel`（卡片列表）/ `ext-editor-panel`（新增/編輯表單）雙面板切換。列表頂部顯示分機總數、已登錄分機數 badge。

## 分機卡片

顯示：分機號碼、顯示名稱、登錄 IP/協定（來自 `/api/registrations`）、狀態 Badge、通話對象、通話計時器、所屬群組。

**排序規則**（狀態優先級升序，同狀態內按號碼字典序）：

| 優先級 | 狀態 | Badge | 背景色 |
|---|---|---|---|
| 1 | `talking` | 🔊 通話 | 淡綠（深框） |
| 2 | `ringing` | 📞 響鈴 | 淡黃 |
| 3 | `holding` | ⏸ 保留 | 淡橘 |
| 4 | `parked` | 🅿 停車 | 淡藍 |
| 5 | `idle` | ✓ 上線 | 淡綠（淡框） |
| 6 | `offline` | ✕ 離線 | 淡灰 |

## 即時狀態（事件驅動，無輪詢）

```
FreeSwitch ESL 事件 → esl_client.py 解析 CHANNEL_*/REGISTER
  → WebSocket 推播 EXT_STATUS_UPDATE → applyExtStatusUpdate(ext, st) 局部更新單一卡片 DOM
```

`extStatusCache` 全域快取；快取有值一律信任，不被輪詢覆蓋。頁面載入時若快取缺資料，才呼叫 `loadExtStatusSnapshot()`（`GET /api/ext/status`）補齊。

## 表單欄位

| 欄位 | 說明 | 預設值 |
|---|---|---|
| 分機號碼 * | 新增可編輯，編輯唯讀 | — |
| 顯示名稱 | `caller_id_name` | — |
| SIP 密碼 | 留空使用 `$${default_password}` | `$${default_password}` |
| 語音信箱密碼 | 留空同分機號碼 | 同分機號碼 |
| 語音信箱啟用 | `voicemail_enabled`，關閉後無人接聽會播問候語但跳過錄音 | 開啟 |
| 通話群組 | `callgroup`（Pickup Group 用） | `default` |
| 撥出權限 | `toll_allow`：全部/國內+本地/僅本地/無限制 | 全部 |
| Context | 下拉選單，動態讀取 `/api/dialplan/contexts`（與路由規則/自定義 Dialplan 共用快取），只能選現有 context，不提供就地建立 | `default` |
| 自動錄音 | `recording_enabled`，詳見 `feature-recordings.md` | 關閉 |

號碼欄位綁定 `oninput`/`onblur` 呼叫 `numCheckConflict()`（見 `feature-numbers.md`），編輯模式自動排除自身。

Context 欄位改為下拉選單（2026-07-16），資料來源與 Dialplan 路由規則、自定義 Dialplan 頁面共用同一份 30 秒快取（`common.js: loadDialplanContexts()`），建立新 context 的入口仍只開放在「自定義 Dialplan」頁面（見 `feature-dialplan-custom.md`），分機表單只能選、不能建。編輯模式若目前值不在清單中（例如該 context 資料夾已被移除），仍保留原值供選擇並標示警語，避免非預期變更。詳見 `changelog-details/20260716-extension-context-dropdown-feature.md`。

## 儲存與 XML

- 新增：`POST /api/extensions` 寫入 `/etc/freeswitch/directory/default/<id>.xml`
- 編輯：`PUT /api/extensions/{id}` 覆寫 XML
- 刪除：`DELETE /api/extensions/{id}`，原檔自動備份為 `<id>.xml.bak`
- 所有寫入後自動 `reloadxml`，無需重啟服務

## 🔄 變更號碼

FreeSwitch directory XML 以分機號碼為檔名，無法原地 rename，採三步驟原子操作：

```
Step 1：POST /api/extensions（用新號碼建立，複製現有設定）
Step 2：DELETE /api/extensions/{oldId}（刪除舊分機，備份 .bak）
Step 3：reloadxml（Step 1/2 後端自動觸發）
```

## 後端 API

| Method | Endpoint | 說明 |
|---|---|---|
| `GET` | `/api/extensions/list` | 列出所有分機 |
| `POST` | `/api/extensions` | 新增 |
| `PUT` | `/api/extensions/{id}` | 更新 |
| `DELETE` | `/api/extensions/{id}` | 刪除（自動備份） |
| `GET` | `/api/ext/status` | 快照所有分機即時狀態 |

## 相關全域狀態

```javascript
let _editingExtId = null;
const extStatusCache = {};  // { "1010": { status, label, badge, peer, since } }
```

## 技術備註

- XML 路徑：`/etc/freeswitch/directory/default/<id>.xml`，備份 `<id>.xml.bak`
- 分機登錄狀態來源：ESL `list_registrations`
- 通話計時器：`data-since` ISO timestamp，前端 JS 週期計算秒數
