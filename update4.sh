#!/usr/bin/env bash
# update4.sh — 修正使用者管理頁面 4 個測試發現的問題：
#   1) 導覽列未依權限矩陣隱藏（新增 JWT payload 解析 + 依權限隱藏 nav-item）
#   2) 使用者列表帳號欄白字看不到（亮色主題誤用 color:#fff）
#   3) 群組卡片標題長名稱被裁切（.panel overflow:hidden + Syne 字體行高不足）
#   4) 側邊欄沒有登出按鈕（common.js 早有 logout()，但沒有 UI 呼叫）
set -euo pipefail
cd /opt/fs-dashboard

echo "═══ update4.sh 開始 ═══"

# ── 0. 前置驗證 ──────────────────────────────────────────────────────────────
echo "[1/6] 前置驗證..."

# 0-1. 確認 update3.sh 已套用
if ! grep -q 'data-page="users"' static/index.html; then
  echo "❌ static/index.html 尚未包含 data-page=\"users\"，請先確認 update3.sh 是否成功套用" >&2
  exit 1
fi
if ! grep -q 'renderUsersManagement' static/js/init.js; then
  echo "❌ static/js/init.js 尚未包含 renderUsersManagement，請先確認 update3.sh 是否成功套用" >&2
  exit 1
fi

# 0-2. 冪等檢查：避免重複套用本次變更
if grep -q 'getTokenPayload' static/js/common.js; then
  echo "❌ static/js/common.js 已包含 getTokenPayload，本次變更疑似已套用過，中止" >&2
  exit 1
fi
if grep -q 'onclick="logout()"' static/index.html; then
  echo "❌ static/index.html 已包含登出按鈕，本次變更疑似已套用過，中止" >&2
  exit 1
fi
if grep -q 'applyAuthUI' static/js/init.js; then
  echo "❌ static/js/init.js 已包含 applyAuthUI，本次變更疑似已套用過，中止" >&2
  exit 1
fi

# 0-3. 確認錨點字串目前確實存在（且只有一份）
python3 - << 'VERIFY_EOF'
import sys

with open('static/js/common.js', encoding='utf-8') as f:
    common = f.read()
with open('static/index.html', encoding='utf-8') as f:
    html = f.read()

common_anchor = '''function isTokenValid(token) {
  if (!token) return false;
  try {
    const payload = JSON.parse(atob(token.split('.')[1]));
    return !!payload.exp && payload.exp * 1000 > Date.now();
  } catch (e) {
    return false;
  }
}

function redirectToLogin() {'''

html_anchor = '''      <div class="server-status" id="sf-sys-status">系統狀態：載入中...</div>
    </div>
  </aside>'''

for name, content, anchor in [
    ('common.js isTokenValid 錨點', common, common_anchor),
    ('index.html sidebar-footer 錨點', html, html_anchor),
]:
    count = content.count(anchor)
    if count != 1:
        print(f"❌ {name} 應剛好出現 1 次，實際出現 {count} 次，中止", file=sys.stderr)
        sys.exit(1)

print("✓ 前置驗證通過")
VERIFY_EOF

# ── 1. 自動歸檔（固定丟進 updateN/ 資料夾，與功能改動分開 commit）───────────
echo "[2/6] 自動歸檔舊版 updateN.sh..."
CURRENT=4
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

# ── 2. common.js：新增 getTokenPayload() ─────────────────────────────────────
echo "[3/6] 更新 static/js/common.js..."
python3 - << 'PATCH_COMMON_EOF'
import sys

path = 'static/js/common.js'
with open(path, encoding='utf-8') as f:
    content = f.read()

anchor = '''function isTokenValid(token) {
  if (!token) return false;
  try {
    const payload = JSON.parse(atob(token.split('.')[1]));
    return !!payload.exp && payload.exp * 1000 > Date.now();
  } catch (e) {
    return false;
  }
}

function redirectToLogin() {'''

insert = '''function isTokenValid(token) {
  if (!token) return false;
  try {
    const payload = JSON.parse(atob(token.split('.')[1]));
    return !!payload.exp && payload.exp * 1000 > Date.now();
  } catch (e) {
    return false;
  }
}

/** 直接解出 JWT payload（含使用者名稱、群組、權限矩陣），不需額外打 API */
function getTokenPayload() {
  const token = getToken();
  if (!token) return null;
  try {
    return JSON.parse(atob(token.split('.')[1]));
  } catch (e) {
    return null;
  }
}

function redirectToLogin() {'''

if content.count(anchor) != 1:
    print("❌ common.js 錨點比對失敗", file=sys.stderr); sys.exit(1)
