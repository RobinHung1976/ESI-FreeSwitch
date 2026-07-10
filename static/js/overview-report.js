// overview-report.js — 總覽 Overview + 通話統計報表

// ── PAGES ─────────────────────────────────────────────────────────────────────
async function renderOverview() {
  // 骨架先顯示（只有即時狀態，統計圖表已移至通話統計報表頁）
  document.getElementById('mainContent').innerHTML = `
  <!-- 使用者即時狀態總覽（全寬） -->
  <div class="panel">
    <div class="panel-header">
      <span class="panel-title">👤 使用者即時狀態</span>
      <span class="panel-badge live" id="monitor-calls-count">LIVE · 0 通話中</span>
      <span class="panel-badge" id="ov-regs-badge"
            style="background:rgba(2,119,189,0.1);color:var(--accent);border-color:rgba(2,119,189,0.25)">— 支已登錄</span>
      <div class="panel-actions">
        <button id="uc-toggle-offline" onclick="ucToggleOffline(this)" title="顯示/隱藏離線分機">⭘ 顯示離線</button>
      </div>
    </div>
    <div style="overflow-y:auto;max-height:calc(100vh - 160px)">
      <table class="uc-table">
        <thead>
          <tr>
            <th style="width:130px">分機</th>
            <th style="width:100px">狀態</th>
            <th style="width:80px">錄音</th>
            <th style="width:90px">方向</th>
            <th style="width:90px">通話類型</th>
            <th>對象號碼</th>
            <th style="width:80px">時長</th>
          </tr>
        </thead>
        <tbody id="uc-tbody">
          <tr><td colspan="7" style="text-align:center;padding:28px;color:var(--muted)">載入中...</td></tr>
        </tbody>
      </table>
    </div>
  </div>`;

  // 取得登錄數更新 badge
  const [regData, extData2, extStatus2] = await Promise.all([
    apiFetch('/api/registrations'),
    apiFetch('/api/extensions/list'),
    apiFetch('/api/ext/status'),
  ]);

  const regs = (regData && regData.rows) ? regData.rows : [];
  const el = id => document.getElementById(id);
  if (el('ov-regs-badge')) el('ov-regs-badge').textContent = `${regs.length} 支已登錄`;

  // 儲存分機清單供後續 WS 更新使用
  _ucExtList = (extData2 && extData2.extensions) ? extData2.extensions : [];
  // 把快照寫入 cache（不蓋掉比快照更新的 WS 推播）
  const snapStatus = (extStatus2 && extStatus2.status) ? extStatus2.status : {};
  Object.entries(snapStatus).forEach(([ext, st]) => {
    const cached = extStatusCache[ext];
    if (!cached || (st.since || 0) >= (cached.since || 0)) extStatusCache[ext] = st;
  });
  // 初始化通話快取
  await _refreshMonitorCallsTable();
}

// ════════════════════════════════════════════════════════════════════════════
// 通話統計報表
// ════════════════════════════════════════════════════════════════════════════

let _rpChartPending = false;
let _rpCdrRows      = [];   // 快取當日 CDR 明細（供未接通明細使用）
let _rpSelectedUser = 'all';

