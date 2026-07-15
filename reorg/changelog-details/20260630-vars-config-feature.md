# 全域系統設定（vars.xml）功能新增 — 2026-06-30

> 原始來源：`vars-config-feature-20260630.md`；現況已併入 `feature-vars.md`

## 需求

過去要修改 FreeSWITCH 全域常用設定只能 SSH 進機器直接編輯 `/etc/freeswitch/vars.xml`。新增網頁端「全域變數」設定頁，讓常用、低風險的變數可以直接在 Dashboard 上修改，沿用既有的 `reloadxml` 機制立即套用，採白名單機制而非自由編輯（詳見 `feature-vars.md`）。

## 測試紀錄

| 項目 | 結果 |
|---|---|
| 白名單解析（只回傳允許變數，排除 `cmd="stun-set"`、黑名單變數） | ✅ 通過（lxml 單元測試） |
| 更新單一/多個白名單變數，其餘變數不受影響 | ✅ 通過 |
| 黑名單變數寫入請求 → 403 拒絕 | ✅ 通過 |
| 不在白名單的未知 key → 400 拒絕 | ✅ 通過 |
| `bool`/`select` 型別值驗證（無效值拒絕） | ✅ 通過 |
| 實機修改 `default_password` 後分機可用新密碼重新註冊 | ✅ 通過（使用者實測） |
| `hold_music` 選擇音檔彈窗（music + custom 試聽、選用） | ✅ 通過（使用者實測） |
| `default_country` 欄位移除後不再出現於頁面 | ✅ 通過（使用者實測） |

## 後續可擴充方向

若日後需要「依國碼/區碼自動轉換撥號規則」，這屬於 Dialplan 邏輯而非 vars.xml 變數，需另外設計 Dialplan extension regex 轉換規則，建議另開功能討論，不混入此頁範疇。

詳細白名單/黑名單清單、驗證邏輯已完整併入 `feature-vars.md`。
