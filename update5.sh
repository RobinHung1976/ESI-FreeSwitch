#!/usr/bin/env bash
# update5.sh — 兩項測試回饋修正：
#   1) 登出按鈕從側邊欄底部移到右上角浮動卡片（position:fixed，不用捲動就看得到）
#   2) 系統狀態列在「無 ESL 讀取權限」時顯示更明確的文字，避免誤以為斷線
set -euo pipefail
cd /opt/fs-dashboard

echo "═══ update5.sh 開始 ═══"

# ── 0. 前置驗證 ──────────────────────────────────────────────────────────────
echo "[1/5] 前置驗證..."

if ! grep -q 'onclick="logout()"' static/index.html; then
  echo "❌ static/index.html 尚未包含登出按鈕，請先確認 update4.sh 是否成功套用" >&2
  exit 1
fi
if ! grep -q 'applyAuthUI' static/js/init.js; then
  echo "❌ static/js/init.js 尚未包含 applyAuthUI，請先確認 update4.sh 是否成功套用" >&2
  exit 1
fi

# 冪等檢查：避免重複套用
if grep -q 'id="topbar-user"' static/index.html; then
  echo "❌ static/index.html 已包含 topbar-user，本次變更疑似已套用過，中止" >&2
  exit 1
fi
if grep -q '無存取權限' static/js/common.js; then
  echo "❌ static/js/common.js 已包含「無存取權限」文字，本次變更疑似已套用過，中止" >&2
  exit 1
fi

python3 - << 'VERIFY_EOF'
import sys

with open('static/index.html', encoding='utf-8') as f:
    html = f.read()
with open('static/js/common.js', encoding='utf-8') as f:
    common = f.read()

sidebar_anchor = '''      <div class="server-status" id="sf-sys-status">系統狀態：載入中...</div>
      <div id="sf-user-info" style="font-size:11px;color:var(--muted);margin-top:6px"></div>
      <button class="btn" style="width:100%;margin-top:8px" onclick="logout()">🚪 登出</button>
    </div>
  </aside>'''

script_anchor = '<script src="/static/js/common.js"></script>'

common_anchor = '''async function loadSysStatus() {
  const res = await runESLCommand('status');
  if (!res || !res.result) { setSysStatus('系統狀態：無法取得'); return; }'''

for name, content, anchor in [
    ('index.html sidebar-footer 錨點', html, sidebar_anchor),
    ('index.html script 錨點', html, script_anchor),
    ('common.js loadSysStatus 錨點', common, common_anchor),
]:
    count = content.count(anchor)
    if count != 1:
        print(f"❌ {name} 應剛好出現 1 次，實際出現 {count} 次，中止", file=sys.stderr)
        sys.exit(1)

print("✓ 前置驗證通過")
VERIFY_EOF

# ── 1. 自動歸檔 ──────────────────────────────────────────────────────────────
echo "[2/5] 自動歸檔舊版 updateN.sh..."
CURRENT=5
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

# ── 2. index.html：移除側邊欄底部的使用者資訊/登出按鈕，改成右上角浮動卡片 ───
echo "[3/5] 更新 static/index.html..."
python3 - << 'PATCH_HTML_EOF'
import sys

path = 'static/index.html'
with open(path, encoding='utf-8') as f:
    content = f.read()

# 2-1：移除側邊欄底部的使用者資訊 + 登出按鈕（搬到右上角）
sidebar_anchor = '''      <div class="server-status" id="sf-sys-status">系統狀態：載入中...</div>
      <div id="sf-user-info" style="font-size:11px;color:var(--muted);margin-top:6px"></div>
      <button class="btn" style="width:100%;margin-top:8px" onclick="logout()">🚪 登出</button>
    </div>
  </aside>'''
sidebar_replace = '''      <div class="server-status" id="sf-sys-status">系統狀態：載入中...</div>
    </div>
  </aside>'''