async function renderReport() {
  const today = new Date().toISOString().split('T')[0];

  document.getElementById('mainContent').innerHTML = `
  <!-- 快捷日期 + 篩選列 -->
  <div class="panel" style="margin-bottom:14px;padding:12px 18px">
    <div style="display:flex;align-items:center;flex-wrap:wrap;gap:8px">
      <span style="font-size:11px;color:var(--label);font-weight:700;letter-spacing:.5px;white-space:nowrap">日期快捷</span>
      <button class="btn rp-quick" data-days="0"  onclick="_rpQuick(0)">今天</button>
      <button class="btn rp-quick" data-days="-1" onclick="_rpQuick(-1)">昨天</button>
      <button class="btn rp-quick" data-days="week" onclick="_rpQuick('week')">本週</button>
      <button class="btn rp-quick" data-days="month" onclick="_rpQuick('month')">本月</button>
      <div style="width:1px;height:22px;background:var(--border);margin:0 4px;flex-shrink:0"></div>
      <input type="date" id="rp-date-start" class="filter-input"
             style="font-size:11px;padding:4px 8px;max-width:130px" value="${today}" />
      <span style="color:var(--muted);font-size:11px">~</span>
      <input type="date" id="rp-date-end" class="filter-input"
             style="font-size:11px;padding:4px 8px;max-width:130px" value="${today}" />
      <select id="rp-user" class="filter-select" style="font-size:11px">
        <option value="all">全部分機</option>
      </select>
      <button class="btn primary" onclick="loadReportData()" style="font-size:11px;padding:4px 12px">🔍 查詢</button>
      <button class="btn" id="rp-export-btn" onclick="_rpExportCSV()" style="font-size:11px;padding:4px 12px;margin-left:auto" disabled>⬇ 匯出 CSV</button>
    </div>
  </div>

  <!-- 摘要卡片列 -->
  <div style="display:grid;grid-template-columns:repeat(4,1fr);gap:12px;margin-bottom:14px">
    <div class="stat-card" style="border-top:3px solid var(--accent)">
      <div class="stat-label">總通話數</div>
      <div class="stat-value" id="rp-total">—</div>
      <div class="stat-sub" id="rp-date-label">—</div>
    </div>
    <div class="stat-card" style="border-top:3px solid var(--green)">
      <div class="stat-label">已接通</div>
      <div class="stat-value" id="rp-answered" style="color:var(--green)">—</div>
      <div class="stat-sub" id="rp-avg-dur">平均時長 —</div>
    </div>
    <div class="stat-card" style="border-top:3px solid var(--red)">
      <div class="stat-label">未接通</div>
      <div class="stat-value" id="rp-missed" style="color:var(--red)">—</div>
      <div class="stat-sub" id="rp-busy-count">忙線 — 通</div>
    </div>
    <div class="stat-card" style="border-top:3px solid var(--yellow)">
      <div class="stat-label">接通率</div>
      <div class="stat-value" id="rp-rate" style="color:var(--yellow)">—</div>
      <div style="margin-top:6px;height:6px;border-radius:3px;background:var(--border);overflow:hidden">
        <div id="rp-rate-bar" style="height:100%;width:0%;background:var(--green);border-radius:3px;transition:width .4s"></div>
      </div>
    </div>
  </div>

  <!-- 圖表卡片（柱狀圖 + 圓餅） -->
  <div class="panel" style="margin-bottom:14px">
    <div class="panel-header">
      <span class="panel-title" id="rp-chart-title">📈 每小時通話量</span>
      <span class="panel-badge" id="rp-chart-badge" style="background:rgba(0,137,123,0.1);color:var(--green);border-color:rgba(0,137,123,0.25)">—</span>
    </div>
    <div style="display:flex;align-items:stretch;min-width:0">
      <!-- 柱狀圖 -->
      <div style="flex:1 1 0;min-width:0;padding:14px 18px 10px">
        <canvas id="rp-chart-canvas" style="display:block;width:100%;height:200px"></canvas>
      </div>
      <!-- 分隔線 -->
      <div style="width:1px;background:var(--border);flex-shrink:0;margin:12px 0"></div>
      <!-- 圓餅 + 圖例 -->
      <div style="width:260px;flex-shrink:0;display:flex;flex-direction:column;
                  align-items:center;padding:10px 14px 12px;gap:8px">
        <div style="font-size:12px;font-weight:700;color:var(--label);letter-spacing:0.5px;align-self:flex-start">
          通話排行 <span class="panel-badge" id="rp-top-badge" style="font-size:11px;padding:2px 8px">—</span>
        </div>
        <canvas id="rp-top-pie" width="180" height="180"
                style="display:block;width:180px;height:180px;flex-shrink:0"></canvas>
        <div id="rp-top-legend"
             style="width:100%;display:flex;flex-wrap:wrap;gap:5px;justify-content:center"></div>
      </div>
    </div>
  </div>

  <!-- 未接通明細 -->
  <div class="panel">
    <div class="panel-header">
      <span class="panel-title">📵 未接通明細</span>
      <span class="panel-badge" id="rp-missed-badge"
            style="background:rgba(198,40,40,0.1);color:var(--red);border-color:rgba(198,40,40,0.25)">—</span>
    </div>
    <div style="overflow-y:auto;max-height:300px">
      <table style="width:100%;border-collapse:collapse" id="rp-missed-table">
        <thead>
          <tr style="position:sticky;top:0;background:var(--panel2);z-index:1">
            <th style="text-align:left;padding:8px 12px;font-size:12px;color:var(--label);border-bottom:1px solid var(--border)">時間</th>
            <th style="text-align:left;padding:8px 12px;font-size:12px;color:var(--label);border-bottom:1px solid var(--border)">來源號碼</th>
            <th style="text-align:left;padding:8px 12px;font-size:12px;color:var(--label);border-bottom:1px solid var(--border)">目的號碼</th>
            <th style="text-align:left;padding:8px 12px;font-size:12px;color:var(--label);border-bottom:1px solid var(--border)">原因</th>
            <th style="text-align:left;padding:8px 12px;font-size:12px;color:var(--label);border-bottom:1px solid var(--border)">時長</th>
          </tr>
        </thead>
        <tbody id="rp-missed-tbody">
          <tr><td colspan="5" style="text-align:center;padding:28px;color:var(--muted)">請先查詢</td></tr>
        </tbody>
      </table>
    </div>
  </div>`;

  // 標記今天快捷按鈕
  document.querySelector('.rp-quick[data-days="0"]')?.classList.add('active');

  // 初始載入
  await loadReportData();
}

// ── 日期快捷按鈕 ───────────────────────────────────────────────────────────────
let _rpDateMode = 'day'; // 'day' | 'week' | 'month'

function _rpQuick(mode) {
  document.querySelectorAll('.rp-quick').forEach(b => b.classList.remove('active'));
  document.querySelector(`.rp-quick[data-days="${mode}"]`)?.classList.add('active');

  const startEl = document.getElementById('rp-date-start');
  const endEl   = document.getElementById('rp-date-end');
  const d = new Date();
  let start = new Date(d), end;

  if (mode === 0) {
    end = new Date(d);
  } else if (mode === -1) {
    start.setDate(start.getDate() - 1);
    end = new Date(start);
  } else if (mode === 'week') {
    const day = d.getDay() || 7;
    start.setDate(d.getDate() - day + 1);                     // 本週一
    end = new Date(start); end.setDate(start.getDate() + 6);  // 本週日
  } else if (mode === 'month') {
    start.setDate(1);                                          // 本月一日
    end = new Date(d.getFullYear(), d.getMonth() + 1, 0);      // 本月最後一日
  }

  if (startEl) startEl.value = start.toISOString().split('T')[0];
  if (endEl)   endEl.value   = end.toISOString().split('T')[0];
  loadReportData();
}

