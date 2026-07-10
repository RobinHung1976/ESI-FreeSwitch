// sip-profile.js — SIP Profile 進階設定（比照 dialplan.js 的 Hub 版面：左側子選單 + 右側內容）

const SP_HUB_TREE = [
  { id: 'sp-params', icon: '📡', label: 'Profile 參數' },
  { id: 'sp-acl',    icon: '🛡️', label: '信任 SBC 清單' },
  { id: 'sp-nat',    icon: '➕', label: '新增 NAT Profile' },
];

let _spTab = 'sp-params';
let _spCurrentProfile = null;

async function renderSipProfile() {
  const treeHtml = SP_HUB_TREE.map(item => `
    <div class="stree-item ${_spTab === item.id ? 'active' : ''}"
         onclick="switchSpTab('${item.id}')">
      <span class="stree-icon">${item.icon}</span>
      <span class="stree-label">${item.label}</span>
    </div>`).join('');

  document.getElementById('mainContent').innerHTML = `
  <div style="display:flex;height:calc(100vh - 120px);gap:0">
    <div style="width:200px;min-width:200px;background:var(--panel);border:1px solid var(--border);
                border-radius:6px;overflow-y:auto;flex-shrink:0">
      <div style="padding:14px 16px;border-bottom:1px solid var(--border);
                  font-family:'Syne',sans-serif;font-weight:700;font-size:15px;color:#fff;
                  background:rgba(66,165,245,0.06)">
        📡 SIP Profile 進階設定
      </div>
      <div class="stree">${treeHtml}</div>
    </div>
    <div id="sp-hub-content" style="flex:1;min-width:0;margin-left:12px;overflow-y:auto"></div>
  </div>`;

  await renderSpTabContent();
}

async function switchSpTab(tabId) {
  _spTab = tabId;
  document.querySelectorAll('.stree-item').forEach(el => el.classList.remove('active'));
  await renderSpTabContent();
  // 重新標記 active（renderSpTabContent 不會重畫左側樹）
  const idx = SP_HUB_TREE.findIndex(t => t.id === tabId);
  const items = document.querySelectorAll('.stree-item');
  if (items[idx]) items[idx].classList.add('active');
}

async function renderSpTabContent() {
  const el = document.getElementById('sp-hub-content');
  if (!el) return;
  if (_spTab === 'sp-params') return renderSpParamsTab(el);
  if (_spTab === 'sp-acl')    return renderSpAclTab(el);
  if (_spTab === 'sp-nat')    return renderSpNatTab(el);
}


// ══════════════════════════════════════════════════════════════════════════
// Tab 1：Profile 參數（白名單編輯 + 黑名單唯讀）
// ══════════════════════════════════════════════════════════════════════════

async function renderSpParamsTab(container) {
  container.innerHTML = `<div style="padding:40px;text-align:center;color:var(--muted)">載入中...</div>`;

  const listData = await apiFetch('/api/sip-profile');
  const profiles = (listData && listData.profiles) ? listData.profiles : [];
  if (!_spCurrentProfile || !profiles.includes(_spCurrentProfile)) {
    _spCurrentProfile = profiles.includes('internal') ? 'internal' : (profiles[0] || null);
  }

  const options = profiles.map(p =>
    `<option value="${p}" ${p === _spCurrentProfile ? 'selected' : ''}>${p}</option>`
  ).join('');

  container.innerHTML = `
  <div class="panel">
    <div class="panel-header">
      <span class="panel-title">SIP Profile 參數</span>
      <div class="panel-actions">
        <select class="settings-select" id="sp-profile-select" style="max-width:220px"
                onchange="onSpProfileChange(this.value)">${options}</select>
        <button class="btn" onclick="switchSpTab('sp-params')">↺ 刷新</button>
      </div>
    </div>
    <div id="sp-params-body" style="padding:20px"></div>
  </div>`;

  if (_spCurrentProfile) {
    await loadSpProfileDetail(_spCurrentProfile);
  } else {
    document.getElementById('sp-params-body').innerHTML =
      `<div style="color:var(--muted);text-align:center;padding:20px">找不到任何 SIP Profile</div>`;
  }
}

async function onSpProfileChange(name) {
  _spCurrentProfile = name;
  await loadSpProfileDetail(name);
}

