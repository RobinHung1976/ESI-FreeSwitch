## 除錯

> 原始來源：`sip-profile-acl-feature-20260703.md`（測試中發現並修復的問題；現況已併入 `feature-sip-profile-acl.md`）

### ✅ IP/CIDR 欄位看不到（CSS 白字疊白底）（2026-07-03）

**原因**：儀表板是淺色主題（`--panel:#ffffff`），表格儲存格誤用深色主題慣用的 `color:#fff` 白字。
**修復**：改用 `color:var(--label)`。

### ✅ `acl.conf.xml` 縮排跑掉（2026-07-03）

**原因**：`tree.write()` 未加 `pretty_print=True`，lxml 新增節點時不會重算既有格式。
**修復**：`tree.write(ACL_XML_PATH, xml_declaration=True, encoding="UTF-8", pretty_print=True)`。

### ℹ️ ACL 判斷邏輯需整個服務重啟才生效（架構限制，非 bug）（2026-07-03）

`acl.conf.xml` 的判斷是 FreeSWITCH core 啟動時建置的記憶體 cache，`reloadxml` 對它無效，新增與刪除皆須整個服務重啟才會真正套用。因此新增了「待生效」即時偵測（`_test_acl_live()`）、一鍵重啟按鈕、刪除時的風險提示。

### ℹ️ `local-network-acl` 認知釐清（非 bug）（2026-07-03）

`local-network-acl` 只是 NAT 判斷邏輯（決定要不要套用 IP 改寫），不是存取控制；來電准不准進來是 `apply-inbound-acl`/dialplan 在管。釐清後確認遷移到 `trusted_sbc` 的目的是解決跨網段 SBC 的 NAT 誤判，不影響現有來電接通行為。

### ✅ FastAPI 單一 `Body` 參數未 `embed`（2026-07-03）

**原因**：`apply_restart(confirm: bool = Body(False))` 只有一個 Body 參數時 FastAPI 不會自動 embed，前端送 `{"confirm": false}` 物件格式被判為 422，錯誤訊息陣列被當字串印出變成 `[object Object]`。
**修復**：`confirm: bool = Body(False, embed=True)`。

### ✅ `systemctl restart` 同步阻塞被 `subprocess` 超時砍斷（2026-07-03）

**原因**：FreeSWITCH graceful shutdown 常超過 30 秒，`subprocess.run(..., timeout=30)` 逾時送出 SIGTERM，指令被腰斬（`exit -15`）。
**修復**：改用 `subprocess.Popen(..., start_new_session=True)` 背景執行、不等待，前端改為 20 秒後自動刷新狀態。

### ✅ 手動修改時的低級錯誤（2026-07-03）

- `_write_and_reload` 誤打成 `write_and_reload`（少底線）→ `NameError`，後端回傳非 JSON 的 500，前端 `res.json()` 直接拋出解析錯誤
- `except Exception:` 少了 `as e` 卻在區塊內用了 `e` → 進入 except 分支時又拋一次 `NameError`，被外層吞掉，行為被掩蓋

**修復**：補回底線與 `as e`；並在前端 `res.json()` 外包 `try/catch`，非 JSON 回應時顯示明確的 HTTP 狀態碼而非解析錯誤原文。

---

**測試結果**：已通過完整測試驗證，包含新增/編輯/刪除信任 SBC、Profile 白名單參數編輯、待生效狀態顯示與一鍵重啟套用，功能運作符合預期。
