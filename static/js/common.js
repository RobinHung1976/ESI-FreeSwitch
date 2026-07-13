// common.js — 後端連線設定、WebSocket、API 工具、分機狀態快取、頁面路由 (pages/switchPage)
// 必須最先載入，其他所有 js 檔都依賴這裡的全域函式與變數。

// ── 後端設定 ──────────────────────────────────────────────────────────────────
const API_BASE = 'http://192.168.100.209:3000';
const WS_URL   = 'ws://192.168.100.209:8080';

// ── 認證：載入頁面時先檢查 token，沒有/過期直接導回登入頁 ─────────────────────
function getToken() {
  return localStorage.getItem('access_token');
}

function isTokenValid(token) {
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

function redirectToLogin() {
  localStorage.removeItem('access_token');
  window.location.href = '/login.html';
}

function logout() {
  redirectToLogin();
}

(function guardAuth() {
  if (!isTokenValid(getToken())) {
    redirectToLogin();
  }
})();

// ── WebSocket：接收 FreeSwitch 即時事件 ───────────────────────────────────────
function setFsDot(color, glow) {
  const dot = document.getElementById('sf-fs-dot');
  if (!dot) return;
  dot.style.background = color;
  dot.style.boxShadow  = glow ? `0 0 8px ${color}` : '0 0 0px transparent';
}

function setSysStatus(text) {
  const el = document.getElementById('sf-sys-status');
  if (el) el.textContent = text;
}

async function loadSysStatus() {
  const res = await runESLCommand('status');
  if (res && res.detail && !res.result) {
    // 後端 require_permission() 403 回傳格式是 {"detail": "..."}，代表此帳號沒有 ESL 模組讀取權限
    setSysStatus('系統狀態：無存取權限');
    return;
  }
  if (!res || !res.result) { setSysStatus('系統狀態：無法取得'); return; }
  const s = res.result;
  const uptimeMatch = s.match(/UP (.+?)\n/);
  if (!uptimeMatch) { setSysStatus('系統運行中'); return; }

  // 只保留 years / days / hours / minutes / seconds，移除 milliseconds & microseconds
  const uptime = uptimeMatch[1]
    .replace(/,?\s*\d+ milliseconds/g, '')
    .replace(/,?\s*\d+ microseconds/g, '')
    .trim()
    .replace(/^,\s*/, '');

  setSysStatus('運行 ' + uptime);
}

function initWebSocket() {
  const token = getToken();
  if (!isTokenValid(token)) {
    redirectToLogin();
    return;
  }

  const ws = new WebSocket(`${WS_URL}/?token=${encodeURIComponent(token)}`);
  ws.onopen    = () => {
    console.log('WebSocket 已連線');
    setFsDot('var(--green)', true);
    setSysStatus('正在取得狀態...');
    loadSysStatus();
    loadExtStatusSnapshot();
  };
  ws.onmessage = (e) => {
    try {
      const event = JSON.parse(e.data);
      handleWSEvent(event);
    } catch(err) { console.warn('WS parse error', err); }
  };
  ws.onclose = (e) => {
    if (e.code === 4401) {
      console.warn('WebSocket 認證失敗，導向登入頁');
      setFsDot('var(--red)', true);
      setSysStatus('登入已過期，請重新登入');
      redirectToLogin();
      return;
    }
    console.warn('WebSocket 斷線，5 秒後重連...');
    setFsDot('var(--red)', true);
    setSysStatus('連線中斷，重新連線中...');
    setTimeout(initWebSocket, 5000);
  };
  ws.onerror = (e) => console.warn('WebSocket 錯誤:', e);
}

// ── 分機即時狀態（前端快取）────────────────────────────────────────────────
// extStatusCache[ext_num] = { status, peer, direction, since }
const extStatusCache = {};

const EXT_STATUS_META = {
  idle:    { label: '✓ 上線',  dot: 'var(--green)',  cls: '',              dotCls: '',            badge: 'background:#2e7d32;color:#fff' },
  ringing: { label: '📞 響鈴', dot: 'var(--yellow)', cls: 'status-active', dotCls: 'dot-ringing', badge: 'background:#f9a825;color:#000' },
  talking: { label: '🔊 通話', dot: 'var(--green)',  cls: 'status-active', dotCls: '',            badge: 'background:#1b5e20;color:#fff' },
  holding: { label: '⏸ 保留',  dot: '#e65100',       cls: 'status-active', dotCls: '',            badge: 'background:#e65100;color:#fff' },
  parked:  { label: '🅿 停車',  dot: 'var(--accent)', cls: 'status-active', dotCls: '',            badge: 'background:#0277bd;color:#fff' },
  offline: { label: '✕ 離線',  dot: 'var(--muted)',  cls: '',              dotCls: '',            badge: 'background:#9e9e9e;color:#fff' },
};

function getExtMeta(status) {
  return EXT_STATUS_META[status] || EXT_STATUS_META['offline'];
}

/** 把後端推播的 EXT_STATUS_UPDATE 套用到分機 card 的 DOM（不重繪整頁） */
function applyExtStatusUpdate(ext, statusData) {
  extStatusCache[ext] = statusData;
  const meta = getExtMeta(statusData.status);

  // ── 分機管理頁 ext-card（不在畫面中則略過，不 crash）
  const card = document.querySelector(`.ext-card[data-ext-id="${ext}"]`);
  if (card) {
    card.dataset.st = statusData.status;
    const statusEl = card.querySelector('.ext-status');
    if (statusEl) {
      statusEl.innerHTML = `
        <span style="display:inline-block;padding:2px 8px;border-radius:20px;font-size:11px;font-weight:700;${meta.badge}">
          ${meta.label}
        </span>
        ${statusData.peer ? `<span style="font-size:10px;margin-left:6px;color:var(--muted)">${statusData.peer}</span>` : ''}`;
    }
    let timerEl = card.querySelector('.ext-timer');
    if (['talking','holding','ringing'].includes(statusData.status)) {
      if (!timerEl) { timerEl = document.createElement('div'); timerEl.className = 'ext-timer'; card.appendChild(timerEl); }
      timerEl.dataset.since = statusData.since || Date.now();
    } else { if (timerEl) timerEl.remove(); }
  }

  // ── 監控 Dashboard：局部更新 UC 表格列 ──────────────────────────────────────
  _ucUpdateRow(ext);
}

/** 從後端取得全部分機目前狀態，初始化快取並更新 DOM
 *  規則：快照的 since 比 cache 新（或 cache 空）才覆蓋，
 *        避免蓋掉 WebSocket 即時推播的最新狀態。
 */
async function loadExtStatusSnapshot() {
  const data = await apiFetch('/api/ext/status');
  if (!data || !data.status) return;
  Object.entries(data.status).forEach(([ext, st]) => {
    const cached = extStatusCache[ext];
    // cache 沒有值，或快照比 cache 更新 → 套用
    if (!cached || (st.since || 0) >= (cached.since || 0)) {
      applyExtStatusUpdate(ext, st);
    }
  });
}

// 計時器 tick：每秒更新通話中分機的時長顯示
setInterval(() => {
  document.querySelectorAll('.ext-timer[data-since]').forEach(el => {
    const since = parseInt(el.dataset.since) || 0;
    if (!since) return;
    const secs = Math.floor((Date.now() - since) / 1000);
    const h = Math.floor(secs / 3600);
    const m = Math.floor((secs % 3600) / 60);
    const s = secs % 60;
    el.textContent = h > 0
      ? `${h}:${String(m).padStart(2,'0')}:${String(s).padStart(2,'0')}`
      : `${m}:${String(s).padStart(2,'0')}`;
  });
}, 1000);

function handleWSEvent(event) {
  const type = event.type || '';
  console.log('FS 事件:', type, event);

  // ── 分機狀態即時更新（不重繪整頁）────────────────────────────
  if (type === 'EXT_STATUS_UPDATE') {
    applyExtStatusUpdate(event.ext, {
      status:    event.status,
      peer:      event.peer      || '',
      direction: event.direction || '',
      since:     event.since     || Date.now(),
    });
    return;   // 不需要繼續往下走
  }

  // ── 即時通話表：前端自維護 _liveCalls，不依賴 API 時序 ─────────────────
  if (type === 'CHANNEL_CREATE') {
    const uuid = event['Unique-ID'] || event.uuid;
    const caller = event['Caller-Caller-ID-Number'] || event.caller || '';
    const dest   = event.destination || '';
    const dir    = event['Call-Direction'] || event.direction || '';
    if (uuid && caller) {
      _liveCalls[uuid] = { uuid, cid_num: caller, dest, direction: dir, callstate: 'CS_RINGING', created_epoch: Math.floor(Date.now()/1000) };
      _renderLiveCalls();
    }
    updateNavBadge();
    return;
  }
  if (type === 'CHANNEL_ANSWER') {
    const uuid = event['Unique-ID'] || event.uuid;
    if (uuid && _liveCalls[uuid]) {
      _liveCalls[uuid].callstate = 'CS_ACTIVE';
      _renderLiveCalls();
    }
    updateNavBadge();
    return;
  }
  if (type === 'CHANNEL_DESTROY') {
    const uuid = event['Unique-ID'] || event.uuid;
    if (uuid) {
      delete _liveCalls[uuid];
      _renderLiveCalls();
    }
    updateNavBadge();
    return;
  }
  if (['CHANNEL_HOLD','CHANNEL_UNHOLD','CHANNEL_PARK','CHANNEL_UNPARK'].includes(type)) {
    const uuid = event['Unique-ID'] || event.uuid;
    if (uuid && _liveCalls[uuid]) {
      _liveCalls[uuid].callstate = type === 'CHANNEL_HOLD' ? 'CS_HOLD' : type === 'CHANNEL_PARK' ? 'CS_PARK' : 'CS_ACTIVE';
      _renderLiveCalls();
    }
    updateNavBadge();
    return;
  }
}

// ── API 工具函式 ───────────────────────────────────────────────────────────────
async function apiFetch(path, options = {}) {
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
}

async function fetchLiveCalls() {
  const data = await apiFetch('/api/calls');
  return (data && data.rows) ? data.rows : [];
}

async function fetchRegistrations() {
  const data = await apiFetch('/api/registrations');
  const rows = (data && data.rows) ? data.rows : [];
  // normalize：reg_user 可能帶有 @realm，統一取 @ 前的部分
  rows.forEach(r => {
    if (r.reg_user && r.reg_user.includes('@')) {
      r.reg_user = r.reg_user.split('@')[0].trim();
    }
  });
  console.debug('[Registrations] raw rows:', rows.map(r => r.reg_user));
  return rows;
}

async function runESLCommand(command) {
  try {
    const res = await fetch(`${API_BASE}/api/esl`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Authorization': `Bearer ${getToken()}`,
      },
      body: JSON.stringify({ command })
    });
    if (res.status === 401) { redirectToLogin(); return { result: '' }; }
    return await res.json();
  } catch (e) {
    return { result: `錯誤: ${e.message}` };
  }
}

