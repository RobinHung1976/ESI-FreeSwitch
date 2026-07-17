#!/usr/bin/env bash
# update28.sh — 補齊 update27.sh（分機管理 Context 下拉選單）的文件記錄
#
# 範圍：
#   1. 新增 changelog-details/20260716-extension-context-dropdown-feature.md
#   2. CHANGELOG.md 加一行索引
#   3. features/feature-extensions.md：Context 欄位說明更新為下拉選單現況，
#      補充共用快取來源說明
#   4. features/feature-dialplan.md：共用基礎設施段落補充「前端 context 清單
#      共用範圍擴大到分機管理頁面」的說明
#
# 純文件變動，不動任何程式碼，不需要 systemctl restart。
set -euo pipefail
cd "$(dirname "$0")"

DOC_DIR="reorg"

# ── 0. 自動歸檔 ──────────────────────────────────────────────────────────────
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
if ! grep -q "_extContextOptionsHtml" static/js/extensions-groups.js 2>/dev/null; then
  echo "❌ static/js/extensions-groups.js 找不到 _extContextOptionsHtml，請先確認 update27.sh 是否已成功套用" >&2
  exit 1
fi

for f in "$DOC_DIR/CHANGELOG.md" "$DOC_DIR/features/feature-extensions.md" "$DOC_DIR/features/feature-dialplan.md"; do
  if [ ! -f "$f" ]; then
    echo "❌ 找不到 $f，請確認執行路徑（文件位於 reorg/ 底下，非 repo 根目錄）" >&2
    exit 1
  fi
done

if grep -q "20260716-extension-context-dropdown-feature.md" "$DOC_DIR/CHANGELOG.md" 2>/dev/null; then
  echo "⚠️  偵測到本次改動已套用過（CHANGELOG.md 已有對應索引），跳過，不重複執行"
  exit 0
fi

# ── 2. 新增 changelog-details 文件 ─────────────────────────────────────────
mkdir -p "$DOC_DIR/changelog-details"
DETAIL_FILE="$DOC_DIR/changelog-details/20260716-extension-context-dropdown-feature.md"

if [ -f "$DETAIL_FILE" ]; then
  echo "❌ ${DETAIL_FILE} 已存在，為避免覆蓋既有內容，請人工確認後再執行" >&2
  exit 1
fi

cat > "$DETAIL_FILE" << 'DOC_EOF'
# 分機管理 Context 欄位改為下拉選單（2026-07-16）

> 對應 `feature-extensions.md` 的表單欄位；重用 [`20260716-dialplan-context-switch-feature.md`](20260716-dialplan-context-switch-feature.md) 建立的 `GET /api/dialplan/contexts`。

## 背景

分機管理新增/編輯表單的 Context 欄位原本是純文字輸入框，需要手動打字，容易打錯字造成分機的 SIP context 對不到任何實際存在的 dialplan 資料夾（等於這個分機永遠無法正確路由）。後端沒有對應校驗，錯字不會被攔下來。

## 修復

### 前端共用重構（`static/js/common.js`）

新增 `loadDialplanContexts()`（30 秒快取）取代原本 `dialplan.js` 兩處（路由規則 Tab 的 `_routeContextCache`、自定義 Dialplan Tab 的 `_dcContextsCache`）各自獨立呼叫 `GET /api/dialplan/contexts` 的作法，改成三個頁面（路由規則、自定義 Dialplan、分機管理）共用同一份快取。同時新增公開版本的 `escHtml()`/`escAttr()`（`dialplan.js` 原本已有私有版本 `_escHtml`/`_escAttr`，這次刻意不動它，避免大範圍改動既有程式碼，只是另外提供公開版本供其他頁面共用）。

自定義 Dialplan Tab 建立新 context 成功後，除了更新自己頁面的本地快取，也會呼叫新增的 `clearDialplanContextsCache()` 清除共用快取，讓分機管理／路由規則頁面下次載入時能立即抓到最新清單，不需要等 30 秒 TTL 過期。

### 分機管理表單（`static/js/extensions-groups.js`）

Context 欄位 `<input>` 改成 `<select>`，選項來源為 `loadDialplanContexts()`。**只能選現有 context，不提供就地建立**——呼應 Context 切換 UI 當初的設計原則：建立新 context 資料夾的入口只開放在「自定義 Dialplan」頁面。

編輯模式若目前值不在清單中（例如該 context 資料夾之後被移除），仍會把原值加進選項並標示「⚠️ 資料夾可能已不存在」，不會強迫使用者一開表單就被迫改成別的 context，避免非預期變更。

## 修改的檔案

- `static/js/common.js`：新增 `loadDialplanContexts()`/`clearDialplanContextsCache()`/`escHtml()`/`escAttr()`
- `static/js/dialplan.js`：路由規則 Tab、自定義 Dialplan Tab 改用共用函式；建立新 context 成功後清共用快取（3 處）
- `static/js/extensions-groups.js`：Context 欄位改為下拉選單，新增 `_extContextOptionsHtml()`（5 處）

（`update27.sh`）

## 驗證方式

純前端變動，瀏覽器強制重新整理（Ctrl+Shift+R）即生效，不需要 `systemctl restart`。

瀏覽器實測：
1. 分機管理新增/編輯分機，Context 欄位為下拉選單，預設/現有值正確帶入
2. 在「自定義 Dialplan」建立一個新 context，回到分機管理重新整理頁面，新增/編輯分機的 Context 下拉選單能立即選到新建的 context（驗證共用快取跨頁面即時失效）
3. 路由規則 Tab 的 Context 篩選/表單選單功能不受影響（確認重構沒有改壞原本行為）
4. 「🔄 變更號碼」流程一併測試，確認新分機的 context 正確帶到新號碼上

