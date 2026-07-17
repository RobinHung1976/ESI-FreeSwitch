// cdr.js — 通話記錄 CDR（即時 + 歸檔）

function cdrStatus(row) {
  const cause = row.hangup_cause || '';
  const billsec = parseInt(row.billsec || '0');
  if (cause === 'NORMAL_CLEARING' || cause === 'NORMAL_UNSPECIFIED') {
    return billsec > 0
      ? { label:'ANSWERED', style:'color:var(--green)', cls:'status-active' }
      : { label:'NO ANSWER', style:'color:var(--red)', cls:'status-hold' };
  }
  if (cause === 'ORIGINATOR_CANCEL' || cause === 'NO_ANSWER') {
    return { label:'NO ANSWER', style:'color:var(--red)', cls:'status-hold' };
  }
  if (cause === 'USER_BUSY') {
    return { label:'BUSY', style:'color:var(--yellow)', cls:'status-hold' };
  }
  return { label: cause.replace(/_/g,' '), style:'color:var(--muted)', cls:'' };
}

// 秒數轉 MM:SS
function secToTime(s) {
  const n = parseInt(s) || 0;
  const m = Math.floor(n / 60).toString().padStart(2,'0');
  const r = (n % 60).toString().padStart(2,'0');
  return `${m}:${r}`;
}

// 判斷通話方向（簡易規則：destination 為純數字且短 = 內線，否則看 context）
// 方向標籤：優先使用後端已計算的 direction 欄位，無則 fallback 到號碼長度判斷
function cdrDirection(row) {
  const d = row.direction || '';
  if (d === 'inbound')  return '來電';
  if (d === 'outbound') return '出撥';
  if (d === 'internal') return '內線';
  // fallback（舊資料無 direction 欄位）
  const dest = row.destination || '';
  const src  = row.caller_num  || '';
  if (/^\d{3,4}$/.test(dest) && /^\d{3,4}$/.test(src)) return '內線';
  if (/^\d{3,4}$/.test(src))  return '出撥';
  return '來電';
}

// 方向 badge 樣式
function cdrDirBadge(row) {
  const label = cdrDirection(row);
  const styles = {
    '來電': 'background:#e3f2fd;color:#0277bd',
    '出撥': 'background:#e8f5e9;color:#00897b',
    '內線': 'background:#fafafa;color:#546e7a',
  };
  return `<span style="font-size:11px;padding:2px 8px;border-radius:10px;${styles[label]||''}">${label}</span>`;
}

// ── CDR 頁面狀態 ──────────────────────────────────────────────────────────────
let _cdrTab    = 'live';   // 'live' | 'archive'
let _cdrSearch = '';
let _cdrPage   = 1;
const CDR_PAGE_SIZE = 20;

// 歸檔 CDR 狀態
let _archDate    = '';
let _archSearch  = '';
let _archStatus  = '';
let _archPage    = 1;
let _archRows    = [];     // 已載入的歸檔資料（前端篩選）

