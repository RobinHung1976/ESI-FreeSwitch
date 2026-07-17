#!/bin/bash
set -e

# ── 自動歸檔（固定寫法）─────────────────────────────────────────────
ARCHIVE_DIR="updateN"
SELF="$(basename "$0")"

mkdir -p "$ARCHIVE_DIR"
for f in update*.sh; do
  [ "$f" = "$SELF" ] && continue
  [ -f "$f" ] || continue
  git mv "$f" "${ARCHIVE_DIR}/$f" 2>/dev/null || mv "$f" "${ARCHIVE_DIR}/$f"
done
git add -A
if ! git diff --cached --quiet; then
  git commit -m "chore: 歸檔已執行的 updateN.sh 腳本"
fi

# ── 前置驗證 ────────────────────────────────────────────────────────
if ! grep -q 'data-page="acl"' static/index.html; then
  echo "❌ static/index.html 缺少 update30.sh 的既有改動（data-page=\"acl\"），請先確認 update30.sh 是否已成功套用" >&2
  exit 1
fi
if ! grep -q "acl:.*{ render: renderAclPage" static/js/init.js; then
  echo "❌ static/js/init.js 缺少 update30.sh 的既有改動（renderAclPage），請先確認 update30.sh 是否已成功套用" >&2
  exit 1
fi
if [ ! -f static/js/acl.js ]; then
  echo "❌ static/js/acl.js 不存在，請先確認 update30.sh 是否已成功套用" >&2
  exit 1
fi

# ── 1. static/index.html：移除 calls nav-item + acl 標籤改名 ─────────
if grep -q 'data-page="calls"' static/index.html; then
  python3 << 'PYEOF'
path = "static/index.html"
with open(path, "r", encoding="utf-8") as f:
    content = f.read()

old = '''          <div class="nav-item" data-page="report" onclick="switchPage('report')">
            <span class="nav-icon">📊</span> 通話統計報表
          </div>
          <div class="nav-item" data-page="calls" onclick="switchPage('calls')">
            <span class="nav-icon">📞</span> 即時通話監控
          </div>
        </div>
      </div>

      <div class="nav-group" data-group="manage">'''

new = '''          <div class="nav-item" data-page="report" onclick="switchPage('report')">
            <span class="nav-icon">📊</span> 通話統計報表
          </div>
        </div>
      </div>

      <div class="nav-group" data-group="manage">'''

if content.count(old) != 1:
    raise SystemExit("❌ index.html: 移除 calls nav-item 的 old_str 比對失敗，中止")
content = content.replace(old, new)

with open(path, "w", encoding="utf-8") as f:
    f.write(content)
print("✓ index.html：已移除 calls nav-item")
PYEOF
else
  echo "↷ static/index.html 的 calls nav-item 已移除，略過"
fi

if grep -q '>ACL 信任清單<' static/index.html; then
  python3 << 'PYEOF'
path = "static/index.html"
with open(path, "r", encoding="utf-8") as f:
    content = f.read()

old = '''          <div class="nav-item" data-page="acl" onclick="switchPage('acl')">
            <span class="nav-icon">🛡️</span> ACL 信任清單
          </div>'''

new = '''          <div class="nav-item" data-page="acl" onclick="switchPage('acl')">
            <span class="nav-icon">🛡️</span> SIPTrunk ACL 信任清單
          </div>'''

if content.count(old) != 1:
    raise SystemExit("❌ index.html: acl 標籤改名的 old_str 比對失敗，中止")
content = content.replace(old, new)

with open(path, "w", encoding="utf-8") as f:
    f.write(content)
print("✓ index.html：acl nav-item 標籤已改名")
PYEOF
else
  echo "↷ static/index.html 的 acl 標籤已改名，略過"
fi

# ── 2. static/js/init.js：移除 pages.calls + acl 標題改名 ────────────
if grep -q "calls:.*{ render: renderCalls" static/js/init.js; then
  python3 << 'PYEOF'
path = "static/js/init.js"
with open(path, "r", encoding="utf-8") as f:
    content = f.read()

