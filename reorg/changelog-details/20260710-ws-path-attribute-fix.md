## 除錯

### ✅ 左下角「連線至 FreeSwitch」狀態燈顯示紅燈，但 fs-dashboard.service / freeswitch.service 皆正常運作中（2026-07-10）

> 原始來源：`Bug-Fix-Notes-20260710.md`

**現象**：`systemctl status fs-dashboard.service` 與 `systemctl status freeswitch.service` 皆顯示 `active (running)`，但前端左下角連線狀態燈仍為紅燈。`journalctl` 中持續出現：

```
uvicorn[106315]: connection handler failed
uvicorn[106315]: Traceback (most recent call last):
uvicorn[106315]:   File "/opt/myapp/venv/lib/...
uvicorn[106315]:     await self.handler(connection)
uvicorn[106315]:   File "/opt/fs-dashboard/core/runtime.py"
uvicorn[106315]:     query = parse_qs(urlparse(websocket.path).query)
uvicorn[106315]: AttributeError: 'ServerConnection' object has no attribute 'path'
```

**根本原因**：

- `requirements.txt` 的 `websockets` 套件未鎖版本，環境重裝/重建（例如自動備份腳本的 `pip install`）時抓到最新的 v14+
- `websockets` v14 起，asyncio 版伺服器實作改用新的 `ServerConnection` 類別取代舊版 `WebSocketServerProtocol`，拿掉了 `.path` 屬性
- `core/runtime.py` 的 `ws_handler()` 為了驗證 WebSocket JWT 登入 token（`ws://host:8080/?token=<JWT>`），用舊寫法 `urlparse(websocket.path).query` 解析 query string，套件升級後每次瀏覽器建立 WebSocket 連線都會在此行 `AttributeError` 崩潰
- 由於是每個連線各自的 handler 崩潰，並不會讓 `fs-dashboard.service` 這個 process 掛掉，所以 `systemctl status` 顯示一切正常，只有前端連線狀態燈是紅燈，容易誤判為網路或設定問題

**修復**（`core/runtime.py`）：

```python
# 修改前
async def ws_handler(websocket):
    query = parse_qs(urlparse(websocket.path).query)
    ...

# 修改後：websockets >=14 的 ServerConnection 沒有 .path，
# 路徑要從 websocket.request.path 取得（內容含完整 query string，
# 與舊版 .path 行為一致）；同時保留 legacy 版相容 fallback。
async def ws_handler(websocket):
    req = getattr(websocket, "request", None)
    raw_path = req.path if req is not None else getattr(websocket, "path", "")
    query = parse_qs(urlparse(raw_path).query)
    ...
```

另同步鎖定 `requirements.txt` 版本範圍，避免日後環境重建再次因套件大版本升級而炸掉：

```txt
websockets>=14,<17
```

**排查方式**：

```bash
journalctl -u fs-dashboard.service -n 100 --no-pager   # 找到 AttributeError traceback
grep -n "websocket.path\|parse_qs" /opt/fs-dashboard/core/runtime.py
```

**驗證方式**：重新部署 `runtime.py` 並 `systemctl restart fs-dashboard.service` 後，前端左下角「連線至 FreeSwitch」狀態燈恢復綠燈，`journalctl` 不再出現 `connection handler failed` / `AttributeError`。

**提醒**：`requirements.txt` 內未鎖版本的套件（尤其是像 `websockets` 這種常有破壞性 API 變更的套件），在環境重建或自動化流程觸發 `pip install` 時都有機會被動升級，建議關鍵依賴一律鎖定版本區間。

---

**測試結果**：已通過測試驗證，狀態燈恢復正常，連線穩定無再出現例外。