async function loadSpProfileDetail(name) {
  const body = document.getElementById('sp-params-body');
  body.innerHTML = `<div style="text-align:center;color:var(--muted);padding:20px">載入中...</div>`;

  const data = await apiFetch(`/api/sip-profile/${name}`);
  if (!data) {
    body.innerHTML = `<div style="color:var(--red)">讀取失敗</div>`;
    return;
  }

  const meta = data.meta || {};
  const editableRows = Object.keys(meta).map(key => {
    const m = meta[key];
    const val = data.editable[key] !== undefined ? data.editable[key] : '';
    let inputHtml = '';
    if (m.type === 'bool') {
      inputHtml = `
        <select class="settings-select" data-sp-key="${key}" style="max-width:160px">
          <option value="true"  ${val === 'true'  ? 'selected' : ''}>是 (true)</option>
          <option value="false" ${val === 'false' ? 'selected' : ''}>否 (false)</option>
        </select>`;
    } else if (m.type === 'select') {
      inputHtml = `
        <select class="settings-select" data-sp-key="${key}" style="max-width:160px">
          ${m.options.map(o => `<option value="${o}" ${o === val ? 'selected' : ''}>${o}</option>`).join('')}
        </select>`;
    } else {
      inputHtml = `<input class="settings-input" data-sp-key="${key}" value="${val}" style="max-width:160px">`;
    }
    return `
      <div class="settings-row">
        <span class="settings-label">${m.label}</span>
        ${inputHtml}
        <div style="font-size:11px;color:var(--muted);margin-left:8px">
          <code>${key}</code>${m.warn ? `　⚠️ ${m.warn}` : ''}
        </div>
      </div>`;
  }).join('');

  const readonlyRows = Object.keys(data.readonly || {}).sort().map(key => `
    <tr>
      <td style="color:var(--muted)"><code>${key}</code></td>
      <td style="color:var(--label);word-break:break-all">${data.readonly[key] || '(空)'}</td>
    </tr>`).join('');

  body.innerHTML = `
    <div style="display:flex;flex-direction:column;gap:14px">
      ${editableRows || '<div style="color:var(--muted)">此 profile 無可編輯參數</div>'}
      <div style="display:flex;gap:8px;align-items:center;margin-top:8px">
        <button class="btn primary" onclick="saveSpParams('${name}')">💾 儲存並套用</button>
        <span id="sp-save-msg" style="font-size:12px;opacity:0;transition:opacity 0.3s"></span>
      </div>
      <div style="font-size:11px;color:var(--muted)">
        ✓ 儲存後自動執行 <code style="color:var(--accent-bright)">reloadxml</code>
        及 <code style="color:var(--accent-bright)">sofia profile ${name} restart</code>
        （參數層級設定需 restart 才會生效）
      </div>
    </div>

    <div class="panel" style="margin-top:20px">
      <div class="panel-header">
        <span class="panel-title">🔒 唯讀進階參數（需 SSH 修改）</span>
      </div>
      <div class="table-wrap">
        <table>
          <thead><tr><th>參數</th><th>目前值</th></tr></thead>
          <tbody>${readonlyRows || '<tr><td colspan="2" style="text-align:center;color:var(--muted);padding:14px">無資料</td></tr>'}</tbody>
        </table>
      </div>
      <div style="padding:10px 16px;font-size:11px;color:var(--muted)">
        這些參數（含 ext-sip-ip / ext-rtp-ip / local-network-acl / sip-port / TLS 等）改錯可能導致
        通話中斷或服務起不來，Dashboard 刻意不開放編輯，如需調整請 SSH 進主機直接改設定檔並自行 restart profile。
      </div>
    </div>`;
}

async function saveSpParams(name) {
  const msg = document.getElementById('sp-save-msg');
  const inputs = document.querySelectorAll('#sp-params-body [data-sp-key]');
  const updates = {};
  inputs.forEach(el => { updates[el.dataset.spKey] = el.value; });

  if (Object.keys(updates).length === 0) return;

  if (msg) { msg.textContent = '儲存中...'; msg.style.opacity = '1'; msg.style.color = 'var(--yellow)'; }

  try {
    const res = await fetch(`${API_BASE}/api/sip-profile/${name}`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(updates),
    });
    const data = await res.json();
    if (res.ok && data.ok) {
      if (msg) { msg.textContent = `✓ 已儲存並 restart profile（備份：${(data.backup || '').split('/').pop()}）`; msg.style.color = 'var(--green)'; }
    } else {
      if (msg) { msg.textContent = `✗ ${data.detail || '儲存失敗'}`; msg.style.color = 'var(--red)'; }
    }
  } catch (e) {
    if (msg) { msg.textContent = `✗ ${e.message}`; msg.style.color = 'var(--red)'; }
  }
}


// ══════════════════════════════════════════════════════════════════════════
// Tab 2：信任 SBC 清單（acl.conf.xml trusted_sbc）
// ══════════════════════════════════════════════════════════════════════════

