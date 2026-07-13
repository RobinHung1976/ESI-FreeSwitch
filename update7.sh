#!/usr/bin/env bash
# update7.sh — 修正「登入身分：xxx（群組名）」一直顯示空白的問題
# 根本原因：core/auth.py 的 create_access_token() 實際存的 claim 是 "sub"，
# 不是我先前沒拿到 auth.py 前用猜的 "username"，導致 payload.username 永遠是 undefined。
set -euo pipefail
cd /opt/fs-dashboard

echo "═══ update7.sh 開始 ═══"

# ── 0. 前置驗證 ──────────────────────────────────────────────────────────────
echo "[1/4] 前置驗證..."

if ! grep -q 'class="topbar"' static/index.html; then
  echo "❌ static/index.html 尚未包含 .topbar 結構，請先確認 update6.sh 是否成功套用" >&2
  exit 1
fi
if ! grep -q 'applyAuthUI' static/js/init.js; then
  echo "❌ static/js/init.js 尚未包含 applyAuthUI，請先確認 update4.sh 是否成功套用" >&2
  exit 1
fi

if grep -q 'payload.sub' static/js/init.js; then
  echo "❌ static/js/init.js 已使用 payload.sub，本次變更疑似已套用過，中止" >&2
  exit 1
fi

python3 - << 'VERIFY_EOF'
import sys

with open('static/js/init.js', encoding='utf-8') as f:
    content = f.read()

anchor = '''  const userInfoEl = document.getElementById('sf-user-info');
  if (userInfoEl) {
    const name  = payload.username   || '';
    const group = payload.group_name || '';
    userInfoEl.textContent = name ? `登入身分：${name}${group ? '（' + group + '）' : ''}` : '';
  }'''

count = content.count(anchor)
if count != 1:
    print(f"❌ init.js applyAuthUI 錨點應剛好出現 1 次，實際出現 {count} 次，中止", file=sys.stderr)
    sys.exit(1)

print("✓ 前置驗證通過")
VERIFY_EOF

# ── 1. 自動歸檔 ──────────────────────────────────────────────────────────────
echo "[2/4] 自動歸檔舊版 updateN.sh..."
CURRENT=7
mkdir -p "updateN"
for f in update*.sh; do
  [ "$f" = "update${CURRENT}.sh" ] && continue
  [ -f "$f" ] || continue
  git mv "$f" "updateN/$f" 2>/dev/null || mv "$f" "updateN/$f"
done
git add -A
if ! git diff --cached --quiet; then
  git commit -m "chore: 歸檔已執行的 updateN.sh 腳本"
  echo "✓ 已歸檔並 commit"
else
  echo "（無需歸檔，跳過）"
fi

# ── 2. init.js：payload.username → payload.sub ───────────────────────────────
echo "[3/4] 更新 static/js/init.js..."
python3 - << 'PATCH_EOF'
import sys

path = 'static/js/init.js'
with open(path, encoding='utf-8') as f:
    content = f.read()

anchor = '''  const userInfoEl = document.getElementById('sf-user-info');
  if (userInfoEl) {
    const name  = payload.username   || '';
    const group = payload.group_name || '';
    userInfoEl.textContent = name ? `登入身分：${name}${group ? '（' + group + '）' : ''}` : '';
  }'''

insert = '''  const userInfoEl = document.getElementById('sf-user-info');
  if (userInfoEl) {
    // core/auth.py 的 create_access_token() 實際存的 claim 是 "sub"（JWT 標準慣例），不是 "username"
    const name  = payload.sub        || '';
    const group = payload.group_name || '';
    userInfoEl.textContent = name ? `登入身分：${name}${group ? '（' + group + '）' : ''}` : '';
  }'''

if content.count(anchor) != 1:
    print("❌ init.js applyAuthUI 錨點比對失敗", file=sys.stderr); sys.exit(1)
content = content.replace(anchor, insert, 1)

with open(path, 'w', encoding='utf-8') as f:
    f.write(content)

print("✓ init.js 更新完成")
PATCH_EOF

# ── 3. Commit ─────────────────────────────────────────────────────────────
echo "[4/4] Git commit..."
git add -A
git commit -m "fix: 登入身分文字改讀 JWT 的 sub claim（原本誤用不存在的 username 欄位，一直顯示空白）"

echo ""
echo "═══ update7.sh 完成 ═══"
git log --oneline -1

cat << 'CHECKLIST_EOF'

── 驗證重點清單 ──────────────────────────────────────────
1. 不需要 systemctl restart（純前端），瀏覽器強制重新整理（Ctrl+Shift+R）
2. 重新登入（舊 token 沒有變化，但保險起見重新登入一次確保拿到的畫面是最新的）
3. 畫面最上方 .topbar 右側應該顯示「登入身分：xxx（群組名）」，例如：
   登入身分：admin（System Admin）
   登入身分：TC-IT-Sup（Taichung_IT_Support）
4. 確認 git log 有 fix: 這筆 commit
CHECKLIST_EOF