async function hangupCall(uuid) {
  const res = await fetch(`${API_BASE}/api/calls/hangup`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'Authorization': `Bearer ${getToken()}`,
    },
    body: JSON.stringify({ uuid })
  });
  if (res.status === 401) { redirectToLogin(); return; }
  setTimeout(() => switchPage(currentPage), 500);
}

async function holdCall(uuid) {
  const res = await fetch(`${API_BASE}/api/calls/hold`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'Authorization': `Bearer ${getToken()}`,
    },
    body: JSON.stringify({ uuid })
  });
  if (res.status === 401) { redirectToLogin(); return; }
  setTimeout(() => switchPage(currentPage), 500);
}

// ── DATA（假資料，僅供 CDR / Gateway / Extensions 頁面備用）─────────────────────
const liveCalls = [
  { uuid: 'a1b2c3', from: '1001', to: '1008', dest: '外線 02-2345-6789', status: 'active', dur: '04:32', codec: 'PCMU', dir: 'inbound' },
  { uuid: 'd4e5f6', from: '1003', to: '1015', dest: 'Internal', status: 'hold', dur: '01:10', codec: 'G729', dir: 'internal' },
  { uuid: 'g7h8i9', from: 'PSTN', to: '1005', dest: '外線', status: 'ringing', dur: '00:08', codec: '—', dir: 'inbound' },
  { uuid: 'j0k1l2', from: '1007', to: 'IVR', dest: 'IVR 主選單', status: 'active', dur: '00:55', codec: 'PCMA', dir: 'ivr' },
  { uuid: 'm3n4o5', from: '1002', to: 'PARK', dest: 'Parking 701', status: 'park', dur: '02:20', codec: 'PCMU', dir: 'park' },
  { uuid: 'p6q7r8', from: '1009', to: '1012', dest: 'Internal', status: 'active', dur: '06:44', codec: 'OPUS', dir: 'internal' },
];

