// logs.js — 系統日誌（即時串流 + 歷史查詢 + 日誌管理）

let _logSSE = null;
let _logFilter = 'ALL';
let _logLines = [];          // 原始解析後的 log 緩衝（最多 5000 筆，供切換篩選時重新渲染）
const MAX_LOG_LINES = 200;   // 畫面最多顯示行數
const MAX_LOG_BUFFER = 5000; // 緩衝區最多保留行數

// 即時日誌分頁狀態
let _livePage = 1;           // 目前頁碼（1-based，最後一頁 = 最新）
let _livePerPage = 200;      // 每頁行數
let _livePaused = false;     // 暫停自動捲動到最新頁

// 通話相關的 FreeSwitch source 檔案關鍵字
const CALL_SOURCES = [
  'mod_sofia.c', 'sofia.c', 'sofia_media.c',
  'switch_core_state_machine.c', 'switch_channel.c',
  'switch_core_session.c', 'switch_core_media.c',
  'mod_dptools.c', 'mod_dialplan_xml.c',
  'switch_ivr_originate.c', 'switch_ivr.c',
];
const CALL_MSG_KEYWORDS = [
  'sofia/', 'CHANNEL_', 'Callstate Change', 'State Change CS_',
  'HANGUP', 'ROUTING', 'EXECUTE', 'Processing ', 'bridge',
  'New Channel', 'Close Channel',
];

// 登入/登出相關
const REG_SOURCES = [
  'sofia_reg.c', 'mod_sofia.c', 'sofia.c',
];
const REG_MSG_KEYWORDS = [
  // FreeSwitch 標準登錄訊息
  'Registered',       // sofia_reg.c: Registered sofia/internal/1002@...
  'UN-Registered',    // sofia_reg.c: UN-Registered sofia/internal/1002@...
  'Unregistered',
  'un-registered',
  // SIP 方法關鍵字（出現在 sofia 詳細日誌）
  'REGISTER sip',
  'sip:REGISTER',
  'method=REGISTER',
  // auth 相關
  'auth_challenge',
  'auth challenge',
  'auth pass',
  'auth fail',
  'Authorization',
  // 從 sofia status 顯示的欄位
  'Contact Expires',
  'Registration expires',
  // 關鍵：直接搜分機號碼出現在登錄上下文的情況
];

// 除了 source/keyword 匹配，也加上純訊息快速比對（不區分大小寫）
const REG_MSG_LOWER = [
  'registered',
  'unregistered',
  'un-registered',
  'register sip',
  'auth challenge',
  'auth pass',
  'auth fail',
  'authorization',
];

function isCallLog(parsed) {
  const src = (parsed.source || '').toLowerCase();
  const msg = parsed.msg || '';
  return CALL_SOURCES.some(s => src.startsWith(s.toLowerCase()))
      || CALL_MSG_KEYWORDS.some(k => msg.includes(k));
}

function isRegLog(parsed) {
  const src = (parsed.source || '').toLowerCase();
  const msgLower = (parsed.msg || '').toLowerCase();
  // source 是登錄相關模組，OR 訊息直接含登錄關鍵字（不區分大小寫）
  const srcMatch = REG_SOURCES.some(s => src.startsWith(s.toLowerCase()));
  const kwMatch  = REG_MSG_LOWER.some(k => msgLower.includes(k));
  // 只要其中一個條件符合就顯示
  return srcMatch || kwMatch;
}

