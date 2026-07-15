# 全域系統設定（vars.xml）功能 — 新增總結

> 新增日期：2026-06-30
> 修改檔案：server.py、index.html

---

## 需求

過去要修改 FreeSWITCH 全域常用設定（分機密碼、SIP 網域、外撥來電顯示等）只能 SSH 進機器直接編輯 `/etc/freeswitch/vars.xml`。新增網頁端「全域變數」設定頁，讓常用、低風險的變數可以直接在 Dashboard 上修改，並沿用既有的 `reloadxml` 機制立即套用。

## 設計原則：白名單而非自由編輯

`vars.xml` 內含網路埠號、TLS、Codec 等動到需重啟服務或破壞 STUN 自動偵測的高風險設定，因此**不開放整份檔案自由編輯**，改採白名單機制：只暴露可安全透過 `reloadxml` 套用、不影響服務穩定性的變數。

---

## 後端 API（server.py）

| Method | Endpoint | 說明 |
|--------|----------|------|
| `GET` | `/api/vars` | 讀取白名單內的全域變數（解析 vars.xml） |
| `POST` | `/api/vars` | 更新白名單變數，寫回前自動備份，成功後 `reloadxml` |

### 白名單變數（VARS_WHITELIST）

依實際 `vars-20260630.xml` 內容校正，最終 8 個變數：

| 變數 | 顯示名稱 | 型別 | 備註 |
|------|---------|------|------|
| `default_password` | 預設分機密碼 | password（可切換顯示明文） | 影響所有未個別覆寫密碼的分機註冊 |
| `domain` | 預設網域 (SIP Domain) | text | 影響分機 SIP 註冊網域 |
| `hold_music` | 保留音樂路徑 | text + 音檔庫選擇器 | |
| `outbound_caller_name` | 外撥顯示名稱 | text | |
| `outbound_caller_id` | 外撥顯示號碼 | text | |
| `console_loglevel` | 主控台日誌等級 | select（debug/info/notice/warning/err/crit/alert） | |
| `call_debug` | 通話除錯模式 | bool（true/false） | |
| `presence_privacy` | 隱藏目的號碼 (Presence Privacy) | bool（true/false） | true 時 NOTIFY 不含目的號碼，影響部分話機來電顯示 |

### 黑名單（VARS_BLACKLIST，防禦性保留）

`internal_sip_port`、`internal_tls_port`、`external_sip_port`、`external_tls_port`、`internal_ssl_enable`、`external_ssl_enable`、`internal_auth_calls`、`external_auth_calls`、`sip_tls_version`、`sip_tls_ciphers`、`rtp_sdes_suites`、`rtp_video_max_bandwidth_in/out`、`bind_server_ip`、`external_rtp_ip`、`external_sip_ip`、`local_ip_v4`、`rtp_start_port`、`rtp_end_port`、`default_provider_password`

> `external_rtp_ip`／`external_sip_ip` 在 vars.xml 中用 `cmd="stun-set"`（非 `set`），代表 FreeSWITCH 啟動時會向 STUN server 動態查詢公網 IP，而非單純設值。解析器只讀 `cmd="set"` 的項目，這兩個變數結構上已被排除；黑名單中仍保留其名稱作為防禦性二次保護，避免日後若 XML 改回 `cmd="set"` 產生漏洞。

### 已評估但移除的欄位

`default_areacode`、`default_country` 原本在白名單內，**經查證後移除**：這兩個變數在 vanilla vars.xml 與本系統 Dialplan 中都只是被動傳遞給 directory 的 `<variable>` 區塊（例如 `default_areacode=$${default_areacode}`），沒有任何 Dialplan 規則實際讀取並用來做撥號邏輯轉換。留在白名單會讓使用者誤以為改了會影響撥號行為，故拿掉，避免混淆。

### 驗證邏輯

