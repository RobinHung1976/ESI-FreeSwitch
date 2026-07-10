// gateway.js — Gateway / SIP Trunk 管理

async function renderGateway() {
  document.getElementById('mainContent').innerHTML = `
  <div style="padding:40px;text-align:center;color:var(--muted)">載入中...</div>`;

  // 同時取得：sofia 狀態、gateway XML 設定、通話數
  const [sofiaRes, gwData, callData] = await Promise.all([
    runESLCommand('sofia status'),
    apiFetch('/api/gateway/list'),
    apiFetch('/api/calls'),
  ]);

  const calls    = (callData && callData.rows)      ? callData.rows      : [];
  const gwFiles  = (gwData   && gwData.gateways)    ? gwData.gateways    : [];
  const profiles = [];
  const gateways = [];

  // 解析 sofia status
  if (sofiaRes && sofiaRes.result) {
    sofiaRes.result.split('\n').forEach(line => {
      if (!line.trim() || line.startsWith('Name') || line.startsWith('===')) return;
      const parts = line.split('\t').map(s => s.trim()).filter(s => s);
      if (parts.length < 4) return;
      const [name, type, data, state] = parts;
      if (type === 'profile') {
        profiles.push({ name, data, state });
      } else if (type === 'gateway') {
        const host = name.replace(/^[^:]+::/, '');
        const activeCalls = calls.filter(c =>
          (c.dest && c.dest.includes(host)) || (c.name && c.name.includes(host))
        ).length;
        // 從 XML 設定找對應的 gateway 設定
        const gwName = name.split('::').pop();
        const gwCfg  = gwFiles.find(g => g.name === gwName) || null;
        gateways.push({ name, host, data, state, activeCalls, gwCfg });
      } else if (type === 'alias') {
        const last = profiles[profiles.length - 1];
        if (last) last.alias = name;
      }
    });
  }

  function stateStyle(state) {
    if (!state) return { cls: 'status-hold', label: '未知' };
    const s = state.toUpperCase();
    if (s.startsWith('RUNNING')) return { cls: 'status-active',  label: 'RUNNING' };
    if (s === 'REGED')           return { cls: 'status-active',  label: 'REGED' };
    if (s === 'NOREG')           return { cls: 'status-hold',    label: 'NOREG' };
    if (s === 'FAILED')          return { cls: 'status-danger',  label: 'FAILED' };
    if (s === 'ALIASED')         return { cls: 'status-ringing', label: 'ALIASED' };
    return { cls: 'status-hold', label: state };
  }

  const profileRows = profiles.length === 0
    ? `<tr><td colspan="4" style="text-align:center;color:var(--muted);padding:20px">無 Profile 資料</td></tr>`
    : profiles.map(p => {
        const st = stateStyle(p.state);
        return `<tr>
          <td style="color:#fff;font-weight:600">${p.name}</td>
          <td style="color:var(--label)">${p.data}</td>
          <td><span class="call-status ${st.cls}"><span class="dot"></span>${st.label}</span></td>
          <td>${p.alias ? `<span style="color:var(--muted);font-size:11px">alias: ${p.alias}</span>` : '—'}</td>
        </tr>`;
      }).join('');

  const gatewayRows = gateways.length === 0
    ? `<tr><td colspan="6" style="text-align:center;color:var(--muted);padding:20px">無 Gateway 資料</td></tr>`
    : gateways.map(g => {
        const st = stateStyle(g.state);
        const hasCfg = !!g.gwCfg;
        return `<tr>
          <td style="color:#fff;font-weight:600">${g.name}</td>
          <td style="color:var(--label);font-size:12px">${g.data}</td>
          <td><span class="call-status ${st.cls}"><span class="dot"></span>${st.label}</span></td>
          <td style="color:var(--accent-bright)">${g.activeCalls}</td>
          <td style="font-size:11px;color:var(--muted)">${hasCfg ? g.gwCfg.proxy || '—' : '—'}</td>
          <td style="display:flex;gap:4px">
            ${hasCfg
              ? `<button class="btn" style="padding:3px 8px;font-size:11px"
                   onclick="openGwEditor('${g.gwCfg.name}')">✏ 編輯</button>
                 <button class="btn danger" style="padding:3px 8px;font-size:11px"
                   onclick="deleteGw('${g.gwCfg.name}')">✕</button>`
              : `<span style="color:var(--muted);font-size:11px">無設定檔</span>`}
            <button class="btn" style="padding:3px 8px;font-size:11px"
              onclick="eslAndRefresh('sofia profile external rescan')">重掃</button>
          </td>
        </tr>`;
      }).join('');

  document.getElementById('mainContent').innerHTML = `
  <!-- 列表面板 -->
  <div id="gw-list-panel">
    <div class="panel" style="margin-bottom:14px">
      <div class="panel-header">
        <span class="panel-title">Sofia Profile</span>
        <span class="panel-badge">${profiles.length} 個 Profile</span>
        <div class="panel-actions">
          <button class="btn" onclick="switchPage('gateway')">↺ 刷新</button>
        </div>
      </div>
      <div class="table-wrap">
        <table>
          <thead><tr><th>名稱</th><th>SIP URI</th><th>狀態</th><th>備註</th></tr></thead>
          <tbody>${profileRows}</tbody>
        </table>
      </div>
    </div>

    <div class="panel">
      <div class="panel-header">
        <span class="panel-title">Gateway / Trunk</span>
        <span class="panel-badge">${gateways.length} 個 Gateway</span>
        <div class="panel-actions">
          <button class="btn primary" onclick="openGwEditor(null)">+ 新增 Gateway</button>
        </div>
      </div>
      <div class="table-wrap">
        <table>
          <thead><tr><th>名稱</th><th>SIP URI</th><th>狀態</th><th>通話數</th><th>Proxy</th><th>操作</th></tr></thead>
          <tbody>${gatewayRows}</tbody>
        </table>
      </div>
    </div>
  </div>

  <!-- 編輯面板 -->
  <div id="gw-editor-panel" style="display:none">
    <div class="panel" style="max-width:580px;margin:0 auto">
      <div class="panel-header">
        <span class="panel-title" id="gw-editor-title">新增 Gateway</span>
      </div>
      <div style="padding:20px;display:flex;flex-direction:column;gap:14px">

        <div class="settings-row">
          <span class="settings-label">Gateway 名稱 *</span>
          <input class="settings-input" id="gw-name" placeholder="例：PSTN-TW" />
        </div>
        <div class="settings-row">
          <span class="settings-label">SIP Proxy / 主機</span>
          <input class="settings-input" id="gw-proxy" placeholder="例：192.168.100.220 或 sip.provider.com" />
        </div>
        <div class="settings-row">
          <span class="settings-label">帳號 Username</span>
          <input class="settings-input" id="gw-username" placeholder="SIP 帳號" />
        </div>
        <div class="settings-row">
          <span class="settings-label">密碼 Password</span>
          <input class="settings-input" id="gw-password" type="password" placeholder="SIP 密碼" />
        </div>
        <div class="settings-row">
          <span class="settings-label">Extension</span>
          <input class="settings-input" id="gw-extension" placeholder="留空同 Username" />
        </div>
        <div class="settings-row">
          <span class="settings-label">自動 Register</span>
          <select class="settings-select" id="gw-register" style="max-width:160px">
            <option value="false">否（NOREG）</option>
            <option value="true">是（自動登錄）</option>
          </select>
        </div>
        <div class="settings-row">
          <span class="settings-label">Caller ID in From</span>
          <select class="settings-select" id="gw-cid-from" style="max-width:160px">
            <option value="false">否</option>
            <option value="true">是</option>
          </select>
        </div>

        <div style="display:flex;gap:8px;margin-top:8px;align-items:center">
          <button class="btn" onclick="closeGwEditor()">← 取消</button>
          <button class="btn primary" onclick="saveGw()" style="flex:1">💾 儲存 Gateway</button>
          <span id="gw-save-msg" style="font-size:12px;opacity:0;transition:opacity 0.3s"></span>
        </div>
        <div style="font-size:11px;color:var(--muted)">
          ✓ 儲存後自動執行 <code style="color:var(--accent-bright)">reloadxml</code>
          及 <code style="color:var(--accent-bright)">sofia profile external rescan</code>
        </div>
      </div>
    </div>
  </div>`;
}