function renderLogs() {
  // 關閉舊的 SSE 連線
  if (_logSSE) { _logSSE.close(); _logSSE = null; }
  _logLines = [];
  _logTab = 'live'; // 預設顯示即時 log

  document.getElementById('mainContent').innerHTML = `
  <!-- ── 系統日誌頁：即時 + 歷史兩個 Tab ── -->
  <div style="display:flex;flex-direction:column;gap:12px;height:calc(100vh - 80px)">

    <!-- Tab 切換列 -->
    <div style="display:flex;align-items:center;gap:0;background:var(--panel);border:1px solid var(--border);border-radius:8px;overflow:hidden;box-shadow:var(--glow)">
      <button id="log-tab-live" onclick="switchLogTab('live')"
        style="flex:1;padding:10px 0;border:none;cursor:pointer;font-family:inherit;font-size:13px;font-weight:600;
               background:var(--accent);color:#fff;border-right:1px solid var(--border)">
        📡 即時日誌
      </button>
      <button id="log-tab-history" onclick="switchLogTab('history')"
        style="flex:1;padding:10px 0;border:none;cursor:pointer;font-family:inherit;font-size:13px;font-weight:600;
               background:var(--panel2);color:var(--muted);border-right:1px solid var(--border)">
        📅 歷史日誌
      </button>
      <button id="log-tab-reg" onclick="switchLogTab('reg')"
        style="flex:1;padding:10px 0;border:none;cursor:pointer;font-family:inherit;font-size:13px;font-weight:600;
               background:var(--panel2);color:var(--muted);border-right:1px solid var(--border)">
        🔐 登錄記錄
      </button>
      <button id="log-tab-manage" onclick="switchLogTab('manage')"
        style="flex:1;padding:10px 0;border:none;cursor:pointer;font-family:inherit;font-size:13px;font-weight:600;
               background:var(--panel2);color:var(--muted)">
        🗂 日誌管理
      </button>
    </div>

    <!-- ── Tab: 即時日誌 ── -->
    <div id="log-pane-live" style="display:flex;flex-direction:column;gap:0;flex:1;min-height:0">
      <div class="panel" style="flex:1;display:flex;flex-direction:column;min-height:0">
        <div class="panel-header">
          <span class="panel-badge live" id="log-badge">LIVE TAIL</span>
          <div class="panel-actions" id="live-pager" style="display:none;align-items:center;gap:6px">
            <button class="btn" id="live-prev" onclick="livePageGo(-1)">◀ 上一頁</button>
            <span id="live-page-label" style="font-size:12px;color:var(--muted)">1 / 1</span>
            <button class="btn" id="live-next" onclick="livePageGo(1)">下一頁 ▶</button>
            <select id="live-per-page" onchange="livePerPageChange(this.value)"
              style="padding:4px 8px;border:1px solid var(--border);border-radius:5px;
                background:var(--panel2);color:var(--text);font-family:inherit;font-size:12px">
              <option value="100">100 行/頁</option>
              <option value="200" selected>200 行/頁</option>
              <option value="500">500 行/頁</option>
              <option value="1000">1000 行/頁</option>
            </select>
          </div>
          <div class="panel-actions">
            <select class="filter-select" id="log-filter" style="margin-right:4px" onchange="setLogFilter(this.value)">
              <option value="ALL">ALL</option>
              <option value="CALL">📞 通話 Log</option>
              <option value="REG">🔐 登錄 Log</option>
              <option value="ERR">ERR</option>
              <option value="WARNING">WARN</option>
              <option value="NOTICE">NOTICE</option>
              <option value="INFO">INFO</option>
              <option value="DEBUG">DEBUG</option>
            </select>
            <button class="btn" onclick="clearLogs()">清空</button>
            <button class="btn" onclick="liveJumpLatest()">↓ 最新</button>
            <button class="btn" onclick="exportLogs()" title="匯出目前顯示的 Log">↓ 匯出</button>
          </div>
        </div>
        <div class="log-stream" id="log-stream" style="flex:1;min-height:0;overflow-y:auto"></div>
      </div>
    </div>

    <!-- ── Tab: 歷史日誌 ── -->
    <div id="log-pane-history" style="display:none;flex-direction:column;gap:12px;flex:1;min-height:0">

      <!-- 查詢列 -->
      <div class="panel" style="padding:14px 16px">
        <div style="display:flex;align-items:center;gap:10px;flex-wrap:wrap">
          <label style="font-weight:600;color:var(--label);white-space:nowrap">選擇日期：</label>
          <select id="hist-date-select" style="padding:6px 12px;border:1px solid var(--border);border-radius:6px;
            background:var(--panel2);color:var(--text);font-family:inherit;font-size:13px;min-width:190px">
            <option value="">-- 載入中 --</option>
          </select>

          <label style="font-weight:600;color:var(--label);white-space:nowrap">等級：</label>
          <select id="hist-level" style="padding:6px 10px;border:1px solid var(--border);border-radius:6px;
            background:var(--panel2);color:var(--text);font-family:inherit;font-size:13px">
            <option value="ALL">ALL</option>
            <option value="CALL">📞 通話</option>
            <option value="REG">🔐 登錄</option>
            <option value="ERR">ERR</option>
            <option value="WARNING">WARN</option>
            <option value="NOTICE">NOTICE</option>
            <option value="INFO">INFO</option>
            <option value="DEBUG">DEBUG</option>
          </select>

          <label style="font-weight:600;color:var(--label);white-space:nowrap">關鍵字：</label>
          <input id="hist-keyword" type="text" placeholder="搜尋訊息或來源…"
            style="padding:6px 10px;border:1px solid var(--border);border-radius:6px;
              background:var(--panel2);color:var(--text);font-family:inherit;font-size:13px;min-width:180px"
            onkeydown="if(event.key==='Enter') searchHistoryLog(1)">

          <button class="btn primary" onclick="searchHistoryLog(1)">🔍 搜尋</button>
          <button class="btn" onclick="downloadHistoryLog()" id="hist-dl-btn" style="display:none">⬇ 下載原始檔</button>
        </div>
      </div>

      <!-- Log 顯示區 -->
      <div class="panel" style="flex:1;display:flex;flex-direction:column;min-height:0">
        <div class="panel-header">
          <span class="panel-badge" id="hist-badge" style="background:#fff;color:var(--text);border:1px solid var(--border)">歷史 LOG</span>
          <div class="panel-actions" id="hist-pager" style="display:none;align-items:center;gap:6px">
            <button class="btn" id="hist-prev" onclick="histPageGo(-1)">◀ 上一頁</button>
            <span id="hist-page-label" style="font-size:12px;color:var(--muted)">1 / 1</span>
            <button class="btn" id="hist-next" onclick="histPageGo(1)">下一頁 ▶</button>
            <select id="hist-per-page" onchange="searchHistoryLog(1)"
              style="padding:4px 8px;border:1px solid var(--border);border-radius:5px;
                background:var(--panel2);color:var(--text);font-family:inherit;font-size:12px">
              <option value="200">200 行/頁</option>
              <option value="500" selected>500 行/頁</option>
              <option value="1000">1000 行/頁</option>
            </select>
          </div>
        </div>
        <div class="log-stream" id="hist-stream" style="flex:1;min-height:0;overflow-y:auto">
          <div style="color:var(--muted);padding:40px;text-align:center">請從上方選擇日期後點擊「搜尋」</div>
        </div>
      </div>
    </div>

    <!-- ── Tab: 登錄記錄 ── -->
    <div id="log-pane-reg" style="display:none;flex-direction:column;gap:12px;flex:1;min-height:0">

      <!-- 查詢列 -->
      <div class="panel" style="padding:14px 16px">
        <div style="display:flex;align-items:center;gap:10px;flex-wrap:wrap">
          <label style="font-weight:600;color:var(--label);white-space:nowrap">起始日期：</label>
          <input id="reg-date-from" type="date"
            style="padding:6px 10px;border:1px solid var(--border);border-radius:6px;
              background:var(--panel2);color:var(--text);font-family:inherit;font-size:13px">

          <label style="font-weight:600;color:var(--label);white-space:nowrap">結束日期：</label>
          <input id="reg-date-to" type="date"
            style="padding:6px 10px;border:1px solid var(--border);border-radius:6px;
              background:var(--panel2);color:var(--text);font-family:inherit;font-size:13px">

          <label style="font-weight:600;color:var(--label);white-space:nowrap">分機：</label>
          <input id="reg-ext-filter" type="text" placeholder="例如 1126"
            style="padding:6px 10px;border:1px solid var(--border);border-radius:6px;
              background:var(--panel2);color:var(--text);font-family:inherit;font-size:13px;min-width:100px"
            onkeydown="if(event.key==='Enter') loadRegLog(1)">

          <label style="font-weight:600;color:var(--label);white-space:nowrap">事件：</label>
          <select id="reg-event-filter" style="padding:6px 10px;border:1px solid var(--border);border-radius:6px;
            background:var(--panel2);color:var(--text);font-family:inherit;font-size:13px">
            <option value="">全部</option>
            <option value="REGISTER">登錄</option>
            <option value="UNREGISTER">登出</option>
          </select>

          <button class="btn primary" onclick="loadRegLog(1)">🔍 查詢</button>
          <button class="btn" onclick="resetRegLogFilter()">↺ 清除篩選</button>
        </div>
      </div>

      <div class="panel" style="flex:1;display:flex;flex-direction:column;min-height:0">
        <div class="panel-header">
          <span class="panel-title">分機登錄 / 登出記錄</span>
          <span class="panel-badge" id="reg-log-badge">載入中...</span>
          <div class="panel-actions" id="reg-pager" style="display:none;align-items:center;gap:6px">
            <button class="btn" id="reg-prev" onclick="regPageGo(-1)">◀ 上一頁</button>
            <span id="reg-page-label" style="font-size:12px;color:var(--muted)">1 / 1</span>
            <button class="btn" id="reg-next" onclick="regPageGo(1)">下一頁 ▶</button>
          </div>
        </div>
        <div style="overflow-y:auto;flex:1;min-height:0" id="reg-log-body">
          <div style="padding:40px;text-align:center;color:var(--muted)">載入中...</div>
        </div>
      </div>
    </div>

    <!-- ── Tab: 日誌管理 ── -->
    <div id="log-pane-manage" style="display:none;flex-direction:column;gap:12px;flex:1;min-height:0">
      <div class="panel" style="padding:16px">
        <div style="display:flex;align-items:center;gap:12px;flex-wrap:wrap">
          <span style="font-weight:600;color:var(--label)">日誌輪轉管理</span>
          <button class="btn primary" onclick="manualRotateLog()" style="background:var(--accent2)">🔄 立即輪轉今日 Log</button>
          <button class="btn" onclick="loadLogManage()">↺ 重新整理</button>
          <span id="manage-msg" style="color:var(--muted);font-size:12px"></span>
        </div>
        <div style="margin-top:10px;font-size:12px;color:var(--muted)">
          系統每日 <strong>00:00:30</strong> 自動將 freeswitch.log 另存為 freeswitch-YYYY-MM-DD.log，並清空原始 log 供繼續寫入。
        </div>
      </div>
      <!-- 目前 log 狀態 -->
      <div class="panel" style="padding:16px">
        <div style="font-weight:600;color:var(--label);margin-bottom:10px">目前 Log 狀態</div>
        <div id="manage-current" style="color:var(--muted)">載入中…</div>
      </div>
      <!-- 歷史日誌檔案列表 -->
      <div class="panel" style="flex:1;display:flex;flex-direction:column;min-height:0">
        <div class="panel-header">
          <span style="font-weight:600">歷史日誌檔案</span>
          <span id="manage-count" class="panel-badge" style="background:#fff;color:var(--text);border:1px solid var(--border)">0 個</span>
        </div>
        <div id="manage-list" style="flex:1;overflow-y:auto;padding:4px 0">
          <div style="color:var(--muted);padding:24px;text-align:center">載入中…</div>
        </div>
      </div>
    </div>

  </div>`;

  startLogStream();
  // 載入歷史日期選單（背景預載）
  loadLogDateList();
  loadLogManage();
}

