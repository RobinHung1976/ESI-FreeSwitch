## 除錯

### ✅ 外線來電轉分機 1210 直接斷線（`public.xml` 分機範圍未同步擴大）（2026-07-02）

**現象**：外線 `+886277286126` 撥入分機 1210，未響鈴即斷線（`NORMAL_CLEARING`）。分機互打（1126→1210）正常。

**根本原因**：`/etc/freeswitch/dialplan/public.xml` 的 `public_extensions` extension，`destination_number` 條件仍寫死只匹配 **1000–1019**：
```xml
<condition field="destination_number" expression="^(10[01][0-9])$">
```
分機 1210 不在此範圍，public context 找不到相符規則，直接落到保底 catch-all（僅 `set`/`export`，無 `bridge`/`transfer`），因此秒斷。

此為 `Bug-Fix-Notes-20260630.md` 中 `default.xml`／`Local_Extension` 同類問題（1000–1019 → 1000–1999）的**修復遺漏**：當時只改了 `default.xml`（分機互打），未同步修正 `public.xml`（外線轉分機）。

**修復**（`/etc/freeswitch/dialplan/public.xml`）：
```xml
<!-- 修改前 -->
<condition field="destination_number" expression="^(10[01][0-9])$">

<!-- 修改後：涵蓋 1000–1999，與 default.xml 的 Local_Extension 範圍一致 -->
<condition field="destination_number" expression="^(1[0-9]{3})$">
```

**驗證方式**：
```bash
fs_cli -x "reloadxml"
```
外線撥打 1210，`fs_cli` log 應出現：
```
Processing ... ->1210 in context public
EXECUTE ... transfer(1210 XML default)
Processing ... ->1210 in context default
EXECUTE ... bridge(user/1210@192.168.100.209)
```
而非直接 `has executed the last dialplan instruction, hanging up`。

**提醒**：日後若再調整分機號段範圍，`default.xml`（內撥）與 `public.xml`（外線轉接）的 `destination_number` 正則需**同步修改**，並檢查 `public_conference_extensions`（35xx 會議室）等其他外線轉接規則有無同樣寫死範圍的問題。

---

### ✅ 外線轉分機修復後改「直接進語音信箱」（Codec 不相容，`INCOMPATIBLE_DESTINATION`）（2026-07-02）

**現象**：上一項修復後外線不再斷線，但撥打 1210 會跳過響鈴，直接進入語音信箱；分機互打 1126→1210 仍可正常響鈴接通。

**根本原因**：兩種通話路徑對 `bridge(user/1210@192.168.100.209)` 的 originate 結果不同：

| | 分機互打 | 外線轉分機 |
|---|---|---|
| 路徑 | `sofia/internal`(1126) → `sofia/internal`(1210) | `sofia/external`(PSTN) → `transfer` → `sofia/internal`(1210) |
| originate 結果 | `Ring-Ready` → `answered` | `Hangup ... INCOMPATIBLE_DESTINATION` |

`INCOMPATIBLE_DESTINATION` 代表 SDP 協商找不到共同 codec。外線來話（AudioCodes SBC `192.168.100.220` → Microsoft PSTN Hub）帶入的 codec 與分機 1210 話機支援的 codec 沒有交集，導致 originate 失敗。因 dialplan 設有 `continue_on_fail=true`，originate 失敗後轉入 `bridge(loopback/app=voicemail...)` 語音信箱保底流程，造成「不響鈴直接進語音信箱」的現象。

**修復**：於 **AudioCodes（`192.168.100.220`）** 端強制外線通話 codec 使用 **G.711 A-law（PCMA）**，統一雙邊 codec，排除協商失配問題。修改後實測外線與分機互打皆可正常響鈴、通話。

**驗證方式**：外線撥打 1210，`fs_cli` log 應出現：
```
Ring-Ready sofia/internal/1210@...
Channel [sofia/internal/1210@...] has been answered
```
而非 `INCOMPATIBLE_DESTINATION` / `Originate Failed`。可搭配 `sofia global siptrace on` 抓 SDP，確認雙邊 Offer/Answer 皆協商出 `PCMA`。

**提醒**：
- FreeSWITCH 端的 `bypass_media` / `proxy_media`（`sip_profiles/external/*.xml`）與 `global_codec_prefs`（`vars.xml`）在本次未變動；問題根因在上游 SBC（AudioCodes）送出的 codec 清單與內部話機不相容，故直接於 SBC 端統一 codec 為根治方式，不需異動 FreeSWITCH 網路/Codec 相關設定（此類設定屬 Dashboard `VARS_BLACKLIST`，本就禁止透過網頁編輯）。
- 若日後其他分機/話機出現同樣 `INCOMPATIBLE_DESTINATION`，優先檢查話機支援的 codec 清單是否含 `PCMA`/`PCMU`，或上游 SBC 是否又改回其他 codec。

---

**測試結果**：以上兩項修改已通過測試驗證，外線來電可正常轉接分機 1210 並響鈴接通，分機互打不受影響。