async function renderSpAclTab(container) {
  container.innerHTML = `<div style="padding:40px;text-align:center;color:var(--muted)">載入中...</div>`;

  const data = await apiFetch('/api/acl/trusted-sbc');
  const entries = (data && data.entries) ? data.entries : [];
  const pendingCount = entries.filter(e => !e.active).length;

  const rows = entries.length === 0
    ? `<tr><td colspan="4" style="text-align:center;color:var(--muted);padding:20px">尚無信任的 SBC，請於下方新增</td></tr>`
    : entries.map(e => `
      <tr>
        <td style="color:var(--label);font-weight:600">${e.cidr}</td>
        <td style="color:var(--label)">${e.note || '—'}</td>
        <td>${e.active
          ? '<span class="call-status status-active"><span class="dot"></span>已生效</span>'
          : '<span class="call-status status-hold"><span class="dot"></span>待重啟</span>'}</td>
        <td style="display:flex;gap:4px">
          <button class="btn" style="padding:3px 8px;font-size:11px"
            onclick="openAclEditor('${e.cidr}', '${(e.note || '').replace(/'/g, "\\'")}')">✏ 編輯</button>
          <button class="btn danger" style="padding:3px 8px;font-size:11px"
            onclick="deleteAclEntry('${e.cidr}')">✕ 移除</button>
        </td>
      </tr>`).join('');

  const pendingBanner = pendingCount > 0 ? `
    <div style="background:rgba(255,152,0,0.12);border:1px solid #ff9800;border-radius:6px;
                padding:12px 16px;margin-bottom:14px;display:flex;justify-content:space-between;align-items:center;gap:12px">
      <div style="font-size:12px;color:#7a4a00;line-height:1.6">
        ⚠️ <strong>${pendingCount} 筆變更尚未生效</strong>，需重啟 FreeSWITCH 服務才會套用到記憶體中的 ACL 判斷。
        重啟會中斷所有進行中的通話，請安排維護時間執行。
      </div>
      <button class="btn primary" style="white-space:nowrap" onclick="restartFreeswitchForAcl()">🔄 立即重啟套用</button>
    </div>` : `
    <div style="background:rgba(76,175,80,0.10);border:1px solid var(--green);border-radius:6px;
                padding:10px 16px;margin-bottom:14px;font-size:12px;color:var(--green)">
      ✓ 所有信任項目皆已生效
    </div>`;

  container.innerHTML = `
  ${pendingBanner}
  <div class="panel" style="margin-bottom:14px">
    <div class="panel-header">
      <span class="panel-title">信任的內部 SBC IP / 網段</span>
      <span class="panel-badge">${entries.length} 筆</span>
      <div class="panel-actions">
        <button class="btn" onclick="switchSpTab('sp-acl')">↺ 刷新</button>
      </div>
    </div>
    <div class="table-wrap">
      <table>
        <thead><tr><th>IP / CIDR</th><th>備註</th><th>狀態</th><th>操作</th></tr></thead>
        <tbody>${rows}</tbody>
      </table>
    </div>
  </div>

  <div class="panel">
    <div class="panel-header"><span class="panel-title" id="acl-form-title">+ 新增信任 SBC</span></div>
    <div style="padding:20px;display:flex;flex-direction:column;gap:14px;max-width:520px">
      <div class="settings-row">
        <span class="settings-label">IP / CIDR *</span>
        <input class="settings-input" id="acl-cidr" placeholder="例：172.16.20.2 或 172.16.20.0/24">
      </div>
      <div class="settings-row">
        <span class="settings-label">備註</span>
        <input class="settings-input" id="acl-note" placeholder="例：台北辦公室 AudioCodes SBC">
      </div>
      <div style="display:flex;gap:8px;align-items:center">
        <button class="btn primary" id="acl-submit-btn" onclick="saveAclEntry()">💾 新增</button>
        <span id="acl-save-msg" style="font-size:12px;opacity:0;transition:opacity 0.3s"></span>
      </div>
    </div>
  </div>`;
}

