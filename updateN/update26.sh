#!/usr/bin/env bash
# update26.sh — 補齊 update25.sh（登錄記錄 reg_log 去重）的文件記錄
#
# 範圍：
#   1. 新增 changelog-details/20260716-reg-log-dedup-feature.md
#   2. CHANGELOG.md 加一行索引
#   3. features/feature-logs.md：更新登錄記錄描述（早於本次就已過時：07-15 SQLite
#      持久化那次就忘了同步這份文件，本次一併補上持久化 + 去重的現況，移除「已知限制」）
#   4. ops/ops-github-workflow.md「已知編號歷史」補上這次 update23 編號誤植的教訓，
#      避免下次又對錯號
#
# 純文件變動，不動任何程式碼，不需要 systemctl restart。
set -euo pipefail
cd "$(dirname "$0")"

DOC_DIR="reorg"

# ── 0. 自動歸檔：把非本次腳本的其他 updateM.sh 搬進固定資料夾 updateN/ ─────────
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
fi

# ── 1. 前置驗證 ────────────────────────────────────────────────────────────
if ! grep -q '_last_reg_state' core/runtime.py; then
  echo "❌ core/runtime.py 找不到 _last_reg_state，請先確認 update25.sh 是否已成功套用" >&2
  exit 1
fi

for f in "$DOC_DIR/PROJECT-OVERVIEW.md" "$DOC_DIR/CHANGELOG.md" "$DOC_DIR/features/feature-logs.md" "$DOC_DIR/ops/ops-github-workflow.md"; do
  if [ ! -f "$f" ]; then
    echo "❌ 找不到 $f，請確認執行路徑（文件位於 reorg/ 底下，非 repo 根目錄）" >&2
    exit 1
  fi
done

if grep -q "20260716-reg-log-dedup-feature.md" "$DOC_DIR/CHANGELOG.md" 2>/dev/null; then
  echo "⚠️  偵測到本次改動已套用過（CHANGELOG.md 已有對應索引），跳過，不重複執行"
  exit 0
fi

# ── 2. 新增 changelog-details 文件 ─────────────────────────────────────────
mkdir -p "$DOC_DIR/changelog-details"
DETAIL_FILE="$DOC_DIR/changelog-details/20260716-reg-log-dedup-feature.md"

if [ -f "$DETAIL_FILE" ]; then
  echo "❌ ${DETAIL_FILE} 已存在，為避免覆蓋既有內容，請人工確認後再執行" >&2
  exit 1
fi

cat > "$DETAIL_FILE" << 'DOC_EOF'
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
DOC_EOF

git add "$DETAIL_FILE"
echo "✓ 新增 $DETAIL_FILE"

# ── 3. 精確字串編輯既有文件 ─────────────────────────────────────────────────
python3 << 'PYEOF'
import sys

def apply_edit(path, label, old, new):
    with open(path, "r", encoding="utf-8") as f:
        content = f.read()
    if new in content:
        print(f"   (已存在，略過) {label}")
        return True
    count = content.count(old)
    if count != 1:
        print(f"❌ {path}：「{label}」比對失敗，找到 {count} 次（預期 1 次）", file=sys.stderr)
        return False
    content = content.replace(old, new, 1)
    with open(path, "w", encoding="utf-8") as f:
        f.write(content)
    print(f"   (已套用) {path} — {label}")
    return True

ok = True

# ── CHANGELOG.md：加一行索引（放在最上方） ──────────────────────────────────
ok &= apply_edit(
    "reorg/CHANGELOG.md",
    "新增 07-16 reg_log 去重索引",
    "## 2026-07\n\n- 07-16 test: 導覽列權限隱藏全面驗證完成",
    "## 2026-07\n\n"
    "- 07-16 fix: 登錄記錄（reg_log）去重，分機定期自動刷新註冊不再視為新登入重複寫入 "
    "→ [詳情](changelog-details/20260716-reg-log-dedup-feature.md)\n"
    "- 07-16 test: 導覽列權限隱藏全面驗證完成",
)

