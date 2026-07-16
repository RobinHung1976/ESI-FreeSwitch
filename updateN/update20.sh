#!/usr/bin/env bash
# update20.sh — 修復「新增/編輯/刪除」寫入操作缺少 Authorization header 導致 401 的既有 bug
#
# 根本原因：static/js/common.js 的 apiFetch() 有正確自動帶 `Authorization: Bearer <token>`，
# 但 gateway.js / dialplan.js 裡多處「寫入操作」（新增/編輯/刪除/PATCH）直接用原生 fetch()，
# 完全沒有帶這個 header；GET 讀取類請求則都是透過 apiFetch() 走，所以看起來「查詢正常、
# 新增/刪除卻 401」。此問題自權限系統上線（約 2026-07-10）後就存在，這次是 Dialplan
# Context 切換 UI 測試時才實際撞到，範圍與本次功能開發無關，一併修復。
#
# 範圍：
#   1. static/js/gateway.js：saveGw()、deleteGw()
#   2. static/js/dialplan.js：saveRoute()、deleteRoute()、toggleRouteEnabled()、
#      testRouteNumber()、_dcUpdatePreview()、dcSaveTemplateForm()、
#      _checkRouteConflict()、_dcCreateNewContext()（後兩者為 update19.sh 新增的函式）
#
# ⚠️ 已知：這個 bug 型態可能也存在於其他前端檔案（extensions-groups.js、ivr.js、
#   numbers.js、cdr.js、recordings.js、sounds.js、settings-vars.js、backup.js、
#   users-management.js、sip-profile.js 等），本次未逐一稽核（無檔案內容可核對），
#   腳本結尾會印出自查指令，請自行確認是否還有其他頁面受影響。
set -e

cd "$(dirname "$0")"

# ════════════════════════════════════════════════════════════════════════════
# 0. 自動歸檔
# ════════════════════════════════════════════════════════════════════════════
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

# ════════════════════════════════════════════════════════════════════════════
# 1. 前置驗證
# ════════════════════════════════════════════════════════════════════════════
if [ ! -f static/js/gateway.js ]; then
  echo "❌ 找不到 static/js/gateway.js，請確認執行路徑" >&2
  exit 1
fi
if [ ! -f static/js/dialplan.js ]; then
  echo "❌ 找不到 static/js/dialplan.js，請確認執行路徑" >&2
  exit 1
fi
if ! grep -q "_routeContextCache" static/js/dialplan.js; then
  echo "❌ static/js/dialplan.js 尚未包含 update19.sh 的改動（Context 切換 UI），請先確認 update19.sh 已成功套用" >&2
  exit 1
fi

cp static/js/gateway.js  static/js/gateway.js.bak.$(date +%Y%m%d%H%M%S)
cp static/js/dialplan.js static/js/dialplan.js.bak.$(date +%Y%m%d%H%M%S)

# ════════════════════════════════════════════════════════════════════════════
# 2. 精確字串比對，逐處補上 Authorization header
# ════════════════════════════════════════════════════════════════════════════
python3 << 'AUTH_FIX_PY_EOF'
import sys

def apply_edits(path, edits):
    with open(path, "r", encoding="utf-8") as f:
        content = f.read()

    failures = []
    already_applied = []
    to_apply = []

    for label, old, new in edits:
        if new in content:
            already_applied.append(label)
            continue
        count = content.count(old)
        if count == 1:
            to_apply.append((label, old, new))
        else:
            failures.append((label, count))

    if failures:
        print(f"❌ {path} 以下項目比對失敗：", file=sys.stderr)
        for label, count in failures:
            print(f"   - {label}：找到 {count} 次（預期剛好 1 次）", file=sys.stderr)
        return False

    for label, old, new in to_apply:
        content = content.replace(old, new, 1)

    with open(path, "w", encoding="utf-8") as f:
        f.write(content)

    print(f"✓ {path}：套用 {len(to_apply)} 項，{len(already_applied)} 項已存在略過")
    for label in already_applied:
        print(f"   (已存在，略過) {label}")
    for label, _, _ in to_apply:
        print(f"   (已套用) {label}")
    return True

# ── gateway.js ──────────────────────────────────────────────────────────────
gateway_edits = [
    ("saveGw() 補 Authorization",
"""    const res  = await fetch(url, {
      method,
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(payload),
    });""",
"""    const res  = await fetch(url, {
      method,
      headers: { 'Content-Type': 'application/json', 'Authorization': `Bearer ${getToken()}` },
      body: JSON.stringify(payload),
    });"""),

    ("deleteGw() 補 Authorization",
"""    const res  = await fetch(`${API_BASE}/api/gateway/${name}`, { method: 'DELETE' });""",
"""    const res  = await fetch(`${API_BASE}/api/gateway/${name}`, {
      method: 'DELETE',
      headers: { 'Authorization': `Bearer ${getToken()}` },
    });"""),
]