// ── 主查詢函式 ─────────────────────────────────────────────────────────────────
async function loadReportData() {
  if (_rpChartPending) return;
  _rpChartPending = true;

  const el = id => document.getElementById(id);
  const startEl = el('rp-date-start');
  const endEl   = el('rp-date-end');
  const selEl   = el('rp-user');
  let date   = startEl ? startEl.value : new Date().toISOString().split('T')[0];
  let dateTo = endEl   ? endEl.value   : date;

  // 防呆：結束日期早於開始日期時自動交換並回寫欄位
  if (dateTo < date) {
    [date, dateTo] = [dateTo, date];
    if (startEl) startEl.value = date;
    if (endEl)   endEl.value   = dateTo;
  }
  _rpDateMode = (date === dateTo) ? 'day' : 'range';

  if (selEl) _rpSelectedUser = selEl.value || 'all';

  // 摘要卡片 loading 態
  ['rp-total','rp-answered','rp-missed','rp-rate'].forEach(id => {
    if (el(id)) el(id).textContent = '…';
  });
  if (el('rp-rate-bar')) el('rp-rate-bar').style.width = '0%';

  try {
    const userParam  = (_rpSelectedUser && _rpSelectedUser !== 'all')
      ? `&user=${encodeURIComponent(_rpSelectedUser)}` : '';
    const rangeParam = (dateTo !== date) ? `&date_to=${dateTo}` : '';

    // /api/cdr 現在支援 date_from/date_to/user 由後端過濾，減少不必要的資料傳輸；
    // 注意：此為「明細」查詢，只涵蓋 cdr_retain_days 保留期內的資料，
    // 超過保留期的日期明細（含未接通清單）已被清除，僅 /api/cdr/stats 仍有彙總統計可用。
    const [statsData, cdrData] = await Promise.all([
      apiFetch(`/api/cdr/stats?date_str=${date}${rangeParam}${userParam}`),
      apiFetch(`/api/cdr?limit=9999&offset=0&date_from=${date}&date_to=${dateTo}${userParam}`),
    ]);

    // ── 更新分機下拉（依統計資料重建） ──────────────────────────────────────
    if (selEl && statsData && statsData.all_users) {
      const keep = _rpSelectedUser;
      selEl.innerHTML = '<option value="all">全部分機</option>';
      statsData.all_users.forEach(u => {
        const opt = document.createElement('option');
        opt.value = u.num;
        opt.textContent = `${u.num}（${u.total} 通）`;
        selEl.appendChild(opt);
      });
      selEl.value = [...selEl.options].some(o => o.value === keep) ? keep : 'all';
      _rpSelectedUser = selEl.value;
    }

    const allRows = (cdrData && cdrData.rows) ? cdrData.rows : [];
    _rpCdrRows = allRows; // 供匯出 CSV 使用（僅涵蓋保留期內的明細）

    // ── 摘要計算：優先採用後端 stats 的合計，涵蓋已被 purge、僅剩彙總的舊日期 ──────
    const hasStats = !!statsData;
    const total     = hasStats ? statsData.total_calls    : allRows.length;
    const answeredN = hasStats ? statsData.answered_total  : allRows.filter(r => cdrStatus(r).label === 'ANSWERED').length;
    const noAnswerN = hasStats ? statsData.no_answer_total : allRows.filter(r => cdrStatus(r).label === 'NO ANSWER').length;
    const busyN     = hasStats ? statsData.busy_total      : allRows.filter(r => cdrStatus(r).label === 'BUSY').length;
    const missed    = noAnswerN + busyN;
    const rate      = total > 0 ? Math.round((answeredN / total) * 100) : 0;
    const avgSec    = hasStats ? statsData.avg_duration_sec : (() => {
      const ans = allRows.filter(r => cdrStatus(r).label === 'ANSWERED');
      return ans.length > 0 ? Math.round(ans.reduce((s, r) => s + parseInt(r.billsec || 0), 0) / ans.length) : 0;
    })();

    const fmt = s => s.split('-').map((v, i) => i === 0 ? v : v.padStart(2,'0')).join('/');
    const fallbackUsed = hasStats && statsData.summary_fallback_used;
    const dateLabel = (date === dateTo ? fmt(date) : `${fmt(date)} ~ ${fmt(dateTo)}`)
      + (fallbackUsed ? '　⚠ 含歷史彙總資料' : '');

    if (el('rp-total'))     el('rp-total').textContent   = total;
    if (el('rp-date-label'))el('rp-date-label').textContent = dateLabel;
    if (el('rp-answered'))  el('rp-answered').textContent = answeredN;
    if (el('rp-avg-dur'))   el('rp-avg-dur').textContent  = `平均時長 ${secToTime(avgSec)}`;
    if (el('rp-missed'))    el('rp-missed').textContent   = missed;
    if (el('rp-busy-count'))el('rp-busy-count').textContent = `忙線 ${busyN} 通`;
    if (el('rp-rate'))      el('rp-rate').textContent     = `${rate}%`;
    if (el('rp-rate-bar'))  el('rp-rate-bar').style.width = `${rate}%`;

    if (el('rp-chart-badge') && statsData)
      el('rp-chart-badge').textContent = `共 ${statsData.total_calls || total} 通`;
    if (el('rp-chart-title'))
      el('rp-chart-title').textContent = (_rpDateMode === 'day') ? '📈 每小時通話量' : '📈 每日通話量';

    // ── 圖表渲染（複用現有函式，替換 canvas id） ──────────────────────────
    if (statsData) {
      requestAnimationFrame(() => {
        _rpRenderHourlyChart(statsData.hourly);
        _rpRenderTopUsers(statsData.top_users);
      });
    }

    // ── 未接通明細（僅涵蓋保留期內、raw 明細仍存在的日期）──────────────────
    const noAnswerRows = allRows.filter(r => cdrStatus(r).label === 'NO ANSWER');
    const busyRows     = allRows.filter(r => cdrStatus(r).label === 'BUSY');
    const missedRows = [...noAnswerRows, ...busyRows].sort((a, b) =>
      (b.created || '').localeCompare(a.created || ''));

    if (el('rp-missed-badge')) el('rp-missed-badge').textContent = `${missedRows.length} 筆`;

    const tbody = el('rp-missed-tbody');
    if (tbody) {
      tbody.innerHTML = fallbackUsed
        ? `<tr><td colspan="5" style="text-align:center;padding:14px;color:var(--yellow);font-size:12px">
             ⚠ 查詢範圍內部分日期已超過明細保留天數，逐通未接通記錄僅顯示保留期內的部分
           </td></tr>`
        : '';
      if (!missedRows.length) {
        tbody.innerHTML += `<tr><td colspan="5" style="text-align:center;padding:28px;color:var(--muted)">✅ 無未接通記錄</td></tr>`;
      } else {
        tbody.innerHTML += missedRows.map(r => {
          const st = cdrStatus(r);
          const timeStr = (r.created || '').replace('T', ' ').substring(0, 19);
          const causeLabel = st.label === 'BUSY' ? '🔴 忙線' : '⚪ 未接';
          return `<tr style="border-bottom:1px solid var(--border)">
            <td style="padding:7px 12px;color:var(--label);font-size:12px">${timeStr}</td>
            <td style="padding:7px 12px;font-weight:600;font-size:13px">${r.caller_num || '—'}</td>
            <td style="padding:7px 12px;font-size:13px">${r.destination || '—'}</td>
            <td style="padding:7px 12px"><span style="font-size:11px;padding:2px 8px;border-radius:20px;
              background:${st.label==='BUSY'?'rgba(230,81,0,0.1)':'rgba(198,40,40,0.08)'};
              color:${st.label==='BUSY'?'var(--yellow)':'var(--red)'}">${causeLabel}</span></td>
            <td style="padding:7px 12px;color:var(--muted);font-size:12px">${secToTime(r.duration)}</td>
          </tr>`;
        }).join('');
      }
    }

    // 啟用匯出按鈕
    if (el('rp-export-btn')) el('rp-export-btn').disabled = (allRows.length === 0);

  } finally {
    _rpChartPending = false;
  }
}