// ── CDR 頁面主渲染（雙 Tab） ──────────────────────────────────────────────────
async function renderCDR() {
  document.getElementById('mainContent').innerHTML = `
  <div style="display:flex;flex-direction:column;gap:12px;height:calc(100vh - 80px)">

    <!-- Tab 切換列 -->
    <div style="display:flex;align-items:center;gap:0;background:var(--panel);border:1px solid var(--border);
                border-radius:8px;overflow:hidden;box-shadow:var(--glow)">
      <button id="cdr-tab-live" onclick="switchCDRTab('live')"
        style="flex:1;padding:10px 0;border:none;cursor:pointer;font-family:inherit;font-size:13px;font-weight:600;
               background:var(--accent);color:#fff;border-right:1px solid var(--border)">
        📞 即時 CDR
      </button>
      <button id="cdr-tab-archive" onclick="switchCDRTab('archive')"
        style="flex:1;padding:10px 0;border:none;cursor:pointer;font-family:inherit;font-size:13px;font-weight:600;
               background:var(--panel2);color:var(--muted)">
        📋 歷史 CDR
      </button>
    </div>

    <!-- ── Tab: 即時 CDR ── -->
    <div id="cdr-pane-live" style="display:flex;flex-direction:column;flex:1;min-height:0">
      <div class="panel" style="flex:1;display:flex;flex-direction:column;min-height:0">
        <div class="panel-header">
          <span class="panel-badge" id="cdr-badge">載入中...</span>
          <div class="panel-actions">
            <button class="btn" onclick="exportCDR()">↓ CSV 匯出</button>
          </div>
        </div>
        <div class="cdr-filter-bar">
          <input class="filter-input" id="cdr-search" placeholder="搜尋分機 / 號碼..."
            value="${_cdrSearch}" oninput="_cdrSearch=this.value;_cdrPage=1;loadCDR()" />
          <select class="filter-select" id="cdr-status-filter" onchange="_cdrPage=1;loadCDR()">
            <option value="">全部狀態</option>
            <option value="ANSWERED">ANSWERED</option>
            <option value="NO ANSWER">NO ANSWER</option>
            <option value="BUSY">BUSY</option>
          </select>
        </div>
        <div class="table-wrap" style="flex:1;overflow-y:auto">
          <table>
            <thead>
              <tr>
                <th>時間</th><th>來源</th><th>目的地</th>
                <th>通話時長</th><th>計費秒數</th><th>Codec</th><th>狀態</th><th>方向</th>
              </tr>
            </thead>
            <tbody id="cdr-tbody">
              <tr><td colspan="8" style="text-align:center;color:var(--muted);padding:30px">載入中...</td></tr>
            </tbody>
          </table>
        </div>
        <div id="cdr-pagination" style="padding:12px 18px;display:flex;gap:8px;align-items:center;border-top:1px solid var(--border)"></div>
      </div>
    </div>

    <!-- ── Tab: 歷史 CDR ── -->
    <div id="cdr-pane-archive" style="display:none;flex-direction:column;gap:12px;flex:1;min-height:0">

      <!-- 篩選列 -->
      <div class="panel" style="padding:14px 18px">
        <div style="display:flex;flex-wrap:wrap;gap:10px;align-items:center">
          <label style="font-weight:600;color:var(--label);white-space:nowrap">歸檔日期：</label>
          <select id="arch-date-select"
            style="padding:6px 10px;border:1px solid var(--border);border-radius:6px;
                   background:var(--panel2);color:var(--text);font-family:inherit;font-size:13px;min-width:180px"
            onchange="_archDate=this.value;_archPage=1;loadArchiveCDR()">
            <option value="">-- 選擇日期 --</option>
          </select>
          <input id="arch-search" type="text" placeholder="搜尋分機 / 號碼..."
            style="padding:6px 10px;border:1px solid var(--border);border-radius:6px;
                   background:var(--panel2);color:var(--text);font-family:inherit;font-size:13px;min-width:160px"
            oninput="_archSearch=this.value;_archPage=1;renderArchivePage()">
          <select id="arch-status-filter"
            style="padding:6px 10px;border:1px solid var(--border);border-radius:6px;
                   background:var(--panel2);color:var(--text);font-family:inherit;font-size:13px"
            onchange="_archStatus=this.value;_archPage=1;renderArchivePage()">
            <option value="">全部狀態</option>
            <option value="ANSWERED">ANSWERED</option>
            <option value="NO ANSWER">NO ANSWER</option>
            <option value="BUSY">BUSY</option>
          </select>
          <button class="btn" onclick="exportArchiveCDR()" id="arch-export-btn" style="display:none">↓ CSV 匯出</button>
          <span id="arch-msg" style="font-size:12px;color:var(--muted);margin-left:auto"></span>
        </div>
      </div>

      <!-- 表格 -->
      <div class="panel" style="flex:1;display:flex;flex-direction:column;min-height:0">
        <div class="panel-header">
          <span class="panel-badge" id="arch-badge" style="background:#fff;color:var(--text);border:1px solid var(--border)">歷史 CDR</span>
          <div class="panel-actions" id="arch-pager-top" style="display:none;align-items:center;gap:6px">
            <button class="btn" id="arch-prev" onclick="_archPage=Math.max(1,_archPage-1);renderArchivePage()">← 上一頁</button>
            <span id="arch-page-label" style="font-size:12px;color:var(--muted)">1 / 1</span>
            <button class="btn" id="arch-next" onclick="_archPage++;renderArchivePage()">下一頁 →</button>
          </div>
        </div>
        <div class="table-wrap" style="flex:1;overflow-y:auto">
          <table>
            <thead>
              <tr>
                <th>時間</th><th>來源</th><th>目的地</th>
                <th>通話時長</th><th>計費秒數</th><th>Codec</th><th>狀態</th><th>方向</th>
              </tr>
            </thead>
            <tbody id="arch-tbody">
              <tr><td colspan="8" style="text-align:center;color:var(--muted);padding:30px">請從上方選擇日期</td></tr>
            </tbody>
          </table>
        </div>
      </div>
    </div>

  </div>`;

  // 預設顯示正確 Tab
  switchCDRTab(_cdrTab, true);
  await loadCDR();
  await loadArchiveDateList();
}

