// numbers.js — 號碼目錄頁面（含通用 Dialplan XML 新增/編輯/刪除 modal）

let _numCache     = null;   // 快取號碼目錄（避免每次輸入都打 API）
let _numCacheTime = 0;
const NUM_CACHE_TTL = 30000; // 30 秒快取

async function _numGetAll() {
  const now = Date.now();
  if (_numCache && (now - _numCacheTime) < NUM_CACHE_TTL) return _numCache;
  try {
    const data = await apiFetch('/api/numbers');
    _numCache     = (data && data.numbers) || [];
    _numCacheTime = now;
  } catch(e) {
    _numCache = [];
  }
  return _numCache;
}

// 清除快取（新增/刪除後呼叫，讓下次重新讀取）
function numClearCache() {
  _numCache     = null;
  _numCacheTime = 0;
}

/**
 * 檢查號碼是否衝突，並在 conflictDivId 顯示結果
 * @param {string} inputId       - 號碼輸入欄位 ID
 * @param {string} conflictDivId - 顯示告警的 div ID
 * @param {string} number        - 要檢查的號碼
 * @param {string} selfType      - 目前正在編輯的類型（'extension'|'group'|'ivr'）
 *                                 用於排除自身（編輯模式）
 */
async function numCheckConflict(inputId, conflictDivId, number, selfType) {
  const div = document.getElementById(conflictDivId);
  if (!div) return;

  const num = (number || '').trim();
  if (!num) { div.innerHTML = ''; return; }

  const all = await _numGetAll();

  // 目前正在編輯的 ID（編輯模式要排除自身）
  let selfId = '';
  if (selfType === 'extension') selfId = (document.getElementById('ext-id')||{}).dataset?.original || '';
  if (selfType === 'group')     selfId = (document.getElementById('group-id')||{}).dataset?.original || '';
  if (selfType === 'ivr')       selfId = (document.getElementById('ivr-id')||{}).value || '';

  // 找衝突（排除自己）
  const conflicts = all.filter(n => {
    if (n.number !== num) return false;
    // 編輯模式：如果是同類型且同 ID，不算衝突
    if (selfId && n.type === selfType && n.number === selfId) return false;
    return true;
  });

  if (conflicts.length === 0) {
    div.innerHTML = `<span style="font-size:11px;color:var(--green)">✓ 號碼可用</span>`;
    return;
  }

  // 有衝突：顯示告警
  const conflictInfo = conflicts.map(c => {
    const meta = { extension:'📞 分機', group:'▣ 群組', ivr:'🎛 IVR',
                   custom:'📋 自定義 Dialplan', reserved:'🔒 FreeSwitch 內建' };
    const typeLabel = meta[c.type] || c.type;
    return `<strong>${typeLabel}</strong>「${c.name || c.number}」${c.detail ? '（' + c.detail + '）' : ''}`;
  }).join('、');

  div.innerHTML = `
    <div style="display:flex;align-items:flex-start;gap:6px;padding:6px 10px;
                background:#ffebee;border:1px solid #ef9a9a;border-radius:4px;margin-top:2px">
      <span style="font-size:14px;flex-shrink:0">⚠️</span>
      <div style="font-size:12px;color:#c62828;line-height:1.5">
        <strong>號碼 ${num} 已被使用！</strong><br>
        目前由 ${conflictInfo} 佔用，請改用其他號碼。
      </div>
    </div>`;
}

// ════════════════════════════════════════════════════════════════════════════
// 號碼目錄（Number Map）
// ════════════════════════════════════════════════════════════════════════════

const NUMBER_TYPE_META = {
  extension: { icon: '📞', label: '分機',          color: '#0277bd', page: 'extensions' },
  group:     { icon: '▣',  label: '群組',          color: '#6a1b9a', page: 'groups'     },
  ivr:       { icon: '🎛', label: 'IVR',           color: '#2e7d32', page: 'ivr'        },
  custom:    { icon: '📋', label: '自定義 Dialplan', color: '#e65100', page: null         },
  reserved:  { icon: '🔒', label: 'FreeSwitch 內建', color: '#546e7a', page: null         },
};