// ── 匯出 CSV ──────────────────────────────────────────────────────────────────
function _rpExportCSV() {
  if (!_rpCdrRows || !_rpCdrRows.length) return;
  const header = ['時間','來源號碼','目的號碼','通話時長(s)','計費時長(s)','狀態','Hangup原因'];
  const rows = _rpCdrRows.map(r => {
    const st = cdrStatus(r);
    return [
      (r.created || '').replace('T',' ').substring(0,19),
      r.caller_num  || '',
      r.destination || '',
      r.duration    || 0,
      r.billsec     || 0,
      st.label,
      r.hangup_cause || '',
    ].map(v => `"${String(v).replace(/"/g,'""')}"`).join(',');
  });
  const csv  = '\uFEFF' + [header.join(','), ...rows].join('\r\n'); // BOM for Excel
  const blob = new Blob([csv], { type: 'text/csv;charset=utf-8;' });
  const url  = URL.createObjectURL(blob);
  const a    = document.createElement('a');
  const dateStart = (document.getElementById('rp-date-start') || {}).value || new Date().toISOString().split('T')[0];
  const dateEnd   = (document.getElementById('rp-date-end')   || {}).value || dateStart;
  const rangeTag  = (dateStart === dateEnd) ? dateStart : `${dateStart}_to_${dateEnd}`;
  a.href     = url;
  a.download = `cdr-report-${rangeTag}${_rpSelectedUser !== 'all' ? '-' + _rpSelectedUser : ''}.csv`;
  a.click();
  URL.revokeObjectURL(url);
}

// ── Report 頁專用圖表（id 前綴 rp- 避免與 overview ov- 衝突） ──────────────────
let _rpHourlyData = [];

function _rpRenderHourlyChart(hourly) {
  const canvas = document.getElementById('rp-chart-canvas');
  if (!canvas || !hourly) return;
  _rpHourlyData = hourly;

  const dpr   = window.devicePixelRatio || 1;
  const dispW = canvas.parentElement?.clientWidth || canvas.offsetWidth || 600;
  const dispH = 200;

  canvas.width  = Math.round(dispW * dpr);
  canvas.height = Math.round(dispH * dpr);
  canvas.style.width  = dispW + 'px';
  canvas.style.height = dispH + 'px';

  if (canvas._chartAbort) canvas._chartAbort.abort();
  const ac = new AbortController();
  canvas._chartAbort = ac;
  canvas.addEventListener('mousemove',  _rpChartMouseMove,  { signal: ac.signal });
  canvas.addEventListener('mouseleave', _rpChartMouseLeave, { signal: ac.signal });

  if (hourly && hourly.length > 0 && hourly[0].hour === null) {
    // 範圍模式：每日一根柱，用專用函式
    _rpDrawDailyChart(canvas, hourly);
  } else {
    _drawHourlyChart(canvas, hourly, -1); // 單日 24 小時
  }
}

