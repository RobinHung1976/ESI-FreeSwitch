// calls.js — 即時通話監控（User-Centric Monitor）

async function renderCalls() {
  document.getElementById('mainContent').innerHTML = `
  <div class="panel">
    <div class="panel-header">
      
      <span class="panel-badge live">LIVE · 載入中...</span>
    </div>
    <div style="padding:40px;text-align:center;color:var(--muted)">正在連線至 FreeSwitch...</div>
  </div>`;

  const callData = await apiFetch('/api/calls');
  const rows = (callData && callData.rows) ? callData.rows : [];

  document.getElementById('mainContent').innerHTML = `
  <div class="panel">
    <div class="panel-header">
      
      <span class="panel-badge live">LIVE · ${rows.length} 通</span>
      <div class="panel-actions">
        <button class="btn" onclick="switchPage('calls')">↺ 刷新</button>
      </div>
    </div>
    <div class="table-wrap">
      <table>
        <thead>
          <tr><th>UUID</th><th>來源</th><th>目的地</th><th>狀態</th><th>時長</th><th>方向</th><th>操作</th></tr>
        </thead>
        <tbody>${buildCallRows(rows)}</tbody>
      </table>
    </div>
  </div>`;
}
// ── User-Centric Monitor：全域分機清單快取 ───────────────────────────────────
let _ucExtList = [];        // [{ id, name }]  從 /api/extensions/list 載入
let _ucShowOffline = false; // 是否顯示離線分機

const UC_STATUS_ORDER = { talking:0, ringing:1, holding:2, parked:3, idle:4, offline:5 };

/** 判斷對象是否為內部分機（3-6位純數字） */
function _ucIsInternal(peer) {
  return peer && /^\d{3,6}$/.test(peer.trim());
}

/** 方向欄：只顯示撥出 / 來電（不管內外線） */
function _ucDirBadge(direction, peer) {
  if (!peer) return '';
  if (direction === 'outbound') return `<span class="uc-dir-out">▶ 撥出</span>`;
  return                               `<span class="uc-dir-in">◀ 來電</span>`;
}

/** 通話類型欄：內線 / 外線 */
function _ucTypeBadge(peer) {
  if (!peer) return '';
  return _ucIsInternal(peer)
    ? `<span class="uc-dir-internal">↔ 內線</span>`
    : `<span class="uc-dir-ext">🌐 外線</span>`;
}

/**
 * 從 _liveCalls 取出與此分機相關的去重通話清單。
 *
 * 問題根源：FreeSWITCH show calls as json 對同一通話回傳
 * A leg 與 B leg 兩筆，造成重複顯示。
 *
 * 去重策略（雙保險）：
 *   1. b_uuid 封鎖：若 row.b_uuid 存在（A leg 特有），
 *      採用此筆並封鎖對應 B leg 的 uuid，防止 B leg 被再次採用。
 *   2. Pair key fallback：以 sorted(cid_num, dest) 字串去重，
 *      處理 b_uuid 不存在的情境（WS 事件寫入的輕量物件）。
 */
function _ucGetCallsForExt(extId) {
  const all = Object.values(_liveCalls).filter(c =>
    c.cid_num === extId || c.dest === extId
  );

  const seenUUIDs = new Set();
  const seenPairs = new Set();
  const deduped   = [];

  for (const c of all) {
    if (seenUUIDs.has(c.uuid)) continue;

    if (c.b_uuid) {
      // A leg 確認：採用並封鎖 B leg
      seenUUIDs.add(c.uuid);
      seenUUIDs.add(c.b_uuid);
      deduped.push(c);
      continue;
    }

    // Fallback：sorted pair 去重
    const pairKey = [c.cid_num || '', c.dest || ''].sort().join('|');
    if (seenPairs.has(pairKey)) continue;
    seenPairs.add(pairKey);
    seenUUIDs.add(c.uuid);
    deduped.push(c);
  }

  return deduped;
}

/**
 * 建立單一分機的所有列 HTML（1 主列 + 0~N 子列）
 *
 * 主列：顯示分機號碼 + 名稱 + 主狀態（rowspan 若有多通則延伸）
 * 子列：每通額外的通話各佔一列，分機欄留空（視覺上屬於同一分機）
 *
 * @returns {string}  一段 <tr>...</tr> HTML，可能含多個 <tr>
 */