let _numData      = [];   // 全部號碼資料
let _numFilter    = 'all'; // 目前篩選類型
let _numSearch    = '';    // 搜尋關鍵字

async function renderNumbers() {
  document.getElementById('mainContent').innerHTML =
    '<div style="padding:40px;text-align:center;color:var(--muted)">載入中…</div>';

  const data = await apiFetch('/api/numbers');
  _numData = (data && data.numbers) || [];

  _numRenderPage(data);
}

function _numRenderPage(data) {
  const tc    = (data && data.type_counts) || {};
  const total = _numData.length;

  // 判斷頁面是否已初始化（有無 num-tbody）
  const alreadyRendered = !!document.getElementById('num-tbody');

  if (!alreadyRendered) {
    // ── 首次：完整渲染整頁骨架 ─────────────────────────────────────────────
    document.getElementById('mainContent').innerHTML = `
    <div>
      <!-- 標題列 -->
      <div style="display:flex;align-items:center;gap:10px;padding:14px 20px 12px;
                  border-bottom:1px solid var(--border)">
        <span style="font-size:18px;font-weight:700;color:var(--text)">☎ 號碼目錄</span>
        <span id="num-total-label" style="font-size:12px;color:var(--muted);margin-left:4px">共 ${total} 個號碼</span>
        <div style="flex:1"></div>
        <input id="num-search-input" placeholder="搜尋號碼 / 名稱 / 用途…"
          value="${_numSearch}"
          oninput="_numSetSearch(this.value)"
          class="settings-input" style="width:220px;padding:5px 10px;font-size:13px">
        <button class="btn" onclick="dpNewFile()" style="white-space:nowrap">＋ 新增 Dialplan</button>
        <button class="btn" onclick="_numExportCSV()" style="white-space:nowrap">⬇ 匯出 CSV</button>
        <button class="btn" onclick="renderNumbers()">↺ 刷新</button>
      </div>

      <!-- 類型篩選 -->
      <div id="num-filter-bar" style="display:flex;gap:6px;flex-wrap:wrap;padding:10px 20px;
                  border-bottom:1px solid var(--border);background:var(--panel2)">
      </div>

      <!-- 統計卡片 -->
      <div id="num-stats-bar" style="display:flex;gap:12px;padding:12px 20px;flex-wrap:wrap">
      </div>

      <!-- 禁用號碼清單（可摺疊） -->
      <div id="num-blocked-card" style="margin:0 20px 14px;border:1px solid #b71c1c40;border-radius:8px;
                  background:#ffebee0a;overflow:hidden">
        <div onclick="_numToggleBlocked()"
             style="display:flex;align-items:center;gap:8px;padding:10px 16px;cursor:pointer;
                    border-bottom:1px solid transparent;user-select:none"
             id="num-blocked-header">
          <span style="font-size:15px">🚫</span>
          <span style="font-weight:700;font-size:13px;color:#c62828">禁用號碼清單</span>
          <span style="font-size:11px;color:var(--muted);margin-left:4px">— FreeSwitch 保留號碼，新增群組 / IVR 時請避開</span>
          <span style="flex:1"></span>
          <span id="num-blocked-arrow" style="font-size:13px;color:var(--muted);transition:transform 0.2s">▸</span>
        </div>
        <div id="num-blocked-body" style="display:none;padding:12px 16px">
          <div style="font-size:12px;color:var(--muted);margin-bottom:10px">
            以下號碼已被 FreeSwitch 預設 Dialplan 佔用，若群組或 IVR 使用相同號碼會被系統攔截，導致通話異常（如 <code style="color:#c62828">NORMAL_TEMPORARY_FAILURE</code>）。
          </div>
          <div id="num-blocked-table"></div>
        </div>
      </div>

      <!-- 表格 -->
      <div style="padding:0 20px 20px;overflow-x:auto">
        <table style="width:100%;border-collapse:collapse;min-width:640px">
          <thead>
            <tr style="border-bottom:2px solid var(--border)">
              <th style="text-align:left;padding:8px 14px;color:var(--label);font-size:11px;
                         font-weight:700;text-transform:uppercase;letter-spacing:1px;white-space:nowrap">號碼</th>
              <th style="text-align:left;padding:8px 10px;color:var(--label);font-size:11px;
                         font-weight:700;text-transform:uppercase;letter-spacing:1px">類型</th>
              <th style="text-align:left;padding:8px 10px;color:var(--label);font-size:11px;
                         font-weight:700;text-transform:uppercase;letter-spacing:1px">名稱</th>
              <th style="text-align:left;padding:8px 10px;color:var(--label);font-size:11px;
                         font-weight:700;text-transform:uppercase;letter-spacing:1px">用途說明</th>
              <th style="text-align:left;padding:8px 10px;color:var(--label);font-size:11px;
                         font-weight:700;text-transform:uppercase;letter-spacing:1px">操作</th>
            </tr>
          </thead>
          <tbody id="num-tbody"></tbody>
        </table>
      </div>

      <!-- 底部說明 -->
      <div style="padding:10px 20px 16px;font-size:12px;color:var(--muted);line-height:1.8;
                  border-top:1px solid var(--border)">
        💡 號碼來源：分機目錄 <code>/etc/freeswitch/directory/default/</code>、
        群組與 IVR Dialplan <code>/etc/freeswitch/dialplan/default/</code>、
        全 Dialplan 目錄掃描。<br>
        🔒 「FreeSwitch 內建」為 vanilla config 預設保留號碼，建議避免使用。
      </div>
    </div>`;
  }

  // ── 局部更新：篩選按鈕、統計卡片、表格列 ───────────────────────────────────

  // 篩選後資料
  let rows = _numData;
  if (_numFilter !== 'all') rows = rows.filter(n => n.type === _numFilter);
  if (_numSearch) {
    const q = _numSearch.toLowerCase();
    rows = rows.filter(n =>
      (n.number||'').includes(q) ||
      (n.name||'').toLowerCase().includes(q) ||
      (n.detail||'').toLowerCase().includes(q) ||
      (n.owner||'').toLowerCase().includes(q)
    );
  }

  // 篩選 tabs
  const typeFilters = [
    { key: 'all',       label: `全部 (${total})` },
    { key: 'extension', label: `📞 分機 (${tc.extension||0})` },
    { key: 'group',     label: `▣ 群組 (${tc.group||0})` },
    { key: 'ivr',       label: `🎛 IVR (${tc.ivr||0})` },
    { key: 'custom',    label: `📋 自定義 (${tc.custom||0})` },
    { key: 'reserved',  label: `🔒 內建 (${tc.reserved||0})` },
  ];
  const filterBar = document.getElementById('num-filter-bar');
  if (filterBar) filterBar.innerHTML = typeFilters.map(f => `
    <button onclick="_numSetFilter('${f.key}')"
      style="padding:4px 12px;border-radius:16px;border:1px solid var(--border);
             background:${_numFilter===f.key ? 'var(--accent)' : 'var(--panel)'};
             color:${_numFilter===f.key ? '#fff' : 'var(--text)'};
             font-size:12px;cursor:pointer;white-space:nowrap">
      ${f.label}
    </button>`).join('');

  // 統計卡片
  const statsBar = document.getElementById('num-stats-bar');
  if (statsBar) statsBar.innerHTML = Object.entries(NUMBER_TYPE_META).map(([k,m]) => `
    <div style="display:flex;align-items:center;gap:8px;padding:8px 14px;
                background:${m.color}0f;border:1px solid ${m.color}30;border-radius:6px;
                cursor:pointer" onclick="_numSetFilter('${k}')">
      <span style="font-size:18px">${m.icon}</span>
      <div>
        <div style="font-size:20px;font-weight:700;color:${m.color};line-height:1">${tc[k]||0}</div>
        <div style="font-size:11px;color:var(--muted)">${m.label}</div>
      </div>
    </div>`).join('');

  // 禁用號碼清單（首次渲染時填入表格內容）
  const blockedTable = document.getElementById('num-blocked-table');
  if (blockedTable && !blockedTable.dataset.rendered) {
    blockedTable.dataset.rendered = '1';
    const reserved = _numData.filter(n => n.type === 'reserved').sort((a,b) => a.number.localeCompare(b.number, undefined, {numeric:true}));
    // 手動定義號碼段說明
    const BLOCKED_RANGES = [
      { range: '0000–0002', desc: '測試音訊（echo、MoH、info）',      color: '#546e7a' },
      { range: '2000–2002', desc: 'Conference Bridge 會議室',          color: '#6a1b9a' },
      { range: '3000–3013', desc: 'Call Center 相關',                  color: '#4527a0' },
      { range: '4000',      desc: 'Valet Parking 停車',                color: '#1565c0' },
      { range: '5000–5002', desc: 'Directory / Conference Bridge（⚠ 5001/5002 外連 conference.freeswitch.org）', color: '#b71c1c' },
      { range: '6000',      desc: 'Park & Retrieve 停車取回',          color: '#1b5e20' },
      { range: '9195–9199', desc: '測試音訊（tone、echo、Tetris、MoH）', color: '#e65100' },
      { range: '9888',      desc: 'Voicemail 語音信箱入口',            color: '#37474f' },
    ];
    blockedTable.innerHTML = `
      <div style="display:flex;flex-wrap:wrap;gap:8px;margin-bottom:12px">
        ${BLOCKED_RANGES.map(r => `
          <div style="display:flex;align-items:center;gap:8px;padding:6px 12px;
                      border-radius:6px;background:${r.color}14;border:1px solid ${r.color}35;min-width:260px;flex:1">
            <code style="font-size:13px;font-weight:700;color:${r.color};white-space:nowrap">${r.range}</code>
            <span style="font-size:12px;color:var(--text)">${r.desc}</span>
          </div>`).join('')}
      </div>
      <table style="width:100%;border-collapse:collapse;font-size:12px">
        <thead>
          <tr style="border-bottom:1px solid var(--border)">
            <th style="text-align:left;padding:5px 10px;color:var(--label);font-size:11px;font-weight:700;white-space:nowrap">號碼</th>
            <th style="text-align:left;padding:5px 10px;color:var(--label);font-size:11px;font-weight:700">用途</th>
            <th style="text-align:left;padding:5px 10px;color:var(--label);font-size:11px;font-weight:700">備註</th>
          </tr>
        </thead>
        <tbody>
          ${reserved.map(n => {
            const isHighRisk = ['5001','5002'].includes(n.number);
            return `<tr style="border-bottom:1px solid var(--border)0a">
              <td style="padding:4px 10px;font-weight:700;font-family:monospace;letter-spacing:1px;
                         color:${isHighRisk ? '#c62828' : 'var(--accent-bright)'}">
                ${n.number}${isHighRisk ? ' ⚠️' : ''}
              </td>
              <td style="padding:4px 10px;color:var(--text)">${n.name}</td>
              <td style="padding:4px 10px;color:var(--muted)">${isHighRisk ? '此號碼曾導致 NORMAL_TEMPORARY_FAILURE' : '─'}</td>
            </tr>`;
          }).join('')}
        </tbody>
      </table>
      <div style="margin-top:10px;font-size:11px;color:var(--muted)">
        💡 建議群組使用 <code style="color:var(--green)">7001、7002…</code>，IVR 使用 <code style="color:var(--green)">9900、9901…</code>，避開上述所有號碼段。
      </div>`;
  }

  // 表格 tbody
  const tableRows = rows.map(n => {
    const meta = NUMBER_TYPE_META[n.type] || NUMBER_TYPE_META.custom;
    const typeBadge = `<span style="display:inline-flex;align-items:center;gap:4px;padding:2px 8px;
      border-radius:10px;font-size:11px;font-weight:600;
      background:${meta.color}18;color:${meta.color};border:1px solid ${meta.color}40">
      ${meta.icon} ${meta.label}</span>`;

    const jumpBtn = n.type === 'custom'
      ? `<div style="display:flex;gap:4px">
           <button class="btn" style="font-size:11px;padding:2px 8px"
             onclick="dpEditFile('${n.file}','${(n.detail||'').match(/來自 (.+)/)?.[1]||''}')">✎ 編輯</button>
           <button class="btn" style="font-size:11px;padding:2px 8px;color:var(--red)"
             onclick="dpDeleteFile('${(n.detail||'').match(/來自 (.+)/)?.[1]||''}','${n.number}')">✕</button>
         </div>`
      : meta.page
        ? `<button class="btn" style="font-size:11px;padding:2px 8px"
               onclick="switchPage('${meta.page}')">→ 前往管理</button>`
        : `<span style="font-size:11px;color:var(--muted)">─</span>`;

    return `
    <tr style="border-bottom:1px solid var(--border)"
        onmouseover="this.style.background='var(--panel2)'"
        onmouseout="this.style.background=''">
      <td style="padding:9px 14px;font-weight:700;font-size:14px;color:var(--accent-bright);
                 font-family:monospace;letter-spacing:1px">${n.number}</td>
      <td style="padding:9px 10px">${typeBadge}</td>
      <td style="padding:9px 10px;font-weight:600;color:var(--text)">${n.name || '─'}</td>
      <td style="padding:9px 10px;font-size:12px;color:var(--muted)">${n.detail || '─'}</td>
      <td style="padding:9px 10px">${jumpBtn}</td>
    </tr>`;
  }).join('');

  const tbody = document.getElementById('num-tbody');
  if (tbody) tbody.innerHTML = tableRows ||
    `<tr><td colspan="5" style="padding:40px;text-align:center;color:var(--muted)">
       沒有符合條件的號碼</td></tr>`;

  // 更新總數標籤
  const totalLabel = document.getElementById('num-total-label');
  if (totalLabel) totalLabel.textContent = `共 ${total} 個號碼`;
}

