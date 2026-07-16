// extensions-groups.js — 分機管理 + 分機群組管理

async function renderExtensions() {
  document.getElementById('mainContent').innerHTML = `
  <div style="padding:40px;text-align:center;color:var(--muted)">載入中...</div>`;

  // 同時取得：設定檔分機清單、已登錄狀態、即時通話
  const [extData, regData, callData] = await Promise.all([
    apiFetch('/api/extensions/list'),
    apiFetch('/api/registrations'),
    apiFetch('/api/calls'),
  ]);

  let exts    = (extData  && extData.extensions) ? extData.extensions : [];
  const regs  = (regData  && regData.rows)        ? regData.rows       : [];
  const calls = (callData && callData.rows)        ? callData.rows      : [];

  // normalize reg_user（防止 "1001@host" 格式造成比對失敗）
  regs.forEach(r => {
    if (r.reg_user && r.reg_user.includes('@')) {
      r.reg_user = r.reg_user.split('@')[0].trim();
    }
  });
  console.debug('[Extensions] regSet:', regs.map(r => r.reg_user));

  // 已登錄分機 Set
  const regSet  = new Set(regs.map(r => r.reg_user));
  // 通話中分機 Set
  const busySet = new Set();
  calls.forEach(c => {
    if (c.cid_num) busySet.add(c.cid_num);
    if (c.dest)    busySet.add(c.dest);
  });

  function extStatus(id) {
    // ✅ cache 有值（來自 WebSocket 推播或先前快照）→ 直接用，絕不讓 API 輪詢覆蓋
    const cached = extStatusCache[id];
    if (cached) {
      const meta = getExtMeta(cached.status);
      return { label: meta.label, cls: meta.cls, dot: meta.dot, dotCls: meta.dotCls,
               status: cached.status, peer: cached.peer || '', since: cached.since || 0 };
    }
    // Fallback：cache 尚無資料（第一次渲染且快照還沒回來）才用 API 資料推算
    // 推算結果寫入 cache，避免下次刷新再被 API 覆蓋
    let fallback;
    if (busySet.has(id))  fallback = { status:'talking', peer:'', direction:'', since:Date.now() };
    else if (regSet.has(id)) fallback = { status:'idle',    peer:'', direction:'', since:Date.now() };
    else                     fallback = { status:'offline',  peer:'', direction:'', since:Date.now() };
    extStatusCache[id] = fallback;  // 寫入 cache，後續刷新就不再用 API 推算
    const meta = getExtMeta(fallback.status);
    return { label: meta.label, cls: meta.cls, dot: meta.dot, dotCls: meta.dotCls,
             status: fallback.status, peer: '', since: fallback.since };
  }

  // D: 上線分機排前面，離線排後面
  const STATUS_ORDER = { talking:0, ringing:1, holding:2, parked:3, idle:4, offline:5 };
  exts = [...exts].sort((a, b) => {
    const sa = STATUS_ORDER[extStatus(a.id).status] ?? 4;
    const sb = STATUS_ORDER[extStatus(b.id).status] ?? 4;
    return sa !== sb ? sa - sb : a.id.localeCompare(b.id);
  });

  const cards = exts.map(e => {
    const st  = extStatus(e.id);
    const reg = regs.find(r => r.reg_user === e.id);
    const ip  = reg ? `${reg.network_ip} · ${(reg.network_proto||'').toUpperCase()}` : '—';
    const timerHtml = ['talking','holding','ringing'].includes(st.status) && st.since
      ? `<div class="ext-timer" data-since="${st.since}"></div>`
      : '';
    return `
    <div class="ext-card" data-ext-id="${e.id}" data-ext-name="${e.name||''}" data-st="${st.status}" style="position:relative">
      <!-- 操作按鈕 -->
      <div style="position:absolute;top:8px;right:8px;display:flex;gap:4px">
        <button class="btn" style="padding:2px 8px;font-size:10px"
          onclick="openExtEditor('${e.id}')">✏</button>
        <button class="btn danger" style="padding:2px 8px;font-size:10px"
          onclick="deleteExt('${e.id}', '${e.filename || ''}')">✕</button>
      </div>
      <div class="ext-num">${e.id}</div>
      <div class="ext-name" style="margin-top:2px;font-size:11px;color:var(--label)">
        ${e.caller_id_name || '—'}
      </div>
      <div style="font-size:10px;color:var(--muted);margin-top:2px">${ip}</div>
      <div class="ext-status" style="margin-top:8px">
        <span style="display:inline-block;padding:2px 8px;border-radius:20px;font-size:11px;font-weight:700;${st.badge}">
          ${st.label}
        </span>
        ${st.peer ? `<span style="font-size:10px;margin-left:6px;color:var(--muted)">${st.peer}</span>` : ''}
      </div>
      ${timerHtml}
      <div style="font-size:10px;color:var(--muted);margin-top:4px">
        群組：${e.callgroup || '—'}
      </div>
    </div>`;
  }).join('');

  document.getElementById('mainContent').innerHTML = `
  <!-- 分機列表 -->
  <div id="ext-list-panel">
    <div class="panel">
      <div class="panel-header">
        <span class="panel-badge">${exts.length} 支分機</span>
        <span class="panel-badge" style="margin-left:4px">${regSet.size} 支已登錄</span>
        <div class="panel-actions">
          <button class="btn" onclick="switchPage('extensions')">↺ 刷新</button>
          <button class="btn primary" onclick="openExtEditor(null)">+ 新增分機</button>
        </div>
      </div>
      <div class="ext-grid" style="grid-template-columns:repeat(auto-fill,minmax(180px,1fr))">
        ${cards.length ? cards : '<div style="padding:40px;text-align:center;color:var(--muted);grid-column:1/-1">尚無分機設定</div>'}
      </div>
    </div>
  </div>

  <!-- 編輯面板（預設隱藏）-->
  <div id="ext-editor-panel" style="display:none">
    <div class="panel" style="max-width:600px;margin:0 auto">
      <div class="panel-header">
        <span class="panel-title" id="ext-editor-title">新增分機</span>
      </div>
      <div style="padding:20px;display:flex;flex-direction:column;gap:14px">

        <div class="settings-row">
          <span class="settings-label">分機號碼 *</span>
          <div style="flex:1;display:flex;flex-direction:column;gap:4px">
            <div style="display:flex;gap:6px">
              <input class="settings-input" id="ext-id" placeholder="例：1010" style="flex:1"
                oninput="numCheckConflict('ext-id','ext-id-conflict',this.value,'extension')"
                onblur="numCheckConflict('ext-id','ext-id-conflict',this.value,'extension')"/>
              <button class="btn" id="ext-change-num-btn" style="display:none;white-space:nowrap"
                onclick="changeExtNumber()">🔄 變更號碼</button>
            </div>
            <div id="ext-id-conflict"></div>
          </div>
        </div>
        <div class="settings-row">
          <span class="settings-label">顯示名稱</span>
          <input class="settings-input" id="ext-name" placeholder="例：王小明" />
        </div>
        <div class="settings-row">
          <span class="settings-label">SIP 密碼</span>
          <input class="settings-input" id="ext-password" placeholder="留空使用預設密碼" />
        </div>
        <div class="settings-row">
          <span class="settings-label">語音信箱密碼</span>
          <input class="settings-input" id="ext-vm-password" placeholder="留空同分機號碼" />
        </div>
		<div class="settings-row">
		  <span class="settings-label">啟用語音信箱</span>
		  <label style="display:flex;align-items:center;gap:6px">
		  <input type="checkbox" id="ext-vm-enabled" checked />
		  <span style="font-size:12px;color:var(--muted)">關閉後無人接聽時不會錄製留言</span>
		  </label>
		</div>
        <div class="settings-row">
          <span class="settings-label">通話群組</span>
          <input class="settings-input" id="ext-callgroup" placeholder="例：techsupport" />
        </div>
        <div class="settings-row">
          <span class="settings-label">撥出權限</span>
          <select class="settings-select" id="ext-toll">
            <option value="domestic,international,local">全部（國內+國際+本地）</option>
            <option value="domestic,local">國內 + 本地</option>
            <option value="local">僅本地</option>
            <option value="">無限制</option>
          </select>
        </div>
        <div class="settings-row">
          <span class="settings-label">Context</span>
          <select class="settings-select" id="ext-context"></select>
        </div>
        <div class="settings-row">
          <span class="settings-label">錄音</span>
          <label style="display:flex;align-items:center;gap:8px;cursor:pointer">
            <input type="checkbox" id="ext-recording" style="width:15px;height:15px;accent-color:var(--accent)">
            <span style="font-size:13px;color:var(--text)">啟用此分機自動錄音</span>
          </label>
        </div>

        <div style="display:flex;gap:8px;margin-top:8px;align-items:center">
          <button class="btn" onclick="closeExtEditor()">← 取消</button>
          <button class="btn primary" onclick="saveExt()" style="flex:1">💾 儲存分機</button>
          <span id="ext-save-msg" style="font-size:12px;opacity:0;transition:opacity 0.3s"></span>
        </div>
        <div style="font-size:11px;color:var(--muted)">
          ✓ 儲存後自動執行 <code style="color:var(--accent-bright)">reloadxml</code>，無需重啟 FreeSwitch
        </div>
      </div>
    </div>
  </div>`;

  // DOM 已就緒：
  // - cache 已有值的分機（來自 WebSocket 推播）→ 直接在 extStatus() 中使用，不需再查
  // - cache 空的分機（第一次載入）→ 由 loadExtStatusSnapshot 補齊
  const needsSnapshot = exts.some(e => !extStatusCache[e.id]);
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
let _editingExtId = null;

async function openExtEditor(id) {
  _editingExtId = id;
  document.getElementById('ext-list-panel').style.display  = 'none';
  document.getElementById('ext-editor-panel').style.display = 'block';

  const title = document.getElementById('ext-editor-title');
  const idInput = document.getElementById('ext-id');

  // Context 下拉選單資料來源與 Dialplan 頁面共用同一份快取（common.js）
  const contexts = await loadDialplanContexts();

  if (id) {
    // 編輯模式：載入現有資料
    if (title) title.textContent = `編輯分機 ${id}`;
    idInput.value    = id;
    idInput.readOnly = true;
    idInput.style.color = 'var(--muted)';
    idInput.dataset.original = id;  // 記錄原始 ID 供衝突檢查排除自身
    // 清除衝突提示（編輯模式不檢查）
    const conflictDiv = document.getElementById('ext-id-conflict');
    if (conflictDiv) conflictDiv.innerHTML = '';
    // 顯示變更號碼按鈕
    const changeBtn = document.getElementById('ext-change-num-btn');
    if (changeBtn) changeBtn.style.display = 'inline-flex';

    const data = await apiFetch('/api/extensions/list');
    const ext  = (data && data.extensions) ? data.extensions.find(e => e.id === id) : null;
    document.getElementById('ext-context').innerHTML = _extContextOptionsHtml(contexts, (ext && ext.context) || 'default');
    if (ext) {
      document.getElementById('ext-name').value       = ext.caller_id_name || '';
      document.getElementById('ext-password').value   = ext.password === '$${default_password}' ? '' : ext.password;
      document.getElementById('ext-vm-password').value= ext.vm_password || '';
      document.getElementById('ext-callgroup').value  = ext.callgroup || '';
      const tollSel = document.getElementById('ext-toll');
      if (tollSel) tollSel.value = ext.toll_allow || 'domestic,international,local';
      const recEl = document.getElementById('ext-recording');
      if (recEl) recEl.checked = !!ext.recording_enabled;
	  const vmEnEl = document.getElementById('ext-vm-enabled');
	  if (vmEnEl) vmEnEl.checked = ext.voicemail_enabled !== false;
    }
  } else {
    // 新增模式
    if (title) title.textContent = '新增分機';
    idInput.value    = '';
    idInput.readOnly = false;
    idInput.style.color = '';
    idInput.dataset.original = '';  // 新增模式無原始 ID
    // 清除衝突提示
    const conflictDiv = document.getElementById('ext-id-conflict');
    if (conflictDiv) conflictDiv.innerHTML = '';
    // 隱藏變更號碼按鈕
    const changeBtn = document.getElementById('ext-change-num-btn');
    if (changeBtn) changeBtn.style.display = 'none';
    ['ext-name','ext-password','ext-vm-password','ext-callgroup'].forEach(id => {
      const el = document.getElementById(id);
      if (el) el.value = '';
    });
    document.getElementById('ext-context').innerHTML = _extContextOptionsHtml(contexts, 'default');
	const vmEnEl = document.getElementById('ext-vm-enabled');
	if (vmEnEl) vmEnEl.checked = true;
	const recEl = document.getElementById('ext-recording');
	if (recEl) recEl.checked = false;
  }
}

function closeExtEditor() {
  document.getElementById('ext-list-panel').style.display   = 'block';
  document.getElementById('ext-editor-panel').style.display = 'none';
}

async function saveExt() {
  const msg = document.getElementById('ext-save-msg');
  const id  = document.getElementById('ext-id').value.trim();
  if (!id) { alert('請輸入分機號碼'); return; }

  const payload = {
    id,
    caller_id_name:   document.getElementById('ext-name').value.trim(),
    password:         document.getElementById('ext-password').value.trim() || '$${default_password}',
    vm_password:      document.getElementById('ext-vm-password').value.trim() || id,
    callgroup:        document.getElementById('ext-callgroup').value.trim() || 'default',
    toll_allow:       document.getElementById('ext-toll').value,
    context:          document.getElementById('ext-context').value.trim() || 'default',
    caller_id_number: id,
    recording_enabled: document.getElementById('ext-recording')?.checked ?? false,
	voicemail_enabled: document.getElementById('ext-vm-enabled')?.checked ?? true,
  };

  if (msg) { msg.textContent = '儲存中...'; msg.style.opacity='1'; msg.style.color='var(--yellow)'; }

  const method = _editingExtId ? 'PUT' : 'POST';
  const url    = _editingExtId
    ? `${API_BASE}/api/extensions/${_editingExtId}`
    : `${API_BASE}/api/extensions`;

  try {
    const res  = await fetch(url, {
      method,
      headers: { 'Content-Type': 'application/json', 'Authorization': `Bearer ${getToken()}` },
      body: JSON.stringify(payload),
    });
    const data = await res.json();
    if (data.ok) {
      if (msg) { msg.textContent='✓ 已儲存'; msg.style.color='var(--green)'; }
      numClearCache(); setTimeout(() => { closeExtEditor(); switchPage('extensions'); }, 800);
    } else {
      if (msg) { msg.textContent=`✗ ${data.detail||'失敗'}`; msg.style.color='var(--red)'; }
    }
  } catch(e) {
    if (msg) { msg.textContent=`✗ ${e.message}`; msg.style.color='var(--red)'; }
  }
}

async function changeExtNumber() {
  const oldId = _editingExtId;
  if (!oldId) return;

  const newId = prompt(`請輸入新的分機號碼（目前：${oldId}）：`);
  if (!newId || !newId.trim()) return;
  const trimmedId = newId.trim();

  if (trimmedId === oldId) {
    alert('新號碼與舊號碼相同，不需要變更。');
    return;
  }

  if (!/^\d+$/.test(trimmedId)) {
    alert('分機號碼只能包含數字。');
    return;
  }

  if (!confirm(`確定要將分機 ${oldId} 改為 ${trimmedId}？\n\n此操作會：\n1. 建立新分機 ${trimmedId}（複製現有設定）\n2. 刪除舊分機 ${oldId}\n3. 執行 reloadxml`)) return;

  const msg = document.getElementById('ext-save-msg');
  if (msg) { msg.textContent = '變更中...'; msg.style.opacity='1'; msg.style.color='var(--yellow)'; }

  // 取得目前表單設定
  const payload = {
    id:               trimmedId,
    caller_id_name:   document.getElementById('ext-name').value.trim(),
    password:         document.getElementById('ext-password').value.trim() || '$${default_password}',
    vm_password:      document.getElementById('ext-vm-password').value.trim() || trimmedId,
    callgroup:        document.getElementById('ext-callgroup').value.trim() || 'default',
    toll_allow:       document.getElementById('ext-toll').value,
    context:          document.getElementById('ext-context').value.trim() || 'default',
    caller_id_number: trimmedId,
    recording_enabled: document.getElementById('ext-recording')?.checked ?? false,
	voicemail_enabled: document.getElementById('ext-vm-enabled')?.checked ?? true,
  };

  try {
    // Step 1：建立新分機
    const createRes = await fetch(`${API_BASE}/api/extensions`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'Authorization': `Bearer ${getToken()}` },
      body: JSON.stringify(payload),
    });
    const createData = await createRes.json();
    if (!createData.ok) {
      if (msg) { msg.textContent = `✗ 建立失敗：${createData.detail||'未知錯誤'}`; msg.style.color='var(--red)'; }
      return;
    }

    // Step 2：刪除舊分機
    const deleteRes = await fetch(`${API_BASE}/api/extensions/${oldId}`, {
      method: 'DELETE',
      headers: { 'Authorization': `Bearer ${getToken()}` },
    });
    const deleteData = await deleteRes.json();
    if (!deleteData.ok) {
      if (msg) { msg.textContent = `⚠ 新分機已建立，但舊分機 ${oldId} 刪除失敗`; msg.style.color='var(--yellow)'; }
      return;
    }

    if (msg) { msg.textContent = `✓ 已從 ${oldId} 變更為 ${trimmedId}`; msg.style.color='var(--green)'; }
    setTimeout(() => { switchPage('extensions'); }, 1000);

  } catch(e) {
    if (msg) { msg.textContent = `✗ 錯誤：${e.message}`; msg.style.color='var(--red)'; }
  }
}