// ── Log Tab 切換 ──────────────────────────────────────────────────────────────
let _logTab = 'live';

function switchLogTab(tab) {
  _logTab = tab;
  ['live','history','reg','manage'].forEach(t => {
    const pane = document.getElementById(`log-pane-${t}`);
    const btn  = document.getElementById(`log-tab-${t}`);
    if (!pane || !btn) return;
    const active = (t === tab);
    pane.style.display = active ? 'flex' : 'none';
    btn.style.background = active ? 'var(--accent)' : 'var(--panel2)';
    btn.style.color      = active ? '#fff'          : 'var(--muted)';
  });
  if (tab === 'reg') loadRegLog();
}

// ── 登錄記錄 ─────────────────────────────────────────────────────────────────
let _regPage = 1;
let _regPerPage = 200;
let _regTotalPages = 1;

async function loadRegLog(page) {
  if (page) _regPage = page;
  const body  = document.getElementById('reg-log-body');
  const badge = document.getElementById('reg-log-badge');
  const pager = document.getElementById('reg-pager');
  if (!body) return;
  body.innerHTML = '<div style="padding:24px;text-align:center;color:var(--muted)">載入中...</div>';

  const dateFromEl = document.getElementById('reg-date-from');
  const dateToEl   = document.getElementById('reg-date-to');
  const extEl      = document.getElementById('reg-ext-filter');
  const eventEl    = document.getElementById('reg-event-filter');
  const dateFrom = dateFromEl ? dateFromEl.value : '';
  const dateTo   = dateToEl   ? dateToEl.value   : '';
  const ext      = extEl      ? extEl.value.trim() : '';
  const eventVal = eventEl    ? eventEl.value : '';

  const params = new URLSearchParams({ page: _regPage, per_page: _regPerPage });
  if (dateFrom) params.set('date_from', dateFrom);
  if (dateTo)   params.set('date_to', dateTo);
  if (ext)      params.set('ext', ext);
  if (eventVal) params.set('event', eventVal);

  try {
    const data = await apiFetch(`/api/reg/log?${params.toString()}`);
    const logs = (data && data.rows) ? data.rows : [];
    _regTotalPages = data.total_pages || 1;
    if (badge) badge.textContent = `共 ${data.total || 0} 筆`;
    if (pager) {
      pager.style.display = _regTotalPages > 1 ? 'flex' : 'none';
      const label   = document.getElementById('reg-page-label');
      const prevBtn = document.getElementById('reg-prev');
      const nextBtn = document.getElementById('reg-next');
      if (label)   label.textContent = `${_regPage} / ${_regTotalPages}`;
      if (prevBtn) prevBtn.disabled = _regPage <= 1;
      if (nextBtn) nextBtn.disabled = _regPage >= _regTotalPages;
    }
    if (!logs.length) {
      body.innerHTML = '<div style="padding:40px;text-align:center;color:var(--muted)">尚無登錄記錄（分機登入/登出後會自動記錄，或篩選條件無符合資料）</div>';
      return;
    }
    const rows = logs.map(r => {
      const isReg = r.event === 'REGISTER';
      const dotColor = isReg ? 'var(--green)' : 'var(--muted)';
      const label    = isReg ? '登錄' : '登出';
      const labelColor = isReg ? 'var(--green)' : 'var(--red)';
      return `<tr>
        <td style="font-size:12px;color:var(--muted);white-space:nowrap">${r.time_str}</td>
        <td style="font-weight:700;color:var(--accent-bright)">${r.ext}</td>
        <td>
          <span style="display:inline-flex;align-items:center;gap:5px">
            <span style="width:7px;height:7px;border-radius:50%;background:${dotColor};display:inline-block"></span>
            <span style="color:${labelColor};font-weight:600">${label}</span>
          </span>
        </td>
        <td style="font-size:12px;color:var(--muted)">${r.ip || '—'}</td>
        <td style="font-size:12px;color:var(--muted)">${r.proto || '—'}</td>
      </tr>`;
    }).join('');
    body.innerHTML = `
      <table style="width:100%">
        <thead>
          <tr>
            <th style="text-align:left;padding:8px 12px;font-size:12px;color:var(--label);border-bottom:1px solid var(--border)">時間</th>
            <th style="text-align:left;padding:8px 12px;font-size:12px;color:var(--label);border-bottom:1px solid var(--border)">分機</th>
            <th style="text-align:left;padding:8px 12px;font-size:12px;color:var(--label);border-bottom:1px solid var(--border)">事件</th>
            <th style="text-align:left;padding:8px 12px;font-size:12px;color:var(--label);border-bottom:1px solid var(--border)">IP</th>
            <th style="text-align:left;padding:8px 12px;font-size:12px;color:var(--label);border-bottom:1px solid var(--border)">協定</th>
          </tr>
        </thead>
        <tbody>${rows}</tbody>
      </table>`;
  } catch(e) {
    body.innerHTML = `<div style="padding:24px;color:var(--red)">載入失敗：${e.message}</div>`;
  }
}

