// recordings.js — 錄音管理頁面

// ── 錄音管理頁面 ──────────────────────────────────────────────────────────────
let _recPage  = 1;
const _recFilter = { extension: '', start_dt: '', end_dt: '' };
const _recPaging = { limit: 200 };  // 每頁筆數，使用者可手動修改

async function renderRecordings() {
  // 載入分機清單
  let extOptions = [];
  try {
    const extData = await apiFetch('/api/extensions');
    if (extData?.extensions) {
      extOptions = extData.extensions
        .map(e => ({ value: e.id, label: `${e.id}${e.caller_id_name ? ' (' + e.caller_id_name + ')' : ''}` }))
        .sort((a, b) => a.value.localeCompare(b.value));
    }
  } catch(_) {}

  // 分機搜尋選單 HTML（復用 IVR 的 _ivrSearchableSelect）
  const extSsHtml = _ivrSearchableSelect({
    id: 'rec-f-ext',
    options: [{ value: '', label: '全部分機' }, ...extOptions],
    value: _recFilter.extension,
    placeholder: '全部分機',
    onChange: `function(v){ _recFilter.extension=v; _recPage=1; loadRecordings(); }`,
    style: 'width:160px;flex:none'
  });

  document.getElementById('mainContent').innerHTML = `
  <div class="panel rec-panel">
    <div class="panel-header">
      <span class="panel-badge" id="rec-badge">載入中...</span>
      <div class="panel-actions" style="flex-wrap:wrap;gap:6px;align-items:center">
        ${extSsHtml}
        <label style="font-size:12px;color:var(--muted);white-space:nowrap">開始</label>
        <input type="date" class="settings-input" id="rec-f-start-d" style="width:150px"
          value="${_recDefDate()}" onchange="_recBuildDt('start')">
        <div style="display:flex;align-items:center;gap:2px">
          <button id="rec-s-am" class="btn" style="font-size:11px;padding:2px 6px"
            onclick="_recToggleAmPm('start','am')">上午</button>
          <button id="rec-s-pm" class="btn" style="font-size:11px;padding:2px 6px"
            onclick="_recToggleAmPm('start','pm')">下午</button>
        </div>
        <input type="number" id="rec-f-start-h" min="1" max="12" placeholder="時"
          class="settings-input" style="width:62px;font-size:12px;text-align:center"
          onchange="_recBuildDt('start')">時
        <input type="number" id="rec-f-start-m" min="0" max="59" placeholder="分"
          class="settings-input" style="width:62px;font-size:12px;text-align:center"
          onchange="_recBuildDt('start')">分
        <label style="font-size:12px;color:var(--muted);white-space:nowrap;margin-left:8px">結束</label>
        <input type="date" class="settings-input" id="rec-f-end-d" style="width:150px"
          value="${_recDefDate()}" onchange="_recBuildDt('end')">
        <div style="display:flex;align-items:center;gap:2px">
          <button id="rec-e-am" class="btn" style="font-size:11px;padding:2px 6px"
            onclick="_recToggleAmPm('end','am')">上午</button>
          <button id="rec-e-pm" class="btn" style="font-size:11px;padding:2px 6px"
            onclick="_recToggleAmPm('end','pm')">下午</button>
        </div>
        <input type="number" id="rec-f-end-h" min="1" max="12" placeholder="時"
          class="settings-input" style="width:62px;font-size:12px;text-align:center"
          onchange="_recBuildDt('end')">時
        <input type="number" id="rec-f-end-m" min="0" max="59" placeholder="分"
          class="settings-input" style="width:62px;font-size:12px;text-align:center"
          onchange="_recBuildDt('end')">分
        <label style="font-size:12px;color:var(--muted);white-space:nowrap;display:flex;align-items:center;gap:4px">
          每頁
          <input type="number" id="rec-limit-input" value="${_recPaging.limit}" min="10" max="1000"
            style="width:64px;padding:3px 6px;border:1px solid var(--border);border-radius:4px;font-size:12px;background:var(--input-bg);color:var(--text)"
            onchange="_recSetLimit(this.value)">
          筆
        </label>
        <button class="btn" onclick="_recResetFilter()">✕ 清除</button>
        <button class="btn" onclick="_recForceSync()">🔄 同步</button>
      </div>
    </div>

    <div class="rec-player-bar" id="rec-player-bar">
      <span style="font-size:11px;color:var(--label);flex-shrink:0">🎧 試聽播放器</span>
      <div class="rec-player-info">
        <span id="rec-player-label">尚未選擇錄音</span>
        <small id="rec-player-ch">-</small>
      </div>
      <audio id="rec-shared-audio" controls preload="none"
        style="flex:1;height:32px;min-width:200px"></audio>
    </div>

    <div class="rec-table-wrap" id="rec-grid-wrap">
      <div style="padding:40px;text-align:center;color:var(--muted)">載入中...</div>
    </div>
    <div class="rec-pager" id="rec-pagination"></div>
  </div>`;

  // 初始化預設時間
  _recInitDefaults();
  await loadRecordings();
}

