# 音檔庫（Sounds）

> 對應頁面：管理 → 音檔庫｜前端：`static/js/sounds.js`｜後端：`routers/sounds.py`
> 演變歷史：[20260630 音檔庫功能新增](../changelog-details/20260630-audio-library-feature.md)

## 功能概述

集中管理自訂音檔與檢視系統內建音檔，取代原本 IVR 等功能各自獨立實作上傳邏輯。IVR 共用同一組 API。

- **自訂音檔**：使用者上傳，存放於 `/var/lib/freeswitch/sounds/custom/`，可上傳/刪除/試聽
- **系統內建音檔**：`/usr/share/freeswitch/sounds/` 下 `en`/`es`/`fr`/`pt`/`ru`/`music` 六分類，遞迴掃描（實測 1016 筆），唯讀僅可試聽

## 前端功能

- 分類篩選（全部/自訂/各語系/保留音樂）
- 檔名關鍵字搜尋（debounce 300ms）
- 內建音檔分頁載入（預設 100 筆，「載入更多」），避免一次渲染上千 DOM
- 統一試聽播放器：清單每筆一個播放/暫停按鈕，實際播放共用同一個 `<audio>` 元件，按鈕圖示依 `play`/`pause`/`ended` 真實事件同步
- 刪除自訂音檔前檢查是否被 IVR 引用中，使用中需 `force=true` 二次確認強制刪除

## 後端 API（更新）

| Method | Endpoint | 說明 |
|---|---|---|
| `GET` | `/api/sounds/list?category=` | 列出音檔（`all`/`custom`/內建分類路徑） |
| `POST` | `/api/sounds/upload` | 上傳（格式/大小/重名檢查） |
| `DELETE` | `/api/sounds/{filename}?force=` | 刪除，預設擋下使用中檔案 |
| `GET` | `/api/sounds/usage?filename=` | 查詢被哪些 IVR 引用 |
| `GET` | `/api/sounds/stream?path=` | 試聽串流。**認證**：`<audio src>` 無法自訂 header，改採 header 或 `?token=<JWT>` query string 兩者擇一（`require_permission_media`，2026-07-20 起），前端 `ivr.js`/`sounds.js`/`settings-vars.js` 三處試聽都已補上 `&token=` |

舊端點 `/api/ivr/sounds/*` 仍保留，內部委派呼叫上述共用函式，向下相容（**注意**：`/api/ivr/sounds/stream` 目前仍是 `require_permission` header-only，尚未確認是否有前端用 `<audio src>` 直接呼叫，如新增此類用法需一併改用 `require_permission_media`）。

## 已知限制 / 待擴充（更新）

- 分機編輯/語音信箱問候語選擇器目前僅 IVR 已串接音檔庫，分機/語音信箱尚未串接（`sound_usage()` 目前僅掃描 IVR JSON 設定）
- 見 `changelog-details/20260720-download-endpoint-auth-fix.md`：`/api/sounds/stream` 認證機制變更記錄





## 內建音檔掃描

```python
BUILTIN_SOUND_ROOTS = [
    ('/usr/share/freeswitch/sounds/en', '英文提示音'), ('.../es', '西班牙文'),
    ('.../fr', '法文'), ('.../pt', '葡萄牙文'), ('.../ru', '俄文'), ('.../music', '保留音樂(MOH)'),
]
```
`os.walk()` 遞迴掃描（深度上限 6 層，官方音檔包底下還分語者/取樣率子目錄），每分類最多列出 200 筆（`BUILTIN_LIST_LIMIT`）。

## 安全性

- 檔名白名單正則 `^[\w\-. ]+\.(wav|mp3|ogg|gsm)$`，防路徑穿越
- 上傳限制副檔名 + 20MB 大小上限，重名直接拒絕（409）
- 串流路徑限制在白名單目錄內
- 刪除前查 `usage`

## 已知限制 / 待擴充

- 分機編輯/語音信箱問候語選擇器目前僅 IVR 已串接音檔庫，分機/語音信箱尚未串接（`sound_usage()` 目前僅掃描 IVR JSON 設定）