function _numSetFilter(type) {
  _numFilter = type;
  _numRenderPage({ numbers: _numData, type_counts: _numCountTypes() });
}

function _numSetSearch(val) {
  _numSearch = val;
  // 只更新表格，不重建整頁（保留搜尋欄焦點）
  _numRenderPage({ numbers: _numData, type_counts: _numCountTypes() });
  // 確保搜尋欄焦點不丟失
  const inp = document.getElementById('num-search-input');
  if (inp && document.activeElement !== inp) inp.focus();
}

function _numCountTypes() {
  const tc = {};
  _numData.forEach(n => { tc[n.type] = (tc[n.type]||0) + 1; });
  return tc;
}

function _numToggleBlocked() {
  const body   = document.getElementById('num-blocked-body');
  const arrow  = document.getElementById('num-blocked-arrow');
  const header = document.getElementById('num-blocked-header');
  if (!body) return;
  const open = body.style.display !== 'none';
  body.style.display  = open ? 'none' : 'block';
  if (arrow)  arrow.style.transform = open ? '' : 'rotate(90deg)';
  if (header) header.style.borderBottomColor = open ? 'transparent' : 'var(--border)';
}

function _numExportCSV() {
  // 依目前篩選條件匯出
  let rows = _numData;
  if (_numFilter !== 'all') rows = rows.filter(n => n.type === _numFilter);
  if (_numSearch) {
    const q = _numSearch.toLowerCase();
    rows = rows.filter(n =>
      (n.number||'').includes(q) ||
      (n.name||'').toLowerCase().includes(q) ||
      (n.detail||'').toLowerCase().includes(q)
    );
  }

  const meta = NUMBER_TYPE_META;
  const header = ['號碼', '類型', '名稱', '用途說明', '管理來源'];
  const csvRows = [header, ...rows.map(n => [
    n.number,
    (meta[n.type]||{}).label || n.type,
    n.name || '',
    (n.detail || '').replace(/｜/g, ' | '),
    n.owner || '',
  ])];

  const csvContent = csvRows.map(r =>
    r.map(cell => `"${String(cell).replace(/"/g, '""')}"`).join(',')
  ).join('\n');

  const bom = '\uFEFF';  // UTF-8 BOM（Excel 中文相容）
  const blob = new Blob([bom + csvContent], { type: 'text/csv;charset=utf-8' });
  const url  = URL.createObjectURL(blob);
  const a    = document.createElement('a');
  a.href     = url;
  a.download = `number-map-${new Date().toISOString().slice(0,10)}.csv`;
  a.click();
  URL.revokeObjectURL(url);
}
// ════════════════════════════════════════════════════════════════════════════
// 自定義 Dialplan 編輯器（從號碼目錄開啟）
// ════════════════════════════════════════════════════════════════════════════