// ── Gateway CRUD ──────────────────────────────────────────────────────────────
let _editingGwName = null;

async function openGwEditor(name) {
  _editingGwName = name;
  document.getElementById('gw-list-panel').style.display   = 'none';
  document.getElementById('gw-editor-panel').style.display = 'block';

  const title   = document.getElementById('gw-editor-title');
  const nameInp = document.getElementById('gw-name');

  if (name) {
    if (title) title.textContent = `編輯 Gateway：${name}`;
    nameInp.value    = name;
    nameInp.readOnly = true;
    nameInp.style.color = 'var(--muted)';

    // 載入現有設定
    const data = await apiFetch('/api/gateway/list');
    const gw   = (data && data.gateways) ? data.gateways.find(g => g.name === name) : null;
    if (gw) {
      document.getElementById('gw-proxy').value     = gw.proxy    || '';
      document.getElementById('gw-username').value  = gw.username || '';
      document.getElementById('gw-password').value  = gw.password || '';
      document.getElementById('gw-extension').value = gw.extension|| '';
      document.getElementById('gw-register').value  = gw.register || 'false';
      document.getElementById('gw-cid-from').value  = gw.caller_id_in_from || 'false';
    }
  } else {
    if (title) title.textContent = '新增 Gateway';
    nameInp.value    = '';
    nameInp.readOnly = false;
    nameInp.style.color = '';
    ['gw-proxy','gw-username','gw-password','gw-extension'].forEach(id => {
      const el = document.getElementById(id);
      if (el) el.value = '';
    });
    document.getElementById('gw-register').value  = 'false';
    document.getElementById('gw-cid-from').value  = 'false';
  }
}

