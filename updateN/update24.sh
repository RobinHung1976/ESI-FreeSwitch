#!/usr/bin/env bash
# update24.sh — 導覽列權限隱藏全面驗證結案 + 記錄 calls/acl 前端缺口待辦
#
# 背景：對應 PROJECT-OVERVIEW.md 已知待處理事項第 7 點。
#   - 靜態比對 core/permissions.py / static/index.html / static/js/init.js，data-page 對應無誤
#   - 5 個內建帳號實機測試皆符合權限矩陣預期
#   - 副產物：發現 calls / acl 兩個模組完全沒有對應前端頁面（既有缺口，非本次造成）
#
# 本腳本只動文件（reorg/ 底下的 PROJECT-OVERVIEW.md / CHANGELOG.md / changelog-details/），
# 不動任何程式碼，不需要 systemctl restart。
#
# 執行方式：
#   cd /opt/fs-dashboard
#   chmod +x update24.sh
#   ./update24.sh

set -euo pipefail

DOC_DIR="reorg"
OVERVIEW="${DOC_DIR}/PROJECT-OVERVIEW.md"
CHANGELOG="${DOC_DIR}/CHANGELOG.md"
DETAIL_FILE="${DOC_DIR}/changelog-details/20260716-nav-permission-audit.md"

echo "==> [1/6] 前置驗證：確認上一支腳本（update21.sh）的改動已存在"

if [ ! -f "$OVERVIEW" ]; then
  echo "❌ 找不到 ${OVERVIEW}，請確認目前所在目錄是否為 /opt/fs-dashboard" >&2
  exit 1
fi

if ! grep -q "全站 Authorization header 缺漏修復（\`update20.sh\`/\`update21.sh\`）僅涵蓋當時排查到的 10 支檔案" "$OVERVIEW"; then
  echo "❌ ${OVERVIEW} 尚未包含 update21.sh 的改動，請先確認上一支腳本是否已成功套用" >&2
  exit 1
fi

if [ ! -f "$CHANGELOG" ]; then
  echo "❌ 找不到 ${CHANGELOG}" >&2
  exit 1
fi

if ! grep -q "20260716-auth-header-missing-fix.md" "$CHANGELOG"; then
  echo "❌ ${CHANGELOG} 尚未包含 update21.sh 的索引，請先確認上一支腳本是否已成功套用" >&2
  exit 1
fi

# 冪等檢查：本次腳本若已套用過，直接跳出（避免重複 commit / 重複插入）
if grep -q "20260716-nav-permission-audit" "$CHANGELOG" 2>/dev/null; then
  echo "⚠️  偵測到本次改動已套用過（CHANGELOG.md 已有 20260716-nav-permission-audit 索引），跳過，不重複執行"
  exit 0
fi

echo "==> [2/6] 自動歸檔已執行過的 updateN.sh 腳本"

ARCHIVE_DIR="updateN"
SELF="$(basename "$0")"

mkdir -p "$ARCHIVE_DIR"
for f in update*.sh; do
  [ "$f" = "$SELF" ] && continue
  [ -f "$f" ] || continue
  git mv "$f" "${ARCHIVE_DIR}/$f" 2>/dev/null || mv "$f" "${ARCHIVE_DIR}/$f"
done
git add "$ARCHIVE_DIR"
if ! git diff --cached --quiet; then
  git commit -m "chore: 歸檔已執行的 updateN.sh 腳本"
fi

echo "==> [3/6] 新增 changelog-details/20260716-nav-permission-audit.md"

mkdir -p "$(dirname "$DETAIL_FILE")"

if [ -f "$DETAIL_FILE" ]; then
  echo "❌ ${DETAIL_FILE} 已存在，為避免覆蓋既有內容，請人工確認後再執行" >&2
  exit 1
fi

cat > "$DETAIL_FILE" << 'AUDIT_DOC_EOF'
# 導覽列權限隱藏全面驗證

日期:2026-07-16
對應待辦:`PROJECT-OVERVIEW.md` 已知待處理事項第 7 點（`applyAuthUI()` 自 2026-07-13 上線後僅測過「使用者管理」單一項目）

## 一、驗證方式

分兩階段：

