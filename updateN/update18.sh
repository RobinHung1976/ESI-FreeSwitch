#!/bin/bash
# update18.sh — 補文件：reg_log 持久化收尾
#   1) reorg/PROJECT-OVERVIEW.md：待辦打勾 + 移入已完成
#   2) reorg/CHANGELOG.md：新增一行索引
#   3) reorg/changelog-details/20260715-reg-log-persistence.md：新增完整詳情文件
#   4) reorg/ops/ops-server-requirements.md：補充 sqlite3 CLI 說明 + reg_log.db 路徑
set -euo pipefail

echo "=== update18.sh：reg_log 持久化 — 文件收尾 ==="

# ── 0. 前置驗證 ───────────────────────────────────────────────────────────────
if [ ! -f core/reg_log_db.py ]; then
  echo "❌ core/reg_log_db.py 不存在，請先確認 update17.sh 已成功套用" >&2
  exit 1
fi
if [ -f reorg/changelog-details/20260715-reg-log-persistence.md ]; then
  echo "❌ reorg/changelog-details/20260715-reg-log-persistence.md 已存在，本腳本只應執行一次" >&2
  exit 1
fi
for f in reorg/PROJECT-OVERVIEW.md reorg/CHANGELOG.md reorg/ops/ops-server-requirements.md; do
  if [ ! -f "$f" ]; then
    echo "❌ 找不到 $f，請確認路徑是否正確（reorg/ 底下）" >&2
    exit 1
  fi
done
echo "✅ 前置驗證通過"

# ── 1. 固定歸檔（chore commit，只 add 歸檔資料夾本身）───────────────────────
ARCHIVE_DIR="updateN"
SELF="$(basename "$0")"

mkdir -p "$ARCHIVE_DIR"
for f in update*.sh; do
  [ "$f" = "$SELF" ] && continue
  [ -f "$f" ] || continue
  git mv "$f" "${ARCHIVE_DIR}/$f" 2>/dev/null || mv "$f" "${ARCHIVE_DIR}/$f"
done
git add "${ARCHIVE_DIR}"
if ! git diff --cached --quiet; then
  git commit -m "chore: 歸檔已執行的 updateN.sh 腳本"
  echo "✅ 已歸檔既有 updateN.sh"
else
  echo "ℹ 無需歸檔（updateN/ 已是最新狀態）"
fi

# ── 2. 新增 changelog-details 詳情文件（完整覆寫，新檔案）───────────────────
mkdir -p reorg/changelog-details
cat > reorg/changelog-details/20260715-reg-log-persistence.md << 'DETAIL_EOF'
# 登錄記錄（reg_log）SQLite 持久化 — 2026-07-15

## 背景 / 問題

`PROJECT-OVERVIEW.md` 中優先待辦「登錄記錄(reg_log)持久化」。`core/state.py` 的
`reg_log` 原本是純記憶體 list（上限 `REG_LOG_MAX` 500 筆），服務每次重啟（部署、
排程重啟、意外崩潰）都會全部歸零，無法回溯查詢分機登入/登出歷史。

（注意：CDR 已於 2026-07-02 完成 SQLite 化，但 `reg_log` 是獨立的另一件事，兩者
不可混淆，見 `changelog-details/20260702-cdr-sqlite-migration.md`。）

## 解法：獨立 SQLite（core/reg_log_db.py）

沿用 `core/cdr_db.py` 的 `_conn()` pattern，但只有單層（`reg_log` 是輕量事件記
錄，不像 CDR 需要「明細 vs 每日彙總」兩層拆分）。

| 項目 | 內容 |
|---|---|
| DB 路徑 | `/opt/fs-dashboard/data/reg_log.db` |
| Table | `reg_log`（`ext`/`event`/`ip`/`proto`/`ts_ms`/`time_str`/`date_str`，index：`ts_ms`/`date_str`/`ext`） |
| 保留策略 | `reg_log_retain_days`（新設定，預設 90 天），每日 00:00:30 排程自動清理 |

**運作流程**：
1. ESL `REGISTER`/`UNREGISTER` 事件觸發 → `core/runtime.py` 的 `write_reg_log()` → `reg_log_db.insert_log()`
2. 每日 00:00:30 排程：`_cleanup_old_reg_logs()` 依 `reg_log_retain_days` 清除過舊記錄
3. `GET /api/reg/log` 改查 SQLite，支援日期區間/分機/事件篩選 + 分頁

## 修改檔案清單

