# SIP Profile 進階設定 / SIPTrunk ACL 信任清單

> 對應頁面：管理 → SIP Profile 進階設定（`static/js/sip-profile.js`）｜系統 → SIPTrunk ACL 信任清單（`static/js/acl.js`）
> 後端：`routers/sip_profile.py` + `routers/acl.py`
> 演變歷史：[20260703 SIP Profile/ACL 功能與踩坑記錄](../changelog-details/20260703-sip-profile-acl-feature.md) · [20260717 ACL 頁面獨立化重構](../changelog-details/20260717-owned-ext-clear-and-acl-calls-refactor.md)

## 設計原則

把「會變動的資料」跟「決定要不要信任/如何運作的邏輯」分開：資料類（IP 清單、白名單安全參數）開放網頁編輯，結構性/高風險決策（context、ACL 指向、TLS、埠號綁定）維持鎖定、需 SSH。此設計是為了避免重演 2026-07-02 `external.xml` 的 `ext-sip-ip`/`ext-rtp-ip` 誤用 STUN IP 導致斷線的同類問題（見 `feature-gateway.md` 相關踩坑）。

## 2026-07-17 更新：ACL 信任清單改為獨立頁面

**原本**：「SIP Profile 進階設定」是三分頁 Hub（Profile 參數 / 信任 SBC 清單 / 新增 NAT Profile），信任 SBC 清單掛在 Tab 2。

**問題**：Tab 2 呼叫的後端端點（`routers/acl.py`）檢查的是 `Module.ACL` 權限，但整個頁面掛在 `sip_profile` 模組底下（側邊欄可見性只看 `sip_profile` 權限）。對照 `feature-permissions-auth.md` 的權限矩陣，`Technical Support` 群組有 `sip_profile` 讀寫權限（看得到這個頁面），但 `acl` 權限是 `none`——實測會出現「看得到頁籤，點進去打 API 卻吃 403」的不一致體驗，也是 `PROJECT-OVERVIEW.md` 已知待處理事項第 10 點記錄的根因之一。

**現況**：
- 「SIP Profile 進階設定」精簡為**兩分頁**：Profile 參數 / 新增 NAT Profile（Tab 2 已完整移除）
- 信任 SBC 清單獨立成側邊欄「系統」分類下的新頁面「**SIPTrunk ACL 信任清單**」（`data-page="acl"`，`static/js/acl.js`），純粹依照 `acl` 模組權限顯示/隱藏，不再受 `sip_profile` 頁面權限牽連
- 兩邊呼叫的後端 API 完全相同（`/api/acl/trusted-sbc*`），只是入口與權限判斷依據不同

## 「SIP Profile 進階設定」兩分頁

| Tab | 說明 |
|---|---|
| Profile 參數 | SIP Profile（internal/external）白名單參數編輯 |
| 新增 NAT Profile | 固定安全模板精靈 |

### Tab 1：Profile 參數

白名單（`SIP_PARAM_WHITELIST`，可編輯，低風險）：`sip-trace`、`sip-capture`、`debug`、`log-auth-failures`、`dtmf-duration`、`nonce-ttl`、`rtp-timeout-sec`、`rtp-hold-timeout-sec`、`inbound-codec-negotiation`。

黑名單（`SIP_PARAM_BLACKLIST`，唯讀顯示）：`context`、`sip-port`、`rtp-ip`/`sip-ip`、`ext-rtp-ip`/`ext-sip-ip`、`local-network-acl`、TLS 全系列、`auth-calls`、`record-template` 等（含造成前次斷線 bug 的參數）。

更新後自動 `reloadxml` + `sofia profile {name} restart`。

### Tab 2：新增 NAT Profile 精靈

固定模板，`ext-sip-ip`/`ext-rtp-ip` 僅開放 `auto`／`stun:`／固定 IP 三種模式選擇，不開放自由填其他黑名單欄位，含埠號衝突檢查。

## 「SIPTrunk ACL 信任清單」獨立頁面（`trusted_sbc`）

只管理 `acl.conf.xml` 裡 `trusted_sbc` 這一個自訂 list，不開放編輯既有系統清單（`domains`、`localnet.auto` 等維持原樣）。用途：內部 SBC/SIP trunk 可能分佈在不同網段（如 `192.168.100.220`、`172.16.20.2`），`local-network-acl` 若仍用 `localnet.auto`（僅自動信任同網段來源），跨網段 SBC 不會被判斷為內部裝置——改用本清單明確列舉信任來源，新增/移除只需增減 IP，不必碰 profile 參數本身。

**重要限制（架構本質，非 bug）**：`acl.conf.xml` 的判斷是 FreeSWITCH core 啟動時建置的記憶體 cache，`reloadxml` 對它無效，**新增與刪除皆須整個服務重啟**才真正套用。因此每筆清單項目都有「待生效」狀態偵測（`_test_acl_live()` 直接呼叫 `esl.api("acl <ip> trusted_sbc")` 交叉驗證，而非只看 XML 是否寫入），配合一鍵重啟按鈕。

**概念澄清**：`local-network-acl` 只是 NAT 判斷邏輯（決定要不要套用 IP 改寫），**不是**存取控制；來電准不准進來是 `apply-inbound-acl`/dialplan 在管。遷移到 `trusted_sbc` 的目的是解決跨網段 SBC 的 NAT 誤判，不影響現有來電接通行為。

## 後端 API

### `routers/sip_profile.py`

| Method | Endpoint | 說明 |
|---|---|---|
| `GET` | `/api/sip-profile` | 列出所有 profile 檔名 |
| `GET` | `/api/sip-profile/{name}` | 白名單可編輯值 + 黑名單唯讀值 |
| `POST` | `/api/sip-profile/{name}` | 更新白名單參數 |
| `POST` | `/api/sip-profile/nat-wizard` | 建立新 NAT profile |
| `DELETE` | `/api/sip-profile/{name}` | 刪除非核心 profile（internal/external 禁止刪除） |

### `routers/acl.py`

| Method | Endpoint | 說明 |
|---|---|---|
| `GET` | `/api/acl/trusted-sbc` | 列出信任清單 + 即時 ACL 判斷結果（`active`），需 `acl` 模組讀取權限 |
| `POST` | `/api/acl/trusted-sbc` | 新增信任 IP/CIDR，需 `acl` 模組新增權限 |
| `PUT` | `/api/acl/trusted-sbc/{old_cidr}` | 編輯（含改 IP 的 rename），需 `acl` 模組更新權限 |
| `DELETE` | `/api/acl/trusted-sbc/{cidr}` | 移除，回傳 `still_active_until_restart`，需 `acl` 模組刪除權限 |
| `POST` | `/api/acl/apply-restart` | 背景重啟 FreeSWITCH 讓 ACL 生效，通話中需二次確認（`confirm` body 參數），需 `acl` 模組更新權限 |

`apply-restart` 用 `subprocess.Popen(..., start_new_session=True)` 背景執行、不等待（FreeSWITCH graceful shutdown 常超過 30 秒，同步等待會被逾時砍斷），前端 20 秒後自動刷新狀態。

## 驗證方式

```bash
curl -s http://127.0.0.1:3000/api/sip-profile/internal | python3 -m json.tool
curl -s http://127.0.0.1:3000/api/acl/trusted-sbc | python3 -m json.tool
fs_cli -x "acl <測試IP> trusted_sbc"     # 交叉驗證是否與 Dashboard 顯示的 active 一致
fs_cli -x "sofia status profile <name>"  # NAT Profile 建立後應為 RUNNING
```