function _dpModalHtml(title, bodyHtml) {
  return `
  <div id="dp-modal-overlay" onclick="if(event.target===this)dpCloseModal()"
    style="position:fixed;inset:0;background:rgba(10,25,41,.55);z-index:2000;
           display:flex;align-items:center;justify-content:center">
    <div style="background:var(--panel);border:1px solid var(--border);border-radius:8px;
                width:min(1100px,96vw);max-height:94vh;display:flex;flex-direction:column;
                box-shadow:0 8px 40px rgba(0,0,0,.4)">
      <!-- Modal 標題 -->
      <div style="padding:14px 18px;border-bottom:1px solid var(--border);
                  display:flex;align-items:center;gap:10px">
        <span style="font-weight:700;font-size:14px;color:var(--text)">${title}</span>
        <button onclick="dpCloseModal()"
          style="margin-left:auto;border:none;background:none;font-size:18px;
                 cursor:pointer;color:var(--muted);line-height:1">×</button>
      </div>
      <!-- Modal 內容 -->
      <div style="flex:1;overflow:auto;padding:16px">
        ${bodyHtml}
      </div>
    </div>
  </div>`;
}

function dpCloseModal() {
  const el = document.getElementById('dp-modal-overlay');
  if (el) el.remove();
}

// ── 新增 Dialplan 檔案 ────────────────────────────────────────────────────
function dpNewFile() {
  const defaultXml =
`<include>
  <extension name="my_extension">
    <condition field="destination_number" expression="^XXXX$">
      <action application="answer"/>
      <action application="playback" data="ivr/ivr-welcome_to_freeswitch.wav"/>
      <action application="hangup"/>
    </condition>
  </extension>
</include>`;

  document.body.insertAdjacentHTML('beforeend', _dpModalHtml('＋ 新增自定義 Dialplan', `
    <div style="display:grid;grid-template-columns:1fr 1fr;gap:12px;margin-bottom:12px">
      <div>
        <label style="font-size:12px;color:var(--label);display:block;margin-bottom:4px">
          檔名 <span style="color:var(--red)">*</span>
          <span style="font-size:11px;color:var(--muted)">（.xml，不含路徑）</span>
        </label>
        <input id="dp-new-filename" class="settings-input" placeholder="例：custom_9001.xml"
          style="width:100%;box-sizing:border-box">
      </div>
      <div>
        <label style="font-size:12px;color:var(--label);display:block;margin-bottom:4px">Context</label>
        <select id="dp-new-context" class="settings-input" style="width:100%;box-sizing:border-box">
          <option value="default">default（分機撥出）</option>
          <option value="public">public（外線來電）</option>
        </select>
      </div>
    </div>
    <label style="font-size:12px;color:var(--label);display:block;margin-bottom:6px">
      XML 內容 <span style="font-size:11px;color:var(--muted)">（儲存前自動驗證語法）</span>
    </label>
    <textarea id="dp-new-content" spellcheck="false"
      style="width:100%;box-sizing:border-box;height:480px;font-family:monospace;font-size:13px;
             padding:10px;border:1px solid var(--border);border-radius:4px;
             background:var(--bg);color:var(--text);resize:vertical;line-height:1.6"
    >${defaultXml}</textarea>
    <div id="dp-new-msg" style="margin-top:8px;font-size:12px;min-height:20px"></div>
    <div style="display:flex;gap:8px;margin-top:12px">
      <button class="btn" onclick="dpNewFileSave()"
        style="background:var(--accent);color:#fff;font-weight:600;padding:6px 20px">
        💾 建立並套用
      </button>
      <button class="btn" onclick="dpCloseModal()">取消</button>
    </div>
  `));
}