async function deleteExt(id, filename) {
  if (!confirm(`確定要刪除分機 ${id}？\n（原檔案會備份保留）`)) return;
  try {
    const qs  = filename ? `?filename=${encodeURIComponent(filename)}` : '';
    const res = await fetch(`${API_BASE}/api/extensions/${encodeURIComponent(id)}${qs}`, {
      method: 'DELETE',
      headers: { 'Authorization': `Bearer ${getToken()}` },
    });
    if (data.ok) {
      switchPage('extensions');
    } else {
      alert(`刪除失敗：${data.detail || '未知錯誤'}`);
    }
  } catch(e) {
    alert(`刪除失敗：${e.message}`);
  }
}

// ── 分機群組管理（Ring Group）─────────────────────────────────────────────────
// 群組＝可直接撥打的虛擬分機號碼（例如 8001），響鈴方式可選「同時響鈴」或
// 「依序響鈴」，無人接聽時可轉接語音信箱／另一分機／直接掛斷。

let _editingGroupId = null;
let _groupMembers   = [];

async function renderGroups() {
  document.getElementById('mainContent').innerHTML = `
  <div style="padding:40px;text-align:center;color:var(--muted)">載入中...</div>`;

  const [groupData, extData] = await Promise.all([
    apiFetch('/api/groups/list'),
    apiFetch('/api/extensions/list'),
  ]);

  const groups = (groupData && groupData.groups)     ? groupData.groups     : [];
  const exts   = (extData  && extData.extensions)    ? extData.extensions   : [];

  const extNameMap = {};
  exts.forEach(e => { extNameMap[e.id] = e.caller_id_name || ''; });

  const strategyLabel = { simultaneous: '◎ 同時響鈴', sequential: '→ 依序響鈴' };
  const fallbackLabel = {
    voicemail: t => `無人接聽 → ${t || '—'} 語音信箱`,
    extension: t => `無人接聽 → 轉接 ${t || '—'}`,
    hangup:    () => '無人接聽 → 掛斷',
  };

  const cards = groups.map(g => {
    const memberTags = (g.members || []).map(m => {
      const nm = extNameMap[m];
      return `<span class="panel-badge" style="margin:3px 4px 0 0;font-size:10px">${m}${nm ? ' · '+nm : ''}</span>`;
    }).join('');
    const fbFn = fallbackLabel[g.fallback_type] || (() => '—');
    return `
    <div class="ext-card" style="position:relative;text-align:left">
      <div style="position:absolute;top:8px;right:8px;display:flex;gap:4px">
        <button class="btn" style="padding:2px 8px;font-size:10px"
          onclick="openGroupEditor('${g.id}')">✏</button>
        <button class="btn danger" style="padding:2px 8px;font-size:10px"
          onclick="deleteGroup('${g.id}')">✕</button>
      </div>
      <div class="ext-num">${g.id}</div>
      <div style="font-size:11px;color:var(--label);margin-top:2px">${g.name || '（未命名群組）'}</div>
      <div style="font-size:10px;color:var(--accent-bright);margin-top:8px">
        ${strategyLabel[g.strategy] || g.strategy} · 響鈴 ${g.ring_timeout}s
      </div>
      <div style="font-size:10px;color:var(--muted);margin-top:3px">${fbFn(g.fallback_target)}</div>
      <div style="margin-top:8px;display:flex;flex-wrap:wrap">
        ${memberTags || '<span style="font-size:10px;color:var(--muted)">尚無成員</span>'}
      </div>
    </div>`;
  }).join('');

  document.getElementById('mainContent').innerHTML = `
  <!-- 群組列表 -->
  <div id="group-list-panel">
    <div class="panel">
      <div class="panel-header">
        <span class="panel-badge">${groups.length} 個群組</span>
        <div class="panel-actions">
          <button class="btn" onclick="switchPage('groups')">↺ 刷新</button>
          <button class="btn primary" onclick="openGroupEditor(null)">+ 新增群組</button>
        </div>
      </div>
      <div class="ext-grid" style="grid-template-columns:repeat(auto-fill,minmax(220px,1fr))">
        ${cards.length ? cards : '<div style="padding:40px;text-align:center;color:var(--muted);grid-column:1/-1">尚無群組設定，點擊「+ 新增群組」建立第一個響鈴群組</div>'}
      </div>
      <div style="padding:10px 18px;font-size:11px;color:var(--muted);border-top:1px solid var(--border)">
        💡 群組撥號號碼即為可直接撥打／轉接的虛擬分機（例如 8001）；同時響鈴＝全部成員一起響、先接聽者接通；依序響鈴＝依清單順序逐一嘗試。
      </div>
    </div>
  </div>

  <!-- 編輯面板（預設隱藏）-->
  <div id="group-editor-panel" style="display:none">
    <div class="panel" style="max-width:640px;margin:0 auto">
      <div class="panel-header">
        <span class="panel-title" id="group-editor-title">新增群組</span>
        <button class="btn" id="group-change-num-btn" style="display:none;margin-left:auto"
          onclick="changeGroupNumber()">🔄 變更號碼</button>
      </div>
      <div style="padding:20px;display:flex;flex-direction:column;gap:14px">

        <div class="settings-row">
          <span class="settings-label">群組撥號號碼 *</span>
          <div style="flex:1;display:flex;flex-direction:column;gap:4px">
            <input class="settings-input" id="group-id" placeholder="例：8001"
              oninput="numCheckConflict('group-id','group-id-conflict',this.value,'group')"
              onblur="numCheckConflict('group-id','group-id-conflict',this.value,'group')"/>
            <div id="group-id-conflict"></div>
          </div>
        </div>
        <div class="settings-row">
          <span class="settings-label">群組名稱</span>
          <input class="settings-input" id="group-name" placeholder="例：銷售部" />
        </div>

        <div>
          <div class="settings-label" style="margin-bottom:8px">成員分機（點擊選取／取消）</div>
          <div id="group-member-picker" style="display:flex;flex-wrap:wrap;gap:6px;padding:10px;border:1px solid var(--border);border-radius:8px;max-height:180px;overflow-y:auto">
            ${exts.length ? exts.map(e => `
              <button type="button" class="btn chip-select" data-ext="${e.id}"
                onclick="toggleGroupMember('${e.id}', this)">
                ${e.id}${e.caller_id_name ? ' · '+e.caller_id_name : ''}
              </button>`).join('') : '<span style="font-size:12px;color:var(--muted)">尚無可用分機，請先到「分機管理」新增</span>'}
          </div>
        </div>

        <div class="settings-row">
          <span class="settings-label">響鈴方式</span>
          <select class="settings-select" id="group-strategy">
            <option value="simultaneous">同時響鈴（全部一起響，先接聽者接通）</option>
            <option value="sequential">依序響鈴（依成員清單順序逐一嘗試）</option>
          </select>
        </div>
        <div class="settings-row">
          <span class="settings-label">每輪響鈴秒數</span>
          <input class="settings-input" id="group-timeout" type="number" min="5" max="120" value="20" />
        </div>
        <div class="settings-row">
          <span class="settings-label">無人接聽時</span>
          <select class="settings-select" id="group-fallback-type" onchange="onGroupFallbackTypeChange()">
            <option value="voicemail">轉接指定分機的語音信箱</option>
            <option value="extension">轉接至指定分機</option>
            <option value="hangup">直接掛斷</option>
          </select>
        </div>
        <div class="settings-row" id="group-fallback-target-row">
          <span class="settings-label">目標分機</span>
          <input class="settings-input" id="group-fallback-target" placeholder="例：1001" />
        </div>

        <div style="display:flex;gap:8px;margin-top:8px;align-items:center">
          <button class="btn" onclick="closeGroupEditor()">← 取消</button>
          <button class="btn primary" onclick="saveGroup()" style="flex:1">💾 儲存群組</button>
          <span id="group-save-msg" style="font-size:12px;opacity:0;transition:opacity 0.3s"></span>
        </div>
        <div style="font-size:11px;color:var(--muted)">
          ✓ 儲存後自動執行 <code style="color:var(--accent-bright)">reloadxml</code>，無需重啟 FreeSwitch｜編輯時可用「🔄 變更號碼」改撥號號碼（會建立新群組並刪除舊群組）
          <br>⚠ 禁用範圍（FreeSwitch 內建保留）：<code style="color:var(--red)">10XX–19XX</code>（分機）、<code style="color:var(--red)">2000–2002</code>（會議）、<code style="color:var(--red)">3000–3013</code>（Call Center）、<code style="color:var(--red)">4000</code>（停車）、<code style="color:var(--red)">5000–5002</code>（Directory / Conference Bridge）、<code style="color:var(--red)">6000</code>（停車取回）、<code style="color:var(--red)">9195–9199、9888</code>（測試/語音信箱）。建議使用 <code style="color:var(--green)">7XXX</code>（如 7001、7002）
        </div>
      </div>
    </div>
  </div>`;
}