| 檔案 | 異動類型 | 說明 |
|---|---|---|
| `core/reg_log_db.py` | 新增 | SQLite 儲存層：`init_db`/`insert_log`/`query_logs`/`purge_before` |
| `core/state.py` | 修改 | 移除 `reg_log`/`REG_LOG_MAX` 記憶體 list |
| `core/runtime.py` | 修改 | `write_reg_log()` 改寫進 SQLite；新增 `reg_log_retain_days` 預設值（90 天）+ `_cleanup_old_reg_logs()`，掛進每日排程 |
| `server.py` | 修改 | lifespan 新增 `reg_log_db.init_db()` 建表 |
| `routers/calls.py` | 修改 | `GET /api/reg/log` 改查 SQLite，擴充分頁 + 日期/分機/事件篩選，回應格式改為 `{total, page, per_page, total_pages, rows}`，並套用 `scope=own` 權限限制（比照 `get_calls()`） |
| `static/js/settings-vars.js` | 修改 | 設定頁「日誌保留設定」新增「登錄記錄保留天數」欄位 |
| `static/js/logs.js` | 修改 | 登錄記錄 Tab 新增日期/分機/事件篩選列 + 分頁 UI，`loadRegLog()` 改讀新回應格式 |

## 已知取捨

- 不像 CDR SQLite 化那次，本次**沒有搬遷腳本**：舊資料本來就只在記憶體，服務
  重啟必歸零，沒有歷史資料可搬。部署後登錄記錄從當下開始持久化累積。
- `reg_log_retain_days` 預設 90 天（比 `log_retain_days`/`cdr_retain_days` 的
  30 天長一些），因為單筆記錄很輕量，SQLite 檔案成長速度慢，可以保留更久。

## 部署（`update17.sh`）

```bash
python3 -m py_compile core/reg_log_db.py core/runtime.py core/state.py server.py routers/calls.py
sudo systemctl restart fs-dashboard
```

## 測試結果

- ✅ `py_compile` 全部通過，`node --check` 前端兩支 JS 語法通過
- ✅ 手動於 venv 直接呼叫 `reg_log_db.insert_log()` 驗證寫入正常
- ✅ 實機測試：分機 `1210`/`1126` 登入/登出事件正確寫入 SQLite
  （`SELECT COUNT(*) FROM reg_log` 確認筆數與內容正確）
- ✅ **重啟服務後記錄仍在，不再歸零**（本次功能的核心驗證點）
- ✅ 瀏覽器「系統 → 系統日誌 → 🔐 登錄記錄」Tab 顯示正常，篩選（日期/分機/
  事件）與分頁功能正常
- ✅ 於 production server（`debian-freeswitch`）實際部署並逐項驗證通過（2026-07-15）

## 附帶說明：`sqlite3` CLI 工具

驗證過程中額外在 server 上用 `apt-get install -y sqlite3` 裝了 `sqlite3` 指令列
工具，方便手動下 SQL 查詢除錯。這是**系統層級套件**，跟 Python 標準函式庫內建
的 `sqlite3` 模組（`core/reg_log_db.py`/`cdr_db.py`/`auth_db.py` 實際用的那個）
是兩回事，**不需要**、也不應該寫進 `requirements.txt`。詳見
`ops/ops-server-requirements.md`。
DETAIL_EOF
echo "✅ 已建立 reorg/changelog-details/20260715-reg-log-persistence.md"

# ── 3. 既有文件精確字串取代（全部驗證通過才會實際寫入任何一個檔案）──────────
python3 << 'PYEOF'
import sys

edits = []

# --- reorg/PROJECT-OVERVIEW.md：已知待處理事項第 2 點打勾 ---
edits.append(("reorg/PROJECT-OVERVIEW.md",
"2. **登錄記錄(`reg_log`)尚未持久化**:目前仍在記憶體,服務重啟後歸零(注意:CDR 已 SQLite 化,但 `reg_log` 尚未,兩者不同,不可混淆)。",
"2. ~~**登錄記錄(`reg_log`)尚未持久化**:目前仍在記憶體,服務重啟後歸零。~~ → 已於 2026-07-15 完成，見 `changelog-details/20260715-reg-log-persistence.md`。",
"PROJECT-OVERVIEW.md：已知待處理事項第 2 點打勾"))

# --- reorg/PROJECT-OVERVIEW.md：下一步開發 checklist 打勾 ---
edits.append(("reorg/PROJECT-OVERVIEW.md",
"- [ ] 登錄記錄(`reg_log`)持久化",
"- [x] 登錄記錄(`reg_log`)持久化（已完成，2026-07-15，見 `changelog-details/20260715-reg-log-persistence.md`）",
"PROJECT-OVERVIEW.md：下一步開發 checklist 打勾"))

# --- reorg/CHANGELOG.md：新增一行索引（插在最新一行之前）---
edits.append(("reorg/CHANGELOG.md",
"- 07-15 fix: reorg/ 文件目錄（PROJECT-OVERVIEW.md/CHANGELOG.md/changelog-details/archive/features/ops/reference）稽核發現從未被 git 追蹤，全數補進版控 → [詳情](changelog-details/20260715-reorg-git-tracking-fix.md)",
"- 07-15 feat: 登錄記錄（reg_log）SQLite 持久化，取代原本服務重啟即歸零的記憶體 list，新增保留天數設定與每日自動清理 → [詳情](changelog-details/20260715-reg-log-persistence.md)\n- 07-15 fix: reorg/ 文件目錄（PROJECT-OVERVIEW.md/CHANGELOG.md/changelog-details/archive/features/ops/reference）稽核發現從未被 git 追蹤，全數補進版控 → [詳情](changelog-details/20260715-reorg-git-tracking-fix.md)",
"CHANGELOG.md：新增一行索引"))