const extensions = [
  { num:'1001', name:'Alice Chen', status:'active' },
  { num:'1002', name:'Bob Wang', status:'active' },
  { num:'1003', name:'Carol Lin', status:'hold' },
  { num:'1004', name:'David Wu', status:'idle' },
  { num:'1005', name:'Eva Huang', status:'ringing' },
  { num:'1006', name:'Frank Liu', status:'idle' },
  { num:'1007', name:'Grace Chang', status:'active' },
  { num:'1008', name:'Harry Chen', status:'active' },
  { num:'1009', name:'Iris Hsu', status:'active' },
  { num:'1010', name:'Jack Kuo', status:'idle' },
  { num:'1011', name:'Karen Su', status:'idle' },
  { num:'1012', name:'Leo Tang', status:'active' },
];

const cdrData = [
  { time:'10:42:11', from:'1001', to:'02-2345-6789', dur:'4:32', status:'ANSWERED', dir:'出撥' },
  { time:'10:38:05', from:'PSTN', to:'1005', dur:'0:08', status:'RINGING', dir:'來電' },
  { time:'10:31:22', from:'1007', to:'IVR', dur:'0:55', status:'ANSWERED', dir:'IVR' },
  { time:'10:28:44', from:'1003', to:'1015', dur:'1:10', status:'ANSWERED', dir:'內線' },
  { time:'10:20:09', from:'1009', to:'1012', dur:'6:44', status:'ANSWERED', dir:'內線' },
  { time:'10:15:33', from:'PSTN', to:'1002', dur:'3:21', status:'ANSWERED', dir:'來電' },
  { time:'10:08:17', from:'1006', to:'02-8765-4321', dur:'0:00', status:'NO ANSWER', dir:'出撥' },
  { time:'09:57:50', from:'1004', to:'1010', dur:'2:05', status:'ANSWERED', dir:'內線' },
];