if content.count(sidebar_anchor) != 1:
    print("❌ index.html sidebar-footer 錨點比對失敗", file=sys.stderr); sys.exit(1)
content = content.replace(sidebar_anchor, sidebar_replace, 1)

# 2-2：在 <body> 內、script 標籤前插入右上角浮動卡片（position:fixed，不受任何父層 overflow 影響）
script_anchor = '<script src="/static/js/common.js"></script>'
topbar_html = '''<div id="topbar-user" style="position:fixed;top:12px;right:16px;z-index:500;display:flex;align-items:center;gap:8px;background:var(--panel);border:1px solid var(--border);border-radius:20px;padding:6px 8px 6px 14px;box-shadow:var(--glow)">
  <span id="sf-user-info" style="font-size:11px;color:var(--muted);white-space:nowrap"></span>
  <button class="btn" style="padding:4px 10px;font-size:11px;white-space:nowrap" onclick="logout()">🚪 登出</button>
</div>

''' + script_anchor

if content.count(script_anchor) != 1:
    print("❌ index.html script 錨點比對失敗", file=sys.stderr); sys.exit(1)
content = content.replace(script_anchor, topbar_html, 1)

with open(path, 'w', encoding='utf-8') as f:
    f.write(content)

print("✓ index.html 更新完成")
PATCH_HTML_EOF

# ── 3. common.js：ESL 403（無讀取權限）時顯示更明確的文字 ────────────────────
echo "[4/5] 更新 static/js/common.js..."
python3 - << 'PATCH_COMMON_EOF'
import sys

path = 'static/js/common.js'
with open(path, encoding='utf-8') as f:
    content = f.read()

anchor = '''async function loadSysStatus() {
  const res = await runESLCommand('status');
  if (!res || !res.result) { setSysStatus('系統狀態：無法取得'); return; }'''

insert = '''async function loadSysStatus() {
  const res = await runESLCommand('status');
  if (res && res.detail && !res.result) {
    // 後端 require_permission() 403 回傳格式是 {"detail": "..."}，代表此帳號沒有 ESL 模組讀取權限
    setSysStatus('系統狀態：無存取權限');
    return;
  }
  if (!res || !res.result) { setSysStatus('系統狀態：無法取得'); return; }'''

if content.count(anchor) != 1:
    print("❌ common.js loadSysStatus 錨點比對失敗", file=sys.stderr); sys.exit(1)
content = content.replace(anchor, insert, 1)

with open(path, 'w', encoding='utf-8') as f:
    f.write(content)

print("✓ common.js 更新完成")
PATCH_COMMON_EOF

echo "✓ 本次無新增/覆寫整份檔案，皆為精確字串修改"

# ── 4. Commit ─────────────────────────────────────────────────────────────
echo "[5/5] Git commit..."
git add -A
git commit -m "fix: 登出按鈕移到右上角浮動卡片 + ESL 無權限時顯示明確狀態文字"

echo ""
echo "═══ update5.sh 完成 ═══"
git log --oneline -1

cat << 'CHECKLIST_EOF'

── 驗證重點清單 ──────────────────────────────────────────
1. 不需要 systemctl restart（純前端），瀏覽器強制重新整理（Ctrl+Shift+R）
2. 畫面右上角應該出現「登入身分：xxx（群組名）」+「🚪 登出」的浮動卡片，
   不管頁面往下捲多少都要一直黏在右上角
3. 側邊欄底部不應該再看到登出按鈕（已搬到右上角，只保留原本的連線狀態/系統狀態）
4. 點右上角「🚪 登出」要能正常導回登入頁
5. 用 TC-IT-Sup（沒有 ESL 讀取權限的帳號）登入：
   - 系統狀態應該顯示「系統狀態：無存取權限」，不是「無法取得」
   - 如果 Taichung_IT_Support 群組後來有勾選 ESL 讀取權限，這裡就會正常顯示運行時間
6. 確認 git log 有 fix: 這筆 commit
CHECKLIST_EOF