// ── CDR Tab 切換 ──────────────────────────────────────────────────────────────
function switchCDRTab(tab, silent) {
  _cdrTab = tab;
  ['live','archive'].forEach(t => {
    const pane = document.getElementById(`cdr-pane-${t}`);
    const btn  = document.getElementById(`cdr-tab-${t}`);
    if (!pane || !btn) return;
    const active = (t === tab);
    pane.style.display = active ? 'flex' : 'none';
    btn.style.background = active ? 'var(--accent)' : 'var(--panel2)';
    btn.style.color      = active ? '#fff' : 'var(--muted)';
  });
}

// ── 即時 CDR 載入 ─────────────────────────────────────────────────────────────
async function loadCDR() {
  const tbody  = document.getElementById('cdr-tbody');
  const badge  = document.getElementById('cdr-badge');
  const pager  = document.getElementById('cdr-pagination');
  if (!tbody) return;

  const offset = (_cdrPage - 1) * CDR_PAGE_SIZE;
  const data   = await apiFetch(`/api/cdr?limit=500&offset=0`);
  if (!data) return;

  let rows = data.rows || [];

  // 前端篩選（搜尋）
  if (_cdrSearch.trim()) {
    const q = _cdrSearch.trim().toLowerCase();
    rows = rows.filter(r =>
      (r.caller_num  || '').includes(q) ||
      (r.destination || '').includes(q) ||
      (r.caller_name || '').includes(q)
    );
  }

  // 狀態篩選
  const statusFilter = document.getElementById('cdr-status-filter');
  if (statusFilter && statusFilter.value) {
    rows = rows.filter(r => cdrStatus(r).label === statusFilter.value);
  }

  const total      = rows.length;
  const pageRows   = rows.slice(offset, offset + CDR_PAGE_SIZE);
  const totalPages = Math.max(1, Math.ceil(total / CDR_PAGE_SIZE));

  if (badge) badge.textContent = `共 ${total} 筆`;

  tbody.innerHTML = pageRows.length === 0
    ? `<tr><td colspan="8" style="text-align:center;color:var(--muted);padding:30px">沒有符合的記錄</td></tr>`
    : pageRows.map(r => {
        const st      = cdrStatus(r);
        const timeStr = (r.created || '').replace('T',' ').substring(0,19);
        return `<tr>
          <td style="color:var(--label)">${timeStr}</td>
          <td style="font-weight:600">${r.caller_num || '—'}</td>
          <td>${r.destination || '—'}</td>
          <td style="color:var(--accent-bright)">${secToTime(r.duration)}</td>
          <td style="color:var(--muted)">${secToTime(r.billsec)}</td>
          <td style="color:var(--muted);font-size:11px">${r.read_codec || '—'}</td>
          <td><span class="call-status ${st.cls}" style="font-size:11px;${st.style}">
            ${st.cls ? '<span class="dot"></span>' : ''}${st.label}
          </span></td>
          <td>${cdrDirBadge(r)}</td>
        </tr>`;
      }).join('');

  if (pager) {
    let h = `<span style="color:var(--muted);font-size:12px">第 ${_cdrPage} / ${totalPages} 頁，共 ${total} 筆</span>`;
    h += `<button class="btn" style="margin-left:auto" onclick="_cdrPage=Math.max(1,_cdrPage-1);loadCDR()" ${_cdrPage<=1?'disabled':''}>← 上一頁</button>`;
    h += `<button class="btn" onclick="_cdrPage=Math.min(${totalPages},_cdrPage+1);loadCDR()" ${_cdrPage>=totalPages?'disabled':''}>下一頁 →</button>`;
    pager.innerHTML = h;
  }
}