const _recAmPm = { start: 'am', end: 'pm' };

function _recDefDate() {
  const now = new Date();
  return `${now.getFullYear()}-${String(now.getMonth()+1).padStart(2,'0')}-${String(now.getDate()).padStart(2,'0')}`;
}

function _recInitDefaults() {
  const now   = new Date();
  const today = _recDefDate();

  // 開始：當下時間（12小時制）
  let sh        = now.getHours();
  const sm      = now.getMinutes();
  const startAP = sh >= 12 ? 'pm' : 'am';
  sh = sh % 12 || 12;   // 0→12, 13→1 ...

  // 結束：當天 23:59 = 下午 11:59
  const endAP = 'pm';
  const eh = 11;
  const em = 59;

  const sd = document.getElementById('rec-f-start-d'); if (sd) sd.value = today;
  const sh_el = document.getElementById('rec-f-start-h'); if (sh_el) sh_el.value = sh;
  const sm_el = document.getElementById('rec-f-start-m'); if (sm_el) sm_el.value = String(sm).padStart(2,'0');
  const ed = document.getElementById('rec-f-end-d');   if (ed) ed.value = today;
  const eh_el = document.getElementById('rec-f-end-h');   if (eh_el) eh_el.value = eh;
  const em_el = document.getElementById('rec-f-end-m');   if (em_el) em_el.value = em;

  _recAmPm.start = startAP;
  _recAmPm.end   = endAP;
  _recToggleAmPm('start', startAP);
  _recToggleAmPm('end',   endAP);
  _recBuildDt('start');
  _recBuildDt('end');
}

function _recToggleAmPm(which, val) {
  _recAmPm[which] = val;
  const prefix = which === 'start' ? 'rec-s' : 'rec-e';
  document.getElementById(`${prefix}-am`).style.background = val === 'am' ? 'var(--accent)' : '';
  document.getElementById(`${prefix}-am`).style.color      = val === 'am' ? '#fff' : '';
  document.getElementById(`${prefix}-pm`).style.background = val === 'pm' ? 'var(--accent)' : '';
  document.getElementById(`${prefix}-pm`).style.color      = val === 'pm' ? '#fff' : '';
  _recBuildDt(which);
}

function _recBuildDt(which) {
  const d  = document.getElementById(`rec-f-${which}-d`)?.value;
  const h  = parseInt(document.getElementById(`rec-f-${which}-h`)?.value) || null;
  const m  = parseInt(document.getElementById(`rec-f-${which}-m`)?.value) || 0;
  if (!d || h === null) { _recFilter[`${which}_dt`] = ''; _recPage=1; loadRecordings(); return; }
  const isPm = _recAmPm[which] === 'pm';
  let h24 = h % 12 + (isPm ? 12 : 0);  // 12am→0, 12pm→12
  _recFilter[`${which}_dt`] = `${d}T${String(h24).padStart(2,'0')}:${String(m).padStart(2,'0')}`;
  _recPage = 1;
  loadRecordings();
}

function _recResetFilter() {
  _recFilter.extension = '';
  _recFilter.start_dt  = '';
  _recFilter.end_dt    = '';
  _recPage = 1;
  renderRecordings();  // 重繪整個頁面讓 select 也重置
}

function _recSetLimit(val) {
  const n = Math.max(10, Math.min(1000, parseInt(val) || 200));
  const el = document.getElementById('rec-limit-input');
  if (el) el.value = n;
  _recPaging.limit = n;
  _recPage = 1;
  loadRecordings();
}

async function _recForceSync() {
  const badge = document.getElementById('rec-badge');
  if (badge) badge.textContent = '同步中...';
  try {
    const res = await apiFetch('/api/recordings/sync', { method: 'POST' });
    if (res?.ok && badge) badge.textContent = `已索引 ${res.indexed} 個錄音`;
  } catch(_) {}
  loadRecordings();
}

