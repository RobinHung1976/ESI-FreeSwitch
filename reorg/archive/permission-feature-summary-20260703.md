# 權限管控功能 — 設計決策彙整（2026-07-03）

## 1. 整體架構

- 儲存：新增 `core/auth_db.py`（SQLite，沿用 `cdr_db.py` 的 `_conn()` pattern）
- 認證：JWT，登入後簽發 token，前端 `Authorization: Bearer <token>`
- **權限改變不即時生效**，需重新登入 token 才會更新（JWT payload 直接快取整份權限矩陣，`require_permission()` 只讀 token，不查 DB，換取效能）
- 群組（Role）與通話群組（callgroup）為不同概念，程式與資料表命名需明確區分（`perm_groups` / `role`，避免與既有 `groups.py`、`callgroup` 欄位混淆）

## 2. 權限模型

- 由字串等級（`none/read/write`）改為 **四個獨立布林旗標**：`read / create / update / delete`
- 原因：需求出現「可新增/修改但不可刪除」的非階層情境（Technical Support Admin 對系統模組即是此情況）
- `scope` 定義在**群組**層級（`all` / `own`），`owned_ext` 定義在**使用者**層級

## 3. 17 個功能模組

`overview, report, extensions, groups, ivr, numbers, calls, cdr, recordings, sounds, gateway, dialplan, esl, logs, settings, backup, users`

三個分類，供矩陣批次套用：

| 分類 | 模組 |
|---|---|
| Dashboard | overview, report |
| Operational | extensions, groups, ivr, numbers, calls, cdr, recordings, sounds |
| System | gateway, dialplan, esl, logs, settings, backup, users |

> ⚠ **待你確認的假設**：`esl`（原始主機指令）與 `logs`（系統日誌）在討論中未明確定案分類，本次先歸入 System 分類（與 settings 同等級）。若你認為這兩者應歸入 Operational（例如 Technical Support 也該能用），請告知調整。

## 4. 最終權限矩陣

| 模組分類 | System Admin | System Viewer | Technical Support Admin | Technical Support | User |
|---|---|---|---|---|---|
| Dashboard (overview/report) | RCUD | R | RCUD | **RCU** | R (own) |
| Operational (ext/群組/ivr/號碼/通話/cdr/錄音/音檔) | RCUD | R | RCUD | RCUD | R (own：僅 cdr/recordings/calls) |
| System (settings/gateway/dialplan/backup/esl/logs/users) | RCUD | R | **RCU（不可 D）** | none | none |

- `scope`：僅 `User` 群組為 `own`，其餘皆 `all`
- 5 個內建群組皆標記 `is_builtin=True`：**群組本身**不可被刪除／改名（與模組層級的 `can_delete` 是兩件事，需在 UI/文件上區分清楚）

## 5. 範例帳號（seed，啟動時 idempotent 建立，已存在則不覆蓋）

| username | 對應群組 | owned_ext |
|---|---|---|
| `admin` | System Admin | — |
| `viewer` | System Viewer | — |
| `admin_tech_support` | Technical Support Admin | — |
| `tech_support` | Technical Support | — |
| `user1001` | User | 1001 |

- 密碼為固定初始值，需搭配 `must_change_password` 欄位強制首次登入改密碼，避免留下已知密碼後門（尚待實作，非本次 `permissions.py` 範圍）

## 6. 本次產出

`core/permissions.py`：權限系統單一資料來源，供後續 `auth_db.py`（seed 寫入 SQLite）與 `core/auth.py`（`require_permission()` dependency）直接 import，避免矩陣定義分散多處。

**不包含**（留待後續步驟）：JWT 簽發/驗證、DB 連線與 seed 邏輯、FastAPI dependency、前端登入頁與 WebSocket 驗證。