function _rpDrawDailyChart(canvas, dailyData, hoverIdx) {
  hoverIdx = (hoverIdx === undefined) ? -1 : hoverIdx;
  const dpr   = window.devicePixelRatio || 1;
  const MIN_BAR_W = 28;
  const containerW = canvas.parentElement?.clientWidth || canvas.offsetWidth || 600;
  const dispW = Math.max(containerW, dailyData.length * MIN_BAR_W);
  const dispH = 200;

  canvas.width  = Math.round(dispW * dpr);
  canvas.height = Math.round(dispH * dpr);
  canvas.style.width  = dispW + 'px';
  canvas.style.height = dispH + 'px';
  if (canvas.parentElement) canvas.parentElement.style.overflowX = 'auto';

  const ctx   = canvas.getContext('2d');
  ctx.setTransform(1, 0, 0, 1, 0, 0);
  ctx.scale(dpr, dpr);
  ctx.clearRect(0, 0, dispW, dispH);

  const PAD_T   = 16, PAD_B = 36;
  const CHART_H = dispH - PAD_T - PAD_B;
  const BASE_Y  = PAD_T + CHART_H;
  const maxCount = Math.max(...dailyData.map(d => d.count), 1);
  const barW    = dispW / dailyData.length;
  const gap     = Math.max(barW * 0.18, 2);

  ctx.strokeStyle = '#b0c8e0'; ctx.lineWidth = 1.5;
  ctx.beginPath(); ctx.moveTo(0, BASE_Y); ctx.lineTo(dispW, BASE_Y); ctx.stroke();

  dailyData.forEach((d, i) => {
    const x      = i * barW + gap / 2;
    const w      = barW - gap;
    const isHov  = (i === hoverIdx);
    const h      = d.count > 0 ? Math.max(Math.round((d.count / maxCount) * CHART_H), 3) : 0;
    const y      = BASE_Y - h;

    if (isHov) {
      ctx.fillStyle = 'rgba(2,119,189,0.08)';
      ctx.fillRect(i * barW, PAD_T, barW, CHART_H);
    }

    ctx.fillStyle = isHov ? '#0277bd' : '#0277bd99';
    ctx.fillRect(x, y, w, h);

    if (d.count > 0) {
      ctx.fillStyle    = '#0a1929';
      ctx.font         = (isHov ? 'bold ' : '') + '8px JetBrains Mono,monospace';
      ctx.textAlign    = 'center';
      ctx.textBaseline = 'bottom';
      ctx.fillText(d.count, x + w / 2, y - 2);
    }

    const label = (d.date || '').substring(5).replace('-', '/');
    ctx.fillStyle    = isHov ? '#0277bd' : '#3a5a7a';
    ctx.font         = (isHov ? 'bold ' : '') + '9px JetBrains Mono,monospace';
    ctx.textBaseline = 'top';
    ctx.fillText(label, x + w / 2, BASE_Y + 5);
  });

  if (hoverIdx >= 0 && dailyData[hoverIdx]) {
    const d     = dailyData[hoverIdx];
    const label = `${d.date} — ${d.count} 通`;
    ctx.font         = 'bold 11px JetBrains Mono,monospace';
    ctx.textBaseline = 'middle';
    const tw = ctx.measureText(label).width;
    const tx = Math.min(hoverIdx * barW + barW / 2 - tw/2 - 8, dispW - tw - 20);
    const ty = 2;
    ctx.fillStyle = 'rgba(2,40,80,0.82)';
    const bx = Math.max(tx, 4), bw = tw + 16;
    ctx.beginPath();
    ctx.moveTo(bx + 4, ty); ctx.lineTo(bx + bw - 4, ty);
    ctx.arcTo(bx + bw, ty, bx + bw, ty + 4, 4);
    ctx.lineTo(bx + bw, ty + 18); ctx.arcTo(bx + bw, ty + 18, bx + bw - 4, ty + 18, 4);
    ctx.lineTo(bx + 4, ty + 18); ctx.arcTo(bx, ty + 18, bx, ty + 14, 4);
    ctx.lineTo(bx, ty + 4); ctx.arcTo(bx, ty, bx + 4, ty, 4);
    ctx.closePath(); ctx.fill();
    ctx.fillStyle = '#fff';
    ctx.textAlign = 'left';
    ctx.fillText(label, bx + 8, ty + 9);
  }
}

function _rpChartMouseMove(e) {
  const canvas  = e.currentTarget;
  const rect    = canvas.getBoundingClientRect();
  const isRange = _rpHourlyData.length > 0 && _rpHourlyData[0].hour === null;
  const slots   = isRange ? _rpHourlyData.length : 24;
  const idx     = Math.floor((e.clientX - rect.left) / (rect.width / slots));
  if (idx < 0 || idx >= slots) return;
  if (isRange) {
    _rpDrawDailyChart(canvas, _rpHourlyData, idx);
  } else {
    _drawHourlyChart(canvas, _rpHourlyData, idx);
  }
}

function _rpChartMouseLeave(e) {
  if (_rpHourlyData.length > 0 && _rpHourlyData[0].hour === null) {
    _rpDrawDailyChart(e.currentTarget, _rpHourlyData, -1);
  } else {
    _drawHourlyChart(e.currentTarget, _rpHourlyData, -1);
  }
}