1. **靜態比對**：核對 `core/permissions.py`（`Module` 常數、`ALL_MODULES`、5 組 `BUILTIN_GROUPS` 權限矩陣）、`static/index.html`（17 個 `.nav-item[data-page]`）、`static/js/init.js`（`NAV_PAGE_TO_MODULE`、`pages{}`、`applyAuthUI()`）三份原始碼是否一致
2. **實機測試**：以 5 個內建帳號（`admin`/`viewer`/`admin_tech_support`/`tech_support`/`user1001`）逐一登入，對照權限矩陣換算出的預期可見範圍，人工勾選側邊欄實際顯示結果

## 二、結果

### 靜態比對：✅ 無命名/拼字錯誤

17 個 nav-item 的 `data-page` 與 `permissions.py` 的 `Module` 常數逐一核對，全部正確對應；`dialplan_routes` 經 `NAV_PAGE_TO_MODULE` 正確轉換為 `dialplan` 模組；`applyAuthUI()` 比對邏輯本身無誤。

### 實機測試：✅ 5 個帳號行為皆符合預期矩陣

- System Admin / System Viewer / Technical Support Admin：17 項 nav-item 全部可見
- Technical Support：System 分類（numbers/esl/logs/users/settings/backup）正確全部隱藏，Dashboard/Operational 正常可見
- User(`user1001`)：僅 overview/report/cdr/recordings 可見，其餘 13 項正確隱藏，且 cdr/recordings 資料範圍正確限縮於 `owned_ext=1001`

## 三、副產物:靜態比對過程中發現的 2 個既有功能缺口(非本次隱藏邏輯的 bug)

1. **`calls` 模組沒有對應的 nav-item**:`init.js` 的 `pages{}` 有 `renderCalls`,但 `index.html` 側邊欄找不到 `data-page="calls"`,此頁面目前無 UI 入口可達
2. **`acl` 模組完全沒有前端頁面**:無 `acl.js`、`pages{}` 無此 key、側邊欄無對應項目。後端 `routers/acl.py`(190 行)已存在,`permissions.py` 的 5 組群組矩陣也都已納入 `acl` 權限設定,但前端從未做出對應畫面,任何群組(含 System Admin)皆無法從 UI 操作 ACL

這兩點與「隱藏邏輯是否正確」無關(矩陣換算與 nav-item 隱藏本身是乾淨的),純粹是前端頁面缺失,已另列待辦(見 `PROJECT-OVERVIEW.md` 第五節新增項目)。

## 四、結論

`PROJECT-OVERVIEW.md` 已知待處理事項第 7 點正式結案,待辦清單第六節對應項目勾選完成。
AUDIT_DOC_EOF

echo "==> [4/6] CHANGELOG.md 精確插入一行索引"

python3 << 'PYEOF'
import sys

path = "reorg/CHANGELOG.md"
with open(path, "r", encoding="utf-8") as f:
    content = f.read()

anchor = "## 2026-07\n\n"
if anchor not in content:
    print(f"❌ 在 {path} 找不到預期的插入錨點，請人工確認檔案內容", file=sys.stderr)
    sys.exit(1)

new_line = (
    "- 07-16 test: 導覽列權限隱藏全面驗證完成（19 模組 × 5 內建群組，"
    "靜態比對 + 5 帳號實機測試皆通過），副產物發現 `calls`/`acl` 模組缺少前端頁面 "
    "→ [詳情](changelog-details/20260716-nav-permission-audit.md)\n"
)

content = content.replace(anchor, anchor + new_line, 1)

with open(path, "w", encoding="utf-8") as f:
    f.write(content)

print("✅ CHANGELOG.md 已插入新索引")
PYEOF

echo "==> [5/6] PROJECT-OVERVIEW.md 精確字串取代（3 處）"

python3 << 'PYEOF'
import sys

path = "reorg/PROJECT-OVERVIEW.md"
with open(path, "r", encoding="utf-8") as f:
    content = f.read()

# 取代 1：第五節第 7 點，改成已解決樣式
old_1 = (
    "7. **導覽列權限隱藏尚未全面驗證**:2026-07-13 新增的 `applyAuthUI()` "
    "是全站性邏輯,但只針對「使用者管理」測試過,其餘既有 18 個頁面的模組名稱對應建議找時間補測。"
)
new_1 = (
    "7. ~~**導覽列權限隱藏尚未全面驗證**:2026-07-13 新增的 `applyAuthUI()` "
    "是全站性邏輯,但只針對「使用者管理」測試過,其餘既有 18 個頁面的模組名稱對應建議找時間補測。~~ "
    "→ 已於 2026-07-16 完成驗證(19 模組 × 5 內建群組皆符合預期),"
    "見 `changelog-details/20260716-nav-permission-audit.md`。"
)
if old_1 not in content:
    print(f"❌ 在 {path} 找不到第 7 點的預期原文，請人工確認檔案內容", file=sys.stderr)
    sys.exit(1)
