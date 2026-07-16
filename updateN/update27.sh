#!/usr/bin/env bash
# update27.sh — 分機管理 Context 欄位：手動輸入 → 下拉選單（重用既有 context 清單）
#
# 範圍：
#   1. common.js：新增共用函式 loadDialplanContexts()（30 秒快取）/
#      clearDialplanContextsCache() / escHtml() / escAttr()
#   2. dialplan.js：路由規則 Tab、自定義 Dialplan Tab 原本各自獨立打
#      /api/dialplan/contexts 的地方，改用共用的 loadDialplanContexts()；
#      建立新 context 成功後順便清共用快取，讓其他頁面下次載入抓到最新清單
#   3. extensions-groups.js：Context 欄位 <input> 換成 <select>，選項來源
#      同樣是 loadDialplanContexts()；只能選現有 context，不提供就地建立
#      （呼應 Context 切換 UI 當初的設計：建立入口只開放在自定義 Dialplan 頁面）
#
# 純前端變動，不動任何後端程式碼，不需要 systemctl restart，
# 瀏覽器強制重新整理（Ctrl+Shift+R）即生效。
set -euo pipefail
cd "$(dirname "$0")"

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
if ! grep -q "20260716-reg-log-dedup-feature.md" reorg/CHANGELOG.md 2>/dev/null; then
  echo "❌ reorg/CHANGELOG.md 尚未包含 update26.sh 的改動，請先確認 update26.sh 是否已成功套用" >&2
  exit 1
fi

for f in static/js/common.js static/js/dialplan.js static/js/extensions-groups.js; do
  if [ ! -f "$f" ]; then
    echo "❌ 找不到 $f" >&2
    exit 1
  fi
done

if grep -q "loadDialplanContexts" static/js/common.js; then
  echo "❌ static/js/common.js 似乎已經套用過本次改動（找到 loadDialplanContexts），略過以避免重複套用" >&2
  exit 1
fi

# ── 2. common.js：新增共用函式 ───────────────────────────────────────────────
python3 << 'PYEOF'
import sys

path = "static/js/common.js"
with open(path, "r", encoding="utf-8") as f:
    content = f.read()

anchor = '''async function apiFetch(path, options = {}) {
  const token = getToken();
  const headers = { ...(options.headers || {}) };
  if (token) headers['Authorization'] = `Bearer ${token}`;

  try {
    const res = await fetch(`${API_BASE}${path}`, { ...options, headers });

    if (res.status === 401) {
      redirectToLogin();
      return null;
    }

    return await res.json();
  } catch (e) {
    console.error(`API 錯誤 ${path}:`, e);
    return null;
  }
}'''

addition = '''

// ── Dialplan Context 清單（共用快取：分機管理／路由規則／自定義 Dialplan）───────
// 2026-07-16 新增，取代原本 dialplan.js 兩處（_routeContextCache/_dcContextsCache）
// 各自獨立打 API 的作法，三個頁面共用同一份 30 秒快取。
let _dialplanContextsCache  = null;   // null = 尚未載入過
let _dialplanContextsAt     = 0;
const DIALPLAN_CONTEXTS_TTL = 30000;

/** 取得目前存在的 dialplan context 清單（GET /api/dialplan/contexts）。
 *  force=true 用於建立新 context 後強制重新打 API。
 */
async function loadDialplanContexts(force = false) {
  const fresh = _dialplanContextsCache && (Date.now() - _dialplanContextsAt) < DIALPLAN_CONTEXTS_TTL;
  if (fresh && !force) return _dialplanContextsCache;
  const data = await apiFetch('/api/dialplan/contexts');
  _dialplanContextsCache = (data && data.contexts && data.contexts.length) ? data.contexts : ['default'];
  _dialplanContextsAt = Date.now();
  return _dialplanContextsCache;
}

/** 清除共用快取（例如剛建立新 context 後），確保其他頁面下次載入抓到最新清單 */
function clearDialplanContextsCache() {
  _dialplanContextsCache = null;
}

// ── 共用 HTML escape（原本只有 dialplan.js 私有的 _escHtml/_escAttr 有，
//    這裡另外提供公開版本供其他頁面共用，不動 dialplan.js 既有的私有版本）─────
function escHtml(s) {
  if (s === null || s === undefined) return '';
  return String(s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');
}
function escAttr(s) {
  return escHtml(s).replace(/'/g, '&#39;');
}'''

if content.count(anchor) != 1:
    print(f"❌ common.js 錨點比對失敗，找到 {content.count(anchor)} 次（預期 1 次）", file=sys.stderr)
    sys.exit(1)

content = content.replace(anchor, anchor + addition, 1)
with open(path, "w", encoding="utf-8") as f:
    f.write(content)
print("✓ common.js 已新增 loadDialplanContexts() 等共用函式")
PYEOF

# ── 3. dialplan.js：改用共用函式（3 處精確取代）─────────────────────────────
python3 << 'PYEOF'
import sys