# ── features/feature-logs.md：更新登錄記錄現況，移除過時的已知限制 ────────────
ok &= apply_edit(
    "reorg/features/feature-logs.md",
    "登錄記錄 Tab 說明更新為 SQLite 持久化 + 去重",
    "| 🔐 登錄記錄 | ESL `REGISTER`/`UNREGISTER` 事件捕捉，最多 200 筆（記憶體保存，服務重啟歸零） |",
    "| 🔐 登錄記錄 | ESL `REGISTER`/`UNREGISTER` 事件捕捉，SQLite 持久化（服務重啟不歸零），"
    "自動過濾分機定期刷新註冊造成的重複記錄，僅記錄首次登入/重新登入/換 IP 或協定 |",
)
ok &= apply_edit(
    "reorg/features/feature-logs.md",
    "移除過時的已知限制段落",
    "## 已知限制\n\n"
    "登錄記錄（`reg_log`）目前僅存在記憶體，服務重啟後歸零，"
    "尚未持久化（見 `PROJECT-OVERVIEW.md` 已知待處理事項）。",
    "## 已知限制\n\n"
    "（無：登錄記錄已於 2026-07-15 完成 SQLite 持久化、2026-07-16 完成去重，"
    "見 `changelog-details/20260715-reg-log-persistence.md`、"
    "`changelog-details/20260716-reg-log-dedup-feature.md`）",
)

# ── ops/ops-github-workflow.md：已知編號歷史補上這次教訓 ───────────────────
ok &= apply_edit(
    "reorg/ops/ops-github-workflow.md",
    "已知編號歷史補上 update23 誤植教訓",
    "### 已知編號歷史\n\n"
    "`update1.sh`：基於已知過時的版本寫成，**從未執行、已正式作廢**。"
    "實際第一支執行過的腳本是 `update2.sh`（孤兒檔案清理 + `calls.router` 重複掛載修正）。",
    "### 已知編號歷史\n\n"
    "`update1.sh`：基於已知過時的版本寫成，**從未執行、已正式作廢**。"
    "實際第一支執行過的腳本是 `update2.sh`（孤兒檔案清理 + `calls.router` 重複掛載修正）。\n\n"
    "⚠️ **2026-07-16 教訓**：撰寫「登錄記錄去重」修復時，誤將編號判斷為 `update23.sh`，"
    "但該編號當時已被另一支無關腳本（Dialplan Context 切換 UI 文件收尾）使用，`update24.sh` "
    "也已存在。原因是只依賴 changelog-details 的既有記錄推斷「下一個可用編號」，而 changelog "
    "文件記錄本身有滯後性（最後 1～2 支腳本常來不及補文件）。後續改用 `update25.sh` 銜接，未造成 "
    "commit 遺失。**往後產生新腳本前，一律先請使用者在 server 上實際執行** "
    "`ls updateN/*.sh update*.sh 2>/dev/null` **確認真正的最大編號，不再只憑文件記錄推斷**。",
)

if not ok:
    sys.exit(1)
PYEOF

git add "$DOC_DIR/CHANGELOG.md" "$DOC_DIR/features/feature-logs.md" "$DOC_DIR/ops/ops-github-workflow.md"

# ── 4. Commit ──────────────────────────────────────────────────────────────
if git diff --cached --quiet; then
  echo "ℹ️  沒有變更需要 commit（可能已經套用過）"
else
  git commit -m "docs: 登錄記錄（reg_log）去重的文件記錄，補上 update23 編號誤植教訓"
fi

echo ""
echo "reorg/ 版控狀態檢查（應無任何輸出，代表全部已追蹤、無未提交變更）："
git --no-pager status --porcelain -- "$DOC_DIR/"

echo ""
echo "════════════════════════════════════════════════════"
git --no-pager log --oneline -4
echo "════════════════════════════════════════════════════"

cat << 'EOF'

── 驗證重點清單 ──────────────────────────────────────
[ ] reorg/changelog-details/20260716-reg-log-dedup-feature.md 存在且內容完整
[ ] reorg/CHANGELOG.md「## 2026-07」區塊最上方多一行 07-16 fix: 登錄記錄去重 索引
[ ] reorg/features/feature-logs.md 登錄記錄 Tab 說明已更新、已知限制段落已清空
[ ] reorg/ops/ops-github-workflow.md「已知編號歷史」補上 update23 誤植教訓
[ ] 純文件變動，不需要 systemctl restart
──────────────────────────────────────────────────────

確認無誤後，手動執行：
  git push
EOF