async function dpNewFileSave() {
  const filename = (document.getElementById('dp-new-filename')?.value || '').trim();
  const context  =  document.getElementById('dp-new-context')?.value  || 'default';
  const content  =  document.getElementById('dp-new-content')?.value  || '';
  const msg      =  document.getElementById('dp-new-msg');

  if (!filename) { if(msg) { msg.textContent='❌ 請輸入檔名'; msg.style.color='var(--red)'; } return; }
  if (!/^[\w\-]+\.xml$/.test(filename)) {
    if(msg) { msg.textContent='❌ 檔名格式錯誤（英數字、底線、連字號，副檔名 .xml）'; msg.style.color='var(--red)'; }
    return;
  }
  if(msg) { msg.textContent='儲存中…'; msg.style.color='var(--muted)'; }

  const res = await apiFetch('/api/dialplan/create', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ filename, context, content }),
  });

  if (res && res.ok) {
    if(msg) { msg.textContent=`✓ 已建立 ${res.path}，reloadxml 完成`; msg.style.color='var(--green)'; }
    numClearCache();
    setTimeout(() => { dpCloseModal(); renderNumbers(); }, 900);
  } else {
    if(msg) { msg.textContent=`❌ ${(res&&res.detail)||JSON.stringify(res)}`; msg.style.color='var(--red)'; }
  }
}