# ── dialplan.js ─────────────────────────────────────────────────────────────
dialplan_edits = [
    ("saveRoute() 補 Authorization",
"""    const res  = await fetch(url, {
      method,
      headers: { 'Content-Type': 'application/json' },
      body,
    });""",
"""    const res  = await fetch(url, {
      method,
      headers: { 'Content-Type': 'application/json', 'Authorization': `Bearer ${getToken()}` },
      body,
    });"""),

    ("deleteRoute() 補 Authorization",
"""    const res  = await fetch(`${API_BASE}/api/dialplan/routes/${id}`, { method: 'DELETE' });""",
"""    const res  = await fetch(`${API_BASE}/api/dialplan/routes/${id}`, {
      method: 'DELETE',
      headers: { 'Authorization': `Bearer ${getToken()}` },
    });"""),

    ("toggleRouteEnabled() 補 Authorization",
"""    const res  = await fetch(`${API_BASE}/api/dialplan/routes/${id}/toggle`, {
      method: 'PATCH',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ enabled: newEnabled }),
    });""",
"""    const res  = await fetch(`${API_BASE}/api/dialplan/routes/${id}/toggle`, {
      method: 'PATCH',
      headers: { 'Content-Type': 'application/json', 'Authorization': `Bearer ${getToken()}` },
      body: JSON.stringify({ enabled: newEnabled }),
    });"""),

    ("testRouteNumber() 補 Authorization",
"""    const res  = await fetch(`${API_BASE}/api/dialplan/routes/test-number`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ number: num }),
    });""",
"""    const res  = await fetch(`${API_BASE}/api/dialplan/routes/test-number`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'Authorization': `Bearer ${getToken()}` },
      body: JSON.stringify({ number: num }),
    });"""),

    ("_dcUpdatePreview() 補 Authorization",
"""    const res = await fetch(`${API_BASE}/api/dialplan/custom/preview`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ template_id: _dcTemplateId, values }),
    });""",
"""    const res = await fetch(`${API_BASE}/api/dialplan/custom/preview`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'Authorization': `Bearer ${getToken()}` },
      body: JSON.stringify({ template_id: _dcTemplateId, values }),
    });"""),

    ("dcSaveTemplateForm() 補 Authorization",
"""    const res  = await fetch(url, { method, headers: { 'Content-Type': 'application/json' }, body });""",
"""    const res  = await fetch(url, { method, headers: { 'Content-Type': 'application/json', 'Authorization': `Bearer ${getToken()}` }, body });"""),

    ("_checkRouteConflict() 補 Authorization",
"""    const res = await fetch(`${API_BASE}/api/dialplan/routes/check-conflict`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        pattern_type: patternType,
        pattern_value: patternValue,
        context,
        self_id: _routeUpgradingLegacyId || _routeEditingId || '',
      }),
    });""",
"""    const res = await fetch(`${API_BASE}/api/dialplan/routes/check-conflict`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'Authorization': `Bearer ${getToken()}` },
      body: JSON.stringify({
        pattern_type: patternType,
        pattern_value: patternValue,
        context,
        self_id: _routeUpgradingLegacyId || _routeEditingId || '',
      }),
    });"""),

    ("_dcCreateNewContext() 補 Authorization",
"""    const res  = await fetch(`${API_BASE}/api/dialplan/contexts`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ context: name }),
    });""",
"""    const res  = await fetch(`${API_BASE}/api/dialplan/contexts`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'Authorization': `Bearer ${getToken()}` },
      body: JSON.stringify({ context: name }),
    });"""),
]

ok1 = apply_edits("static/js/gateway.js", gateway_edits)
ok2 = apply_edits("static/js/dialplan.js", dialplan_edits)

if not (ok1 and ok2):
    sys.exit(1)
AUTH_FIX_PY_EOF

if command -v node >/dev/null 2>&1; then
  node --check static/js/gateway.js
  node --check static/js/dialplan.js
  echo "✓ JS 語法檢查通過"
else
  echo "⚠️  找不到 node，略過 JS 語法檢查，建議手動確認"
fi

git add static/js/gateway.js static/js/dialplan.js

# ════════════════════════════════════════════════════════════════════════════
# 3. Commit
# ════════════════════════════════════════════════════════════════════════════
if ! git diff --cached --quiet; then
  git commit -m "fix: gateway.js/dialplan.js 寫入操作補上缺少的 Authorization header（既有 bug，導致新增/編輯/刪除 401）"
else
  echo "ℹ️  沒有變更需要 commit（可能已經套用過）"
fi

echo ""
echo "════════════════════════════════════════════════════"
git log --oneline -3
echo "════════════════════════════════════════════════════"
echo ""
echo "驗證重點清單："
echo "  1. 瀏覽器強制重新整理（Ctrl+Shift+R）"
echo "  2. Gateway / SIP Trunk 頁面：新增一個測試 Gateway，確認不再 401，儲存成功"
echo "  3. Dialplan 路由設定 → 路由規則 Tab：新增路由規則，確認可以正常儲存；"
echo "     編輯、停用/啟用、刪除、路由測試（快速測試欄位）都要各測一次"
echo "  4. Dialplan 路由設定 → 自定義 Dialplan Tab：範本模式新增、建立新 context 都要測"
echo "  5. journalctl -u fs-dashboard -f 確認寫入操作不再出現 401"
echo ""
echo "⚠️  自查指令（找出其他頁面是否也有同樣的既有 bug，本次未逐一稽核）："
echo "  cd static/js"
echo "  grep -n \"await fetch(\" *.js | grep -v \"apiFetch\\|gateway.js\\|dialplan.js\\|common.js\""
echo "  # 對每一筆結果，往上下各看 5 行，確認 headers 裡有沒有帶 'Authorization': \`Bearer \${getToken()}\`"
echo "  # 若某支檔案的寫入操作(POST/PUT/DELETE/PATCH)都用 apiFetch()，就沒有這個問題，可以跳過"
echo "  # 有找到缺漏的話，把該檔案內容貼給我，我再開下一支 updateN.sh 修"