function regPageGo(delta) {
  const next = _regPage + delta;
  if (next < 1 || next > _regTotalPages) return;
  loadRegLog(next);
}

function resetRegLogFilter() {
  ['reg-date-from', 'reg-date-to', 'reg-ext-filter', 'reg-event-filter'].forEach(id => {
    const el = document.getElementById(id);
    if (el) el.value = '';
  });
  loadRegLog(1);
}

// ── 歷史日誌：載入日期選單 ───────────────────────────────────────────────────
async function loadLogDateList() {
  try {
    const res  = await fetch(`${API_BASE}/api/logs/list`, { headers: { 'Authorization': `Bearer ${getToken()}` } });
    const data = await res.json();
    const sel  = document.getElementById('hist-date-select');
    if (!sel) return;
    if (!data.files || !data.files.length) {
      sel.innerHTML = '<option value="">（尚無歷史日誌）</option>';
      return;
    }
    sel.innerHTML = '<option value="">-- 選擇日期 --</option>' +
      data.files.map(f =>
        `<option value="${f.date}">${f.date}（${f.size_mb} MB）</option>`
      ).join('');
  } catch(e) {
    const sel = document.getElementById('hist-date-select');
    if (sel) sel.innerHTML = '<option value="">（無法取得列表）</option>';
  }
}