**測試結果**：已於 production server（`debian-freeswitch`）實際執行 `update27.sh`，依上述步驟測試通過，使用者確認功能正常。
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
    "新增 07-16 分機 Context 下拉選單索引",
    "## 2026-07\n\n- 07-16 fix: 登錄記錄（reg_log）去重",
    "## 2026-07\n\n"
    "- 07-16 feat: 分機管理 Context 欄位改為下拉選單，重用既有 context 清單並抽出共用快取函式 "
    "→ [詳情](changelog-details/20260716-extension-context-dropdown-feature.md)\n"
    "- 07-16 fix: 登錄記錄（reg_log）去重",
)

# ── features/feature-extensions.md ───────────────────────────────────────────
ok &= apply_edit(
    "reorg/features/feature-extensions.md",
    "Context 欄位說明更新為下拉選單",
    "| Context | SIP context | `default` |",
    "| Context | 下拉選單，動態讀取 `/api/dialplan/contexts`（與路由規則/自定義 Dialplan 共用快取），"
    "只能選現有 context，不提供就地建立 | `default` |",
)
ok &= apply_edit(
    "reorg/features/feature-extensions.md",
    "補充 Context 下拉選單的共用快取說明",
    "號碼欄位綁定 `oninput`/`onblur` 呼叫 `numCheckConflict()`（見 `feature-numbers.md`），編輯模式自動排除自身。\n\n"
    "## 儲存與 XML",
    "號碼欄位綁定 `oninput`/`onblur` 呼叫 `numCheckConflict()`（見 `feature-numbers.md`），編輯模式自動排除自身。\n\n"
    "Context 欄位改為下拉選單（2026-07-16），資料來源與 Dialplan 路由規則、自定義 Dialplan 頁面共用同一份 "
    "30 秒快取（`common.js: loadDialplanContexts()`），建立新 context 的入口仍只開放在「自定義 Dialplan」"
    "頁面（見 `feature-dialplan-custom.md`），分機表單只能選、不能建。編輯模式若目前值不在清單中（例如該 "
    "context 資料夾已被移除），仍保留原值供選擇並標示警語，避免非預期變更。詳見 "
    "`changelog-details/20260716-extension-context-dropdown-feature.md`。\n\n"
    "## 儲存與 XML",
)

# ── features/feature-dialplan.md ─────────────────────────────────────────────
ok &= apply_edit(
    "reorg/features/feature-dialplan.md",
    "共用基礎設施段落補充前端共用範圍擴大說明",
    "`list_contexts()`/`create_context_dir()`（2026-07-16 新增）也放在 `dialplan_routes.py`，"
    "透過 `GET`/`POST /api/dialplan/contexts` 供類型一（路由規則）與類型三（自定義）共用；"
    "一個 context 對應 `/etc/freeswitch/dialplan/` 底下一個子資料夾，建立入口只開放在類型三（自定義）頁面，"
    "類型一只能選既有清單，詳見 [`20260716-dialplan-context-switch-feature.md`]"
    "(../changelog-details/20260716-dialplan-context-switch-feature.md)。\n\n"
    "## 尚未實作的通用功能",
    "`list_contexts()`/`create_context_dir()`（2026-07-16 新增）也放在 `dialplan_routes.py`，"
    "透過 `GET`/`POST /api/dialplan/contexts` 供類型一（路由規則）與類型三（自定義）共用；"
    "一個 context 對應 `/etc/freeswitch/dialplan/` 底下一個子資料夾，建立入口只開放在類型三（自定義）頁面，"
    "類型一只能選既有清單，詳見 [`20260716-dialplan-context-switch-feature.md`]"
    "(../changelog-details/20260716-dialplan-context-switch-feature.md)。\n\n"
    "前端這份 context 清單的共用範圍後續（同日）擴大到分機管理頁面：`static/js/common.js` 新增 "
    "`loadDialplanContexts()`（30 秒快取）供路由規則、自定義 Dialplan、分機管理三處共用，取代原本各頁各自"
    "獨立打 API 的作法；建立新 context 成功後會呼叫 `clearDialplanContextsCache()` 讓其他頁面下次載入抓到"
    "最新清單。詳見 [`20260716-extension-context-dropdown-feature.md`]"
    "(../changelog-details/20260716-extension-context-dropdown-feature.md)。\n\n"
    "## 尚未實作的通用功能",
)

if not ok:
    sys.exit(1)
PYEOF

git add "$DOC_DIR/CHANGELOG.md" "$DOC_DIR/features/feature-extensions.md" "$DOC_DIR/features/feature-dialplan.md"

# ── 4. Commit ──────────────────────────────────────────────────────────────
if git diff --cached --quiet; then
  echo "ℹ️  沒有變更需要 commit（可能已經套用過）"
else
  git commit -m "docs: 分機管理 Context 下拉選單功能的文件記錄"
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
[ ] reorg/changelog-details/20260716-extension-context-dropdown-feature.md 存在且內容完整
[ ] reorg/CHANGELOG.md「## 2026-07」區塊最上方多一行 07-16 feat: 分機管理 Context 下拉選單 索引
[ ] reorg/features/feature-extensions.md Context 欄位說明已更新
[ ] reorg/features/feature-dialplan.md 共用基礎設施段落已補充前端共用說明
[ ] 純文件變動，不需要 systemctl restart
──────────────────────────────────────────────────────

確認無誤後，手動執行：
  git push
EOF
