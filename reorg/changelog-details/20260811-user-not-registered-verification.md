# USER_NOT_REGISTERED 查證：確認為 FreeSwitch 官方範例的無害正常行為（2026-08-11）

> 對應 `PROJECT-OVERVIEW.md` 已知待處理事項第 5 點（原記錄）、第 12 點（重新查證待辦）。
> 本次查證是在 `changelog-details/20260811-log-rotate-hup-fix.md` 修復日誌寫入管線之後才有辦法真正進行的——log 修復前這個問題已停擺超過一個月，先前「無害可忽略」的結論從未有實機證據佐證。

## 一、背景

`PROJECT-OVERVIEW.md` 原記錄：「USER_NOT_REGISTERED 警告：每通電話出現的無害 NOTICE，`mod_sofia` 內部查詢順序造成，不影響通話品質，可忽略。」這句話本身沒有附任何佐證，查證當下才發現整個 log 系統已停擺超過一個月（見 `20260811-log-rotate-hup-fix.md`），修復後才有辦法真正撈到資料驗證這個結論是否成立。

## 二、比對樣本

log 修復並實際撥測試電話後，撈出當時所有 10 通測試通話的完整軌跡：

| # | UUID（前 8 碼） | 通話方向 | 撥號路徑 | 結果 |
|---|---|---|---|---|
| 1 | ed6ece28 | 1210 撥出 | 非 `bridge(user/...)` 語法 | `NORMAL_CLEARING`，無 `USER_NOT_REGISTERED` |
| 2 | b223fc34 | 1126→1210 | context 誤設為 `TC-ACSBC`（另一個插曲，見下方說明），連 dialplan 都未進入 bridge | `NO_ROUTE_DESTINATION`，無 `USER_NOT_REGISTERED` |
| 3 | 2fce6862 | 同上 | 同上 | 同上 |
| 4 | c90436c8 | 同上 | 同上 | 同上 |
| 5 | **3ae0b80f** | 1210→1126 | `bridge(user/1126@192.168.100.209)` | **觸發 `USER_NOT_REGISTERED`** → 同一秒內 fallback 成功接通 |
| 6 | ef44af75 | 1126→1210（context 尚未修正） | 同 #2 | `NO_ROUTE_DESTINATION` |
| 7 | c6212424 | 同上 | 同上 | 同上 |
| 8 | **0ea9d26f** | 1126→1210（context 已修正回 `default`） | `bridge(user/1210@192.168.100.209)` | **觸發 `USER_NOT_REGISTERED`** → 同一秒內 fallback 成功接通 |

**結論**：只有真正執行到 `bridge(user/<分機>@<網域>)` 這行撥號語法時才會觸發，且每次都在同一時間戳記內自動 fallback 成功、通話正常完成，使用者完全無感。

## 三、根因：FreeSwitch 官方 vanilla 範例的既有行為

追到撥號語法來源：

```bash
grep -B10 "bridge" /etc/freeswitch/dialplan/default.xml
```

確認來自 `/etc/freeswitch/dialplan/default.xml` 的 `Local_Extension` extension：

```xml
<extension name="Local_Extension">
  <condition field="destination_number" expression="^(1[0-9]{3})$">
    ...
    <action application="bridge" data="user/${dialed_extension}@${domain_name}"/>
    ...
  </condition>
</extension>
```

比對整份 `default.xml` 的內容（開頭英文版權/使用說明註解、感恩節/聖誕節等美國假日路由範例、`echo`/`milliwatt`/`fax_receive` 等測試 extension），確認**這整份檔案就是 FreeSwitch 官方安裝包隨附的 vanilla 範例設定**，不是本專案自訂邏輯——這也解釋了為什麼 `feature-dialplan.md` 從一開始就把這個檔案標記為「系統內建 Tab（唯讀）」，是專案自己的設計原則，避免有人動到 FreeSwitch 官方維護的參考設定。

`user/<分機>@<網域>` 是 FreeSwitch 官方建議的內線撥號標準寫法，好處是不受分機實際註冊 IP/port 變動影響（漫遊、NAT、多裝置註冊皆可正確處理）。`USER_NOT_REGISTERED` 是 `mod_sofia` 底層依序檢查多個 sofia profile（本機同時有 `internal`、`external` 兩個 profile）時，尚未檢查到正確 profile 前留下的中繼記錄，屬於 FreeSwitch 社群裡廣為人知的正常兩階段行為，非本系統獨有問題。

## 四、途中意外插曲：1126 分機 context 誤設定

排查過程中發現分機 1126 的 Context 欄位被設成 `TC-ACSBC`——但 `/etc/freeswitch/dialplan/` 底下**從未存在過**這個 context 資料夾，導致 1126 撥出的電話連 dialplan 都進不去，直接 `NO_ROUTE_DESTINATION`（表 #2/#3/#4/#6/#7）。使用者已自行把 context 改回 `default` 排除。

這與 `USER_NOT_REGISTERED` 是兩個完全獨立的問題，只是剛好在同一批測試電話中一起被發現。`feature-extensions.md` 提到「編輯模式若目前值不在清單中，仍保留原值供選擇並標示警語，避免非預期變更」是針對「context 資料夾事後被刪除」的情境設計，這次是「一開始就選到一個從未存在過的 context」，目前沒有對應的前端防呆（例如儲存前檢查 context 是否真的存在於 `/api/dialplan/contexts` 清單）。是否要補這個防呆，使用者表示之後再討論，本次不處理。

## 五、結論

- `USER_NOT_REGISTERED` **確認為無害**，且這次終於有完整實機證據佐證（觸發條件、根因、官方出處三方確認一致），原記錄的判斷方向正確，只是先前缺乏驗證
- **不修改** dialplan：`default.xml` 是 FreeSwitch 官方 vanilla 範例，`user/` 撥號語法的價值（容錯漫遊/NAT/多裝置註冊）遠高於消除一行無害 log 雜訊的價值；若要繞過會犧牲容錯能力（例如改用 `${sofia_contact(...)}` 直接指定連線位置，分機離線時會直接撥號失敗、無 fallback）
- 使用者確認不需要進一步處理（不修 dialplan、不加前端 log 過濾），本次查證正式結案

## 六、待辦（非本次處理範圍，僅記錄）

- 1126 誤設定 context 的插曲，是否要在分機管理表單加上「儲存前檢查 context 是否存在」的防呆，使用者表示之後再討論