async function loadRecordings() {
  const wrap  = document.getElementById('rec-grid-wrap');
  const badge = document.getElementById('rec-badge');
  const pager = document.getElementById('rec-pagination');
  if (!wrap) return;

  const offset = (_recPage - 1) * _recPaging.limit;
  const params = new URLSearchParams({ limit: _recPaging.limit, offset });
  if (_recFilter.extension) params.set('extension', _recFilter.extension);
  if (_recFilter.start_dt)  params.set('start_dt',  _recFilter.start_dt);
  if (_recFilter.end_dt)    params.set('end_dt',    _recFilter.end_dt);

  const data = await apiFetch(`/api/recordings?${params}`);
  if (!data) {
    wrap.innerHTML = `<div style="padding:40px;text-align:center;color:var(--red)">無法連線到後端</div>`;
    return;
  }

  const total      = data.total || 0;
  const files      = data.files || [];
  const totalPages = Math.max(1, Math.ceil(total / _recPaging.limit));
  const filterOn   = Object.values(_recFilter).some(v => v);

  if (badge) badge.textContent = filterOn ? `篩選結果：${total} 筆` : `共 ${total} 個錄音`;

  if (files.length === 0) {
    wrap.innerHTML = `<div style="padding:60px;text-align:center;color:var(--muted)">
      <div style="font-size:32px;margin-bottom:12px">🎙</div>
      <div>${filterOn ? '找不到符合條件的錄音' : '錄音目錄目前為空'}</div>
    </div>`;
    if (pager) pager.innerHTML = '';
    return;
  }

  wrap.innerHTML = `
    <table class="rec-table">
      <thead>
        <tr>
          <th>主叫</th>
          <th>被叫</th>
          <th>開始時間</th>
          <th>結束時間</th>
          <th>時長</th>
          <th>大小</th>
          <th>播放</th>
          <th>下載</th>
        </tr>
      </thead>
      <tbody>${files.map(f => buildRecRow(f)).join('')}</tbody>
    </table>`;
    
  if (pager) {
    let ph = `<span style="color:var(--muted);font-size:12px">第 ${_recPage} / ${totalPages} 頁，共 ${total} 筆</span>`;
    ph += `<button class="btn" style="margin-left:auto" onclick="_recGotoPage(${_recPage - 1})" ${_recPage<=1?'disabled':''}>← 上一頁</button>`;
    ph += `<button class="btn" onclick="_recGotoPage(${_recPage + 1})" ${_recPage>=totalPages?'disabled':''}>下一頁 →</button>`;
    pager.innerHTML = ph;
  }
}

function _recGotoPage(p) {
  _recPage = p;
  loadRecordings();
  document.getElementById('rec-grid-wrap')?.scrollIntoView({ behavior: 'smooth', block: 'start' });
}

// URL 存在 JS Map，避免放進 HTML attribute 被截斷
const _recUrlMap = new Map();

function buildRecRow(f) {
  const _tok = encodeURIComponent(getToken());
  const streamUrl = `${API_BASE}/api/recordings/stream?path=${encodeURIComponent(f.path)}&token=${_tok}`;
  const monoUrl   = `${API_BASE}/api/recordings/stream_mono?path=${encodeURIComponent(f.path)}&token=${_tok}`;
  const dlUrl     = `${API_BASE}/api/download?path=${encodeURIComponent(f.path)}&token=${_tok}`;
  const monoFile  = f.mono_path ? f.mono_path.split('/').pop() : '';
  const dlMonoUrl = f.mono_path ? `${API_BASE}/api/download?path=${encodeURIComponent(f.mono_path)}&token=${_tok}` : '';
  const hasMono   = !!f.mono_path;
  const uid       = btoa(f.path).replace(/[^a-zA-Z0-9]/g, '');

  _recUrlMap.set(uid, {
    stereo: streamUrl, mono: monoUrl,
    dlStereo: dlUrl,  dlMono: dlMonoUrl,
    dlName: f.filename, dlMonoName: monoFile,
    caller: f.caller || '-', callee: f.callee || '-',
  });

  const startTime = f.rec_date
    ? `${f.rec_date.slice(0,4)}-${f.rec_date.slice(4,6)}-${f.rec_date.slice(6,8)}<br><b>${f.rec_time.slice(0,2)}:${f.rec_time.slice(2,4)}</b>`
    : f.mtime;

  const endTime = (() => {
    try {
      const base = f.rec_date
        ? new Date(`${f.rec_date.slice(0,4)}-${f.rec_date.slice(4,6)}-${f.rec_date.slice(6,8)}T${f.rec_time.slice(0,2)}:${f.rec_time.slice(2,4)}:${f.rec_time.slice(4,6)}`)
        : new Date(f.mtime);
      const end = new Date(base.getTime() + f.duration_est * 1000);
      return `${end.getFullYear()}-${String(end.getMonth()+1).padStart(2,'0')}-${String(end.getDate()).padStart(2,'0')}<br><b>${String(end.getHours()).padStart(2,'0')}:${String(end.getMinutes()).padStart(2,'0')}</b>`;
    } catch(_) { return '-'; }
  })();

  const totalSec = Math.round(f.duration_est);
  const durStr   = `${Math.floor(totalSec/60)}:${String(totalSec%60).padStart(2,'0')}`;
  const sizeStr  = f.size >= 1048576
    ? (f.size/1048576).toFixed(1) + ' MB'
    : Math.round(f.size/1024) + ' KB';
  const monoDisabled = hasMono ? '' : 'disabled title="mono 尚未產生"';

  const playCell = `
    <div style="display:flex;align-items:center;gap:4px">
      <button class="rec-ch-btn active" id="rp-s-${uid}" onclick="_recChSel('${uid}','stereo')">立體音</button>
      <button class="rec-ch-btn" id="rp-m-${uid}" ${monoDisabled} onclick="_recChSel('${uid}','mono')">單聲道</button>
      <button class="btn" style="font-size:11px;padding:2px 8px" onclick="_recPlay('${uid}')">▶ 播放</button>
    </div>`;

  const dlCell = `
    <div style="display:flex;align-items:center;gap:4px">
      <button class="rec-ch-btn active" id="rd-s-${uid}" onclick="_recDlChSel('${uid}','stereo')">立體音</button>
      <button class="rec-ch-btn" id="rd-m-${uid}" ${monoDisabled} onclick="_recDlChSel('${uid}','mono')">單聲道</button>
      <a id="rd-link-${uid}" href="${dlUrl}" download="${f.filename}"
        class="btn" style="font-size:11px;padding:2px 8px;text-decoration:none">↓ 下載</a>
    </div>`;

  return `<tr data-uid="${uid}" data-play-ch="stereo" data-dl-ch="stereo">
  	<td style="color:#4a9eff;font-weight:600">${f.caller || '-'}</td>
  	<td style="color:#3dbe7a;font-weight:600">${f.callee || '-'}</td>
  	<td style="min-width:120px;line-height:1.6;color:#4a9eff">${startTime}</td>
  	<td style="min-width:120px;line-height:1.6;color:#e05a5a">${endTime}</td>
  	<td>${durStr}</td>
  	<td>${sizeStr}</td>
  	<td>${playCell}</td>
  	<td>${dlCell}</td>
  </tr>`;
}
// 播放聲道切換 → 永遠連動下載
function _recChSel(uid, ch) {
  const row = document.querySelector(`tr[data-uid="${uid}"]`);
  if (!row) return;
  row.dataset.playCh = ch;
  document.getElementById(`rp-s-${uid}`)?.classList.toggle('active', ch === 'stereo');
  document.getElementById(`rp-m-${uid}`)?.classList.toggle('active', ch === 'mono');
  // 播放切換永遠連動下載
  _recDlChSelInternal(uid, ch);
}