content = content.replace(anchor, insert, 1)

with open(path, 'w', encoding='utf-8') as f:
    f.write(content)

print("✓ common.js 更新完成")
PATCH_COMMON_EOF

# ── 3. index.html：側邊欄補登入身分顯示 + 登出按鈕 ───────────────────────────
echo "[4/6] 更新 static/index.html..."
python3 - << 'PATCH_HTML_EOF'
import sys

path = 'static/index.html'
with open(path, encoding='utf-8') as f:
    content = f.read()

anchor = '''      <div class="server-status" id="sf-sys-status">系統狀態：載入中...</div>
    </div>
  </aside>'''

insert = '''      <div class="server-status" id="sf-sys-status">系統狀態：載入中...</div>
      <div id="sf-user-info" style="font-size:11px;color:var(--muted);margin-top:6px"></div>
      <button class="btn" style="width:100%;margin-top:8px" onclick="logout()">🚪 登出</button>
    </div>
  </aside>'''

if content.count(anchor) != 1:
    print("❌ index.html sidebar-footer 錨點比對失敗", file=sys.stderr); sys.exit(1)
content = content.replace(anchor, insert, 1)

with open(path, 'w', encoding='utf-8') as f:
    f.write(content)

print("✓ index.html 更新完成")
PATCH_HTML_EOF

# ── 4. init.js：完整覆寫（新增 applyAuthUI：依權限隱藏 nav-item + 顯示登入身分）─
echo "[5/6] 寫入 static/js/init.js..."
cat > static/js/init.js << 'INITJS_EOF'
// init.js — App 啟動進入點，必須放在所有其他 js 檔「之後」載入，
// 因為這裡會呼叫 switchPage('overview') 等，依賴所有頁面 render 函式已經定義完成。

const pages = {
  overview:    { render: renderOverview,    title: '通話即時狀態' },
  report:      { render: renderReport,      title: '通話統計報表' },
  calls:       { render: renderCalls,       title: '即時通話監控' },
  extensions:  { render: renderExtensions,  title: '分機管理' },
  groups:      { render: renderGroups,      title: '分機群組管理' },
  ivr:         { render: renderIVR,         title: 'IVR 互動語音管理' },
  cdr:         { render: renderCDR,         title: '通話記錄 CDR' },
  gateway:     { render: renderGateway,     title: 'Gateway / SIP Trunk' },
  dialplan_routes:     { render: () => renderDialplanHub('dialplan_routes'),     title: 'Dialplan 路由設定' },
  dialplan_custom:     { render: () => renderDialplanHub('dialplan_custom'),     title: 'Dialplan 路由設定' },
  dialplan_system_ext: { render: () => renderDialplanHub('dialplan_system_ext'), title: 'Dialplan 路由設定' },
  sounds:      { render: renderSoundLibrary, title: '音檔庫' },
  recordings:  { render: renderRecordings,  title: '錄音管理' },
  esl:         { render: renderESL,         title: 'ESL 終端機' },
  numbers:     { render: renderNumbers,     title: '號碼目錄' },
  logs:        { render: renderLogs,        title: '系統日誌' },
  settings:    { render: () => renderSettings(_settingsNode), title: '系統設定' },
  backup:      { render: () => renderBackupPage(_backupNode),  title: '備份管理' },
  sip_profile: { render: renderSipProfile,  title: 'SIP Profile 進階設定' },
  users:       { render: renderUsersManagement, title: '使用者管理' },
};

let currentPage = 'overview';

// ── 依 JWT 權限矩陣調整畫面：隱藏無權限的導覽項目 + 顯示登入身分 ──────────────
// JWT payload 已快取整份權限矩陣（core/auth.py 設計如此），不需額外打 API。
// data-page 與 core/permissions.py 的 Module 常數大部分同名，Dialplan 三個子頁共用 'dialplan' 模組。
const NAV_PAGE_TO_MODULE = {
  dialplan_routes: 'dialplan', dialplan_custom: 'dialplan', dialplan_system_ext: 'dialplan',
};

function applyAuthUI() {
  const payload = getTokenPayload();
  if (!payload) return;

  const perms = payload.permissions;
  if (perms) {
    document.querySelectorAll('.nav-item[data-page]').forEach(el => {
      const page = el.dataset.page;
      const mod  = NAV_PAGE_TO_MODULE[page] || page;
      const p    = perms[mod];
      if (!p || !p.read) el.style.display = 'none';
    });
  }

  const userInfoEl = document.getElementById('sf-user-info');
  if (userInfoEl) {
    const name  = payload.username   || '';
    const group = payload.group_name || '';
    userInfoEl.textContent = name ? `登入身分：${name}${group ? '（' + group + '）' : ''}` : '';
  }
}