path = "static/js/dialplan.js"
with open(path, "r", encoding="utf-8") as f:
    content = f.read()

edits = [
    ("路由規則 Tab 改用 loadDialplanContexts()",
"""  const [routeData, gwData, ctxData] = await Promise.all([
    apiFetch('/api/dialplan/routes'),
    apiFetch('/api/gateway/list'),
    apiFetch('/api/dialplan/contexts'),
  ]);

  const routes = (routeData && routeData.routes) ? routeData.routes : [];
  _routeGatewayCache   = (gwData && gwData.gateways) ? gwData.gateways : [];
  _routeContextCache   = (ctxData && ctxData.contexts) ? ctxData.contexts : ['default'];""",
"""  const [routeData, gwData, contexts] = await Promise.all([
    apiFetch('/api/dialplan/routes'),
    apiFetch('/api/gateway/list'),
    loadDialplanContexts(),
  ]);

  const routes = (routeData && routeData.routes) ? routeData.routes : [];
  _routeGatewayCache   = (gwData && gwData.gateways) ? gwData.gateways : [];
  _routeContextCache   = contexts;"""),

    ("自定義 Dialplan Tab 改用 loadDialplanContexts()",
"""  const [tplData, fileData, ctxData] = await Promise.all([
    apiFetch('/api/dialplan/custom/templates'),
    apiFetch('/api/dialplan/custom/files'),
    apiFetch('/api/dialplan/contexts'),
  ]);

  _dcTemplates     = (tplData && tplData.templates) ? tplData.templates : [];
  _dcFiles         = (fileData && fileData.files) ? fileData.files : [];
  _dcContextsCache = (ctxData && ctxData.contexts) ? ctxData.contexts : ['default', 'public'];""",
"""  const [tplData, fileData, contexts] = await Promise.all([
    apiFetch('/api/dialplan/custom/templates'),
    apiFetch('/api/dialplan/custom/files'),
    loadDialplanContexts(),
  ]);

  _dcTemplates     = (tplData && tplData.templates) ? tplData.templates : [];
  _dcFiles         = (fileData && fileData.files) ? fileData.files : [];
  _dcContextsCache = contexts;"""),

    ("建立新 context 成功後清共用快取",
"""    if (res.ok && data.ok) {
      if (!_dcContextsCache.includes(name)) _dcContextsCache.push(name);
      dpCloseModal();""",
"""    if (res.ok && data.ok) {
      if (!_dcContextsCache.includes(name)) _dcContextsCache.push(name);
      clearDialplanContextsCache();  // 讓分機管理/路由規則頁面下次載入抓到最新清單
      dpCloseModal();"""),
]

failures = []
for label, old, new in edits:
    count = content.count(old)
    if count != 1:
        failures.append((label, count))
        continue
    content = content.replace(old, new, 1)

if failures:
    for label, count in failures:
        print(f"❌ dialplan.js「{label}」比對失敗，找到 {count} 次（預期 1 次）", file=sys.stderr)
    sys.exit(1)

with open(path, "w", encoding="utf-8") as f:
    f.write(content)
print("✓ dialplan.js 已改用共用函式（3 處）")
PYEOF

# ── 4. extensions-groups.js：Context 欄位改成下拉選單 ───────────────────────
python3 << 'PYEOF'
import sys

path = "static/js/extensions-groups.js"
with open(path, "r", encoding="utf-8") as f:
    content = f.read()

