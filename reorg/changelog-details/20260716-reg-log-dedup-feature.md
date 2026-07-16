# 登錄記錄（reg_log）去重：分機定期刷新註冊不再視為新登入（2026-07-16）

> 對應 `feature-logs.md` 的「🔐 登錄記錄」Tab。

## 現象

「登錄記錄」頁面同一分機每隔幾分鐘就多一筆 `REGISTER`，但使用者實際上只登入了一次（screenshot 顯示分機 1210 從 11:27 到 12:36 之間每 5 分鐘一筆，IP/協定完全相同）。

## 根本原因

分機話機/軟體電話為維持 NAT 穿透與註冊有效，會在到期前自動送出 `REGISTER` 刷新請求（keepalive），這是正常 SIP 行為。FreeSwitch 每收到一次都會觸發 ESL `REGISTER` 事件，`core/runtime.py` 的 `write_reg_log()`（`20260715-reg-log-persistence.md` 新增）原本是「來一筆事件就寫一筆」，沒有區分「首次登入」與「到期前自動刷新」，導致同一分機的每次 keepalive 都在 `reg_log` SQLite 多一筆記錄。

## 修復

`write_reg_log()` 新增模組層級去重狀態 `_last_reg_state: dict`（`ext -> {event, ip, proto}`），只有下列情況才真正寫入一筆記錄：

1. 服務啟動後該分機第一次註冊
2. 先前是 `UNREGISTER`，這次重新 `REGISTER`（真正的重新登入）
3. `REGISTER` 的來源 IP 或協定跟上一筆不同（換裝置/換網路）
4. `UNREGISTER` 一律照寫（狀態改變）

```python
_last_reg_state: dict = {}

def write_reg_log(ext, event, ip, proto, ts_ms):
    ...
    prev = _last_reg_state.get(ext)
    if (event == "REGISTER" and prev and prev.get("event") == "REGISTER"
            and prev.get("ip") == ip and prev.get("proto") == proto_up):
        return
    _last_reg_state[ext] = {"event": event, "ip": ip, "proto": proto_up}
    ...
```

## 已知取捨

- 去重狀態存在記憶體，服務重啟後歸零（跟 `state.ext_status` 等其他執行期狀態一致），重啟後該分機下一次收到的 `REGISTER`（不論是否為刷新）會照寫一筆，之後才恢復去重效果
- 只比對「上一筆」狀態，不回頭掃描歷史記錄，設計上刻意簡化以避免每次寫入都要查 SQLite

## 修改的檔案

- `core/runtime.py`：`write_reg_log()` 加去重邏輯（`update25.sh`）

## 驗證方式

```bash
python3 -m py_compile core/runtime.py
systemctl restart fs-dashboard
```

瀏覽器/實機測試：
1. 分機長時間上線（跨過其註冊刷新週期），登錄記錄不再每隔幾分鐘多一筆
2. 分機登出（`UNREGISTER`）再重新登入（`REGISTER`）→ 正常各寫入一筆
3. 分機換 IP/協定重新註冊 → 正常寫入新的一筆

**測試結果**：已於 production server（`debian-freeswitch`）實際執行 `update25.sh` 並 `systemctl restart` 後，依上述步驟測試通過，使用者確認登錄記錄不再重複灌入。

## 附帶記錄：本次腳本編號誤植教訓

撰寫本次修復的第一版腳本時，誤將其編號為 `update23.sh`，但 server 上該編號早已被另一支無關的腳本（`Dialplan Context 切換 UI` 文件收尾）使用，`update24.sh` 也已存在（導覽列權限稽核結案）。原因是判斷「下一個可用編號」時只依賴 changelog-details 的既有記錄，而 changelog 文件本身有記錄滯後的情況（最後 1～2 支腳本常常還來不及補文件），導致誤判。

後續已改為 `update25.sh` 銜接，未造成任何 commit 遺失（`update23.sh`/`update24.sh` 原本的 commit 都完好保留）。已於 `ops-github-workflow.md`「已知編號歷史」補上這次教訓，往後產生新腳本前，一律先請使用者在 server 上實際執行 `ls updateN/*.sh update*.sh 2>/dev/null` 確認真正的最大編號，不再只憑文件記錄推斷。