const barHeights = [30,45,52,38,60,72,55,80,68,74,90,85,78,95,88,72,65,80,92,87,70,60,50,45,38];
const barLabels = ['00','02','04','06','08','10','11','12','13','14'];

// ── 共用：計算通話時長 ────────────────────────────────────────────────────────
function calcDuration(createdEpoch) {
  if (!createdEpoch || createdEpoch === '0') return '—';
  const secs = Math.floor(Date.now() / 1000) - parseInt(createdEpoch);
  if (secs < 0) return '00:00';
  const m = Math.floor(secs / 60).toString().padStart(2, '0');
  const s = (secs % 60).toString().padStart(2, '0');
  return `${m}:${s}`;
}

// ── 共用：通話列表 HTML ───────────────────────────────────────────────────────
function buildCallRows(rows) {
  const stateMap  = { ACTIVE:'通話中', HELD:'保留', RINGING:'響鈴', RING_WAIT:'等待', EARLY:'早期媒體' };
  const stateClass = { ACTIVE:'status-active', HELD:'status-hold', RINGING:'status-ringing', RING_WAIT:'status-ringing' };
  if (rows.length === 0) {
    return `<tr><td colspan="7" style="text-align:center;color:var(--muted);padding:24px">目前沒有進行中的通話</td></tr>`;
  }
  return rows.map(c => {
    const uuid      = c.uuid || '—';
    const cidNum    = c.cid_num  || '—';
    const cidName   = c.cid_name || '';
    const caller    = cidName ? `${cidName} <${cidNum}>` : cidNum;
    const dest      = c.dest     || '—';
    const callstate = c.callstate || 'ACTIVE';
    const direction = c.direction === 'outbound' ? '出撥' : '來電';
    const duration  = calcDuration(c.created_epoch);
    const safeUUID  = uuid.replace(/'/g, "\\'");
    return `<tr>
      <td style="color:var(--muted);font-size:10px;font-family:monospace" title="${uuid}">${uuid.substring(0,8)}...</td>
      <td style="color:#fff">${caller}</td>
      <td>${dest}</td>
      <td><span class="call-status ${stateClass[callstate]||'status-active'}"><span class="dot"></span>${stateMap[callstate]||callstate}</span></td>
      <td style="color:var(--accent);font-weight:700">${duration}</td>
      <td style="font-size:11px">${direction}</td>
      <td style="display:flex;gap:4px;flex-wrap:wrap">
        <button class="btn danger" style="padding:3px 8px;font-size:10px" onclick="hangupCall('${safeUUID}')">掛斷</button>
        <button class="btn" style="padding:3px 8px;font-size:10px" onclick="holdCall('${safeUUID}')">保留</button>
      </td>
    </tr>`;
  }).join('');
}



// ── 側邊欄分類收合（記憶於 localStorage，跨重整保留狀態）───────────────────────
const NAV_COLLAPSE_KEY = 'fsdash_nav_collapsed';

function _loadNavCollapsedState() {
  try { return JSON.parse(localStorage.getItem(NAV_COLLAPSE_KEY)) || {}; }
  catch(e) { return {}; }
}

function toggleNavGroup(group) {
  const el = document.querySelector(`.nav-group[data-group="${group}"]`);
  if (!el) return;
  const collapsed = el.classList.toggle('collapsed');
  const state = _loadNavCollapsedState();
  state[group] = collapsed;
  localStorage.setItem(NAV_COLLAPSE_KEY, JSON.stringify(state));
}

function initNavCollapse() {
  const state = _loadNavCollapsedState();
  document.querySelectorAll('.nav-group').forEach(el => {
    if (state[el.dataset.group]) el.classList.add('collapsed');
  });
}

// ── 即時通話 badge 更新（事件觸發，不輪詢）─────────────────────────────────
async function updateNavBadge() {
  const data = await apiFetch('/api/calls');
  const count = (data && data.row_count) ? data.row_count : 0;
  const badge = document.getElementById('nav-calls-badge');
  if (badge) badge.textContent = count;
}