function _rpRenderTopUsers(topUsers) {
  // 複用圓餅繪圖邏輯，指向 rp- canvas
  const canvas   = document.getElementById('rp-top-pie');
  const legendEl = document.getElementById('rp-top-legend');
  const badgeEl  = document.getElementById('rp-top-badge');
  if (!canvas) return;
  if (badgeEl) badgeEl.textContent = `${(topUsers||[]).length} 位`;

  const W = 180, H = 180;
  const ctx = canvas.getContext('2d');
  ctx.setTransform(1, 0, 0, 1, 0, 0);
  ctx.clearRect(0, 0, W, H);

  if (!topUsers || !topUsers.length) {
    ctx.fillStyle = '#c8d9ee';
    ctx.beginPath(); ctx.arc(W/2, H/2, 78, 0, Math.PI * 2); ctx.fill();
    ctx.beginPath(); ctx.arc(W/2, H/2, 42, 0, Math.PI * 2);
    ctx.fillStyle = '#ffffff'; ctx.fill();
    ctx.fillStyle = '#3a5a7a'; ctx.font = '11px JetBrains Mono,monospace';
    ctx.textAlign = 'center'; ctx.fillText('無通話', W/2, H/2 + 4);
    if (legendEl) legendEl.innerHTML = '';
    return;
  }

  const PIE_COLORS = ['#0277bd','#00897b','#e65100','#7b1fa2','#f57f17','#78909c'];
  const top5       = topUsers.slice(0, 5);
  const others     = topUsers.slice(5);
  const otherTotal = others.reduce((s, u) => s + u.total, 0);
  const slices     = top5.map((u, i) => ({ label: u.num, value: u.total, color: PIE_COLORS[i], user: u }));
  if (otherTotal > 0) slices.push({ label: '其他', value: otherTotal, color: PIE_COLORS[5] });

  const total = slices.reduce((s, sl) => s + sl.value, 0);
  const cx = W/2, cy = H/2, r = 82, ri = 44, GAP = 0.02;
  let startAngle = -Math.PI / 2;

  slices.forEach(sl => {
    const sweep = (sl.value / total) * Math.PI * 2;
    ctx.beginPath(); ctx.moveTo(cx, cy);
    ctx.arc(cx, cy, r, startAngle + GAP/2, startAngle + sweep - GAP/2);
    ctx.closePath(); ctx.fillStyle = sl.color; ctx.fill();
    startAngle += sweep;
  });

  ctx.beginPath(); ctx.arc(cx, cy, ri, 0, Math.PI * 2);
  ctx.fillStyle = '#ffffff'; ctx.fill();
  ctx.textAlign = 'center';
  ctx.font = 'bold 24px Syne,sans-serif'; ctx.fillStyle = '#0a1929';
  ctx.fillText(total, cx, cy + 5);
  ctx.font = '9px JetBrains Mono,monospace'; ctx.fillStyle = '#3a5a7a';
  ctx.fillText('通話', cx, cy + 18);

  if (legendEl) {
    legendEl.innerHTML = slices.map(sl => {
      const pct = Math.round((sl.value / total) * 100);
      return `<div style="display:inline-flex;align-items:center;gap:6px;
              padding:5px 12px 5px 8px;border-radius:20px;
              background:${sl.color}18;border:1.5px solid ${sl.color}66">
        <span style="width:10px;height:10px;border-radius:50%;background:${sl.color};flex-shrink:0"></span>
        <span style="font-weight:800;color:#0a1929;font-size:14px">${sl.label}</span>
        <span style="color:${sl.color};font-weight:700;font-size:13px">${sl.value}</span>
        <span style="color:#3a5a7a;font-size:11px">${pct}%</span>
      </div>`;
    }).join('');
  }
}

// ── 圖表渲染 ──────────────────────────────────────────────────────────────────
// 儲存 hourly 資料供 hover 使用
let _ovHourlyData = [];

function renderHourlyChart(hourly, allUsers) {
  const canvas = document.getElementById('ov-chart-canvas');
  if (!canvas || !hourly) return;
  _ovHourlyData = hourly;

  const dpr   = window.devicePixelRatio || 1;
  const dispW = canvas.parentElement?.clientWidth || canvas.offsetWidth || 600;
  const dispH = 200; // 含底部標籤區（加高讓柱體區更大）

  canvas.width  = Math.round(dispW * dpr);
  canvas.height = Math.round(dispH * dpr);
  canvas.style.width  = dispW + 'px';
  canvas.style.height = dispH + 'px';

  // 先移除舊 listener（用 AbortController），再畫圖
  if (canvas._chartAbort) canvas._chartAbort.abort();
  const ac = new AbortController();
  canvas._chartAbort = ac;
  canvas.addEventListener('mousemove',  _ovChartMouseMove,  { signal: ac.signal });
  canvas.addEventListener('mouseleave', _ovChartMouseLeave, { signal: ac.signal });

  _drawHourlyChart(canvas, hourly, -1);
}