old = "  calls:       { render: renderCalls,       title: '即時通話監控' },\n"
if content.count(old) != 1:
    raise SystemExit("❌ init.js: 移除 pages.calls 的 old_str 比對失敗，中止")
content = content.replace(old, "")

with open(path, "w", encoding="utf-8") as f:
    f.write(content)
print("✓ init.js：已移除 pages.calls")
PYEOF
else
  echo "↷ static/js/init.js 的 pages.calls 已移除，略過"
fi

if grep -q "title: 'ACL 信任清單'" static/js/init.js; then
  python3 << 'PYEOF'
path = "static/js/init.js"
with open(path, "r", encoding="utf-8") as f:
    content = f.read()

old = "  acl:         { render: renderAclPage,     title: 'ACL 信任清單' },"
new = "  acl:         { render: renderAclPage,     title: 'SIPTrunk ACL 信任清單' },"

if content.count(old) != 1:
    raise SystemExit("❌ init.js: acl 標題改名的 old_str 比對失敗，中止")
content = content.replace(old, new)

with open(path, "w", encoding="utf-8") as f:
    f.write(content)
print("✓ init.js：acl 標題已改名")
PYEOF
else
  echo "↷ static/js/init.js 的 acl 標題已改名，略過"
fi

# ── 3. static/js/acl.js：說明文字更新（反映 Tab2 已移除的現況）──────
if grep -q "SIP Profile 進階設定」頁的「信任 SBC 清單」" static/js/acl.js; then
  python3 << 'PYEOF'
path = "static/js/acl.js"
with open(path, "r", encoding="utf-8") as f:
    content = f.read()

old_header = '''// acl.js — ACL 信任清單獨立頁面
//
// 與 static/js/sip-profile.js 的「信任 SBC 清單」Tab（renderSpAclTab）呼叫同一組後端 API
// （/api/acl/trusted-sbc*），但獨立成頁面，理由：
// core/permissions.py 把 acl 歸在 System 類、sip_profile 歸在 Operational 類，
// 兩者權限矩陣可能不同（例如 Technical Support 群組有 sip_profile 讀寫但無 acl 權限），
// 若只靠 sip-profile.js 內嵌的 Tab 2，會出現「看得到頁籤但打 API 吃 403」的情況。
// 本頁純粹依照 acl 模組的權限顯示/隱藏（沿用 init.js 既有的 applyAuthUI() 邏輯，
// data-page="acl" 直接對應 Module.ACL，不需額外設定 NAV_PAGE_TO_MODULE）。
//
// 刻意不重用 sip-profile.js 內的 openAclEditor/saveAclEntry/deleteAclEntry/restartFreeswitchForAcl，
// 因為那組函式的「刷新」邏輯綁死在 sip_profile 的 Hub 版面（switchSpTab('sp-acl')），
// 直接呼叫在本頁面會找不到對應 DOM 而失效；因此本檔案的函式全部獨立命名（aclPage 前綴），
// 避免與 sip-profile.js 的全域函式撞名或互相干擾。'''

new_header = '''// acl.js — SIPTrunk ACL 信任清單（唯一入口）
//
// 2026-07-17：原本 static/js/sip-profile.js 的 Tab 2「信任 SBC 清單」已移除，
// 本頁面是 acl.conf.xml 自訂信任清單（/api/acl/trusted-sbc*）管理的唯一入口，
// 純粹依照 acl 模組的權限顯示/隱藏（沿用 init.js 既有的 applyAuthUI() 邏輯，
// data-page="acl" 直接對應 Module.ACL，不需額外設定 NAV_PAGE_TO_MODULE）。
// 函式命名維持 aclPage 前綴，與其他頁面的同類命名風格一致。'''

if content.count(old_header) != 1:
    raise SystemExit("❌ acl.js: header 註解 old_str 比對失敗，中止")
content = content.replace(old_header, new_header)

old_note = '''      <div style="font-size:11px;color:var(--muted)">
        此頁面與「SIP Profile 進階設定」頁的「信任 SBC 清單」Tab 使用同一份資料（同一支後端 API），兩邊互相同步，差別只在權限判斷依據 acl 模組。
      </div>'''

