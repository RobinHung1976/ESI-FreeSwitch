# 全域變數設定（Vars）

> 對應頁面：設定 → 全域變數｜前端：`static/js/settings-vars.js`｜後端：`routers/vars.py`
> 演變歷史：[20260630 全域變數功能新增](../changelog-details/20260630-vars-config-feature.md)

## 設計原則：白名單而非自由編輯

`vars.xml` 內含網路埠號、TLS、Codec 等動到需重啟服務或破壞 STUN 自動偵測的高風險設定，**不開放整份檔案自由編輯**，只暴露可安全透過 `reloadxml` 套用、不影響服務穩定性的變數。

## 白名單變數（8 個）

| 變數 | 顯示名稱 | 型別 |
|---|---|---|
| `default_password` | 預設分機密碼 | password（可切換明文） |
| `domain` | 預設網域 (SIP Domain) | text |
| `hold_music` | 保留音樂路徑 | text + 音檔庫選擇器 |
| `outbound_caller_name` | 外撥顯示名稱 | text |
| `outbound_caller_id` | 外撥顯示號碼 | text |
| `console_loglevel` | 主控台日誌等級 | select |
| `call_debug` | 通話除錯模式 | bool |
| `presence_privacy` | 隱藏目的號碼 | bool |

## 黑名單（防禦性保留）

`internal_sip_port`/`internal_tls_port`/`external_sip_port`/`external_tls_port`/`internal_ssl_enable`/`external_ssl_enable`/`internal_auth_calls`/`external_auth_calls`/`sip_tls_version`/`sip_tls_ciphers`/`rtp_sdes_suites`/`rtp_video_max_bandwidth_in`/`out`/`bind_server_ip`/`external_rtp_ip`/`external_sip_ip`/`local_ip_v4`/`rtp_start_port`/`rtp_end_port`/`default_provider_password`

`external_rtp_ip`/`external_sip_ip` 用 `cmd="stun-set"`（非 `set`），解析器只讀 `cmd="set"` 項目，結構上已排除，黑名單保留其名稱作防禦性二次保護。

## 驗證邏輯

- `bool`：值必須 `true`/`false`
- `select`：值必須在預定義 `options` 內
- `text`/`password`：不可空白
- 黑名單變數：403 拒絕
- 非白名單 key：400 拒絕

## 寫入安全機制

寫入前自動備份（`vars.xml.bak.YYYYMMDD_HHMMSS`），失敗自動還原備份，成功後 `esl.api('reloadxml')` 立即套用，不需重啟服務。

## 後端 API

| Method | Endpoint | 說明 |
|---|---|---|
| `GET` | `/api/vars` | 讀取白名單變數 |
| `POST` | `/api/vars` | 更新（body 為 `{key: value}` dict） |

## 前端特殊處理

- `hold_music`：欄位旁「🔊 選擇音檔」按鈕，彈窗列出 `music`（內建）+ `custom`（自訂）分類可試聽選用，文字框仍可手動輸入特殊格式（如 `local_stream://moh`）
- 高風險欄位（`default_password`/`domain`）儲存時二次確認彈窗，列出變更項目名稱
- 每個欄位下方顯示變數 key（code 樣式）與風險警示文字

## 已評估但移除的欄位

`default_areacode`/`default_country` 原在白名單內，經查證 vanilla vars.xml 與本系統 Dialplan 均無規則實際引用這兩個變數做撥號邏輯轉換，故移除避免誤導使用者。相關輔助函式（`ISO_COUNTRY_MAP`/`checkCountryCode()`）保留未刪除，供日後若有國碼相關欄位需求時複用。
