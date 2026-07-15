## 除錯

### ✅ 分機登入/登出無法即時更新（需重新整理才顯示）（2026-07-02）

> 原始來源：`Bug-Fix-Notes-20260702.md`

**現象**：分機（如 1126）登入、登出後，卡片狀態不會即時更新，需重新整理網頁才正常顯示。

**根本原因**：`core/runtime.py` 的 `update_ext_status()` 在處理 `REGISTER` / `UNREGISTER` 事件時，於呼叫 `broadcast_ext_status()` **之前**先執行了兩處會拋例外的程式碼，導致推播永遠執行不到：

1. **函式名稱不一致**：呼叫端寫成 `_write_reg_log(...)`，但實際定義的函式是 `write_reg_log(...)`（無底線前綴）→ `NameError`
2. **未限定命名空間**：`write_reg_log()` 內部使用 `REG_LOG_MAX`，但該常數定義在 `core/state.py`（`state.REG_LOG_MAX`），`runtime.py` 只 `from core import state`，未匯入裸名 `REG_LOG_MAX` → `NameError`

因為 `esl_client.py` 呼叫 `_status_callback` 時包在 `try/except` 裡（只印 log、不中斷程式），兩個 `NameError` 都被靜默吞掉，`state.ext_status` 從未真正更新、`EXT_STATUS_UPDATE` 也從未推播。

**修復**（`core/runtime.py`）：
```python
# 修改前
_write_reg_log(reg_user, "REGISTER", network_ip, network_proto, now_ts)
...
if len(state.reg_log) > REG_LOG_MAX:

# 修改後
write_reg_log(reg_user, "REGISTER", network_ip, network_proto, now_ts)
...
if len(state.reg_log) > state.REG_LOG_MAX:
```

**驗證方式**：分機登出/登入後，`journalctl -u fs-dashboard -f` 應成對出現 `[REGISTER]`/`[REG_LOG]` 兩行，且無 `status_callback 錯誤`。

---

### ✅ 部署路徑錯誤：`server.py` 誤放進 `routers/` 子目錄，服務無法啟動（2026-07-02）

**現象**：修改 `core/runtime.py` 後重啟 `fs-dashboard.service`，持續 crash-loop：
```
ERROR:    Error loading ASGI app. Could not import module "server".
```

**根本原因**：部署/複製步驟遺漏，`server.py` 被放進了 `/opt/fs-dashboard/routers/server.py`，而非專案根目錄。`systemd` unit 的 `WorkingDirectory=/opt/fs-dashboard` + `ExecStart=uvicorn server:app` 會直接在根目錄找 `server.py`，找不到就 import 失敗。

**排查方式**：
```bash
cd /opt/fs-dashboard
/opt/myapp/venv/bin/python -c "import server"
# → ModuleNotFoundError: No module named 'server'
find /opt/fs-dashboard -maxdepth 3 -iname "server.py"
# → /opt/fs-dashboard/routers/server.py
```

**修復**：
```bash
mv /opt/fs-dashboard/routers/server.py /opt/fs-dashboard/server.py
cd /opt/fs-dashboard
/opt/myapp/venv/bin/python -c "import server"
systemctl restart fs-dashboard
```

**提醒**：`ModuleNotFoundError: No module named 'server'` 未必是程式碼錯誤，也可能是部署檔案位置錯誤；`journalctl` 的 uvicorn 摘要不會印出完整 traceback，遇到「Could not import module」時，第一步應先用 venv 的 python 直接 `import` 該模組取得真正的錯誤原因。

---

**測試結果**：以上兩項修改已通過測試驗證，分機登入/登出狀態可即時更新，服務可正常啟動。
