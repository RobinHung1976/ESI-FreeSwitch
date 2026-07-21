# 即時日誌 SSE 串流被 401 擋住，畫面完全沒有任何訊息（2026-07-20）

## 現象

系統日誌頁「即時日誌」Tab 完全沒有任何訊息，即使撥打測試電話也一樣。逐層排查：

- FreeSWITCH 服務本身正常運作，`/var/log/freeswitch/freeswitch.log` 確認有即時寫入，撥號當下 `tail -f` 可清楚看到對應的 `sofia.c`/`switch_channel.c` 等記錄
- 直接對 dashboard 後端 curl 測試：
  ```
  curl -N http://127.0.0.1:3000/api/logs/stream
  {"detail":"缺少登入憑證"}
  ```
  確認問題出在 dashboard 的 `/api/logs/stream` 端點本身，回傳 401，不是 FreeSWITCH 或 nginx 的問題

## 根本原因

`/api/logs/stream` 掛了 `dependencies=[Depends(require_permission(Module.LOGS, "read"))]`，這個 dependency 鏈最終落到 `core/auth.py` 的 `get_current_user()`，只認 `Authorization: Bearer <token>` header。

但前端「即時日誌」用瀏覽器原生 `EventSource` API 建立 SSE 連線（`static/js/logs.js` 的 `startLogStream()`），**`EventSource` 無法自訂任何 HTTP header**，所以每次連線都只能是裸的 GET，必然撞上 401。

這跟 `feature-permissions-auth.md` 第八節記載的 WebSocket 認證是同一類瀏覽器 API 限制（`WebSocket` 原生也無法自訂 header），只是這次換成 SSE 才真正被撞到——`20260716-auth-header-missing-fix.md` 那次修復的 4 處 `logs.js` 寫入操作（歷史日期清單/歷史查詢/log rotate）都是走 `fetch()`，可以正常補 header，唯獨即時串流這個用 `EventSource` 建立的連線不在那次修復範圍內。

## 修復

比照 WebSocket 既有解法（`core/runtime.py` 的 `?token=` query string），新增一組 **SSE 專用**的認證機制，不動到其他 18 個模組現有的 header-only 認證行為：

- **`core/auth.py`**：新增 `get_current_user_sse()`（header 或 query string token 兩者擇一皆可通過）與 `require_permission_sse()`
- **`routers/logs.py`**：`/api/logs/stream` 端點的 dependency 從 `require_permission(Module.LOGS, "read")` 改為 `require_permission_sse(Module.LOGS, "read")`
- **`static/js/logs.js`**：`startLogStream()` 建立 `EventSource` 時網址補上 `?token=${encodeURIComponent(getToken())}`

`updateN.sh`：`update39.sh`

## 驗證

```bash
# 後端直接驗證（帶正確 token）
TOKEN=$(curl -s -X POST http://127.0.0.1:3000/api/auth/login \
  -H "Content-Type: application/json" \
  -d '{"username":"admin","password":"<密碼>"}' | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")

curl -N "http://127.0.0.1:3000/api/logs/stream?token=${TOKEN}"
# 預期：持續吐出 data: {"line": ...} 而非 401
```

實測結果：curl 驗證正常收到即時 log 行（含測試通話的完整記錄）。瀏覽器實測「即時日誌」Tab 徽章正常顯示「LIVE · 已連線」，撥打測試電話後畫面即時出現對應行，功能恢復正常。

**測試結果**：已於 production server（`debian-freeswitch`）實際部署並驗證通過。