// static/js/sip-profile.js — restartFreeswitchForAcl()
async function restartFreeswitchForAcl(confirmed = false) {
  if (!confirmed && !confirm('確定要重啟 FreeSWITCH 服務嗎？\n這會中斷所有進行中的通話，請確認已安排維護時間。')) return;

  try {
    const res  = await fetch(`${API_BASE}/api/acl/apply-restart`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ confirm: confirmed }),
    });
    const data = await res.json();
    const detailText = Array.isArray(data.detail)
      ? data.detail.map(d => d.msg || JSON.stringify(d)).join('; ')
      : (data.detail || '未知錯誤');

    if (res.status === 409) {
      if (confirm(detailText)) return restartFreeswitchForAcl(true);
      return;
    }
    if (res.ok && data.ok) {
      alert(`✓ 重啟指令已送出（中斷了 ${data.active_calls_dropped} 通通話），約 15-30 秒後自動重新整理狀態`);
      setTimeout(() => switchSpTab('sp-acl'), 20000);   // 5000 → 20000
    } else {
      alert(`✗ 重啟失敗：${detailText}`);
    }
  } catch (e) {
    alert(`✗ 重啟失敗：${e.message}`);
  }
}

let _aclEditingCidr = null;   // null = 新增模式，非 null = 編輯模式（存原始 cidr）

function openAclEditor(cidr, note) {
  _aclEditingCidr = cidr || null;
  document.getElementById('acl-form-title').textContent = cidr ? `編輯信任 SBC：${cidr}` : '+ 新增信任 SBC';
  document.getElementById('acl-cidr').value = cidr || '';
  document.getElementById('acl-note').value = note || '';
  document.getElementById('acl-submit-btn').textContent = cidr ? '💾 儲存修改' : '💾 新增';
}

async function saveAclEntry() {
  const msg  = document.getElementById('acl-save-msg');
  const cidr = document.getElementById('acl-cidr').value.trim();
  const note = document.getElementById('acl-note').value.trim();
  if (!cidr) { alert('請輸入 IP 或 CIDR'); return; }

  if (msg) { msg.textContent = '儲存中...'; msg.style.opacity = '1'; msg.style.color = 'var(--yellow)'; }

  const isEdit = !!_aclEditingCidr;
  const url    = isEdit
    ? `${API_BASE}/api/acl/trusted-sbc/${encodeURIComponent(_aclEditingCidr)}`
    : `${API_BASE}/api/acl/trusted-sbc`;

  try {
    const res  = await fetch(url, {
      method: isEdit ? 'PUT' : 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ cidr, note }),
    });
    const data = await res.json();
    if (res.ok && data.ok) {
      _aclEditingCidr = null;
      switchSpTab('sp-acl');
    } else {
      if (msg) { msg.textContent = `✗ ${data.detail || '儲存失敗'}`; msg.style.color = 'var(--red)'; }
    }
  } catch (e) {
    if (msg) { msg.textContent = `✗ ${e.message}`; msg.style.color = 'var(--red)'; }
  }
}

// static/js/sip-profile.js — deleteAclEntry()
async function deleteAclEntry(cidr) {
  if (!confirm(
    `確定要移除信任來源「${cidr}」？\n\n` +
    `⚠️ 移除後該來源會從清單消失，但 FreeSWITCH 記憶體中的 ACL 判斷「不會」立即改變，` +
    `仍會被視為信任來源，直到重啟服務為止。\n如需立即撤銷信任，移除後請執行「立即重啟套用」。`
  )) return;

  try {
    const res = await fetch(`${API_BASE}/api/acl/trusted-sbc/${encodeURIComponent(cidr)}`, { method: 'DELETE' });
    let data;
    try { data = await res.json(); }
    catch { alert(`移除失敗：伺服器錯誤（HTTP ${res.status}）`); return; }

    // static/js/sip-profile.js — deleteAclEntry() 成功分支
    if (res.ok && data.ok) {
      if (data.still_active_until_restart) {
        alert(`已從清單移除「${cidr}」，但目前仍在 FreeSWITCH 記憶體中生效，需重啟服務才會真正撤銷信任。`);
      }
      switchSpTab('sp-acl');
    } else {
      alert(`移除失敗：${data.detail || '未知錯誤'}`);
    }
  } catch (e) {
    alert(`移除失敗：${e.message}`);
  }
}


// ══════════════════════════════════════════════════════════════════════════
// Tab 3：新增 NAT Profile 精靈
// ══════════════════════════════════════════════════════════════════════════