async function switchPage(id) {
  if (!pages[id]) return;

  // 離開日誌頁時關閉 SSE
  if (currentPage === 'logs' && id !== 'logs') {
    if (_logSSE) { _logSSE.close(); _logSSE = null; }
  }

  currentPage = id;

  try {
    const result = pages[id].render();
    if (result && typeof result.then === 'function') {
      await result;
    } else if (result) {
      document.getElementById('mainContent').innerHTML = result;
    }
  } catch(e) {
    console.error('switchPage error:', e);
    document.getElementById('mainContent').innerHTML =
      `<div style="padding:40px;text-align:center;color:var(--red)">頁面載入錯誤：${e.message}</div>`;
  }

  const titleEl = document.getElementById('pageTitle');
  if (titleEl) titleEl.textContent = pages[id].title;
  // 高亮側邊欄對應的 nav-item（Dialplan 3 個子頁共用同一個 nav-item）
  const DIALPLAN_HUB_IDS = ['dialplan_routes', 'dialplan_system_ext', 'dialplan_custom'];
  const navTargetId = DIALPLAN_HUB_IDS.includes(id) ? 'dialplan_routes' : id;
  document.querySelectorAll('.nav-item').forEach(el => {
    el.classList.toggle('active', el.dataset.page === navTargetId);
  });
}

async function refreshData() {
  await switchPage(currentPage);
}



initWebSocket();
initNavCollapse();
applyAuthUI();
switchPage('overview');
updateNavBadge();  // 初始載入取一次

// 自動請求瀏覽器通知權限（若尚未設定）
if ('Notification' in window && Notification.permission === 'default') {
  document.addEventListener('click', function askPerm() {
    Notification.requestPermission();
    document.removeEventListener('click', askPerm);
  }, { once: true });
}

// 頁面狀態完全由 WebSocket 事件驅動，不使用 setInterval 輪詢
// - 分機頁：EXT_STATUS_UPDATE 事件 → applyExtStatusUpdate() 局部更新 DOM
// - 總覽/通話頁：CHANNEL_* 事件 → switchPage() 重繪
// - 即時通話 badge：CHANNEL_* 事件 → updateNavBadge()
INITJS_EOF

echo "✓ init.js 寫入完成（$(wc -l < static/js/init.js) 行）"

# ── 5. users-management.js：完整覆寫（修正白字 + 標題裁切）───────────────────
echo "[6/6] 寫入 static/js/users-management.js..."
cat > static/js/users-management.js << 'USERSJS_EOF'
// users-management.js — 使用者管理 + 權限群組管理（單頁雙 Tab）
// 依賴 common.js 的 apiFetch() / getToken()，慣例比照 extensions-groups.js 的 list/editor 面板切換寫法。
// 欄位已對照 core/auth_db.py 確認：list_users()/list_groups() 回傳欄位與本檔假設一致。

const _UM_MODULE_LABELS = {
  overview: '總覽', report: '報表', extensions: '分機管理', groups: '分機群組',
  ivr: 'IVR', numbers: '號碼目錄', calls: '即時通話', cdr: 'CDR',
  recordings: '錄音', sounds: '音檔庫', sip_profile: 'SIP Profile',
  gateway: 'Gateway', dialplan: 'Dialplan', esl: 'ESL', logs: '系統日誌',
  acl: 'ACL', settings: '系統設定', backup: '備份', users: '使用者管理',
};
const _UM_CATEGORIES = [
  { label: 'Dashboard',   mods: ['overview', 'report'] },
  { label: 'Operational', mods: ['extensions', 'groups', 'ivr', 'numbers', 'calls', 'cdr', 'recordings', 'sounds', 'sip_profile'] },
  { label: 'System',      mods: ['gateway', 'dialplan', 'esl', 'logs', 'acl', 'settings', 'backup', 'users'] },
];
const _UM_SCOPABLE_MODULES = new Set(['cdr', 'recordings', 'calls']);

let _umTab = 'users';
let _umUsers = [];
let _umGroups = [];
let _umEditingUserId = null;
let _umEditingGroupId = null;