- `bool` 型別：值必須是 `true` 或 `false`
- `select` 型別：值必須在預定義 `options` 清單內
- `text`／`password` 型別：不可為空白
- 黑名單變數：直接 403 拒絕，提示需用 SSH 修改
- 非白名單 key：400 拒絕

### 寫入安全機制

- 寫入前自動備份原檔（`vars.xml.bak.YYYYMMDD_HHMMSS`）
- 寫入失敗時自動還原備份，避免留下半套設定
- 成功後呼叫 `esl.api('reloadxml')` 立即套用，不需重啟 FreeSWITCH 服務

---

## 前端 UI（index.html）

### Settings Tree 新增節點

```
系統設定
  ├── 連線設定
  ├── CDR 設定
  ├── 日誌保留設定
  ├── 介面設定
  ├── 全域變數     ← 新增
  └── Dialplan 設定
```

### 欄位渲染邏輯

依變數型別自動產生對應 UI：

- `bool` / `select` → 下拉選單
- `password` → 輸入框 + 👁 顯示/隱藏切換按鈕（明文/遮蔽，圖示同步變 🙈）
- `text` → 一般輸入框
- 每個欄位下方顯示變數 key（code 樣式）與風險警示文字（`warn`，若有）

### 特殊欄位處理

**`hold_music`**：欄位旁加「🔊 選擇音檔」按鈕，點擊開啟彈窗，同時列出兩個分類：
- `music`（內建保留音樂，`/usr/share/freeswitch/sounds/music`）
- `custom`（自訂音檔）

彈窗內可逐筆試聽（呼叫既有 `/api/sounds/stream`），點選「選用」後自動把路徑填回文字框；文字框仍可手動輸入特殊格式（如 `local_stream://moh`）。彈窗沿用既有的 `_dpModalHtml()` / `dpCloseModal()` 共用元件。

### 高風險欄位二次確認

`saveVarsPage()` 儲存時，若異動到 `default_password` 或 `domain`，會跳出 `confirm()` 對話框列出變更項目名稱，要求使用者二次確認後才送出，避免誤觸：

> 「即將變更『預設分機密碼、預設網域 (SIP Domain)』，這會影響所有分機的註冊/認證行為。確定要儲存嗎？」

### 已實作但目前未使用的輔助函式

`ISO_COUNTRY_MAP`（常用國家 ISO alpha-2 對照表）與 `checkCountryCode()`（即時比對國碼是否有效）原為 `default_country` 欄位設計的即時驗證提示，欄位移除後函式予以保留（未刪除），未被任何欄位呼叫，供日後若有其他國碼相關欄位需求時複用。

---

## 測試紀錄

| 項目 | 結果 |
|------|------|
| 白名單解析（只回傳允許變數，排除 `cmd="stun-set"`、黑名單變數） | ✅ 通過（lxml 單元測試） |
| 更新單一/多個白名單變數，其餘變數不受影響 | ✅ 通過 |
| 黑名單變數寫入請求 → 403 拒絕 | ✅ 通過 |
| 不在白名單的未知 key → 400 拒絕 | ✅ 通過 |
| `bool`/`select` 型別值驗證（無效值拒絕） | ✅ 通過 |
| 實機修改 `default_password` 後分機可用新密碼重新註冊 | ✅ 通過（使用者實測） |
| `hold_music` 選擇音檔彈窗（music + custom 試聽、選用） | ✅ 通過（使用者實測） |
| `default_country` 欄位移除後不再出現於頁面 | ✅ 通過（使用者實測） |

---

## 後續可擴充方向

- 若日後需要「依國碼/區碼自動轉換撥號規則」（例如自動補 `+886`），這屬於 **Dialplan 邏輯**而非 vars.xml 變數，需另外設計 Dialplan extension regex 轉換規則，建議另開功能討論，不混入此頁範疇。
- `default_password` 顯示明文目前無權限管控，待之後加入角色權限（admin / operator / viewer）後，可評估是否限制僅特定角色能看到明文切換按鈕。