function renderSpNatTab(container) {
  container.innerHTML = `
  <div class="panel" style="max-width:600px">
    <div class="panel-header"><span class="panel-title">➕ 新增 NAT Profile</span></div>
    <div style="padding:20px;display:flex;flex-direction:column;gap:14px">

      <div style="font-size:12px;color:var(--muted);line-height:1.6">
        用於需要對外公開公網 IP 的 SIP trunk（例如需要 STUN/固定公網 IP 的 provider）。
        會建立一個全新、獨立的 sip profile，不影響現有 internal/external。
      </div>

      <div class="settings-row">
        <span class="settings-label">Profile 名稱 *</span>
        <input class="settings-input" id="nat-name" placeholder="例：external_nat">
      </div>
      <div class="settings-row">
        <span class="settings-label">SIP Port *</span>
        <input class="settings-input" id="nat-port" type="number" min="5000" max="65000" placeholder="例：5090">
      </div>
      <div class="settings-row">
        <span class="settings-label">Dialplan Context</span>
        <input class="settings-input" id="nat-context" value="public">
      </div>

      <div class="settings-row">
        <span class="settings-label">公網 IP 模式 *</span>
        <select class="settings-select" id="nat-ext-mode" onchange="onNatExtModeChange(this.value)" style="max-width:220px">
          <option value="stun" selected>STUN 動態查詢（建議，IP 變動免維護）</option>
          <option value="auto">Auto（伺服器直接綁定公網 IP）</option>
          <option value="static">固定 IP（手動維護）</option>
        </select>
      </div>

      <div class="settings-row" id="nat-stun-row">
        <span class="settings-label">STUN Server</span>
        <input class="settings-input" id="nat-stun-server" value="stun:stun.freeswitch.org">
      </div>

      <div class="settings-row" id="nat-static-row" style="display:none">
        <span class="settings-label">固定公網 IP</span>
        <input class="settings-input" id="nat-static-ip" placeholder="例：59.125.29.120">
      </div>
      <div id="nat-static-warn" style="display:none;font-size:11px;color:var(--red);margin-left:164px">
        ⚠️ 固定 IP 若日後被 ISP 變更，需回來這裡手動更新並重啟 profile，否則會重演「30 秒後自動斷線」的問題。
      </div>

      <div style="display:flex;gap:8px;align-items:center;margin-top:8px">
        <button class="btn primary" onclick="createNatProfile()">💾 建立 Profile</button>
        <span id="nat-save-msg" style="font-size:12px;opacity:0;transition:opacity 0.3s"></span>
      </div>
      <div style="font-size:11px;color:var(--muted)">
        建立後自動 <code style="color:var(--accent-bright)">reloadxml</code> 及
        <code style="color:var(--accent-bright)">sofia profile &lt;name&gt; start</code>，
        請至「Gateway / SIP Trunk」頁面確認狀態為 RUNNING。
      </div>
    </div>
  </div>`;
}

function onNatExtModeChange(mode) {
  document.getElementById('nat-stun-row').style.display   = (mode === 'stun')   ? 'flex' : 'none';
  document.getElementById('nat-static-row').style.display = (mode === 'static') ? 'flex' : 'none';
  document.getElementById('nat-static-warn').style.display = (mode === 'static') ? 'block' : 'none';
}

async function createNatProfile() {
  const msg  = document.getElementById('nat-save-msg');
  const name = document.getElementById('nat-name').value.trim();
  const port = parseInt(document.getElementById('nat-port').value, 10);
  const mode = document.getElementById('nat-ext-mode').value;

  if (!name) { alert('請輸入 Profile 名稱'); return; }
  if (!port || port < 5000 || port > 65000) { alert('請輸入有效的 SIP Port (5000-65000)'); return; }

  const payload = {
    name,
    sip_port: port,
    ext_ip_mode: mode,
    stun_server: document.getElementById('nat-stun-server').value.trim(),
    static_ip:   document.getElementById('nat-static-ip').value.trim(),
    context:     document.getElementById('nat-context').value.trim() || 'public',
  };

  if (mode === 'static') {
    if (!payload.static_ip) { alert('固定 IP 模式需輸入公網 IP'); return; }
    if (!confirm(`即將建立固定 IP 模式的 NAT Profile「${name}」（IP：${payload.static_ip}）。\n此 IP 若日後變更需手動回來更新，確定要建立嗎？`)) return;
  }

  if (msg) { msg.textContent = '建立中...'; msg.style.opacity = '1'; msg.style.color = 'var(--yellow)'; }

  try {
    const res = await fetch(`${API_BASE}/api/sip-profile/nat-wizard`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(payload),
    });
    const data = await res.json();
    if (res.ok && data.ok) {
      if (msg) { msg.textContent = `✓ 已建立（ext-ip：${data.ext_ip_value}）`; msg.style.color = 'var(--green)'; }
      setTimeout(() => { _spCurrentProfile = name; switchSpTab('sp-params'); }, 1200);
    } else {
      if (msg) { msg.textContent = `✗ ${data.detail || '建立失敗'}`; msg.style.color = 'var(--red)'; }
    }
  } catch (e) {
    if (msg) { msg.textContent = `✗ ${e.message}`; msg.style.color = 'var(--red)'; }
  }
}