function _drawHourlyChart(canvas, hourly, hoverIdx) {
  const dpr   = window.devicePixelRatio || 1;
  const dispW = parseInt(canvas.style.width)  || canvas.offsetWidth  || 600;
  const dispH = parseInt(canvas.style.height) || canvas.offsetHeight || 170;

  const ctx = canvas.getContext('2d');
  ctx.setTransform(1, 0, 0, 1, 0, 0);
  ctx.scale(dpr, dpr);
  ctx.clearRect(0, 0, dispW, dispH);

  // PAD_T: 頂部數字空間；PAD_B: 底部時間標籤空間
  // BASE_Y 就是底線，柱體從 BASE_Y 往上長
  const PAD_T   = 16;
  const PAD_B   = 28; // 底部留給時間標籤（加大確保標籤完整顯示）
  const CHART_H = dispH - PAD_T - PAD_B;
  const MIN_BAR = 2;
  const maxCount = Math.max(...hourly.map(h => h.count), 1);
  const now      = new Date().getHours();
  const barW     = dispW / 24;
  const gap      = Math.max(barW * 0.18, 1.5);
  const BASE_Y   = PAD_T + CHART_H;

  // ── 底線 ────────────────────────────────────────────────────────────────
  ctx.strokeStyle = '#b0c8e0';
  ctx.lineWidth   = 1.5;
  ctx.beginPath();
  ctx.moveTo(0, BASE_Y);
  ctx.lineTo(dispW, BASE_Y);
  ctx.stroke();

  // ── 刻度線 + 時間標籤 ────────────────────────────────────────────────────
  ctx.textBaseline = 'top';
  ctx.textAlign    = 'center';
  for (let i = 0; i < 24; i++) {
    const cx      = i * barW + barW / 2;
    const isMajor = i % 3 === 0; // 0/3/6/9/12/15/18/21 → HH:00
    const isMinor = !isMajor;    // 其餘 → 短刻度線，無文字

    // 刻度線
    ctx.strokeStyle = isMajor ? '#7a9ab8' : '#c8d9ee';
    ctx.lineWidth   = 1;
    ctx.beginPath();
    ctx.moveTo(cx, BASE_Y);
    ctx.lineTo(cx, BASE_Y + (isMajor ? 6 : 3));
    ctx.stroke();

    // 主要標籤：每 3 小時，粗體深色
    if (isMajor) {
      ctx.fillStyle = '#1e3d5c';
      ctx.font      = 'bold 10px JetBrains Mono,monospace';
      ctx.fillText(String(i).padStart(2,'0') + ':00', cx, BASE_Y + 8);
    }
  }

  // ── hover 背景高亮欄 ─────────────────────────────────────────────────────
  if (hoverIdx >= 0) {
    ctx.fillStyle = 'rgba(2,119,189,0.07)';
    ctx.fillRect(hoverIdx * barW, 0, barW, BASE_Y);
  }

  // ── 柱體 ────────────────────────────────────────────────────────────────
  hourly.forEach((h, i) => {
    const barH = h.count > 0
      ? Math.max(Math.round((h.count / maxCount) * CHART_H), MIN_BAR)
      : 0;
    if (barH === 0) return;

    const x      = i * barW + gap / 2;
    const w      = barW - gap;
    const y      = BASE_Y - barH;
    const isPeak = h.count === maxCount;
    const isNow  = h.hour === now;
    const isHov  = i === hoverIdx;

    ctx.fillStyle = (isHov || isPeak) ? '#0277bd'
                  : isNow             ? 'rgba(2,119,189,0.55)'
                  :                     'rgba(66,165,245,0.28)';

    const r2 = Math.min(2, w / 2, barH / 2);
    ctx.beginPath();
    ctx.moveTo(x + r2, y);
    ctx.lineTo(x + w - r2, y);
    ctx.arcTo(x + w, y, x + w, y + r2, r2);
    ctx.lineTo(x + w, y + barH);
    ctx.lineTo(x, y + barH);
    ctx.arcTo(x, y, x + r2, y, r2);
    ctx.closePath();
    ctx.fill();

    if (isPeak || isNow || isHov) {
      ctx.fillStyle = 'rgba(2,136,209,0.9)';
      ctx.fillRect(x, y, w, 2);
    }

    // 通話數字
    ctx.textAlign    = 'center';
    ctx.textBaseline = 'alphabetic';
    ctx.fillStyle    = isHov ? '#0277bd' : isPeak ? '#0277bd' : '#7a9ab8';
    ctx.font         = (isHov || isPeak ? 'bold ' : '') + '8px JetBrains Mono,monospace';
    ctx.fillText(h.count, x + w / 2, y - 3);
  });

  // ── Tooltip（hover 時右上角顯示） ─────────────────────────────────────
  if (hoverIdx >= 0 && hourly[hoverIdx]) {
    const h     = hourly[hoverIdx];
    const label = `${String(h.hour).padStart(2,'0')}:00 — ${h.count} 通`;
    ctx.font         = 'bold 11px JetBrains Mono,monospace';
    ctx.textBaseline = 'middle';
    const tw = ctx.measureText(label).width;
    const tx = Math.min(hoverIdx * barW + barW / 2 - tw/2 - 8, dispW - tw - 20);
    const ty = 2;
    ctx.fillStyle = 'rgba(2,40,80,0.82)';
    const bx = Math.max(tx, 4), bw = tw + 16;
    ctx.beginPath();
    ctx.moveTo(bx + 4, ty); ctx.lineTo(bx + bw - 4, ty);
    ctx.arcTo(bx + bw, ty, bx + bw, ty + 4, 4);
    ctx.lineTo(bx + bw, ty + 18); ctx.arcTo(bx + bw, ty + 18, bx + bw - 4, ty + 18, 4);
    ctx.lineTo(bx + 4, ty + 18); ctx.arcTo(bx, ty + 18, bx, ty + 14, 4);
    ctx.lineTo(bx, ty + 4); ctx.arcTo(bx, ty, bx + 4, ty, 4);
    ctx.closePath(); ctx.fill();
    ctx.fillStyle = '#fff';
    ctx.textAlign = 'left';
    ctx.fillText(label, bx + 8, ty + 9);
  }
}

function _ovChartMouseMove(e) {
  const canvas = e.currentTarget;
  const rect   = canvas.getBoundingClientRect();
  const idx    = Math.floor((e.clientX - rect.left) / (rect.width / 24));
  if (idx >= 0 && idx < 24) _drawHourlyChart(canvas, _ovHourlyData, idx);
}

function _ovChartMouseLeave(e) {
  _drawHourlyChart(e.currentTarget, _ovHourlyData, -1);
}