// ── 歸檔 CDR：載入日期選單 ────────────────────────────────────────────────────
async function loadArchiveDateList() {
  try {
    const data = await apiFetch('/api/cdr/archives');
    const sel  = document.getElementById('arch-date-select');
    if (!sel) return;
    const files = (data && data.files) ? data.files : [];
    if (!files.length) {
      sel.innerHTML = '<option value="">（尚無歸檔記錄）</option>';
      return;
    }
    sel.innerHTML = '<option value="">-- 選擇日期 --</option>' +
      files.map(f => {
        // 從 cdr-YYYY-MM-DD.csv 取得日期
        const dateStr = f.filename.replace('cdr-','').replace('.csv','');
        const sizeKB  = (f.size / 1024).toFixed(1);
        return `<option value="${f.filename}">${dateStr}（${sizeKB} KB）</option>`;
      }).join('');
    // 若有之前選過的日期，恢復選取
    if (_archDate) sel.value = _archDate;
  } catch(e) {
    const sel = document.getElementById('arch-date-select');
    if (sel) sel.innerHTML = '<option value="">（無法取得列表）</option>';
  }
}

// ── 歸檔 CDR：載入並解析指定檔案 ─────────────────────────────────────────────
async function loadArchiveCDR() {
  const msg   = document.getElementById('arch-msg');
  const badge = document.getElementById('arch-badge');
  const tbody = document.getElementById('arch-tbody');
  const pager = document.getElementById('arch-pager-top');
  const expBtn= document.getElementById('arch-export-btn');

  if (!_archDate) return;
  if (msg)   msg.textContent   = '載入中…';
  if (badge) badge.textContent = '載入中…';
  if (tbody) tbody.innerHTML   = `<tr><td colspan="8" style="text-align:center;color:var(--muted);padding:30px">⏳ 載入中…</td></tr>`;

  try {
    // 串流下載 CSV 並解析（後端回傳純文字 CSV）
    const res = await fetch(`${API_BASE}/api/cdr/archive/download?filename=${encodeURIComponent(_archDate)}`);
    if (!res.ok) {
      const err = await res.json().catch(() => ({}));
      throw new Error(err.detail || `HTTP ${res.status}`);
    }
    const text = await res.text();
    const lines = text.split('\n').filter(l => l.trim());
    _archRows = lines.map(line => {
      // 簡單 CSV 解析（欄位不含換行）
      const row = line.split(',').map(v => v.trim().replace(/^"|"$/g,''));
      if (row.length < 11) return null;
      const ctx    = row[3] || '';
      const caller = row[1] || '';
      const dest   = row[2] || '';
      // 方向判斷（context 欄位）
      let direction = 'inbound';
      if (ctx.toLowerCase() === 'public') direction = 'inbound';
      else if (caller.length <= 4 && /^\d+$/.test(caller) && dest.length <= 4 && /^\d+$/.test(dest)) direction = 'internal';
      else if (caller.length <= 4 && /^\d+$/.test(caller)) direction = 'outbound';
      return {
        caller_name:  row[0],
        caller_num:   caller,
        destination:  dest,
        context:      ctx,
        direction,
        created:      row[4],
        answered:     row[5],
        ended:        row[6],
        duration:     row[7],
        billsec:      row[8],
        hangup_cause: row[9],
        uuid:         row[10],
        read_codec:   row.length > 13 ? row[13] : '',
        write_codec:  row.length > 14 ? row[14] : '',
      };
    }).filter(Boolean);

    _archPage = 1;
    if (msg)    msg.textContent = '';
    if (expBtn) expBtn.style.display = '';
    renderArchivePage();
  } catch(e) {
    if (msg)   msg.textContent   = `載入失敗：${e.message}`;
    if (badge) badge.textContent = '歷史 CDR';
    if (tbody) tbody.innerHTML   = `<tr><td colspan="8" style="text-align:center;color:var(--red);padding:30px">載入失敗：${e.message}</td></tr>`;
  }
}