function _ucBuildRows(ext) {
  const st   = extStatusCache[ext.id] || { status: 'offline', peer: '', direction: '', since: 0 };
  const meta = getExtMeta(st.status);

  // 離線且不顯示 → 不輸出
  if (st.status === 'offline' && !_ucShowOffline) return '';

  const rowCls    = `uc-row-${st.status}`;
  const statusBadge = `<span class="uc-status-badge" style="${meta.badge}">${meta.label}</span>`;

  // ── 從 _liveCalls 取本分機的所有通話 ─────────────────────────────────────
  const calls = _ucGetCallsForExt(ext.id);

  // 若 _liveCalls 有資料，優先用它（更精確的 per-uuid 資訊）；
  // 否則 fallback 到 extStatusCache（僅顯示單筆）
  const callRows = calls.length > 0 ? calls : (
    st.peer ? [{ cid_num: st.direction === 'outbound' ? ext.id : st.peer,
                 dest:    st.direction === 'outbound' ? st.peer : ext.id,
                 direction: st.direction, created_epoch: st.since ? Math.floor(st.since/1000) : null,
                 callstate: 'CS_ACTIVE', _fromCache: true }]
            : []
  );

  const hasCall = ['talking','ringing','holding','parked'].includes(st.status) && callRows.length > 0;
  const span    = hasCall ? Math.max(callRows.length, 1) : 1;

  // ── 分機欄（含 rowspan）──────────────────────────────────────────────────
  const extCell = `<td rowspan="${span}" style="vertical-align:middle;border-right:1px solid var(--border)">
    <div class="uc-ext-num">${ext.id}</div>
    ${ext.name ? `<div class="uc-ext-name">${ext.name}</div>` : ''}
  </td>`;

  // ── 錄音格（rowspan 與 extCell 相同，需在 hasCall 判斷前宣告）────────────
  const isRecording = ext.recording_enabled && hasCall;
  const recCell = `<td rowspan="${span}" style="vertical-align:middle;text-align:center;border-right:1px solid var(--border)">${
    isRecording ? '<span class="uc-rec-badge" title="錄音中">🔴</span>' : ''
  }</td>`;

  // ── 無通話：單列輸出 ──────────────────────────────────────────────────────
  if (!hasCall) {
    return `<tr class="${rowCls}" data-uc-ext="${ext.id}" data-uc-st="${st.status}">
      ${extCell}
      <td>${statusBadge}</td>
      ${recCell}
      <td></td><td></td><td></td><td></td>
    </tr>`;
  }

  // ── 多通話：第一通在主列，後續各佔子列 ───────────────────────────────────
  const callStateMap = {
    CS_RINGING:'📞 響鈴中', CS_ROUTING:'⏳ 撥號中',
    CS_ACTIVE:'🔊 通話中',  CS_EXECUTE:'🔊 通話中',
    CS_HOLD:'⏸ 保留中',    CS_PARK:'🅿 停車中',
  };

  const rows = callRows.map((c, i) => {
    // 從通話中判斷「對象」號碼
    const peer      = c.cid_num === ext.id ? (c.dest || '—') : (c.cid_num || '—');
    const direction = c.cid_num === ext.id ? 'outbound' : 'inbound';
    const since     = c.created_epoch ? parseInt(c.created_epoch) * 1000 : (st.since || 0);
    const callLabel = c._fromCache ? statusBadge
      : `<span class="uc-status-badge" style="${
          c.callstate === 'CS_HOLD' ? 'background:#e65100;color:#fff'
          : (c.callstate === 'CS_RINGING' || c.callstate === 'CS_ROUTING') ? 'background:#f9a825;color:#000'
          : 'background:#1b5e20;color:#fff'
        }">${callStateMap[c.callstate] || '通話中'}</span>`;

    const dirBadge  = _ucDirBadge(direction, peer);
	const typeBadge = _ucTypeBadge(peer);
    const timerSpan = since ? `<span class="ext-timer" data-since="${since}">00:00</span>` : '';

    // 多通時第 2+ 列的子列樣式（左側分機欄由 rowspan 佔用）
    const subCls = i === 0 ? '' : `style="border-top:1px dashed rgba(200,217,238,0.6)"`;

    if (i === 0) {
      // 主列：含分機欄（rowspan）
      return `<tr class="${rowCls}" data-uc-ext="${ext.id}" data-uc-st="${st.status}">
        ${extCell}
        <td>${callLabel}</td>
		${recCell}
        <td>${dirBadge}</td>
		<td>${typeBadge}</td>
        <td><div class="uc-peer-num">${peer}</div></td>
        <td>${timerSpan}</td>
      </tr>`;
    } else {
      // 子列：分機欄由 rowspan 覆蓋，不需輸出
      return `<tr class="${rowCls} uc-subcall" data-uc-ext="${ext.id}" data-uc-st="${st.status}" ${subCls}>
        <td>${callLabel}</td>
        <td>${dirBadge}</td>
		<td>${typeBadge}</td>
        <td><div class="uc-peer-num">${peer}</div></td>
        <td>${timerSpan}</td>
      </tr>`;
    }
  });

  return rows.join('');
}

/**
 * 完整重繪 UC 表格
 * ─ 先過濾（是否顯示離線），再排序，最後渲染
 * ─ 確保離線分機不影響上線分機的排序位置
 */