# --- reorg/ops/ops-server-requirements.md：sqlite3 CLI 說明 ---
edits.append(("reorg/ops/ops-server-requirements.md",
"套件：`fastapi`、`uvicorn`、`websockets`（鎖版本區間 `>=14,<17`，見下方提醒）、`lxml`、`python-multipart`",
"套件：`fastapi`、`uvicorn`、`websockets`（鎖版本區間 `>=14,<17`，見下方提醒）、`lxml`、`python-multipart`\n\n**⚠️ `sqlite3` 不需要，也不應該加進 `requirements.txt`**：Python 標準函式庫內建 `sqlite3` 模組（`core/cdr_db.py`、`core/auth_db.py`、`core/reg_log_db.py` 都是用這個，隨 Python 直接可用，不需安裝）。2026-07-15 另外用 `apt-get install -y sqlite3` 裝的是**系統層級的 CLI 工具**（`sqlite3` 指令本身），純粹方便手動下 SQL 查詢除錯用，跟 Python 程式碼的執行完全無關，兩者不要混淆。",
"ops-server-requirements.md：新增 sqlite3 CLI 說明"))

# --- reorg/ops/ops-server-requirements.md：目錄路徑表新增 reg_log.db ---
edits.append(("reorg/ops/ops-server-requirements.md",
"| CDR SQLite DB | `/opt/fs-dashboard/data/cdr.db` |",
"| CDR SQLite DB | `/opt/fs-dashboard/data/cdr.db` |\n| 登錄記錄 SQLite DB | `/opt/fs-dashboard/data/reg_log.db`（2026-07-15 起持久化，見 `changelog-details/20260715-reg-log-persistence.md`） |",
"ops-server-requirements.md：目錄路徑表新增 reg_log.db"))

file_cache = {}
errors = []
for path, old, new, desc in edits:
    if path not in file_cache:
        try:
            with open(path, "r", encoding="utf-8") as f:
                file_cache[path] = f.read()
        except FileNotFoundError:
            errors.append(f"❌ 找不到檔案：{path}（{desc}）")
            continue
    count = file_cache[path].count(old)
    if count != 1:
        errors.append(f"❌ [{desc}] 在 {path} 中比對到 {count} 次（預期 1 次），中止")

if errors:
    for e in errors:
        print(e, file=sys.stderr)
    print("\n未寫入任何檔案，請確認上述比對失敗項目後再重試（可能是文件實際內容跟預期有落差，"
          "請把失敗訊息貼回去，我再依實際內容重新產生對應替換字串）。", file=sys.stderr)
    sys.exit(1)

applied_content = dict(file_cache)
for path, old, new, desc in edits:
    applied_content[path] = applied_content[path].replace(old, new, 1)
    print(f"✅ {desc}")

for path, content in applied_content.items():
    with open(path, "w", encoding="utf-8") as f:
        f.write(content)

print("\n✅ 所有精確字串取代完成")
PYEOF

# ── 4. Commit（只 add 本次實際改動的檔案）───────────────────────────────────
git add reorg/PROJECT-OVERVIEW.md reorg/CHANGELOG.md \
        reorg/changelog-details/20260715-reg-log-persistence.md \
        reorg/ops/ops-server-requirements.md

git commit -m "docs: 登錄記錄(reg_log) SQLite 持久化 — 文件收尾

- PROJECT-OVERVIEW.md：待辦事項打勾，移入已完成
- CHANGELOG.md：新增一行索引
- changelog-details/20260715-reg-log-persistence.md：完整詳情文件
- ops-server-requirements.md：補充 sqlite3 CLI 工具說明（系統套件，非
  requirements.txt 依賴）+ reg_log.db 路徑登記"

echo ""
echo "=== 最新 commit ==="
git --no-pager log --oneline -1
echo ""
echo "=== commit message（避免中文亂碼，用 %B 完整輸出）==="
git --no-pager log -1 --format="%B"

cat << 'CHECKLIST'

=== 驗證重點清單 ===
1. git --no-pager diff HEAD~1 HEAD --stat   # 確認只改動了預期的 4 個文件檔案
2. cat reorg/changelog-details/20260715-reg-log-persistence.md   # 確認內容完整
3. grep -n "reg_log" reorg/PROJECT-OVERVIEW.md                   # 確認兩處都已更新
4. grep -n "reg-log-persistence" reorg/CHANGELOG.md               # 確認新增索引行
5. grep -n "sqlite3" reorg/ops/ops-server-requirements.md         # 確認新增說明段落
CHECKLIST
