#!/usr/bin/env bash
# update6.sh — 修正右上角浮動登出卡片會擋住頁面按鈕（如「分機管理」的「+ 新增分機」）的問題
# 改用 style.css 裡本來就有、但目前沒被用到的 .topbar / .page-title / .topbar-right 插槽，
# 版面結構上獨立一列，不會疊在任何頁面內容上面。
# 額外副作用（好事）：init.js 的 switchPage() 本來就會寫 #pageTitle，
# 過去因為畫面上沒有這個元素一直靜默失效，這次補上後頁面標題會開始正常顯示。
set -euo pipefail
cd /opt/fs-dashboard

echo "═══ update6.sh 開始 ═══"

# ── 0. 前置驗證 ──────────────────────────────────────────────────────────────
echo "[1/4] 前置驗證..."

if ! grep -q 'id="topbar-user"' static/index.html; then
  echo "❌ static/index.html 尚未包含 update5.sh 加入的 topbar-user 浮動卡片，請先確認 update5.sh 是否成功套用" >&2
  exit 1
fi

if grep -q 'class="topbar"' static/index.html; then
  echo "❌ static/index.html 已包含 .topbar 結構，本次變更疑似已套用過，中止" >&2
  exit 1
fi

python3 - << 'VERIFY_EOF'
import sys

with open('static/index.html', encoding='utf-8') as f:
    html = f.read()

floating_anchor = '''<div id="topbar-user" style="position:fixed;top:12px;right:16px;z-index:500;display:flex;align-items:center;gap:8px;background:var(--panel);border:1px solid var(--border);border-radius:20px;padding:6px 8px 6px 14px;box-shadow:var(--glow)">
  <span id="sf-user-info" style="font-size:11px;color:var(--muted);white-space:nowrap"></span>
  <button class="btn" style="padding:4px 10px;font-size:11px;white-space:nowrap" onclick="logout()">🚪 登出</button>
</div>

<script src="/static/js/common.js"></script>'''

main_anchor = '''  <!-- Main -->
  <main class="main">
    <!-- Content -->
    <div class="content" id="mainContent">'''

for name, anchor in [
    ('index.html 浮動卡片錨點', floating_anchor),
    ('index.html <main> 錨點', main_anchor),
]:
    count = html.count(anchor)
    if count != 1:
        print(f"❌ {name} 應剛好出現 1 次，實際出現 {count} 次，中止", file=sys.stderr)
        sys.exit(1)

print("✓ 前置驗證通過")
VERIFY_EOF

# ── 1. 自動歸檔 ──────────────────────────────────────────────────────────────
echo "[2/4] 自動歸檔舊版 updateN.sh..."
CURRENT=6
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

# ── 2. index.html：移除浮動卡片，改用既有 .topbar 插槽 ───────────────────────
echo "[3/4] 更新 static/index.html..."
python3 - << 'PATCH_HTML_EOF'
import sys

path = 'static/index.html'
with open(path, encoding='utf-8') as f:
    content = f.read()

# 2-1：移除 update5.sh 加的浮動卡片
floating_anchor = '''<div id="topbar-user" style="position:fixed;top:12px;right:16px;z-index:500;display:flex;align-items:center;gap:8px;background:var(--panel);border:1px solid var(--border);border-radius:20px;padding:6px 8px 6px 14px;box-shadow:var(--glow)">
  <span id="sf-user-info" style="font-size:11px;color:var(--muted);white-space:nowrap"></span>
  <button class="btn" style="padding:4px 10px;font-size:11px;white-space:nowrap" onclick="logout()">🚪 登出</button>
</div>

<script src="/static/js/common.js"></script>'''
floating_replace = '<script src="/static/js/common.js"></script>'

if content.count(floating_anchor) != 1:
    print("❌ index.html 浮動卡片錨點比對失敗", file=sys.stderr); sys.exit(1)
content = content.replace(floating_anchor, floating_replace, 1)

# 2-2：在 <main> 內、.content 之前插入 .topbar（style.css 既有但未使用的插槽）
main_anchor = '''  <!-- Main -->
  <main class="main">
    <!-- Content -->
    <div class="content" id="mainContent">'''
main_replace = '''  <!-- Main -->
  <main class="main">
    <div class="topbar">
      <span class="page-title" id="pageTitle"></span>
      <div class="topbar-right">
        <span id="sf-user-info" style="font-size:11px;color:var(--muted);white-space:nowrap"></span>
        <button class="btn" onclick="logout()">🚪 登出</button>
      </div>
    </div>
    <!-- Content -->
    <div class="content" id="mainContent">'''

if content.count(main_anchor) != 1:
    print("❌ index.html <main> 錨點比對失敗", file=sys.stderr); sys.exit(1)
content = content.replace(main_anchor, main_replace, 1)

with open(path, 'w', encoding='utf-8') as f:
    f.write(content)

print("✓ index.html 更新完成")
PATCH_HTML_EOF

echo "（本次不需要更新 common.js / init.js：#sf-user-info 只是換了位置，applyAuthUI() 找的是同一個 id；#pageTitle 是 switchPage() 一直都有在寫的既有邏輯，只是過去畫面上沒有這個元素）"

# ── 3. Commit ─────────────────────────────────────────────────────────────
echo "[4/4] Git commit..."
git add -A
git commit -m "fix: 登出/使用者資訊改用既有 .topbar 插槽，避免蓋住各頁面右上角按鈕（附帶修好 pageTitle 一直沒顯示的問題）"

echo ""
echo "═══ update6.sh 完成 ═══"
git log --oneline -1

cat << 'CHECKLIST_EOF'

── 驗證重點清單 ──────────────────────────────────────────
1. 不需要 systemctl restart（純前端），瀏覽器強制重新整理（Ctrl+Shift+R）
2. 畫面最上方應該出現一條獨立的橫列（高 54px）：
   - 左邊是目前頁面標題（例如切到「分機管理」應該顯示「分機管理」字樣）
   - 右邊是「登入身分：xxx（群組名）」+「🚪 登出」
3. 切換到「分機管理」頁，確認「+ 新增分機」按鈕沒有被擋住、可以正常點擊
   （這是這次要修的主要問題，務必實際點一次確認）
4. 切換到「使用者管理」頁，確認「+ 新增使用者」「+ 新增自訂群組」都沒被擋住
5. 捲動任何一個內容較長的頁面（例如錄音管理），確認頂部這條橫列不會被捲走
   （.content 自己有 overflow-y:auto，只有內容區塊在捲，橫列本來就在捲動範圍外）
6. 點「🚪 登出」能正常導回登入頁
7. 確認 git log 有 fix: 這筆 commit
CHECKLIST_EOF