function renderTopUsers(topUsers) {
  const canvas   = document.getElementById('ov-top-pie');
  const legendEl = document.getElementById('ov-top-legend');
  const badgeEl  = document.getElementById('ov-top-badge');
  if (!canvas) return;
  if (badgeEl) badgeEl.textContent = `${(topUsers||[]).length} 位`;

  // canvas 尺寸由 HTML attribute 固定 (180x180)，不在 JS 裡修改避免觸發 reflow
  const W = 180, H = 180;
  const ctx = canvas.getContext('2d');
  ctx.setTransform(1, 0, 0, 1, 0, 0);
  ctx.clearRect(0, 0, W, H);

  if (!topUsers || topUsers.length === 0) {
    ctx.fillStyle = '#c8d9ee';
    ctx.beginPath(); ctx.arc(W/2, H/2, 78, 0, Math.PI * 2); ctx.fill();
    ctx.beginPath(); ctx.arc(W/2, H/2, 42, 0, Math.PI * 2);
    ctx.fillStyle = '#ffffff'; ctx.fill();
    ctx.fillStyle = '#3a5a7a'; ctx.font = '11px JetBrains Mono,monospace';
    ctx.textAlign = 'center'; ctx.fillText('今日無通話', W/2, H/2 + 4);
    if (legendEl) legendEl.innerHTML = '';
    return;
  }

  const PIE_COLORS = ['#0277bd','#00897b','#e65100','#7b1fa2','#f57f17','#78909c'];
  const top5       = topUsers.slice(0, 5);
  const others     = topUsers.slice(5);
  const otherTotal = others.reduce((s, u) => s + u.total, 0);

  const slices = top5.map((u, i) => ({ label: u.num, value: u.total, color: PIE_COLORS[i], user: u }));
  if (otherTotal > 0) slices.push({ label: '其他', value: otherTotal, color: PIE_COLORS[5] });

  const total = slices.reduce((s, sl) => s + sl.value, 0);
  const cx = W/2, cy = H/2, r = 82, ri = 44;
  const GAP = 0.02;
  let startAngle = -Math.PI / 2;

  slices.forEach(sl => {
    const sweep = (sl.value / total) * Math.PI * 2;
    ctx.beginPath();
    ctx.moveTo(cx, cy);
    ctx.arc(cx, cy, r, startAngle + GAP/2, startAngle + sweep - GAP/2);
    ctx.closePath();
    ctx.fillStyle = sl.color;
    ctx.fill();
    startAngle += sweep;
  });

  // Donut 中心鑿洞
  ctx.beginPath(); ctx.arc(cx, cy, ri, 0, Math.PI * 2);
  ctx.fillStyle = '#ffffff'; ctx.fill();

  // 中心文字
  ctx.textAlign = 'center';
  ctx.font = 'bold 24px Syne,sans-serif';
  ctx.fillStyle = '#0a1929';
  ctx.fillText(total, cx, cy + 5);
  ctx.font = '9px JetBrains Mono,monospace';
  ctx.fillStyle = '#3a5a7a';
  ctx.fillText('今日通話', cx, cy + 18);

  // 圖例：水平 pill 排列在圓餅下方
  if (legendEl) {
    legendEl.innerHTML = slices.map(sl => {
      const u   = sl.user;
      const pct = Math.round((sl.value / total) * 100);
      const isSelected = u && _selectedUser === sl.label;
      return `<div data-ext="${sl.label}" data-clickable="${u ? '1' : '0'}"
                style="display:inline-flex;align-items:center;gap:6px;
                padding:5px 12px 5px 8px;border-radius:20px;cursor:${u?'pointer':'default'};
                background:${isSelected ? sl.color+'35' : sl.color+'18'};
                border:${isSelected ? '2px' : '1.5px'} solid ${isSelected ? sl.color : sl.color+'66'};
                transition:background 0.15s">
        <span style="width:10px;height:10px;border-radius:50%;background:${sl.color};flex-shrink:0"></span>
        <span style="font-weight:800;color:#0a1929;font-size:14px;letter-spacing:0.3px">${sl.label}</span>
        <span style="color:${sl.color};font-weight:700;font-size:13px">${sl.value}</span>
        <span style="color:#3a5a7a;font-size:11px">${pct}%</span>
      </div>`;
    }).join('');
    // 用 addEventListener 綁定點擊，避免 innerHTML 字串引號轉義問題
    legendEl.querySelectorAll('[data-clickable="1"]').forEach(el => {
      el.addEventListener('mouseenter', function() { this.style.background = this.style.background.replace(/18|35/, '30'); });
      el.addEventListener('mouseleave', function() { this.style.background = this.style.background.replace(/18|35|30/, _selectedUser === this.dataset.ext ? '35' : '18'); });
      el.addEventListener('click', function() { filterByUser(this.dataset.ext); });
    });
  }
}

let _selectedUser = 'all'; // 全域記住當前選中的分機

function filterByUser(num) {
  const sel = document.getElementById('ov-user-filter');
  if (!sel) return;
  // toggle：再點同一分機 → 回全部
  const next = (_selectedUser === num) ? 'all' : num;
  // 先設 select value，updateOvChart 開頭會從它讀
  sel.value = [...sel.options].some(o => o.value === next) ? next : 'all';
  _selectedUser = sel.value;
  updateOvChart();
}

let _ovChartPending = false; // 防止重入

async function updateOvChart() {
  if (_ovChartPending) return; // 已有一次在飛行中，丟棄這次
  _ovChartPending = true;

  try {
    const dateInput = document.getElementById('ov-date-filter');
    const sel       = document.getElementById('ov-user-filter');
    const date      = dateInput ? dateInput.value : new Date().toISOString().split('T')[0];

    // select 是 source of truth
    if (sel) _selectedUser = sel.value;

    const userParam = (_selectedUser && _selectedUser !== 'all')
      ? `&user=${encodeURIComponent(_selectedUser)}` : '';
    const statsData = await apiFetch(`/api/cdr/stats?date_str=${date}${userParam}`);
    if (!statsData) return;

    const el = id => document.getElementById(id);

    if (el('ov-today-calls-badge')) {
      const dateLabel = (statsData.date || date).split('-').map((v,i) => i===0 ? v : v.padStart(2,'0')).join('/');
      el('ov-today-calls-badge').textContent = `今日 ${statsData.total_calls} 通`;
      el('ov-today-calls-badge').title = `今日通話總量（${dateLabel}）`;
    }

    // 重建下拉選單時暫時移除 onchange，防止 innerHTML 觸發連鎖呼叫
    if (sel && statsData.all_users) {
      const keep = _selectedUser;
      sel.onchange = null; // 暫時斷開
      sel.innerHTML = '<option value="all">全部使用者</option>';
      statsData.all_users.forEach(u => {
        const opt = document.createElement('option');
        opt.value = u.num;
        opt.textContent = `${u.num}（${u.total} 通）`;
        sel.appendChild(opt);
      });
      sel.value = [...sel.options].some(o => o.value === keep) ? keep : 'all';
      _selectedUser = sel.value;
      sel.onchange = () => updateOvChart(); // 重新掛上
    }

    requestAnimationFrame(() => {
      renderHourlyChart(statsData.hourly, statsData.all_users);
      renderTopUsers(statsData.top_users);
    });
  } finally {
    _ovChartPending = false;
  }
}