edits = [
    ("表單欄位：<input> 換成 <select>",
'          <input class="settings-input" id="ext-context" value="default" />',
'          <select class="settings-select" id="ext-context"></select>'),

    ("新增 _extContextOptionsHtml() 輔助函式",
"""  const needsSnapshot = exts.some(e => !extStatusCache[e.id]);
  if (needsSnapshot) loadExtStatusSnapshot();
}

// ── 分機 CRUD 函式 ────────────────────────────────────────────────────────────
let _editingExtId = null;""",
"""  const needsSnapshot = exts.some(e => !extStatusCache[e.id]);
  if (needsSnapshot) loadExtStatusSnapshot();
}

// ── Context 下拉選單（2026-07-16，取代原本手動輸入的文字框）──────────────────
// 資料來源與路由規則/自定義 Dialplan 共用同一份快取（common.js: loadDialplanContexts()）。
// 只能選現有 context，不提供就地建立——呼應 Context 切換 UI 當初的設計：
// 建立新 context 資料夾的入口只開放在「自定義 Dialplan」頁面。
// 編輯模式若目前值不在清單中（例如該 context 資料夾已被移除），仍保留原值供選擇，
// 避免使用者一開表單就被迫改成別的 context，造成非預期變更。
function _extContextOptionsHtml(contexts, selected) {
  const list = (contexts && contexts.length) ? contexts : ['default'];
  let opts = list.map(c =>
    `<option value="${escAttr(c)}" ${c === selected ? 'selected' : ''}>${escHtml(c)}</option>`
  ).join('');
  if (selected && !list.includes(selected)) {
    opts += `<option value="${escAttr(selected)}" selected>⚠️ ${escHtml(selected)}（資料夾可能已不存在）</option>`;
  }
  return opts;
}

// ── 分機 CRUD 函式 ────────────────────────────────────────────────────────────
let _editingExtId = null;"""),

    ("openExtEditor：載入 context 清單",
"""  const title = document.getElementById('ext-editor-title');
  const idInput = document.getElementById('ext-id');

  if (id) {""",
"""  const title = document.getElementById('ext-editor-title');
  const idInput = document.getElementById('ext-id');

  // Context 下拉選單資料來源與 Dialplan 頁面共用同一份快取（common.js）
  const contexts = await loadDialplanContexts();

  if (id) {"""),

    ("編輯模式：套用下拉選單（含 ext 找不到時的防呆 fallback）",
"""    const data = await apiFetch('/api/extensions/list');
    const ext  = (data && data.extensions) ? data.extensions.find(e => e.id === id) : null;
    if (ext) {
      document.getElementById('ext-name').value       = ext.caller_id_name || '';
      document.getElementById('ext-password').value   = ext.password === '$${default_password}' ? '' : ext.password;
      document.getElementById('ext-vm-password').value= ext.vm_password || '';
      document.getElementById('ext-callgroup').value  = ext.callgroup || '';
      document.getElementById('ext-context').value    = ext.context || 'default';
      const tollSel = document.getElementById('ext-toll');""",
"""    const data = await apiFetch('/api/extensions/list');
    const ext  = (data && data.extensions) ? data.extensions.find(e => e.id === id) : null;
    document.getElementById('ext-context').innerHTML = _extContextOptionsHtml(contexts, (ext && ext.context) || 'default');
    if (ext) {
      document.getElementById('ext-name').value       = ext.caller_id_name || '';
      document.getElementById('ext-password').value   = ext.password === '$${default_password}' ? '' : ext.password;
      document.getElementById('ext-vm-password').value= ext.vm_password || '';
      document.getElementById('ext-callgroup').value  = ext.callgroup || '';
      const tollSel = document.getElementById('ext-toll');"""),

    ("新增模式：套用下拉選單",
"""    document.getElementById('ext-context').value = 'default';""",
"""    document.getElementById('ext-context').innerHTML = _extContextOptionsHtml(contexts, 'default');"""),
]

failures = []
for label, old, new in edits:
    count = content.count(old)
    if count != 1:
        failures.append((label, count))
        continue
    content = content.replace(old, new, 1)

if failures:
    for label, count in failures:
        print(f"❌ extensions-groups.js「{label}」比對失敗，找到 {count} 次（預期 1 次）", file=sys.stderr)
    sys.exit(1)

with open(path, "w", encoding="utf-8") as f:
    f.write(content)
print("✓ extensions-groups.js 已完成 5 處取代")
PYEOF

# ── 5. 語法檢查（若有裝 node）────────────────────────────────────────────────
if command -v node >/dev/null 2>&1; then
  node --check static/js/common.js
  node --check static/js/dialplan.js
  node --check static/js/extensions-groups.js
  echo "✅ node --check 全部通過"
else
  echo "ℹ️  未偵測到 node，略過語法檢查（純前端改動，瀏覽器實測即可驗證）"
fi

# ── 6. Commit ──────────────────────────────────────────────────────────────
git add static/js/common.js static/js/dialplan.js static/js/extensions-groups.js
git commit -m "feat: 分機管理 Context 欄位改為下拉選單，抽出共用 loadDialplanContexts()"

echo ""
echo "=== git log ==="
git --no-pager log --oneline -3

cat << 'EOF'

=== 部署步驟（server 上執行）===
純前端變動，不需要 systemctl restart。
瀏覽器強制重新整理（Ctrl+Shift+R）清除快取即可生效。

=== 驗證重點清單 ===
[ ] 分機管理 → 新增分機：Context 欄位是下拉選單，預設選中 default
[ ] 分機管理 → 編輯既有分機：Context 下拉選單正確帶入目前值並選中
[ ] Dialplan 路由設定 → 自定義 Dialplan → 建立一個新 context（例如 branch9）
[ ] 回到分機管理，重新整理頁面，新增/編輯分機時 Context 下拉選單應該要看得到 branch9
    （驗證共用快取確實跨頁面生效，不需要清瀏覽器快取或等 30 秒）
[ ] Dialplan 路由設定 → 路由規則 Tab：Context 篩選/表單選單功能一切正常（確認重構沒有改壞原本行為）
[ ] 瀏覽器 Console 檢查：開啟分機管理、路由規則、自定義 Dialplan 三個頁面皆無 JS 錯誤
[ ] 儲存分機（含 Context 值）後，用「🔄 變更號碼」流程也測一次，確認新分機的 context 正確帶到新號碼上
──────────────────────────────────────────────────────

確認無誤後，手動執行：
  git push
EOF