function _ucRenderTable() {
  const tbody = document.getElementById('uc-tbody');
  const badge = document.getElementById('monitor-calls-count');
  if (!tbody) return;

  // 1. 先過濾
  const visible = _ucExtList.filter(e => {
    const s = (extStatusCache[e.id] || {}).status || 'offline';
    return _ucShowOffline || s !== 'offline';
  });

  // 2. 再排序（過濾後不含被隱藏的離線分機，排序不會錯亂）
  visible.sort((a, b) =>
    (UC_STATUS_ORDER[(extStatusCache[a.id]||{}).status] ?? 4) -
    (UC_STATUS_ORDER[(extStatusCache[b.id]||{}).status] ?? 4)
  );

  // 3. 渲染
  const html = visible.map(_ucBuildRows).join('');
  tbody.innerHTML = html || `<tr><td colspan="5" style="text-align:center;padding:28px;color:var(--muted)">目前無上線分機</td></tr>`;

  _ucUpdateBadge();
}

/** WS 推播後局部更新單一分機的所有列（含多通子列） */
function _ucUpdateRow(extId) {
  const tbody = document.getElementById('uc-tbody');
  if (!tbody) return;

  const ext = _ucExtList.find(e => e.id === extId);
  if (!ext) return;

  const st = extStatusCache[extId] || { status: 'offline' };

  // 移除此分機的所有現有列（主列 + 子列）
  tbody.querySelectorAll(`tr[data-uc-ext="${extId}"]`).forEach(r => r.remove());

  // 離線 + 不顯示 → 刪完就結束
  if (st.status === 'offline' && !_ucShowOffline) {
    _ucUpdateBadge();
    return;
  }

  const newHtml = _ucBuildRows(ext);
  if (!newHtml) { _ucUpdateBadge(); return; }

  // 根據新狀態找插入位置（插在第一個 order 更大的主列之前）
  const myOrder  = UC_STATUS_ORDER[st.status] ?? 4;
  const mainRows = [...tbody.querySelectorAll('tr[data-uc-ext]:not(.uc-subcall)')];
  const insertBefore = mainRows.find(r => {
    const rSt = r.dataset.ucSt || 'offline';
    return (UC_STATUS_ORDER[rSt] ?? 4) > myOrder;
  });

  // 用 DocumentFragment 批次插入（支援多個 <tr>）
  const tmp = document.createElement('table');
  tmp.innerHTML = `<tbody>${newHtml}</tbody>`;
  const frag = document.createDocumentFragment();
  [...tmp.querySelector('tbody').children].forEach(tr => frag.appendChild(tr));
  tbody.insertBefore(frag, insertBefore || null);

  _ucUpdateBadge();
}

/** 更新 header badge 計數 */
function _ucUpdateBadge() {
  const badge = document.getElementById('monitor-calls-count');
  if (!badge) return;
  const activeCalls = Object.keys(_liveCalls).length;
  badge.innerHTML = activeCalls > 0
    ? `<span class="uc-call-dot"></span>${activeCalls} 通通話中`
    : 'LIVE · 0 通話中';
}

/** 切換顯示離線分機 */
function ucToggleOffline(btn) {
  _ucShowOffline = !_ucShowOffline;
  btn.classList.toggle('active', _ucShowOffline);
  btn.textContent = _ucShowOffline ? '⭘ 隱藏離線' : '⭘ 顯示離線';
  _ucRenderTable(); // 切換時完整重繪，確保排序正確
}

// ── 保留：_liveCalls 快取（供 WS 事件使用）────────────────────────────────────
const _liveCalls = {};

// 從 /api/calls 初始化快取（頁面首次載入時）
async function _refreshMonitorCallsTable() {
  const callData = await apiFetch('/api/calls');
  const rows = (callData && callData.rows) ? callData.rows : [];
  // 重建快取
  Object.keys(_liveCalls).forEach(k => delete _liveCalls[k]);
  rows.forEach(r => { if (r.uuid) _liveCalls[r.uuid] = r; });
  _ucRenderTable();
}

// WS 通話事件後呼叫：重新渲染所有受影響分機的列（支援多通）
function _renderLiveCalls() {
  // 取得目前所有通話涉及的分機號碼，逐一局部更新
  const affectedExts = new Set();
  Object.values(_liveCalls).forEach(c => {
    if (c.cid_num) affectedExts.add(c.cid_num);
    if (c.dest)    affectedExts.add(c.dest);
  });
  // 同時更新表中已有列但通話已消失的分機（恢復 idle）
  document.querySelectorAll('tr[data-uc-ext]').forEach(r => affectedExts.add(r.dataset.ucExt));

  if (affectedExts.size > 0) {
    affectedExts.forEach(extId => _ucUpdateRow(extId));
  } else {
    // 無任何通話 → 只更新 badge，不需重繪列
    _ucUpdateBadge();
  }
}