// ── 歸檔 CDR：前端篩選 + 分頁渲染 ───────────────────────────────────────────
function renderArchivePage() {
  const tbody = document.getElementById('arch-tbody');
  const badge = document.getElementById('arch-badge');
  const pager = document.getElementById('arch-pager-top');
  if (!tbody) return;

  let rows = _archRows;

  // 關鍵字搜尋
  if (_archSearch.trim()) {
    const q = _archSearch.trim().toLowerCase();
    rows = rows.filter(r =>
      (r.caller_num  || '').includes(q) ||
      (r.destination || '').includes(q) ||
      (r.caller_name || '').includes(q)
    );
  }

  // 狀態篩選
  if (_archStatus) {
    rows = rows.filter(r => cdrStatus(r).label === _archStatus);
  }

  const total      = rows.length;
  const totalPages = Math.max(1, Math.ceil(total / CDR_PAGE_SIZE));
  _archPage        = Math.min(_archPage, totalPages);
  const pageRows   = rows.slice((_archPage-1)*CDR_PAGE_SIZE, _archPage*CDR_PAGE_SIZE);

  if (badge) badge.textContent = `共 ${total} 筆`;

  if (pager) {
    pager.style.display = 'flex';
    const lbl = document.getElementById('arch-page-label');
    if (lbl) lbl.textContent = `${_archPage} / ${totalPages}`;
    const prev = document.getElementById('arch-prev');
    const next = document.getElementById('arch-next');
    if (prev) prev.disabled = (_archPage <= 1);
    if (next) next.disabled = (_archPage >= totalPages);
  }

  tbody.innerHTML = pageRows.length === 0
    ? `<tr><td colspan="8" style="text-align:center;color:var(--muted);padding:30px">沒有符合的記錄</td></tr>`
    : pageRows.map(r => {
        const st      = cdrStatus(r);
        const timeStr = (r.created || '').replace('T',' ').substring(0,19);
        return `<tr>
          <td style="color:var(--label)">${timeStr}</td>
          <td style="font-weight:600">${r.caller_num || '—'}</td>
          <td>${r.destination || '—'}</td>
          <td style="color:var(--accent-bright)">${secToTime(r.duration)}</td>
          <td style="color:var(--muted)">${secToTime(r.billsec)}</td>
          <td style="color:var(--muted);font-size:11px">${r.read_codec || '—'}</td>
          <td><span class="call-status ${st.cls}" style="font-size:11px;${st.style}">
            ${st.cls ? '<span class="dot"></span>' : ''}${st.label}
          </span></td>
          <td>${cdrDirBadge(r)}</td>
        </tr>`;
      }).join('');
}

// ── CSV 匯出 ──────────────────────────────────────────────────────────────────
async function exportCDR() {
  const data = await apiFetch('/api/cdr?limit=9999&offset=0');
  if (!data || !data.rows) return;
  _downloadCDRCSV(data.rows, `CDR_即時_${new Date().toISOString().slice(0,10)}.csv`);
}

function exportArchiveCDR() {
  if (!_archRows.length) return;
  const dateStr = _archDate.replace('cdr-','').replace('.csv','');
  _downloadCDRCSV(_archRows, `CDR_${dateStr}.csv`);
}

function _downloadCDRCSV(rows, filename) {
  const headers = ['時間','來源','目的地','通話時長(秒)','計費秒數','Codec','狀態','方向'];
  const csvRows = [headers.join(',')];
  rows.forEach(r => {
    const st  = cdrStatus(r);
    csvRows.push([
      r.created, r.caller_num, r.destination,
      r.duration, r.billsec, r.read_codec,
      st.label, cdrDirection(r)
    ].map(v => `"${(v||'').replace(/"/g,'""')}"`).join(','));
  });
  const blob = new Blob(['\uFEFF'+csvRows.join('\n')], { type:'text/csv;charset=utf-8' });
  const a = document.createElement('a');
  a.href = URL.createObjectURL(blob);
  a.download = filename;
  a.click();
}

