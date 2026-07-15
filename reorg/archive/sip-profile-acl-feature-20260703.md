# SIP Profile 進階設定 / 信任 SBC 清單功能實作總結

**實作日期**：2026-07-03
**功能描述**：新增 SIP Profile（internal/external）白名單參數編輯、跨網段內部 SBC 信任清單管理（acl.conf.xml）、NAT Profile 新增精靈三項功能，供網頁直接管理 sip profile / gateway 相關 XML，取代原本純 SSH 手動編輯的方式。

---

## 背景與動機

- 2026-07-02 曾發生 `external.xml` 的 `ext-sip-ip`/`ext-rtp-ip` 誤用 STUN IP 導致內部 SBC（192.168.100.220）通話 30 秒後斷線的 bug（詳見 `call-routing-1210-fix-part2-20260702.md`）
- 未來會新增跨網段的內部 SBC（例如 172.16.20.2），以及需要公網 IP 的 NAT trunk，若繼續用自由文字編輯 sip profile XML，風險與前次 bug 同類
- 設計原則：**把「會變動的資料」跟「決定要不要信任/如何運作的邏輯」分開**——資料類（IP 清單、白名單安全參數）開放網頁編輯，結構性/高風險決策（context、ACL 指向、TLS、埠號綁定）維持鎖定、需 SSH

---

## 架構設計

| 模組 | 方案 | 說明 |
|---|---|---|
| SIP Profile 參數 | 白名單／黑名單分離（比照 `vars.py`） | 只開放低風險參數（sip-trace、debug、codec 協商模式等），高風險參數（ext-sip-ip、TLS、ACL 指向等）唯讀顯示 + 403 |
| 多網段內部 SBC 信任 | 自訂 ACL 清單（`acl.conf.xml` 的 `trusted_sbc`） | 不依賴 `localnet.auto` 自動偵測（只認同網段來源），改為明確列舉信任的 IP/CIDR，新增/移除 SBC 只是加減一行，不用碰 profile 結構參數 |
| NAT Profile 新增 | 固定安全模板精靈 | `ext-sip-ip`/`ext-rtp-ip` 僅開放 `auto`／`stun:`／固定 IP 三種模式選擇，不開放自由填其他黑名單欄位 |

---

## 修改/新增檔案

### 1. `routers/sip_profile.py`（新增）

- `GET /api/sip-profile`：列出所有 profile 檔名
- `GET /api/sip-profile/{name}`：回傳白名單可編輯值 + 黑名單唯讀值
- `POST /api/sip-profile/{name}`：更新白名單參數，寫入後自動 `reloadxml` + `sofia profile {name} restart`
- `POST /api/sip-profile/nat-wizard`：建立新 NAT profile，固定模板 + 埠號衝突檢查
- `DELETE /api/sip-profile/{name}`：刪除非核心 profile（internal/external 禁止刪除）

白名單參數（`SIP_PARAM_WHITELIST`）：`sip-trace`、`sip-capture`、`debug`、`log-auth-failures`、`dtmf-duration`、`nonce-ttl`、`rtp-timeout-sec`、`rtp-hold-timeout-sec`、`inbound-codec-negotiation`。

黑名單參數（`SIP_PARAM_BLACKLIST`，唯讀）：`context`、`sip-port`、`rtp-ip`/`sip-ip`、`ext-rtp-ip`/`ext-sip-ip`、`local-network-acl`、TLS 全系列、`auth-calls`、`record-template` 等（含造成前次斷線 bug 的參數）。

### 2. `routers/acl.py`（新增）

- `GET /api/acl/trusted-sbc`：列出信任清單，並即時查詢 FreeSWITCH ACL 記憶體判斷結果（`active` 欄位）
- `POST /api/acl/trusted-sbc`：新增信任 IP/CIDR
- `PUT /api/acl/trusted-sbc/{old_cidr}`：編輯既有項目（含改 IP 的 rename）
- `DELETE /api/acl/trusted-sbc/{cidr}`：移除，回傳 `still_active_until_restart` 供前端提示尚未真正撤銷
- `POST /api/acl/apply-restart`：背景重啟 FreeSWITCH 服務讓 ACL 變更生效，通話中需二次確認

### 3. `static/js/sip-profile.js`（新增）

三分頁 Hub（比照 `dialplan.js` 版面）：Profile 參數 / 信任 SBC 清單 / 新增 NAT Profile。信任 SBC 清單頁附「待重啟」狀態列 + 一鍵重啟套用按鈕。