// ── 歷史日誌：分頁搜尋狀態 ───────────────────────────────────────────────────
let _histDate     = '';
let _histPage     = 1;
let _histTotal    = 0;
let _histTotalPg  = 1;

async function searchHistoryLog(page) {
  const date    = (document.getElementById('hist-date-select') || {}).value || '';
  const level   = (document.getElementById('hist-level')       || {}).value || 'ALL';
  const keyword = (document.getElementById('hist-keyword')     || {}).value || '';
  const perPage = parseInt((document.getElementById('hist-per-page') || {}).value || '500');

  if (!date) { alert('請先選擇日期'); return; }
  _histDate = date;
  _histPage = page || 1;

  const stream = document.getElementById('hist-stream');
  const badge  = document.getElementById('hist-badge');
  const pager  = document.getElementById('hist-pager');
  const dlBtn  = document.getElementById('hist-dl-btn');

  if (stream) stream.innerHTML = `<div style="color:var(--muted);padding:32px;text-align:center">⏳ 搜尋中…</div>`;
  if (badge)  badge.textContent = '搜尋中…';
  if (pager)  pager.style.display = 'none';

  try {
    const params = new URLSearchParams({
      date, level, keyword,
      page: _histPage,
      per_page: perPage,
    });
    const res  = await fetch(`${API_BASE}/api/logs/history?${params}`, { headers: { 'Authorization': `Bearer ${getToken()}` } });
    if (!res.ok) {
      const err = await res.json();
      throw new Error(err.detail || res.statusText);
    }
    const data = await res.json();
    _histTotal   = data.total;
    _histTotalPg = data.total_pages;
    _histPage    = data.page;

    // 更新 badge
    const kw = keyword ? ` · "${keyword}"` : '';
    const lv = level !== 'ALL' ? ` · ${level}` : '';
    if (badge) badge.textContent = `${date}${lv}${kw} · 共 ${data.total} 行`;

    // 渲染行
    renderHistRows(data.rows);

    // 更新分頁控制
    updateHistPager(data.page, data.total_pages, data.total, perPage);
    if (dlBtn) dlBtn.style.display = '';

  } catch(e) {
    if (stream) stream.innerHTML = `<div style="color:var(--red);padding:24px;text-align:center">❌ 錯誤：${e.message}</div>`;
    if (badge)  badge.textContent = '錯誤';
  }
}