function onGroupFallbackTypeChange() {
  const type = document.getElementById('group-fallback-type').value;
  const row  = document.getElementById('group-fallback-target-row');
  if (row) row.style.display = (type === 'hangup') ? 'none' : 'flex';
}

function toggleGroupMember(extId, btn) {
  const idx = _groupMembers.indexOf(extId);
  if (idx === -1) {
    _groupMembers.push(extId);
    btn.classList.add('active');
  } else {
    _groupMembers.splice(idx, 1);
    btn.classList.remove('active');
  }
}

async function openGroupEditor(id) {
  _editingGroupId = id;
  _groupMembers   = [];

  document.getElementById('group-list-panel').style.display   = 'none';
  document.getElementById('group-editor-panel').style.display = 'block';

  const title    = document.getElementById('group-editor-title');
  const idInput  = document.getElementById('group-id');

  document.querySelectorAll('#group-member-picker .chip-select').forEach(el => el.classList.remove('active'));

  if (id) {
    // 編輯模式：載入現有設定
    if (title) title.textContent = `編輯群組 ${id}`;
    idInput.value    = id;
    idInput.readOnly = true;
    idInput.style.color = 'var(--muted)';
    idInput.dataset.original = id;
    const conflictDiv = document.getElementById('group-id-conflict');
    if (conflictDiv) conflictDiv.innerHTML = '';
    // 顯示變更號碼按鈕
    const changeBtn = document.getElementById('group-change-num-btn');
    if (changeBtn) changeBtn.style.display = 'inline-flex';

    const data = await apiFetch('/api/groups/list');
    const g = (data && data.groups) ? data.groups.find(x => x.id === id) : null;
    if (g) {
      document.getElementById('group-name').value          = g.name || '';
      document.getElementById('group-strategy').value      = g.strategy || 'simultaneous';
      document.getElementById('group-timeout').value        = g.ring_timeout || 20;
      document.getElementById('group-fallback-type').value  = g.fallback_type || 'voicemail';
      document.getElementById('group-fallback-target').value = g.fallback_target || '';
      _groupMembers = (g.members || []).slice();
      _groupMembers.forEach(m => {
        const chip = document.querySelector(`#group-member-picker .chip-select[data-ext="${m}"]`);
        if (chip) chip.classList.add('active');
      });
    }
  } else {
    // 新增模式
    if (title) title.textContent = '新增群組';
    idInput.value    = '';
    idInput.readOnly = false;
    idInput.style.color = '';
    idInput.dataset.original = '';
    const conflictDiv = document.getElementById('group-id-conflict');
    if (conflictDiv) conflictDiv.innerHTML = '';
    // 隱藏變更號碼按鈕
    const changeBtn = document.getElementById('group-change-num-btn');
    if (changeBtn) changeBtn.style.display = 'none';
    document.getElementById('group-name').value             = '';
    document.getElementById('group-strategy').value         = 'simultaneous';
    document.getElementById('group-timeout').value           = 20;
    document.getElementById('group-fallback-type').value     = 'voicemail';
    document.getElementById('group-fallback-target').value   = '';
  }
  onGroupFallbackTypeChange();
}