async function renderUsersManagement() {
  document.getElementById('mainContent').innerHTML =
    `<div style="padding:40px;text-align:center;color:var(--muted)">載入中...</div>`;

  const [userData, groupData] = await Promise.all([
    apiFetch('/api/users'),
    apiFetch('/api/perm-groups'),
  ]);
  _umUsers  = (userData  && userData.rows) ? userData.rows  : [];
  _umGroups = (groupData && groupData.rows) ? groupData.rows : [];

  document.getElementById('mainContent').innerHTML = `
  <div class="panel" style="margin-bottom:12px">
    <div style="display:flex;gap:8px;padding:14px 20px 0 20px">
      <button class="btn ${_umTab === 'users' ? 'primary' : ''}" onclick="_umSwitchTab('users')">👤 使用者</button>
      <button class="btn ${_umTab === 'groups' ? 'primary' : ''}" onclick="_umSwitchTab('groups')">🛡 權限群組</button>
    </div>
    <div style="font-size:11px;color:var(--muted);padding:8px 20px 14px 20px">
      ⚠️ 權限異動不會立即生效：使用者需要重新登入，JWT 才會帶入最新的權限矩陣。
    </div>
  </div>

  <div id="um-tab-users-content" style="${_umTab === 'users' ? '' : 'display:none'}">
    <div id="um-users-list-panel">${_umBuildUsersListPanel()}</div>
    <div id="um-users-editor-panel" style="display:none"></div>
  </div>

  <div id="um-tab-groups-content" style="${_umTab === 'groups' ? '' : 'display:none'}">
    <div id="um-groups-list-panel">${_umBuildGroupsListPanel()}</div>
    <div id="um-groups-editor-panel" style="display:none"></div>
  </div>
  `;
}

function _umSwitchTab(tab) {
  _umTab = tab;
  document.getElementById('um-tab-users-content').style.display  = tab === 'users'  ? '' : 'none';
  document.getElementById('um-tab-groups-content').style.display = tab === 'groups' ? '' : 'none';
  const btns = document.querySelectorAll('#mainContent > .panel:first-child button.btn');
  if (btns[0]) btns[0].className = `btn ${tab === 'users' ? 'primary' : ''}`;
  if (btns[1]) btns[1].className = `btn ${tab === 'groups' ? 'primary' : ''}`;
}

function _umGroupName(u) {
  if (u.group_name) return u.group_name;
  const g = _umGroups.find(g => g.id === u.group_id);
  return g ? g.name : (u.group_id != null ? `#${u.group_id}` : '—');
}

function _umBuildUsersListPanel() {
  const rows = _umUsers.map(u => {
    const disabled = !!u.disabled;
    const mustChange = !!u.must_change_password;
    return `
    <tr>
      <td style="padding:8px 10px;color:var(--text)">${u.username}</td>
      <td style="padding:8px 10px">${_umGroupName(u)}</td>
      <td style="padding:8px 10px;font-family:monospace">${u.owned_ext || '—'}</td>
      <td style="padding:8px 10px">
        <span style="padding:2px 8px;border-radius:20px;font-size:11px;font-weight:700;
          ${disabled ? 'background:#616161;color:#fff' : 'background:#2e7d32;color:#fff'}">
          ${disabled ? '已停用' : '啟用中'}
        </span>
        ${mustChange ? '<span style="margin-left:6px;font-size:10px;color:var(--yellow)">待改密碼</span>' : ''}
      </td>
      <td style="padding:8px 10px;display:flex;gap:4px;flex-wrap:wrap">
        <button class="btn" style="padding:3px 8px;font-size:10px" onclick="_umOpenUserEditor(${u.id})">✏ 編輯</button>
        <button class="btn" style="padding:3px 8px;font-size:10px" onclick="_umResetPassword(${u.id}, '${(u.username||'').replace(/'/g, "\\'")}')">🔑 重設密碼</button>
        <button class="btn danger" style="padding:3px 8px;font-size:10px" onclick="_umDeleteUser(${u.id}, '${(u.username||'').replace(/'/g, "\\'")}')">✕ 刪除</button>
      </td>
    </tr>`;
  }).join('');

  return `
  <div class="panel">
    <div class="panel-header">
      <span class="panel-badge">${_umUsers.length} 位使用者</span>
      <div class="panel-actions">
        <button class="btn" onclick="switchPage('users')">↺ 刷新</button>
        <button class="btn primary" onclick="_umOpenUserEditor(null)">+ 新增使用者</button>
      </div>
    </div>
    <table style="width:100%;border-collapse:collapse;font-size:12px">
      <thead>
        <tr style="text-align:left;color:var(--muted);border-bottom:1px solid var(--border)">
          <th style="padding:8px 10px">帳號</th>
          <th style="padding:8px 10px">權限群組</th>
          <th style="padding:8px 10px">專屬分機</th>
          <th style="padding:8px 10px">狀態</th>
          <th style="padding:8px 10px">操作</th>
        </tr>
      </thead>
      <tbody>
        ${rows || `<tr><td colspan="5" style="text-align:center;color:var(--muted);padding:24px">尚無使用者</td></tr>`}
      </tbody>
    </table>
  </div>`;
}

