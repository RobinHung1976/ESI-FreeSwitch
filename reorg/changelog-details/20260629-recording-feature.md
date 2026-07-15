# 錄音功能實作總結 — 2026-06-29

> 原始來源：`recording-feature-20260629.md`（實作過程與踩坑記錄；現況已併入 `feature-recordings.md`）

## 功能描述

針對個別分機設定是否自動錄音，勾選後該分機的所有通話將自動錄音並儲存至伺服器，可在 Dashboard 錄音管理頁面播放、下載、刪除。

## 修改檔案清單

**`server.py`**：`ExtensionData` 新增 `recording_enabled: bool = False`；`write_extension_xml` 寫入 XML variable；`list_extensions` 回傳值新增該欄位。

**`index.html`**：分機表單加入勾選框；`openExtEditor()`/`saveExt()`/`changeExtNumber()` 對應載入與送出邏輯。

**`/etc/freeswitch/dialplan/default.xml`**：在 `global` extension（`continue="true"`）最後一個 `<condition>` 結尾前插入錄音 condition，透過 `user_data()` 讀取分機的 `recording_enabled` 變數。

## 踩坑記錄

| 問題 | 原因 | 解法 |
|---|---|---|
| `default/` 目錄的 XML 未載入 | `X-PRE-PROCESS` 在此版本重啟後不重新掃描目錄 | 直接修改 `default.xml` 本體 |
| Extension 順序問題 | 獨立的 `per_ext_recording` extension 被分機撥號 extension 搶先執行後不再繼續 | 改寫進 `global` extension 的 condition（`global` 有 `continue="true"`） |
| `user_data()` 兩段 condition 方式失敗 | `rec_check` set 後無法跨 extension 使用 | 合併為單一 condition，直接在 `field` 屬性呼叫 `user_data()` |
| `record_session` 執行但無檔案產生 | `RECORD_BRIDGE_REQ=true` 要求必須 bridge 後才寫檔，IVR/未接通通話不 bridge | 移除 `RECORD_BRIDGE_REQ` 設定 |
| 子目錄不存在導致寫入失敗 | `record_session` 不會自動建立日期子目錄 | 在 `record_session` 前加 `system` application 執行 `mkdir -p` |
| Python 腳本 pattern 不匹配 | 檔案內混用 tab 與空格，heredoc 方式難以精確比對 | 改用 `content.find()` 定位位置後直接切割字串插入 |

## FreeSWITCH ESL 診斷指令參考

```bash
cat /etc/freeswitch/directory/default/1126.xml
fs_cli -H 127.0.0.1 -P 8055 -p FSPyAdmin -x "user_data 1126@192.168.100.209 var recording_enabled"
fs_cli -H 127.0.0.1 -P 8055 -p FSPyAdmin -x "domain_exists 192.168.100.209"
fs_cli -H 127.0.0.1 -P 8055 -p FSPyAdmin -x "show registrations"
fs_cli -H 127.0.0.1 -P 8055 -p FSPyAdmin -x "reloadxml"
grep "<UUID>" /var/log/freeswitch/freeswitch.log | grep -v "CRIT"
find /var/lib/freeswitch/recordings/ -type f
```

---

**測試結果**：功能實作完成並驗證通過。
