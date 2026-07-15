# FreeSwitch Dashboard — Dialplan 類型一（外撥路由規則）開發總結

**日期**：2026-07-01
**涵蓋範圍**：類型一（外撥路由規則 Outbound Routing）— 已完成 ✅
**整體架構與其他類型**：請見 `dialplan-management-overview-20260701.md`

---

## 二、類型一：外撥路由規則（Outbound Routing）✅ 已完成

### 定義

決定「哪些號碼透過哪條 SIP Trunk 外撥」的 dialplan extension。
例如：`DP_AC220.xml`、新建的 `00_route_*.xml`。

### 為何用表單而非 XML 編輯器

外撥路由規則的結構高度一致：號碼樣式 → 設定 caller ID → bridge 到 gateway。
可變部分只有 4–5 個欄位，適合用表單取代手寫 XML，避免語法錯誤、gateway 打錯 IP 等人為失誤。

### 表單欄位

| 欄位 | UI 元件 | 說明 |
|---|---|---|
| 規則名稱 | 文字輸入 | 顯示用，例：「市話手機外撥」 |
| 號碼樣式 | 下拉選單 | 開頭為 / 完全符合 / 任意 / 自訂正規式 |
| 號碼樣式值 | 文字輸入 + 即時測試器 | 輸入 `6,7` → 自動顯示範例：「符合 6xxx、7xxx」 |
| 目標 Gateway | 下拉選單 | 從 `/api/gateway/list` 撈取，顯示名稱+proxy |
| 來電顯示覆寫 | 文字輸入（選填） | 留空則使用預設 `${outbound_caller_id_number}` |
| Toll Allow | 下拉選單 | local / domestic / international / 全部 / 不限制 |
| 優先順序 | 數字輸入（1–999） | 數字越小越優先，影響 Dashboard 排列順序 |
| 啟用狀態 | 下拉選單 | 停用時 condition 包入恆不成立的條件 |
| 進階 XML 預覽 | 可摺疊區塊 | 依表單欄位即時生成，讓使用者理解底層在做什麼 |

### 號碼樣式（pattern_type）對照

| 類型 | pattern_value 範例 | 產生的 regex |
|---|---|---|
| `prefix`（開頭為） | `6,7` | `^[67](\d*)$` |
| `exact`（完全符合） | `0912345678` | `^0912345678$` |
| `any`（全部攔截） | （空白） | `^(.*)$` |
| `custom_regex`（自訂） | `^00(\d+)$` | 原樣使用 |

### 檔案格式（Dashboard 標準）

```
/etc/freeswitch/dialplan/default/00_route_<id>.xml
```

檔案開頭嵌入 `DASHBOARD_ROUTE_META` JSON 註解，記錄所有表單欄位：

```xml
<!-- DASHBOARD_ROUTE_META: {"id":"r260701123456","name":"市話手機外撥",...} -->
<include>
  <extension name="route_市話手機外撥">
    <condition field="destination_number" expression="^[67](\d*)$">
      <action application="set" data="effective_caller_id_number=${outbound_caller_id_number}"/>
      <action application="bridge" data="sofia/gateway/AC220/$1"/>
    </condition>
  </extension>
</include>
```

### 舊有手寫檔案的偵測與升級

自動掃描 `dialplan/default/*.xml` 和 `dialplan/public/*.xml`，找出符合「外撥路由規則結構」的手寫檔案（如 `DP_AC220.xml`）。

**識別條件**（三項同時成立）：
1. 只含單一 `<extension>`
2. 有 `<condition field="destination_number" ...>`
3. 有 `<action application="bridge" data="sofia/gateway/..."/>`

**反解析欄位**：

| 原始 XML 寫法 | 反解析結果 |
|---|---|
| `expression="^[6,7](\d*)$"` | `prefix`，`6,7` |
| `expression="^0912345678$"` | `exact`，`0912345678` |
| `sofia/gateway/AC220/$1` | `gateway_name=AC220` |
| `sofia/gateway/192.168.100.220/$1` | 反查 `/sip_profiles/external/` 還原 → `AC220` |
| `<condition field="${toll_allow}" expression="local"/>` | `toll_allow=local` |

**升級流程**：
偵測到舊有檔案 → 列表標示「⚠️ 未納入管理」（橘色）→ 點擊升級 → 表單預填反解析結果 → 確認後儲存 → 備份原始 → 寫入新格式 → 刪除原始 → reloadxml 驗證。未升級的 legacy 規則無法直接 PUT/DELETE/PATCH（回傳 400），必須走升級流程。

### 路由測試工具

**列表頁（全域）**：輸入號碼 → 後端模擬 FreeSwitch 比對 → 顯示命中規則 + 完整比對過程（含未升級舊有檔案）。

**表單內（即時）**：純前端 JavaScript 即時比對目前正在編輯的 pattern，不打 API，輸入即回應。

### 安全機制

**自動備份**：所有寫入操作前一律先備份 `.bak.YYYYMMDD_HHMMSS`。

**reloadxml 驗證 + 自動 rollback**：

```
寫入新 XML → reloadxml
  +OK → 正常回傳
  -ERR → 還原備份 → 再次 reloadxml → 回傳 HTTP 500（含錯誤訊息）
```

| 操作 | Rollback 方式 |
|---|---|
| 新增 | 刪除剛建立的新檔案 |
| 更新 / 停用啟用 | 從 `.bak.*` 還原 |
| 刪除 | 從 `.bak.*` 還原（取消刪除） |
| 升級 | 還原舊有 legacy 路徑 + 刪除新建的 `00_route_*.xml` |

**號碼樣式衝突檢查**：新增/編輯時雙向取樣比對，重疊回傳 409 並列出衝突清單，表單 400ms debounce 自動觸發。

**Dashboard 管理檔案保護**：掃描時排除 `00_group_*`、`00_ivr_*`、`default.xml`、`public.xml`。

### API 端點

| 方法 | 路徑 | 說明 |
|---|---|---|
| GET | `/api/dialplan/routes` | 列表（含 legacy 檔案） |
| GET | `/api/dialplan/routes/{id}` | 讀取單一（支援 `legacy:` 前綴） |
| POST | `/api/dialplan/routes` | 新增 |
| PUT | `/api/dialplan/routes/{id}` | 更新 |
| DELETE | `/api/dialplan/routes/{id}` | 刪除（備份後刪） |
| PATCH | `/api/dialplan/routes/{id}/toggle` | 啟用/停用 |
| POST | `/api/dialplan/routes/check-conflict` | 衝突檢查（不寫檔） |
| POST | `/api/dialplan/routes/test-number` | 路由測試 |
| POST | `/api/dialplan/routes/legacy/upgrade` | 升級舊有手寫檔案 |

---

