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