function _umOpenUserEditor(userId) {
  _umEditingUserId = userId;
  const listPanel   = document.getElementById('um-users-list-panel');
  const editorPanel = document.getElementById('um-users-editor-panel');
  const u = userId != null ? _umUsers.find(x => x.id === userId) : null;

  const groupOptions = _umGroups.map(g =>
    `<option value="${g.id}" ${u && u.group_id === g.id ? 'selected' : ''}>${g.name}${g.is_builtin ? '（內建）' : ''}</option>`
  ).join('');

  editorPanel.innerHTML = `
  <div class="panel" style="max-width:560px;margin:0 auto">
    <div class="panel-header">
      <span class="panel-title" style="line-height:1.6;display:inline-block">${u ? `編輯使用者：${u.username}` : '新增使用者'}</span>
    </div>
    <div style="padding:20px;display:flex;flex-direction:column;gap:14px">
      <div class="settings-row">
        <span class="settings-label">帳號 *</span>
        ${u
          ? `<span style="flex:1;color:var(--muted)">${u.username}（建立後不可變更）</span>`
          : `<input class="settings-input" id="um-user-username" placeholder="例：user1002" />`}
      </div>
      ${u ? '' : `
      <div class="settings-row">
        <span class="settings-label">密碼 *</span>
        <input class="settings-input" id="um-user-password" type="password" placeholder="至少 8 個字元" />
      </div>`}
      <div class="settings-row">
        <span class="settings-label">權限群組 *</span>
        <select class="settings-select" id="um-user-group">
          <option value="">請選擇</option>
          ${groupOptions}
        </select>
      </div>
      <div class="settings-row">
        <span class="settings-label">專屬分機</span>
        <div style="flex:1;display:flex;flex-direction:column;gap:4px">
          <input class="settings-input" id="um-user-owned-ext" placeholder="例：1001（scope=own 群組必填）" value="${u && u.owned_ext ? u.owned_ext : ''}" />
          ${u ? '<span class="settings-hint">留空送出不會清除舊值（後端目前的更新邏輯是「未提供」才略過，無法用空字串清空），如需清空請聯絡後端調整</span>' : ''}
        </div>
      </div>
      ${u ? `
      <div class="settings-row">
        <span class="settings-label">停用帳號</span>
        <label style="display:flex;align-items:center;gap:6px">
          <input type="checkbox" id="um-user-disabled" ${u.disabled ? 'checked' : ''} />
          <span style="font-size:12px;color:var(--muted)">停用後該帳號無法登入</span>
        </label>
      </div>` : ''}

      <div style="display:flex;gap:8px;margin-top:8px;align-items:center">
        <button class="btn" onclick="_umCloseUserEditor()">← 取消</button>
        <button class="btn primary" style="flex:1" onclick="${u ? `_umSaveUserEdits(${u.id})` : '_umSaveNewUser()'}">💾 儲存</button>
        <span id="um-user-save-msg" style="font-size:12px;opacity:0;transition:opacity 0.3s"></span>
      </div>
    </div>
  </div>`;

  listPanel.style.display   = 'none';
  editorPanel.style.display = 'block';
}

function _umCloseUserEditor() {
  document.getElementById('um-users-list-panel').style.display   = 'block';
  document.getElementById('um-users-editor-panel').style.display = 'none';
}

async function _umSaveNewUser() {
  const msg = document.getElementById('um-user-save-msg');
  const username = document.getElementById('um-user-username').value.trim();
  const password = document.getElementById('um-user-password').value;
  const groupId  = document.getElementById('um-user-group').value;
  const ownedExt = document.getElementById('um-user-owned-ext').value.trim();

  if (!username) { alert('請輸入帳號'); return; }
  if (!password || password.length < 8) { alert('密碼至少需要 8 個字元'); return; }
  if (!groupId) { alert('請選擇權限群組'); return; }

  const selectedGroup = _umGroups.find(g => g.id === parseInt(groupId));
  if (selectedGroup && selectedGroup.scope === 'own' && !ownedExt) {
    alert(`「${selectedGroup.name}」的 scope 是 own，必須填寫專屬分機（owned_ext）。`);
    return;
  }

  if (msg) { msg.textContent = '儲存中...'; msg.style.opacity = '1'; msg.style.color = 'var(--yellow)'; }
  const data = await apiFetch('/api/users', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ username, password, group_id: parseInt(groupId), owned_ext: ownedExt || null }),
  });
  if (data && data.id != null) {
    if (msg) { msg.textContent = '✓ 已建立'; msg.style.color = 'var(--green)'; }
    setTimeout(() => switchPage('users'), 500);
  } else {
    if (msg) { msg.textContent = `✗ 建立失敗：${(data && data.detail) || '未知錯誤'}`; msg.style.color = 'var(--red)'; }
  }
}

