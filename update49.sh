#!/bin/bash
# ============================================================
# update49.sh
# 修正「內線互撥」範本的分機勾選區版面：改用獨立直向版型（不再跟
# 標籤/說明文字擠在同一行），並讓全選/清除按鈕在空間不夠時自動換行，
# 解決實機測試發現的「需要橫向捲動才看得到清除按鈕」問題。
# 對應：changelog-details/20260811-internal-extension-template.md
#
# 修改檔案：static/js/dialplan.js（精確字串替換，純前端，不需重啟服務）
# ============================================================
set -e

cd "$(dirname "$0")"

FRONTEND="static/js/dialplan.js"

# --- 0. 自動歸檔 ---
ARCHIVE_DIR="updateN"
SELF="$(basename "$0")"

mkdir -p "$ARCHIVE_DIR"
for f in update*.sh; do
  [ "$f" = "$SELF" ] && continue
  [ -f "$f" ] || continue
  git mv "$f" "${ARCHIVE_DIR}/$f" 2>/dev/null || mv "$f" "${ARCHIVE_DIR}/$f"
done
git add update*.sh "$ARCHIVE_DIR"/ 2>/dev/null || true
if ! git diff --cached --quiet 2>/dev/null; then
  git commit -m "chore: 歸檔已執行的 updateN.sh 腳本"
fi

# --- 1. 前置驗證 ---
echo "[前置驗證] 確認 $FRONTEND 目前內容符合預期（已套用 update47/48，尚未套用本次改動）..."

[ -f "$FRONTEND" ] || { echo "❌ 找不到 $FRONTEND" >&2; exit 1; }

if grep -q "flex-direction:column;align-items:stretch;gap:6px" "$FRONTEND"; then
  echo "❌ $FRONTEND 已包含本次改動的比對錨點，可能已套用過，中止避免重複套用" >&2
  exit 1
fi

if ! grep -q "_dcToggleAllDynamicOptions" "$FRONTEND"; then
  echo "❌ $FRONTEND 找不到 _dcToggleAllDynamicOptions，代表 update47/48 可能還沒套用，請先確認執行順序" >&2
  exit 1
fi

echo "  ✓ 前置驗證通過"

echo "[Step 1] 套用 $FRONTEND 改動..."
cp "$FRONTEND" "${FRONTEND}.pre-update49.bak"

python3 << 'PYEOF_FRONTEND'
import sys

path = "static/js/dialplan.js"
with open(path, "r", encoding="utf-8") as f:
    content = f.read()

edits = []

# Edit 1: fieldsHtml 對 dynamic_multiselect 改用獨立直向版型
old1 = """  const fieldsHtml = tpl.fields.map(f => `
    <div class="settings-row">
      <span class="settings-label">${_escHtml(f.label)}${f.required ? ' *' : ''}</span>
      ${_dcFieldInputHtml(f, prefill[f.key])}
      ${f.help ? `<span style="font-size:11px;color:var(--muted);margin-left:8px">${_escHtml(f.help)}</span>` : ''}
    </div>`).join('');"""
new1 = """  const fieldsHtml = tpl.fields.map(f => {
    if (f.type === 'dynamic_multiselect') {
      // 這種欄位需要較大面積（如分機勾選清單），不適合跟其他欄位一樣塞進
      // 「標籤＋輸入框＋說明文字」同一行的版型，改成標籤獨立一行、
      // 欄位本身佔滿整行寬度、說明文字移到下方，避免可用寬度被兩側擠壓變窄
      return `
    <div class="settings-row" style="flex-direction:column;align-items:stretch;gap:6px">
      <span class="settings-label">${_escHtml(f.label)}${f.required ? ' *' : ''}</span>
      ${_dcFieldInputHtml(f, prefill[f.key])}
      ${f.help ? `<span style="font-size:11px;color:var(--muted)">${_escHtml(f.help)}</span>` : ''}
    </div>`;
    }
    return `
    <div class="settings-row">
      <span class="settings-label">${_escHtml(f.label)}${f.required ? ' *' : ''}</span>
      ${_dcFieldInputHtml(f, prefill[f.key])}
      ${f.help ? `<span style="font-size:11px;color:var(--muted);margin-left:8px">${_escHtml(f.help)}</span>` : ''}
    </div>`;
  }).join('');"""
edits.append(("fieldsHtml 獨立版型", old1, new1))

# Edit 2: 按鈕列加上 flex-wrap
old2 = '        <div style="display:flex;gap:6px;margin-bottom:8px">'
new2 = '        <div style="display:flex;flex-wrap:wrap;gap:6px;margin-bottom:8px">'
edits.append(("按鈕列 flex-wrap", old2, new2))

# Edit 3: 篩選框加上 min-width
old3 = '''          <input id="${filterId}" class="settings-input" style="flex:1;box-sizing:border-box;font-size:12px"'''
new3 = '''          <input id="${filterId}" class="settings-input" style="flex:1;min-width:160px;box-sizing:border-box;font-size:12px"'''
edits.append(("篩選框 min-width", old3, new3))

for name, old, new in edits:
    count = content.count(old)
    if count != 1:
        print(f"❌ 比對錨點「{name}」在 {path} 中出現 {count} 次（預期 1 次），中止", file=sys.stderr)
        sys.exit(1)
    content = content.replace(old, new)

with open(path, "w", encoding="utf-8") as f:
    f.write(content)

print("  ✓ static/js/dialplan.js 三處改動皆已套用")
PYEOF_FRONTEND

if [ $? -ne 0 ]; then
  echo "❌ static/js/dialplan.js 字串替換失敗，還原備份並中止" >&2
  cp "${FRONTEND}.pre-update49.bak" "$FRONTEND"
  exit 1
fi

# --- 語法驗證 ---
echo "[Step 2] 語法檢查..."
if command -v node >/dev/null 2>&1; then
  node -c "$FRONTEND" \
    && echo "  ✓ $FRONTEND 語法檢查通過" \
    || { echo "❌ $FRONTEND 語法檢查失敗，還原備份" >&2; cp "${FRONTEND}.pre-update49.bak" "$FRONTEND"; exit 1; }
else
  echo "  ⚠ 找不到 node，略過語法檢查"
fi

rm -f "${FRONTEND}.pre-update49.bak"

# --- git commit ---
echo "[Step 3] git commit..."
git add "$FRONTEND"
git status
git commit -m "fix: 內線互撥範本分機勾選區改用獨立直向版型，避免跟標籤/說明文字擠壓變窄，全選/清除按鈕加上自動換行"

echo ""
echo "======================================================"
echo " ✓ update49.sh 執行完成"
echo ""
git log --oneline -1
echo ""
echo " ℹ️ 本次只修改 $FRONTEND（純前端），不需要 systemctl restart，"
echo "    瀏覽器強制重新整理（Ctrl+Shift+R）即可看到效果"
echo ""
echo " 驗證重點清單："
echo "  1. 瀏覽器強制重新整理，進「自定義 Dialplan」→ 從範本建立 → 內線互撥"
echo "  2. 分機勾選區應該佔滿整個表單寬度（跟上方檔名/Context 那排一樣寬）"
echo "  3. 「全選」「清除」按鈕應該完整可見，不需要橫向捲動"
echo "  4. 縮小瀏覽器視窗寬度測試：按鈕空間不夠時應該自動換行，而不是被截斷或跑出邊界"
echo "  5. 確認 push 前 git status 乾淨、git log 看到本次 fix: commit"
echo "  6. push 由你自己手動執行"
echo "======================================================"