// 下載聲道切換 → 只改下載，不影響播放
function _recDlChSel(uid, ch) {
  _recDlChSelInternal(uid, ch);
}

function _recDlChSelInternal(uid, ch) {
  const row = document.querySelector(`tr[data-uid="${uid}"]`);
  if (!row) return;
  row.dataset.dlCh = ch;
  document.getElementById(`rd-s-${uid}`)?.classList.toggle('active', ch === 'stereo');
  document.getElementById(`rd-m-${uid}`)?.classList.toggle('active', ch === 'mono');
  const urls = _recUrlMap.get(uid);
  const link = document.getElementById(`rd-link-${uid}`);
  if (!link || !urls) return;
  if (ch === 'stereo') {
    link.href = urls.dlStereo; link.download = urls.dlName;
  } else {
    link.href = urls.dlMono || urls.dlStereo;
    link.download = urls.dlMonoName || urls.dlName;
  }
}

// 播放
function _recPlay(uid) {
  const urls = _recUrlMap.get(uid);
  const row  = document.querySelector(`tr[data-uid="${uid}"]`);
  if (!urls || !row) return;

  const ch  = row.dataset.playCh || 'stereo';
  const url = ch === 'mono' ? urls.mono : urls.stereo;
  const startTime = row.children[2].innerText.replace('\n', ' ');

  const audio = document.getElementById('rec-shared-audio');
  const label = document.getElementById('rec-player-label');
  const chEl  = document.getElementById('rec-player-ch');
  if (!audio) return;

  audio.src = url;
  label.innerHTML = `<span style="color:#4a9eff;font-weight:600">${urls.caller}</span> → <span style="color:#3dbe7a;font-weight:600">${urls.callee}</span>　<span style="color:#4a9eff">${startTime}</span>`;
  chEl.textContent = ch === 'mono' ? '單聲道（Mono）' : '立體音（Stereo）';
  audio.play();
}

async function deleteRecording(path) {
  if (!confirm(`確定要刪除此錄音？\n${path}\n\n（檔案將移至 .trash 目錄）`)) return;
  try {
    const res = await fetch(`${API_BASE}/api/recordings`, {
      method: 'DELETE',
      headers: { 'Content-Type': 'application/json', 'Authorization': `Bearer ${getToken()}` },
      body: JSON.stringify({ path })
    });
    if (res.ok) {
      loadRecordings();
    } else {
      const err = await res.json();
      alert('刪除失敗：' + (err.detail || '未知錯誤'));
    }
  } catch(e) {
    alert('刪除失敗：' + e.message);
  }
}