content = content.replace(old_1, new_1, 1)

# 取代 2：第五節第 9 點之後，新增第 10 點
old_2 = (
    "9. **全站 Authorization header 缺漏修復（`update20.sh`/`update21.sh`）僅涵蓋當時排查到的 10 支檔案**:"
    "之後新增前端檔案時，寫入操作應優先使用 `apiFetch()`，避免重蹈覆轍。"
    "詳見 `changelog-details/20260716-auth-header-missing-fix.md`。\n"
)
new_2 = old_2 + (
    "10. **`calls`/`acl` 模組缺少前端頁面**:`calls` 有 render 函式但側邊欄無入口;"
    "`acl` 後端 API(`routers/acl.py`)已存在但完全沒有對應前端頁面,任何群組皆無法從 UI 操作。"
    "詳見 `changelog-details/20260716-nav-permission-audit.md`。\n"
)
if old_2 not in content:
    print(f"❌ 在 {path} 找不到第 9 點的預期原文，請人工確認檔案內容", file=sys.stderr)
    sys.exit(1)
content = content.replace(old_2, new_2, 1)

# 取代 3：第六節「下一步開發」勾選完成
old_3 = "- [ ] 導覽列權限隱藏全面驗證(見已知待處理事項第 7 點)\n"
new_3 = (
    "- [x] 導覽列權限隱藏全面驗證(見已知待處理事項第 7 點) → 已完成,"
    "見 `changelog-details/20260716-nav-permission-audit.md`\n"
)
if old_3 not in content:
    print(f"❌ 在 {path} 找不到「下一步開發」待辦原文，請人工確認檔案內容", file=sys.stderr)
    sys.exit(1)
content = content.replace(old_3, new_3, 1)

# 取代 4：低優先區塊補一行新待辦
old_4 = "- [ ] `owned_ext` 清空端點設計(見已知待處理事項第 6 點)\n"
new_4 = old_4 + "- [ ] `calls`/`acl` 前端頁面補齊(見已知待處理事項第 10 點)\n"
if old_4 not in content:
    print(f"❌ 在 {path} 找不到低優先待辦清單原文，請人工確認檔案內容", file=sys.stderr)
    sys.exit(1)
content = content.replace(old_4, new_4, 1)

with open(path, "w", encoding="utf-8") as f:
    f.write(content)

print("✅ PROJECT-OVERVIEW.md 已完成 4 處精確取代")
PYEOF

echo "==> [6/6] git add + commit"

git add "$DETAIL_FILE" "$CHANGELOG" "$OVERVIEW"

if git diff --cached --quiet; then
  echo "⚠️  沒有偵測到任何變動，略過 commit"
else
  git commit -m "docs: 導覽列權限隱藏全面驗證結案（19 模組 x 5 群組通過），新增 calls/acl 前端缺口待辦"
fi

echo ""
echo "=================================================="
echo "✅ update24.sh 執行完成"
echo "=================================================="
git log --oneline -3

cat << 'CHECKLIST_EOF'

── 驗證重點清單 ──────────────────────────────────────
[ ] reorg/changelog-details/20260716-nav-permission-audit.md 存在且內容完整
[ ] reorg/CHANGELOG.md 的「## 2026-07」區塊最上方多了一行 07-16 test: 索引
[ ] reorg/PROJECT-OVERVIEW.md 第五節第 7 點已變成刪除線 + 已完成
[ ] reorg/PROJECT-OVERVIEW.md 第五節新增第 10 點（calls/acl 缺口）
[ ] reorg/PROJECT-OVERVIEW.md 第六節「導覽列權限隱藏全面驗證」已打勾
[ ] reorg/PROJECT-OVERVIEW.md 低優先清單新增一行 calls/acl 待辦
[ ] git log 可看到 1 筆 chore（若有腳本需歸檔）+ 1 筆 docs commit
[ ] 純文件變動，不需要 systemctl restart
──────────────────────────────────────────────────────

確認無誤後，手動執行：
  git push
CHECKLIST_EOF