// ── 編輯現有 Dialplan 檔案 ────────────────────────────────────────────────
async function dpEditFile(filename, filepath) {
  // filepath 從 detail 欄位解析，若無則自己組
  const path = filepath || `/etc/freeswitch/dialplan/default/${filename}`;

  // 先讀取檔案內容
  const data = await apiFetch(`/api/dialplan/file?path=${encodeURIComponent(path)}`);
  if (!data || !data.content) {
    alert('讀取檔案失敗：' + JSON.stringify(data)); return;
  }

  document.body.insertAdjacentHTML('beforeend', _dpModalHtml(
    `✎ 編輯 Dialplan：${filename || path.split('/').pop()}`, `
    <div style="margin-bottom:6px;display:flex;align-items:center;gap:8px">
      <code style="font-size:11px;color:var(--muted);word-break:break-all">${path}</code>
    </div>
    <label style="font-size:12px;color:var(--label);display:block;margin-bottom:6px">
      XML 內容
      <span style="font-size:11px;color:var(--muted)">（儲存前自動驗證語法並備份原檔）</span>
    </label>
    <textarea id="dp-edit-content" spellcheck="false"
      data-path="${path}"
      style="width:100%;box-sizing:border-box;height:520px;font-family:monospace;font-size:13px;
             padding:10px;border:1px solid var(--border);border-radius:4px;
             background:var(--bg);color:var(--text);resize:vertical;line-height:1.6"
    >${data.content.replace(/</g,'&lt;').replace(/>/g,'&gt;')}</textarea>
    <div id="dp-edit-msg" style="margin-top:8px;font-size:12px;min-height:20px"></div>
    <div style="display:flex;gap:8px;margin-top:12px">
      <button class="btn" onclick="dpEditFileSave()"
        style="background:var(--accent);color:#fff;font-weight:600;padding:6px 20px">
        💾 儲存並套用
      </button>
      <button class="btn" onclick="dpCloseModal()">取消</button>
      <span style="font-size:11px;color:var(--muted);align-self:center">
        💡 儲存後自動執行 reloadxml，立即生效
      </span>
    </div>
  `));

  // textarea 需要 decode HTML entities
  const ta = document.getElementById('dp-edit-content');
  if (ta) ta.value = data.content;
}