function closeGroupEditor() {
  document.getElementById('group-list-panel').style.display   = 'block';
  document.getElementById('group-editor-panel').style.display = 'none';
}

async function saveGroup() {
  const msg = document.getElementById('group-save-msg');
  const id  = document.getElementById('group-id').value.trim();
  if (!id) { alert('請輸入群組撥號號碼'); return; }
  if (!/^\d{2,6}$/.test(id)) { alert('群組撥號號碼請輸入 2-6 位數字'); return; }
  if (_groupMembers.length === 0) { alert('請至少選擇一位成員分機'); return; }

  const fallbackType   = document.getElementById('group-fallback-type').value;
  const fallbackTarget = document.getElementById('group-fallback-target').value.trim();
  if (fallbackType !== 'hangup' && !fallbackTarget) {
    alert('請輸入無人接聽時要轉接的目標分機'); return;
  }

  // ── 新增模式：號碼衝突檢查（含 FreeSwitch 保留號碼）──────────────────────
  const isEdit = !!_editingGroupId;
  if (!isEdit) {
    const allNums = await _numGetAll();
    const conflicts = allNums.filter(n => n.number === id);
    if (conflicts.length > 0) {
      const info = conflicts.map(c => {
        const meta = { extension:'📞 分機', group:'▣ 群組', ivr:'🎛 IVR',
                       custom:'📋 自定義 Dialplan', reserved:'🔒 FreeSwitch 內建' };
        return `${meta[c.type]||c.type}「${c.name || c.number}」`;
      }).join('、');
      if (msg) { msg.textContent = `✗ 號碼 ${id} 已被佔用`; msg.style.opacity='1'; msg.style.color='var(--red)'; }
      alert(`⚠️ 號碼 ${id} 已被 ${info} 佔用！\n\n請改用其他號碼。`);
      return;
    }
  }

  const payload = {
    id,
    name:            document.getElementById('group-name').value.trim(),
    members:         _groupMembers,
    strategy:        document.getElementById('group-strategy').value,
    ring_timeout:    parseInt(document.getElementById('group-timeout').value) || 20,
    fallback_type:   fallbackType,
    fallback_target: fallbackTarget,
  };

  if (msg) { msg.textContent = '儲存中...'; msg.style.opacity = '1'; msg.style.color = 'var(--yellow)'; }

  try {
    const url    = isEdit ? `${API_BASE}/api/groups/${_editingGroupId}` : `${API_BASE}/api/groups`;
    const res    = await fetch(url, {
      method: isEdit ? 'PUT' : 'POST',
      headers: { 'Content-Type': 'application/json', 'Authorization': `Bearer ${getToken()}` },
      body: JSON.stringify(payload),
    });
    const data = await res.json();
    if (data.ok) {
      if (msg) { msg.textContent = '✓ 已儲存'; msg.style.color = 'var(--green)'; }
      numClearCache(); setTimeout(() => { switchPage('groups'); }, 600);
    } else {
      if (msg) { msg.textContent = `✗ 儲存失敗：${data.detail || '未知錯誤'}`; msg.style.color = 'var(--red)'; }
    }
  } catch(e) {
    if (msg) { msg.textContent = `✗ 錯誤：${e.message}`; msg.style.color = 'var(--red)'; }
  }
}

