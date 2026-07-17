#!/bin/bash
set -e

# ── 自動歸檔（固定寫法）─────────────────────────────────────────────
ARCHIVE_DIR="updateN"
SELF="$(basename "$0")"

mkdir -p "$ARCHIVE_DIR"
for f in update*.sh; do
  [ "$f" = "$SELF" ] && continue
  [ -f "$f" ] || continue
  git mv "$f" "${ARCHIVE_DIR}/$f" 2>/dev/null || mv "$f" "${ARCHIVE_DIR}/$f"
done
git add -A
if ! git diff --cached --quiet; then
  git commit -m "chore: 歸檔已執行的 updateN.sh 腳本"
fi

# ── 前置驗證 ────────────────────────────────────────────────────────
if ! grep -q "title: 'SIPTrunk ACL 信任清單'" static/js/init.js; then
  echo "❌ static/js/init.js 缺少 update31.sh 的既有改動，請先確認 update31.sh 是否已成功套用" >&2
  exit 1
fi
if ! grep -q 'data-page="acl"' static/index.html; then
  echo "❌ static/index.html 缺少 acl 的 nav-item，請先確認環境狀態" >&2
  exit 1
fi

# ── 修正 update31.sh 的判斷邏輯錯誤：────────────────────────────────
# 該腳本用 grep -q '>ACL 信任清單<' 判斷是否已改名，但實際 HTML 是
# 「ACL 信任清單」後面接換行再接 </div>，不是緊接著 <，
# 導致從未命中、誤判成「已改名」而跳過，標籤實際上還是舊名稱。
# 這裡改用明確判斷「新名稱是否已存在」，不會再誤判。
if grep -q "SIPTrunk ACL 信任清單" static/index.html; then
  echo "↷ static/index.html 的 acl 標籤已改名，略過"
else
  python3 << 'PYEOF'
path = "static/index.html"
with open(path, "r", encoding="utf-8") as f:
    content = f.read()

old = '''          <div class="nav-item" data-page="acl" onclick="switchPage('acl')">
            <span class="nav-icon">🛡️</span> ACL 信任清單
          </div>'''

new = '''          <div class="nav-item" data-page="acl" onclick="switchPage('acl')">
            <span class="nav-icon">🛡️</span> SIPTrunk ACL 信任清單
          </div>'''

if content.count(old) != 1:
    raise SystemExit("❌ index.html: acl 標籤改名的 old_str 比對失敗，中止")
content = content.replace(old, new)

with open(path, "w", encoding="utf-8") as f:
    f.write(content)
print("✓ index.html：acl nav-item 標籤已改名為 SIPTrunk ACL 信任清單")
PYEOF
fi

# ── 語法檢查（HTML 沒有 node --check 可用，改用簡單標籤配對檢查）────
python3 -c "
content = open('static/index.html', encoding='utf-8').read()
assert content.count('<div class=\"nav-item\"') == content.count('switchPage'), 'nav-item 與 switchPage 呼叫數不一致，疑似標籤破損'
print('✓ index.html 基本結構檢查通過')
"

# ── Commit ──────────────────────────────────────────────────────────
git add static/index.html
if git diff --cached --quiet; then
  echo "（無變更需要 commit，可能是重跑此腳本、上次已成功 commit 過）"
else
  git commit -m "fix: 修正 update31.sh 誤判邏輯，補上 acl nav-item 標籤改名為 SIPTrunk ACL 信任清單"
fi

echo ""
echo "===== git log ====="
git log --oneline -4
echo ""
echo "===== 確認結果 ====="
grep -A1 'data-page="acl"' static/index.html