function renderHistRows(rows) {
  const stream = document.getElementById('hist-stream');
  if (!stream) return;
  if (!rows || !rows.length) {
    stream.innerHTML = '<div style="color:var(--muted);padding:40px;text-align:center">沒有符合條件的日誌</div>';
    return;
  }
  // 用 DocumentFragment 批次插入，避免多次 reflow
  const frag = document.createDocumentFragment();
  rows.forEach(p => {
    const div = document.createElement('div');
    div.className = 'log-line';
    div.innerHTML = `
      <span class="log-time">${p.time}</span>
      <span class="log-level ${logLevelClass(p.level)}">${logLevelLabel(p.level)}</span>
      <span class="log-source" style="color:var(--muted);font-size:10px;min-width:200px;margin-right:8px">${p.source}</span>
      <span class="log-msg">${escapeHtml(p.msg)}</span>`;
    frag.appendChild(div);
  });
  stream.innerHTML = '';
  stream.appendChild(frag);
  stream.scrollTop = 0;
}

function updateHistPager(page, totalPages, total, perPage) {
  const pager = document.getElementById('hist-pager');
  const label = document.getElementById('hist-page-label');
  const prev  = document.getElementById('hist-prev');
  const next  = document.getElementById('hist-next');
  if (!pager) return;

  if (totalPages <= 1) {
    pager.style.display = 'none';
    return;
  }
  pager.style.display = 'flex';
  if (label) label.textContent = `第 ${page} / ${totalPages} 頁（共 ${total} 行）`;
  if (prev)  prev.disabled  = (page <= 1);
  if (next)  next.disabled  = (page >= totalPages);
}

function histPageGo(delta) {
  const newPage = _histPage + delta;
  if (newPage < 1 || newPage > _histTotalPg) return;
  searchHistoryLog(newPage);
}

function downloadHistoryLog() {
  if (!_histDate) return;
  const a = document.createElement('a');
  a.href     = `${API_BASE}/api/logs/download?date=${_histDate}`;
  a.download = `freeswitch-${_histDate}.log`;
  a.click();
}

function scrollHistBottom() {
  const stream = document.getElementById('hist-stream');
  if (stream) stream.scrollTop = stream.scrollHeight;
}

// viewHistByDate: 從日誌管理跳轉過來時使用
function viewHistByDate(date) {
  switchLogTab('history');
  const sel = document.getElementById('hist-date-select');
  if (sel) sel.value = date;
  searchHistoryLog(1);
}

function dlLogByDate(date) {
  _histDate = date;
  downloadHistoryLog();
}
async function loadLogManage() {
  const el    = document.getElementById('manage-list');
  const curr  = document.getElementById('manage-current');
  const count = document.getElementById('manage-count');
  if (!el) return;

  try {
    const res  = await fetch(`${API_BASE}/api/logs/list`, { headers: { 'Authorization': `Bearer ${getToken()}` } });
    const data = await res.json();

    // 目前 log 狀態
    if (curr) {
      curr.innerHTML = `
        <div style="display:flex;gap:24px;flex-wrap:wrap">
          <span>📄 <strong>freeswitch.log</strong></span>
          <span>大小：<strong style="color:var(--accent)">${data.current_size_mb} MB</strong></span>
          <span style="color:var(--muted);font-size:11px">${data.current_log}</span>
        </div>`;
    }

    if (!data.files || !data.files.length) {
      el.innerHTML = '<div style="color:var(--muted);padding:24px;text-align:center">尚無歷史日誌檔案</div>';
      if (count) count.textContent = '0 個';
      return;
    }

    if (count) count.textContent = `${data.files.length} 個`;

    el.innerHTML = `
      <table style="width:100%;border-collapse:collapse">
        <thead>
          <tr style="background:var(--panel2);text-align:left">
            <th style="padding:8px 14px;color:var(--label);font-size:12px;border-bottom:1px solid var(--border)">日期</th>
            <th style="padding:8px 14px;color:var(--label);font-size:12px;border-bottom:1px solid var(--border)">檔名</th>
            <th style="padding:8px 14px;color:var(--label);font-size:12px;border-bottom:1px solid var(--border)">大小</th>
            <th style="padding:8px 14px;color:var(--label);font-size:12px;border-bottom:1px solid var(--border)">儲存時間</th>
            <th style="padding:8px 14px;color:var(--label);font-size:12px;border-bottom:1px solid var(--border)">操作</th>
          </tr>
        </thead>
        <tbody>
          ${data.files.map(f => `
            <tr style="border-bottom:1px solid var(--border)" onmouseover="this.style.background='var(--panel2)'" onmouseout="this.style.background=''">
              <td style="padding:8px 14px;font-weight:600;color:var(--accent)">${f.date}</td>
              <td style="padding:8px 14px;color:var(--muted);font-size:11px">${f.filename}</td>
              <td style="padding:8px 14px">${f.size_mb} MB</td>
              <td style="padding:8px 14px;color:var(--muted);font-size:11px">${f.mtime}</td>
              <td style="padding:8px 14px;display:flex;gap:6px">
                <button class="btn" style="font-size:11px;padding:3px 10px"
                  onclick="viewHistByDate('${f.date}')">🔍 檢視</button>
                <button class="btn primary" style="font-size:11px;padding:3px 10px"
                  onclick="dlLogByDate('${f.date}')">⬇ 下載</button>
              </td>
            </tr>`).join('')}
        </tbody>
      </table>`;
  } catch(e) {
    if (el) el.innerHTML = `<div style="color:var(--red);padding:24px">載入失敗：${e.message}</div>`;
  }
}