async function _umSaveUserEdits(userId) {
  const msg = document.getElementById('um-user-save-msg');
  const groupId  = document.getElementById('um-user-group').value;
  const ownedExt = document.getElementById('um-user-owned-ext').value.trim();
  const disabledEl = document.getElementById('um-user-disabled');

  if (!groupId) { alert('請選擇權限群組'); return; }
  const selectedGroup = _umGroups.find(g => g.id === parseInt(groupId));
  if (selectedGroup && selectedGroup.scope === 'own' && !ownedExt) {
    if (!confirm(`「${selectedGroup.name}」的 scope 是 own，通常需要專屬分機才能正常運作，確定要保存空白的專屬分機？`)) return;
  }

  if (msg) { msg.textContent = '儲存中...'; msg.style.opacity = '1'; msg.style.color = 'var(--yellow)'; }
  const data = await apiFetch(`/api/users/${userId}`, {
    method: 'PUT',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      group_id: parseInt(groupId),
      owned_ext: ownedExt || null,
      disabled: disabledEl ? disabledEl.checked : undefined,
    }),
  });
  if (data && data.ok) {
    if (msg) { msg.textContent = '✓ 已儲存'; msg.style.color = 'var(--green)'; }
    setTimeout(() => switchPage('users'), 500);
  } else {
    if (msg) { msg.textContent = `✗ 儲存失敗：${(data && data.detail) || '未知錯誤'}`; msg.style.color = 'var(--red)'; }
  }
}

async function _umResetPassword(userId, username) {
  const pwd = prompt(`請輸入使用者「${username}」的新密碼（至少 8 個字元）：`);
  if (!pwd) return;
  if (pwd.length < 8) { alert('密碼至少需要 8 個字元'); return; }
  if (!confirm(`確定要重設「${username}」的密碼？下次登入將強制要求變更密碼。`)) return;

  const data = await apiFetch(`/api/users/${userId}/reset-password`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ new_password: pwd }),
  });
  if (data && data.ok) { alert('✓ 密碼已重設'); }
  else { alert(`✗ 重設失敗：${(data && data.detail) || '未知錯誤'}`); }
}

async function _umDeleteUser(userId, username) {
  if (!confirm(`確定要刪除使用者「${username}」？此操作無法復原。`)) return;
  const data = await apiFetch(`/api/users/${userId}`, { method: 'DELETE' });
  if (data && data.ok) { switchPage('users'); }
  else { alert(`刪除失敗：${(data && data.detail) || '未知錯誤'}`); }
}