async function changeGroupNumber() {
  const oldId = _editingGroupId;
  if (!oldId) return;

  const newId = prompt(`請輸入新的群組撥號號碼（目前：${oldId}）：`);
  if (!newId || !newId.trim()) return;
  const trimmedId = newId.trim();

  if (trimmedId === oldId) {
    alert('新號碼與舊號碼相同，不需要變更。');
    return;
  }
  if (!/^\d{2,6}$/.test(trimmedId)) {
    alert('群組撥號號碼請輸入 2-6 位數字。');
    return;
  }
  if (_groupMembers.length === 0) {
    alert('請至少選擇一位成員分機後再變更號碼。');
    return;
  }

  // ── 號碼衝突檢查（變更號碼時必做）──────────────────────────────────────
  const allNums = await _numGetAll();
  const conflicts = allNums.filter(n => {
    if (n.number !== trimmedId) return false;
    // 排除舊群組自身（舊號碼本來就存在，不算衝突）
    if (n.type === 'group' && n.number === oldId) return false;
    return true;
  });
  if (conflicts.length > 0) {
    const info = conflicts.map(c => {
      const meta = { extension:'📞 分機', group:'▣ 群組', ivr:'🎛 IVR',
                     custom:'📋 自定義 Dialplan', reserved:'🔒 FreeSwitch 內建' };
      return `${meta[c.type]||c.type}「${c.name || c.number}」`;
    }).join('、');
    alert(`⚠️ 號碼 ${trimmedId} 已被 ${info} 佔用！\n\n請改用其他號碼。`);
    return;
  }

  const fallbackType   = document.getElementById('group-fallback-type').value;
  const fallbackTarget = document.getElementById('group-fallback-target').value.trim();
  if (fallbackType !== 'hangup' && !fallbackTarget) {
    alert('請輸入無人接聽時要轉接的目標分機。');
    return;
  }

  if (!confirm(`確定要將群組 ${oldId} 改為 ${trimmedId}？\n\n此操作會：\n1. 建立新群組 ${trimmedId}（複製現有設定）\n2. 刪除舊群組 ${oldId}\n3. 執行 reloadxml`)) return;

  const msg = document.getElementById('group-save-msg');
  if (msg) { msg.textContent = '變更中...'; msg.style.opacity = '1'; msg.style.color = 'var(--yellow)'; }

  // 取得目前表單設定
  const payload = {
    id:              trimmedId,
    name:            document.getElementById('group-name').value.trim(),
    members:         _groupMembers,
    strategy:        document.getElementById('group-strategy').value,
    ring_timeout:    parseInt(document.getElementById('group-timeout').value) || 20,
    fallback_type:   fallbackType,
    fallback_target: fallbackTarget,
  };

  try {
    // Step 1：建立新群組
    const createRes  = await fetch(`${API_BASE}/api/groups`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'Authorization': `Bearer ${getToken()}` },
      body: JSON.stringify(payload),
    });
    const createData = await createRes.json();
    if (!createData.ok) {
      if (msg) { msg.textContent = `✗ 建立失敗：${createData.detail || '未知錯誤'}`; msg.style.color = 'var(--red)'; }
      return;
    }

    // Step 2：刪除舊群組
    const deleteRes  = await fetch(`${API_BASE}/api/groups/${oldId}`, {
      method: 'DELETE',
      headers: { 'Authorization': `Bearer ${getToken()}` },
    });
    const deleteData = await deleteRes.json();
    if (!deleteData.ok) {
      if (msg) { msg.textContent = `⚠ 新群組已建立，但舊群組 ${oldId} 刪除失敗`; msg.style.color = 'var(--yellow)'; }
      return;
    }

    if (msg) { msg.textContent = `✓ 已從 ${oldId} 變更為 ${trimmedId}`; msg.style.color = 'var(--green)'; }
    setTimeout(() => { switchPage('groups'); }, 1000);

  } catch(e) {
    if (msg) { msg.textContent = `✗ 錯誤：${e.message}`; msg.style.color = 'var(--red)'; }
  }
}

async function deleteGroup(id) {
  if (!confirm(`確定要刪除群組 ${id}？\n（原檔案會備份保留）`)) return;
  try {
    const res  = await fetch(`${API_BASE}/api/groups/${id}`, {
      method: 'DELETE',
      headers: { 'Authorization': `Bearer ${getToken()}` },
    });
    const data = await res.json();
    if (data.ok) {
      switchPage('groups');
    } else {
      alert(`刪除失敗：${data.detail || '未知錯誤'}`);
    }
  } catch(e) {
    alert(`刪除失敗：${e.message}`);
  }
}

// CDR 狀態：依 hangup_cause 和 billsec 判斷