function closeGwEditor() {
  document.getElementById('gw-list-panel').style.display   = 'block';
  document.getElementById('gw-editor-panel').style.display = 'none';
}

async function saveGw() {
  const msg  = document.getElementById('gw-save-msg');
  const name = document.getElementById('gw-name').value.trim();
  if (!name) { alert('請輸入 Gateway 名稱'); return; }

  const payload = {
    name,
    proxy:              document.getElementById('gw-proxy').value.trim(),
    username:           document.getElementById('gw-username').value.trim(),
    password:           document.getElementById('gw-password').value.trim(),
    extension:          document.getElementById('gw-extension').value.trim(),
    register:           document.getElementById('gw-register').value,
    caller_id_in_from:  document.getElementById('gw-cid-from').value,
  };

  if (msg) { msg.textContent='儲存中...'; msg.style.opacity='1'; msg.style.color='var(--yellow)'; }

  const method = _editingGwName ? 'PUT' : 'POST';
  const url    = _editingGwName
    ? `${API_BASE}/api/gateway/${_editingGwName}`
    : `${API_BASE}/api/gateway`;

  try {
    const res  = await fetch(url, {
      method,
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(payload),
    });
    const data = await res.json();
    if (data.ok) {
      if (msg) { msg.textContent='✓ 已儲存'; msg.style.color='var(--green)'; }
      setTimeout(() => { closeGwEditor(); switchPage('gateway'); }, 800);
    } else {
      if (msg) { msg.textContent=`✗ ${data.detail||'失敗'}`; msg.style.color='var(--red)'; }
    }
  } catch(e) {
    if (msg) { msg.textContent=`✗ ${e.message}`; msg.style.color='var(--red)'; }
  }
}

async function deleteGw(name) {
  if (!confirm(`確定要刪除 Gateway「${name}」？\n（原檔案會備份保留）`)) return;
  try {
    const res  = await fetch(`${API_BASE}/api/gateway/${name}`, { method: 'DELETE' });
    const data = await res.json();
    if (data.ok) {
      switchPage('gateway');
    } else {
      alert(`刪除失敗：${data.detail || '未知錯誤'}`);
    }
  } catch(e) {
    alert(`刪除失敗：${e.message}`);
  }
}