function _umBuildGroupsListPanel() {
  const cards = _umGroups.map(g => {
    const scopeLabel = g.scope === 'own' ? '僅本人 (own)' : '全部 (all)';
    return `
    <div class="panel" style="margin-bottom:10px">
      <div class="panel-header">
        <span class="panel-title" style="line-height:1.6;display:inline-block">${g.name} ${g.is_builtin ? '<span style="font-size:10px;color:var(--muted);margin-left:6px">內建・不可刪除/改名</span>' : ''}</span>
        <div class="panel-actions">
          <span class="panel-badge">scope: ${scopeLabel}</span>
          <button class="btn" style="padding:3px 8px;font-size:11px" onclick="_umOpenGroupEditor(${g.id})">${g.is_builtin ? '👁 檢視矩陣' : '✏ 編輯權限矩陣'}</button>
          ${g.is_builtin ? '' : `<button class="btn danger" style="padding:3px 8px;font-size:11px" onclick="_umDeleteGroup(${g.id}, '${(g.name||'').replace(/'/g, "\\'")}')">✕ 刪除</button>`}
        </div>
      </div>
      ${g.description ? `<div style="padding:0 20px 14px 20px;font-size:12px;color:var(--muted)">${g.description}</div>` : ''}
    </div>`;
  }).join('');

  return `
  <div class="panel" style="margin-bottom:10px">
    <div class="panel-header">
      <span class="panel-badge">${_umGroups.length} 個群組</span>
      <div class="panel-actions">
        <button class="btn" onclick="switchPage('users')">↺ 刷新</button>
        <button class="btn primary" onclick="_umOpenGroupEditor(null)">+ 新增自訂群組</button>
      </div>
    </div>
  </div>
  ${cards || `<div style="padding:40px;text-align:center;color:var(--muted)">尚無群組</div>`}`;
}

function _umBuildMatrixTable(prefix, existingPerms, readonly) {
  const dis = readonly ? 'disabled' : '';
  const sections = _UM_CATEGORIES.map(cat => {
    const rows = cat.mods.map(mod => {
      const p = (existingPerms && existingPerms[mod]) || {};
      const scopableNote = _UM_SCOPABLE_MODULES.has(mod)
        ? '<span style="font-size:9px;color:var(--accent)" title="scope=own 時此模組會依專屬分機過濾">◆</span>' : '';
      return `
      <tr>
        <td style="padding:5px 8px">${_UM_MODULE_LABELS[mod] || mod} ${scopableNote}</td>
        ${['read', 'create', 'update', 'delete'].map(action => `
        <td style="padding:5px 8px;text-align:center">
          <input type="checkbox" id="${prefix}-${mod}-${action}" ${p[action] ? 'checked' : ''} ${dis} />
        </td>`).join('')}
      </tr>`;
    }).join('');
    return `
    <tr><td colspan="5" style="padding:10px 8px 4px 8px;font-size:11px;color:var(--accent-bright);font-weight:700">${cat.label}</td></tr>
    ${rows}`;
  }).join('');

  return `
  <table style="width:100%;border-collapse:collapse;font-size:12px">
    <thead>
      <tr style="text-align:center;color:var(--muted);border-bottom:1px solid var(--border)">
        <th style="text-align:left;padding:5px 8px">模組</th>
        <th>讀取 (R)</th><th>新增 (C)</th><th>修改 (U)</th><th>刪除 (D)</th>
      </tr>
    </thead>
    <tbody>${sections}</tbody>
  </table>
  <div style="font-size:10px;color:var(--muted);margin-top:8px">◆ = 此模組會受群組 scope=own 影響，僅回傳使用者「專屬分機」相關資料</div>`;
}

function _umCollectMatrix(prefix) {
  const perms = {};
  _UM_CATEGORIES.forEach(cat => cat.mods.forEach(mod => {
    perms[mod] = {
      read:   document.getElementById(`${prefix}-${mod}-read`).checked,
      create: document.getElementById(`${prefix}-${mod}-create`).checked,
      update: document.getElementById(`${prefix}-${mod}-update`).checked,
      delete: document.getElementById(`${prefix}-${mod}-delete`).checked,
    };
  }));
  return perms;
}

function _umOpenGroupEditor(groupId) {
  _umEditingGroupId = groupId;
  const listPanel   = document.getElementById('um-groups-list-panel');
  const editorPanel = document.getElementById('um-groups-editor-panel');
  const g = groupId != null ? _umGroups.find(x => x.id === groupId) : null;
  const readonly = !!(g && g.is_builtin);

  editorPanel.innerHTML = `
  <div class="panel" style="max-width:720px;margin:0 auto">
    <div class="panel-header">
      <span class="panel-title" style="line-height:1.6;display:inline-block">${g ? (readonly ? `檢視群組：${g.name}` : `編輯權限矩陣：${g.name}`) : '新增自訂群組'}</span>
    </div>
    <div style="padding:20px;display:flex;flex-direction:column;gap:14px">
      <div class="settings-row">
        <span class="settings-label">群組名稱 *</span>
        ${g
          ? `<span style="flex:1;color:var(--muted)">${g.name}（建立後不可變更）</span>`
          : `<input class="settings-input" id="um-group-name" placeholder="例：Sales Manager" />`}
      </div>
      <div class="settings-row">
        <span class="settings-label">說明</span>
        ${g
          ? `<span style="flex:1;color:var(--muted)">${g.description || '—'}</span>`
          : `<input class="settings-input" id="um-group-description" placeholder="選填，說明此群組用途" />`}
      </div>
      <div class="settings-row">
        <span class="settings-label">Scope *</span>
        ${g
          ? `<span style="flex:1;color:var(--muted)">${g.scope === 'own' ? '僅本人 (own)（建立後不可變更）' : '全部 (all)（建立後不可變更）'}</span>`
          : `<select class="settings-select" id="um-group-scope">
               <option value="all">全部 (all)</option>
               <option value="own">僅本人 (own)</option>
             </select>`}
      </div>

      <div style="overflow-x:auto">
        ${_umBuildMatrixTable('um-group', g ? g.permissions : null, readonly)}
      </div>

      <div style="display:flex;gap:8px;margin-top:8px;align-items:center">
        <button class="btn" onclick="_umCloseGroupEditor()">← ${readonly ? '關閉' : '取消'}</button>
        ${readonly ? '' : `
        <button class="btn primary" style="flex:1" onclick="${g ? `_umSaveGroupPermissions(${g.id})` : '_umSaveNewGroup()'}">💾 儲存</button>
        <span id="um-group-save-msg" style="font-size:12px;opacity:0;transition:opacity 0.3s"></span>`}
      </div>
      ${readonly ? '' : `
      <div style="font-size:11px;color:var(--muted)">
        ⚠️ 群組名稱與 Scope 一經建立即無法修改；已登入的使用者需要重新登入才會套用新的權限矩陣。
      </div>`}
    </div>
  </div>`;

  listPanel.style.display   = 'none';
  editorPanel.style.display = 'block';
}

function _umCloseGroupEditor() {
  document.getElementById('um-groups-list-panel').style.display   = 'block';
  document.getElementById('um-groups-editor-panel').style.display = 'none';
}

async function _umSaveNewGroup() {
  const msg = document.getElementById('um-group-save-msg');
  const name        = document.getElementById('um-group-name').value.trim();
  const description = document.getElementById('um-group-description').value.trim();
  const scope       = document.getElementById('um-group-scope').value;

  if (!name) { alert('請輸入群組名稱'); return; }

  const permissions = _umCollectMatrix('um-group');

  if (msg) { msg.textContent = '儲存中...'; msg.style.opacity = '1'; msg.style.color = 'var(--yellow)'; }
  const data = await apiFetch('/api/perm-groups', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ name, description, scope, permissions }),
  });
  if (data && data.id != null) {
    if (msg) { msg.textContent = '✓ 已建立'; msg.style.color = 'var(--green)'; }
    setTimeout(() => switchPage('users'), 500);
  } else {
    if (msg) { msg.textContent = `✗ 建立失敗：${(data && data.detail) || '未知錯誤'}`; msg.style.color = 'var(--red)'; }
  }
}

async function _umSaveGroupPermissions(groupId) {
  const msg = document.getElementById('um-group-save-msg');
  const permissions = _umCollectMatrix('um-group');

  if (msg) { msg.textContent = '儲存中...'; msg.style.opacity = '1'; msg.style.color = 'var(--yellow)'; }
  const data = await apiFetch(`/api/perm-groups/${groupId}/permissions`, {
    method: 'PUT',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ permissions }),
  });
  if (data && data.ok) {
    if (msg) { msg.textContent = '✓ 已儲存'; msg.style.color = 'var(--green)'; }
    setTimeout(() => switchPage('users'), 500);
  } else {
    if (msg) { msg.textContent = `✗ 儲存失敗：${(data && data.detail) || '未知錯誤'}`; msg.style.color = 'var(--red)'; }
  }
}

async function _umDeleteGroup(groupId, name) {
  if (!confirm(`確定要刪除群組「${name}」？若有使用者正在使用此群組，刪除可能會失敗。`)) return;
  const data = await apiFetch(`/api/perm-groups/${groupId}`, { method: 'DELETE' });
  if (data && data.ok) { switchPage('users'); }
  else { alert(`刪除失敗：${(data && data.detail) || '未知錯誤'}`); }
}
USERSJS_EOF

echo "✓ users-management.js 寫入完成（$(wc -l < static/js/users-management.js) 行）"

# ── 6. Commit ─────────────────────────────────────────────────────────────
echo "Git commit..."
git add -A
git commit -m "fix: 使用者管理頁面 4 項測試回饋（權限隱藏導覽列/帳號白字/標題裁切/補登出按鈕）"

echo ""
echo "═══ update4.sh 完成 ═══"
git log --oneline -1

cat << 'CHECKLIST_EOF'

── 驗證重點清單 ──────────────────────────────────────────
1. 不需要 systemctl restart（純前端），瀏覽器強制重新整理（Ctrl+Shift+R）
2. 用 Taichung_IT_Support 群組（未勾使用者管理讀取）的帳號登入：
   - 側邊欄「使用者管理」應該消失
   - 順便檢查其他沒勾權限的模組，nav-item 是否也正確消失
3. 用有權限的帳號登入「使用者管理」：
   - 使用者列表帳號欄文字應該是深色可讀，不用反白
   - 權限群組 Tab 裡 Taichung_IT_Support 的完整名稱（含 g 的下伸筆畫）要能完整顯示
4. 側邊欄最下方應該出現「登入身分：xxx（群組名）」文字 + 「🚪 登出」按鈕，點擊登出應導回登入頁
5. 確認 git log 有 fix: 這筆 commit
CHECKLIST_EOF