### 4. `server.py` / `init.js` / `index.html`（掛載）

```python
# server.py
from routers import (..., sip_profile, acl)
app.include_router(sip_profile.router)
app.include_router(acl.router)
```
```javascript
// init.js pages{}
sip_profile: { render: renderSipProfile, title: 'SIP Profile 進階設定' },
```
```html
<!-- index.html -->
<div class="nav-item" data-page="sip_profile" onclick="switchPage('sip_profile')">
  <span class="nav-icon">📡</span> SIP Profile 進階設定
</div>
<script src="/static/js/gateway.js"></script>
<script src="/static/js/sip-profile.js"></script>
```

---

## 測試中發現並修復的問題

### ① IP/CIDR 欄位看不到（CSS）

- **原因**：儀表板是淺色主題（`--panel:#ffffff`），表格儲存格誤用深色主題慣用的 `color:#fff` 白字，白字疊白底不可見
- **修復**：改用 `color:var(--label)`

### ② `acl.conf.xml` 縮排跑掉

- **原因**：`tree.write()` 未加 `pretty_print=True`，lxml 新增節點時不會重算既有格式，新節點擠成一行
- **修復**：`tree.write(ACL_XML_PATH, xml_declaration=True, encoding="UTF-8", pretty_print=True)`

### ③ `ACL 判斷邏輯` 需整個服務重啟才生效（架構限制，非 bug）

- `acl.conf.xml` 的判斷是 FreeSWITCH core 啟動時建置的記憶體 cache，`reloadxml` 對它無效，**新增與刪除皆須整個服務重啟**才會真正套用
- 因此新增了「待生效」即時偵測（`_test_acl_live()` 直接呼叫 `esl.api("acl <ip> trusted_sbc")` 交叉驗證，而非只看 XML 是否寫入），以及一鍵重啟按鈕、刪除時的風險提示

### ④ `local-network-acl` 認知釐清（非 bug）

- `local-network-acl` 只是 NAT 判斷邏輯（決定要不要套用 IP 改寫），**不是**存取控制；來電准不准進來是 `apply-inbound-acl`/dialplan 在管
- 澄清後確認遷移到 `trusted_sbc` 的目的是解決跨網段 SBC 的 NAT 誤判，不影響現有來電接通行為

### ⑤ FastAPI 單一 `Body` 參數未 `embed`

- **原因**：`apply_restart(confirm: bool = Body(False))` 只有一個 Body 參數時 FastAPI 不會自動 embed，前端送 `{"confirm": false}` 物件格式會被判為 422，錯誤訊息陣列被當字串印出變成 `[object Object]`
- **修復**：`confirm: bool = Body(False, embed=True)`

### ⑥ `systemctl restart` 同步阻塞被 `subprocess` 超時砍斷

- **原因**：FreeSWITCH graceful shutdown 常超過 30 秒，`subprocess.run(..., timeout=30)` 逾時送出 SIGTERM，指令被腰斬（`exit -15`）
- **修復**：改用 `subprocess.Popen(..., start_new_session=True)` 背景執行、不等待，前端改為 20 秒後自動刷新狀態

### ⑦ 手動修改時的低級錯誤（人為）

- `_write_and_reload` 誤打成 `write_and_reload`（少底線）→ `NameError`，後端回傳非 JSON 的 500，前端 `res.json()` 直接拋出解析錯誤
- `except Exception:` 少了 `as e` 卻在區塊內用了 `e` → 進入 except 分支時又拋一次 `NameError`，被外層吞掉，行為被掩蓋
- **修復**：補回底線與 `as e`；並在前端 `res.json()` 外包 `try/catch`，非 JSON 回應時顯示明確的 HTTP 狀態碼而非解析錯誤原文

---

## 驗證方式

```bash
# SIP Profile 白名單參數
curl -s http://127.0.0.1:3000/api/sip-profile/internal | python3 -m json.tool

# 信任 SBC 清單 + 即時生效狀態
curl -s http://127.0.0.1:3000/api/acl/trusted-sbc | python3 -m json.tool
fs_cli -x "acl <測試IP> trusted_sbc"     # 交叉驗證是否與 Dashboard 顯示的 active 一致

# NAT Profile 建立後確認狀態
fs_cli -x "sofia status profile <name>"  # 應為 RUNNING
```

---

**測試結果**：已通過完整測試驗證，包含新增/編輯/刪除信任 SBC、Profile 白名單參數編輯、待生效狀態顯示與一鍵重啟套用，功能運作符合預期。