async function dpEditFileSave() {
  const ta   = document.getElementById('dp-edit-content');
  const msg  = document.getElementById('dp-edit-msg');
  const path = ta?.dataset?.path || '';
  const content = ta?.value || '';

  if (!path) return;
  if(msg) { msg.textContent='儲存中…'; msg.style.color='var(--muted)'; }

  const res = await apiFetch('/api/dialplan/file', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ path, content }),
  });

  if (res && res.ok) {
    const backupNote = res.backup ? `（備份：${res.backup.split('/').pop()}）` : '';
    if(msg) { msg.textContent=`✓ 已儲存並 reloadxml ${backupNote}`; msg.style.color='var(--green)'; }
    numClearCache();
    setTimeout(() => { dpCloseModal(); renderNumbers(); }, 1000);
  } else {
    if(msg) { msg.textContent=`❌ ${(res&&res.detail)||JSON.stringify(res)}`; msg.style.color='var(--red)'; }
  }
}

// ── 刪除 Dialplan 檔案 ────────────────────────────────────────────────────
async function dpDeleteFile(filepath, number) {
  const path = filepath || '';
  const fname = path.split('/').pop();
  if (!path) { alert('無法取得檔案路徑'); return; }
  if (!confirm(`確定要刪除 Dialplan 檔案？\n\n檔案：${fname}\n號碼：${number}\n\n原始檔案將備份保留。`)) return;

  const res = await apiFetch('/api/dialplan/file', {
    method: 'DELETE',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ path }),
  });

  if (res && res.ok) {
    numClearCache();
    renderNumbers();
  } else {
    alert('刪除失敗：' + ((res&&res.detail)||JSON.stringify(res)));
  }
}

// ════════════════════════════════════════════════════════════════════════════
// [Injected] Dialplan 路由規則 UI module
// ════════════════════════════════════════════════════════════════════════════
// ════════════════════════════════════════════════════════════════════════════
// Dialplan 路由規則管理（類型一：外撥路由規則）
// ════════════════════════════════════════════════════════════════════════════
// 依賴既有全域：API_BASE, apiFetch(), switchPage()
// 對應後端：dialplan_routes.py（/api/dialplan/routes ...）
//
// 安裝方式：
//   1. 將本檔內容貼到 index.html 的 SCRIPT 結尾前（或另存 .js 並用
//      SCRIPT src="dialplan-routes-ui.js" 標籤在主程式之後載入）
//   2. 在 nav 加入一個項目：
//        <div class="nav-item" data-page="dialplan_routes" onclick="switchPage('dialplan_routes')">
//          <span class="nav-icon">🛣</span> Dialplan 路由
//        </div>
//   3. 在 pages 物件加入：
//        dialplan_routes: { render: renderDialplanRoutes, title: 'Dialplan 路由規則' },
// ════════════════════════════════════════════════════════════════════════════