new_note = '''      <div style="font-size:11px;color:var(--muted)">
        用途：內部 SBC/SIP Trunk 可能分佈在不同網段，僅靠 local-network-acl 的同網段自動信任無法涵蓋，
        於此明確列舉信任來源。新增/移除項目後，若下方顯示「待重啟」，需執行「立即重啟套用」才會生效。
      </div>'''

if content.count(old_note) != 1:
    raise SystemExit("❌ acl.js: 說明文字 old_str 比對失敗，中止")
content = content.replace(old_note, new_note)

with open(path, "w", encoding="utf-8") as f:
    f.write(content)
print("✓ acl.js：說明文字已更新")
PYEOF
else
  echo "↷ static/js/acl.js 的說明文字已更新，略過"
fi

# ── 4. static/js/calls.js：移除獨立頁面 renderCalls()，保留 _uc* 共用函式庫（完整覆寫）──
if grep -q "async function renderCalls" static/js/calls.js; then
cat > static/js/calls.js << 'CALLSJS_EOF'
// calls.js — 通話監控共用函式庫（User-Centric Monitor）
//
// 2026-07-17：移除獨立的「即時通話監控」頁面（原本的 renderCalls()），
// 因為功能與「通話即時狀態」（overview.js 的 renderOverview()）完全重複，
// 且沒有掛斷/保留/轉接操作按鈕，確認不需要保留獨立頁面。
// 本檔案下方的 _uc* 系列輔助函式仍被 overview.js 的 renderOverview() 呼叫使用，
// 不能整支刪除，只移除上面這個已經不再需要的獨立頁面函式。

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
CALLSJS_EOF
  echo "✓ static/js/calls.js：已移除獨立頁面 renderCalls()，保留 _uc* 共用函式庫"
else
  echo "↷ static/js/calls.js 的 renderCalls() 已移除，略過"
fi

# ── 5. static/js/sip-profile.js：移除 Tab2「信任 SBC 清單」（完整覆寫）──
if grep -q "sp-acl" static/js/sip-profile.js; then
cat > static/js/sip-profile.js << 'SIPPROFILEJS_EOF'
// sip-profile.js — SIP Profile 進階設定（比照 dialplan.js 的 Hub 版面：左側子選單 + 右側內容）
//
// 2026-07-17：原本的 Tab 2「信任 SBC 清單」已移除，統一改由獨立頁面
// static/js/acl.js（側邊欄「SIPTrunk ACL 信任清單」）管理，避免同一功能有兩個入口，
// 也避免此處掛在 sip_profile 權限下、但後端實際檢查的是 acl 權限造成的權限不一致問題。

const SP_HUB_TREE = [
  { id: 'sp-params', icon: '📡', label: 'Profile 參數' },
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
      headers: { 'Content-Type': 'application/json', 'Authorization': `Bearer ${getToken()}` },
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
      headers: { 'Content-Type': 'application/json', 'Authorization': `Bearer ${getToken()}` },
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
SIPPROFILEJS_EOF
  echo "✓ static/js/sip-profile.js：已移除 Tab2「信任 SBC 清單」"
else
  echo "↷ static/js/sip-profile.js 的 Tab2 已移除，略過"
fi

# ── 語法檢查 ─────────────────────────────────────────────────────────
if command -v node >/dev/null 2>&1; then
  node --check static/js/init.js
  node --check static/js/acl.js
  node --check static/js/calls.js
  node --check static/js/sip-profile.js
  echo "✓ node --check 通過"
else
  echo "⚠ 此環境沒有安裝 node，略過 JS 語法檢查（改動內容已於沙箱環境用 node --check 驗證過）"
fi

# ── Commit ──────────────────────────────────────────────────────────
git add static/index.html static/js/init.js static/js/acl.js static/js/calls.js static/js/sip-profile.js
if git diff --cached --quiet; then
  echo "（無變更需要 commit，可能是重跑此腳本、上次已成功 commit 過）"
else
  git commit -m "refactor: ACL 頁面統一為單一入口（更名 SIPTrunk ACL 信任清單）+ 移除重複的即時通話監控頁面"
fi

echo ""
echo "===== git log ====="
git log --oneline -3
