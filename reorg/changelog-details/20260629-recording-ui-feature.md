# 錄音管理介面優化總結 — 2026-06-29

> 原始來源：`recording-UI-feature-20260629.md`（實作過程記錄；現況已併入 `feature-recordings.md`）

## `server.py` 修改

1. **新增 Mono 合併音檔功能**：新增函式 `_merge_stereo_to_mono()`，使用 Python 標準庫 `wave` + `array`，將立體聲 WAV 左右聲道平均混成 mono，無需安裝 ffmpeg。輸出至 `.mono/` 目錄，已存在且來源未更新則跳過。
2. `_rec_db()` 新增 `mono_path` 欄位、`idx_callee` 索引，自動 `ALTER TABLE` 補欄位（舊版 DB 升級相容）
3. `_upsert_file_to_db()` 修正：原本 `size` 不變就直接 `return`，導致 mono 永遠不產生。改為 size 不變但 `mono_path` 為空時仍執行混音；WAV 入庫後自動呼叫 `_merge_stereo_to_mono()` 並更新 `mono_path`
4. `sync_recordings_to_db()` 掃描時跳過 `.mono` 目錄，避免 mono 檔被索引進主表
5. `GET /api/recordings` 分機篩選改為 `(caller = ? OR callee = ?)`，避免被叫方錄音找不到；預設每頁筆數從 50 改為 200；回傳新增 `mono_path` 欄位
6. 新增 `GET /api/recordings/stream_mono`：串流播放 mono 合併音檔，DB 記錄缺失則即時補建

## `index.html` 修改

1. 舊卡片樣式（`.rec-card`/`.rec-grid`）改為表格樣式（`.rec-table`），新增聲道切換按鈕與共用播放器樣式
2. 表格欄位重新設計：主叫（藍）/ 被叫（綠）/ 開始時間 / 結束時間 / 時長 / 大小 / 播放（立體音/單聲道切換）/ 下載，個別播放改為頁面底部共用播放器（支援拖拉進度）
3. 時間篩選 UI：原 `datetime-local`（中文系統顯示上午/下午有問題）改為日期日曆選擇 + 上午/下午切換按鈕 + 時/分獨立數字輸入框；進入頁面自動帶入預設值（開始=當下時間，結束=當天 23:59）
4. 分頁：預設每頁 200 筆，可手動輸入（10～1000），切頁後自動捲回頂部
5. 聲道切換連動邏輯：播放切換聲道永遠連動下載；下載切換聲道只改下載不影響播放；mono 尚未產生時按鈕自動 disabled

## Bug 修正記錄

| Bug | 原因 | 修正 |
|---|---|---|
| 合併播放一直顯示「處理中」 | `size` 不變時直接 `return`，跳過混音 | 補判斷 `mono_path` 是否為空 |
| 所有筆數都播放第一筆 | URL 含 `&` 寫進 HTML attribute 被截斷 | URL 改存 JS Map，完全不放 DOM attribute |
| uid 重複導致按鈕無反應 | `btoa().slice(0,16)` 太短造成衝突 | 移除 `.slice()`，使用完整 base64 字串 |
| 分機篩選漏掉被叫方錄音 | 只查 `caller`，未查 `callee` | 改為 `(caller = ? OR callee = ?)` |
| 網頁開不了 | 手動修改時 `buildRecRow` 函式缺少結尾 `}` | 補上 `}` |

---

**測試結果**：功能實作完成並驗證通過。