async function manualRotateLog() {
  const msg = document.getElementById('manage-msg');
  if (msg) msg.textContent = '執行中…';
  try {
    const res  = await fetch(`${API_BASE}/api/logs/rotate`, {
      method: 'POST',
      headers: { 'Authorization': `Bearer ${getToken()}` },
    });
    const data = await res.json();
    if (msg) msg.textContent = res.ok
      ? `✅ 成功：已建立 ${data.file}（${data.size} bytes）`
      : `❌ 失敗：${data.detail || data.error}`;
    loadLogManage();
    loadLogDateList();
  } catch(e) {
    if (msg) msg.textContent = `❌ 錯誤：${e.message}`;
  }
}

// ── 日誌管理：載入列表 & 立即輪轉 ────────────────────────────────────────────
function parseFSLogLine(raw) {
  // FreeSwitch log 格式有兩種：
  // 1. 帶 UUID：  <uuid> <date> <time> <cpu>% [LEVEL] <file> <message>
  // 2. 不帶 UUID：<date> <time> <cpu>% [LEVEL] <file> <message>
  // 也有純 SDP/dialplan 行（無時間戳記）

  // 嘗試匹配帶時間戳的行
  // 格式：YYYY-MM-DD HH:MM:SS.ssssss xx.xx% [LEVEL] source msg
  const tsRe = /(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\.\d+\s+[\d.]+%\s+\[(\w+)\]\s+(.*)/;

  // 可能帶 UUID 前綴（36字元）
  let line = raw.trim();
  const uuidRe = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\s+/i;
  line = line.replace(uuidRe, '');

  const m = line.match(tsRe);
  if (m) {
    // 只取時間部分 HH:MM:SS
    const time = m[1].split(' ')[1].substring(0, 8);
    const level = m[2];
    const rest = m[3];
    // 分離 source file 和訊息（source 通常是 file.c:linenum）
    const srcRe = /^(\S+\.\w+:\d+)\s+(.*)/;
    const sm = rest.match(srcRe);
    const source = sm ? sm[1] : '';
    const msg    = sm ? sm[2] : rest;
    return { time, level, source, msg, raw };
  }

  // 純 dialplan / SDP / EXECUTE 行
  return { time: '', level: 'RAW', source: '', msg: line, raw };
}

function logLevelClass(level) {
  const map = {
    ERR:'log-err', ERROR:'log-err',
    WARNING:'log-warn', WARN:'log-warn',
    NOTICE:'log-info',
    INFO:'log-info',
    DEBUG:'log-dbg',
    RAW:'log-dbg',
  };
  return map[level] || 'log-dbg';
}

function logLevelLabel(level) {
  const map = { ERR:'ERR', ERROR:'ERR', WARNING:'WARN', NOTICE:'NTC', INFO:'INFO', DEBUG:'DBG', RAW:'' };
  return map[level] || level;
}

function shouldShowLog(parsed) {
  if (_logFilter === 'ALL')  return true;
  if (_logFilter === 'CALL') return isCallLog(parsed);
  if (_logFilter === 'REG')  return isRegLog(parsed);
  return parsed.level === _logFilter;
}

function appendLogLine(parsed) {
  // 不顯示空白行
  if (!parsed.msg.trim()) return;

  // 存入緩衝區
  _logLines.push(parsed);
  if (_logLines.length > MAX_LOG_BUFFER) _logLines.shift();

  // 若目前在最後一頁（或尚未分頁），才即時更新畫面
  const filtered = _logLines.filter(shouldShowLog);
  const totalPages = Math.max(1, Math.ceil(filtered.length / _livePerPage));
  if (_livePage >= totalPages) {
    // 在最新頁，直接重新渲染該頁
    _livePage = totalPages;
    renderLivePage();
  } else {
    // 不在最新頁，只更新分頁資訊
    updateLivePager(filtered.length);
  }
}

// ── 即時日誌分頁渲染 ──────────────────────────────────────────────────────────
function renderLivePage() {
  const stream = document.getElementById('log-stream');
  if (!stream) return;

  const filtered = _logLines.filter(shouldShowLog);
  const totalPages = Math.max(1, Math.ceil(filtered.length / _livePerPage));
  if (_livePage > totalPages) _livePage = totalPages;
  if (_livePage < 1) _livePage = 1;

  const start = (_livePage - 1) * _livePerPage;
  const pageItems = filtered.slice(start, start + _livePerPage);

  stream.innerHTML = '';
  pageItems.forEach(parsed => {
    const div = document.createElement('div');
    div.className = 'log-line';
    div.innerHTML = `
      <span class="log-time">${parsed.time}</span>
      <span class="log-level ${logLevelClass(parsed.level)}">${logLevelLabel(parsed.level)}</span>
      <span class="log-source" style="color:var(--muted);font-size:10px;min-width:200px;margin-right:8px">${parsed.source}</span>
      <span class="log-msg">${escapeHtml(parsed.msg)}</span>`;
    stream.appendChild(div);
  });

  // 最新頁自動捲到底
  if (_livePage === totalPages) stream.scrollTop = stream.scrollHeight;

  updateLivePager(filtered.length);
}

function updateLivePager(totalFiltered) {
  const totalPages = Math.max(1, Math.ceil(totalFiltered / _livePerPage));
  const pager = document.getElementById('live-pager');
  const label = document.getElementById('live-page-label');
  const prev  = document.getElementById('live-prev');
  const next  = document.getElementById('live-next');
  const badge = document.getElementById('log-badge');

  if (pager) pager.style.display = 'flex';  // 永遠顯示
  if (label) label.textContent = `第 ${_livePage} / ${totalPages} 頁（共 ${totalFiltered} 行）`;
  if (prev)  prev.disabled  = _livePage <= 1;
  if (next)  next.disabled  = _livePage >= totalPages;
  if (badge) badge.textContent = `LIVE`;
}

function livePageGo(delta) {
  const filtered   = _logLines.filter(shouldShowLog);
  const totalPages = Math.max(1, Math.ceil(filtered.length / _livePerPage));
  _livePage = Math.min(Math.max(1, _livePage + delta), totalPages);
  renderLivePage();
}

function livePerPageChange(val) {
  _livePerPage = parseInt(val);
  const filtered   = _logLines.filter(shouldShowLog);
  const totalPages = Math.max(1, Math.ceil(filtered.length / _livePerPage));
  _livePage = totalPages; // 跳到最新頁
  renderLivePage();
}

function liveJumpLatest() {
  const filtered   = _logLines.filter(shouldShowLog);
  const totalPages = Math.max(1, Math.ceil(filtered.length / _livePerPage));
  _livePage = totalPages;
  renderLivePage();
  const stream = document.getElementById('log-stream');
  if (stream) stream.scrollTop = stream.scrollHeight;
}

function escapeHtml(str) {
  return str.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');
}

function startLogStream() {
  const stream = document.getElementById('log-stream');
  if (!stream) return;

  _logSSE = new EventSource(`${API_BASE}/api/logs/stream`);

  _logSSE.onmessage = (e) => {
    try {
      const data = JSON.parse(e.data);
      if (data.line) {
        appendLogLine(parseFSLogLine(data.line));
      }
    } catch(err) {}
  };

  _logSSE.onerror = () => {
    const badge = document.getElementById('log-badge');
    if (badge) { badge.textContent = '連線中斷'; badge.className = 'panel-badge'; }
  };

  _logSSE.onopen = () => {
    const badge = document.getElementById('log-badge');
    if (badge) { badge.textContent = 'LIVE · 已連線'; badge.className = 'panel-badge live'; }
  };
}

function setLogFilter(val) {
  _logFilter = val;
  // 篩選變更後跳到最新頁重新渲染
  const filtered   = _logLines.filter(shouldShowLog);
  const totalPages = Math.max(1, Math.ceil(filtered.length / _livePerPage));
  _livePage = totalPages;
  renderLivePage();
}

function exportLogs() {
  // 匯出目前篩選條件下的所有緩衝 log
  const filtered = _logLines.filter(shouldShowLog);
  if (!filtered.length) { alert('目前沒有可匯出的 Log'); return; }

  const lines = filtered.map(p => {
    const level = logLevelLabel(p.level) || p.level;
    return `${p.time || '—'}\t${level}\t${p.source || ''}\t${p.msg}`;
  });

  const header = `FreeSwitch Log 匯出\n篩選條件：${_logFilter}\n匯出時間：${new Date().toLocaleString('zh-TW')}\n${'─'.repeat(80)}\n`;
  const content = header + lines.join('\n');

  const blob = new Blob(['\ufeff' + content], { type: 'text/plain;charset=utf-8' });
  const url  = URL.createObjectURL(blob);
  const a    = document.createElement('a');
  a.href     = url;
  a.download = `freeswitch_log_${_logFilter}_${new Date().toISOString().slice(0,19).replace(/:/g,'-')}.txt`;
  a.click();
  URL.revokeObjectURL(url);
}

function clearLogs() {
  _logLines = [];
  _livePage = 1;
  const stream = document.getElementById('log-stream');
  if (stream) stream.innerHTML = '';
  updateLivePager(0);
}

