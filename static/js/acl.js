// acl.js — SIPTrunk ACL 信任清單（唯一入口）
//
// 2026-07-17：原本 static/js/sip-profile.js 的 Tab 2「信任 SBC 清單」已移除，
// 本頁面是 acl.conf.xml 自訂信任清單（/api/acl/trusted-sbc*）管理的唯一入口，
// 純粹依照 acl 模組的權限顯示/隱藏（沿用 init.js 既有的 applyAuthUI() 邏輯，
// data-page="acl" 直接對應 Module.ACL，不需額外設定 NAV_PAGE_TO_MODULE）。
// 函式命名維持 aclPage 前綴，與其他頁面的同類命名風格一致。

let _aclPageEditingCidr = null;

async function renderAclPage() {
  document.getElementById('mainContent').innerHTML =
    `<div id="acl-page-body"><div style="padding:40px;text-align:center;color:var(--muted)">載入中...</div></div>`;
  await _aclPageLoad();
}

async function _aclPageLoad() {
  const container = document.getElementById('acl-page-body');
  if (!container) return;

  const data = await apiFetch('/api/acl/trusted-sbc');
  const entries = (data && data.entries) ? data.entries : [];
  const pendingCount = entries.filter(e => !e.active).length;

  const rows = entries.length === 0
    ? `<tr><td colspan="4" style="text-align:center;color:var(--muted);padding:20px">尚無信任的 SBC，請於下方新增</td></tr>`
    : entries.map(e => `
      <tr>
        <td style="color:var(--label);font-weight:600">${e.cidr}</td>
        <td style="color:var(--label)">${e.note || '—'}</td>
        <td>${e.active
          ? '<span class="call-status status-active"><span class="dot"></span>已生效</span>'
          : '<span class="call-status status-hold"><span class="dot"></span>待重啟</span>'}</td>
        <td style="display:flex;gap:4px">
          <button class="btn" style="padding:3px 8px;font-size:11px"
            onclick="aclPageOpenEditor('${e.cidr}', '${(e.note || '').replace(/'/g, "\\'")}')">✏ 編輯</button>
          <button class="btn danger" style="padding:3px 8px;font-size:11px"
            onclick="aclPageDeleteEntry('${e.cidr}')">✕ 移除</button>
        </td>
      </tr>`).join('');

  const pendingBanner = pendingCount > 0 ? `
    <div style="background:rgba(255,152,0,0.12);border:1px solid #ff9800;border-radius:6px;
                padding:12px 16px;margin-bottom:14px;display:flex;justify-content:space-between;align-items:center;gap:12px">
      <div style="font-size:12px;color:#7a4a00;line-height:1.6">
        ⚠️ <strong>${pendingCount} 筆變更尚未生效</strong>，需重啟 FreeSWITCH 服務才會套用到記憶體中的 ACL 判斷。
        重啟會中斷所有進行中的通話，請安排維護時間執行。
      </div>
      <button class="btn primary" style="white-space:nowrap" onclick="aclPageRestart()">🔄 立即重啟套用</button>
    </div>` : `
    <div style="background:rgba(76,175,80,0.10);border:1px solid var(--green);border-radius:6px;
                padding:10px 16px;margin-bottom:14px;font-size:12px;color:var(--green)">
      ✓ 所有信任項目皆已生效
    </div>`;

  container.innerHTML = `
  ${pendingBanner}
  <div class="panel" style="margin-bottom:14px">
    <div class="panel-header">
      <span class="panel-title">信任的內部 SBC IP / 網段</span>
      <span class="panel-badge">${entries.length} 筆</span>
      <div class="panel-actions">
        <button class="btn" onclick="_aclPageLoad()">↺ 刷新</button>
      </div>
    </div>
    <div class="table-wrap">
      <table>
        <thead><tr><th>IP / CIDR</th><th>備註</th><th>狀態</th><th>操作</th></tr></thead>
        <tbody>${rows}</tbody>
      </table>
    </div>
  </div>

  <div class="panel">
    <div class="panel-header"><span class="panel-title" id="acl-page-form-title">+ 新增信任 SBC</span></div>
    <div style="padding:20px;display:flex;flex-direction:column;gap:14px;max-width:520px">
      <div class="settings-row">
        <span class="settings-label">IP / CIDR *</span>
        <input class="settings-input" id="acl-page-cidr" placeholder="例：172.16.20.2 或 172.16.20.0/24">
      </div>
      <div class="settings-row">
        <span class="settings-label">備註</span>
        <input class="settings-input" id="acl-page-note" placeholder="例：台北辦公室 AudioCodes SBC">
      </div>
      <div style="display:flex;gap:8px;align-items:center">
        <button class="btn primary" id="acl-page-submit-btn" onclick="aclPageSaveEntry()">💾 新增</button>
        <span id="acl-page-save-msg" style="font-size:12px;opacity:0;transition:opacity 0.3s"></span>
      </div>
      <div style="font-size:11px;color:var(--muted)">
        用途：內部 SBC/SIP Trunk 可能分佈在不同網段，僅靠 local-network-acl 的同網段自動信任無法涵蓋，
        於此明確列舉信任來源。新增/移除項目後，若下方顯示「待重啟」，需執行「立即重啟套用」才會生效。
      </div>
    </div>
  </div>`;
}

function aclPageOpenEditor(cidr, note) {
  _aclPageEditingCidr = cidr || null;
  document.getElementById('acl-page-form-title').textContent = cidr ? `編輯信任 SBC：${cidr}` : '+ 新增信任 SBC';
  document.getElementById('acl-page-cidr').value = cidr || '';
  document.getElementById('acl-page-note').value = note || '';
  document.getElementById('acl-page-submit-btn').textContent = cidr ? '💾 儲存修改' : '💾 新增';
}

async function aclPageSaveEntry() {
  const msg  = document.getElementById('acl-page-save-msg');
  const cidr = document.getElementById('acl-page-cidr').value.trim();
  const note = document.getElementById('acl-page-note').value.trim();
  if (!cidr) { alert('請輸入 IP 或 CIDR'); return; }

  if (msg) { msg.textContent = '儲存中...'; msg.style.opacity = '1'; msg.style.color = 'var(--yellow)'; }

  const isEdit = !!_aclPageEditingCidr;
  const url    = isEdit
    ? `${API_BASE}/api/acl/trusted-sbc/${encodeURIComponent(_aclPageEditingCidr)}`
    : `${API_BASE}/api/acl/trusted-sbc`;

  try {
    const res  = await fetch(url, {
      method: isEdit ? 'PUT' : 'POST',
      headers: { 'Content-Type': 'application/json', 'Authorization': `Bearer ${getToken()}` },
      body: JSON.stringify({ cidr, note }),
    });
    const data = await res.json();
    if (res.ok && data.ok) {
      _aclPageEditingCidr = null;
      _aclPageLoad();
    } else {
      if (msg) { msg.textContent = `✗ ${data.detail || '儲存失敗'}`; msg.style.color = 'var(--red)'; }
    }
  } catch (e) {
    if (msg) { msg.textContent = `✗ ${e.message}`; msg.style.color = 'var(--red)'; }
  }
}

async function aclPageDeleteEntry(cidr) {
  if (!confirm(
    `確定要移除信任來源「${cidr}」？\n\n` +
    `⚠️ 移除後該來源會從清單消失，但 FreeSWITCH 記憶體中的 ACL 判斷「不會」立即改變，` +
    `仍會被視為信任來源，直到重啟服務為止。\n如需立即撤銷信任，移除後請執行「立即重啟套用」。`
  )) return;

  try {
    const res = await fetch(`${API_BASE}/api/acl/trusted-sbc/${encodeURIComponent(cidr)}`, {
      method: 'DELETE',
      headers: { 'Authorization': `Bearer ${getToken()}` },
    });
    let data;
    try { data = await res.json(); }
    catch { alert(`移除失敗：伺服器錯誤（HTTP ${res.status}）`); return; }

    if (res.ok && data.ok) {
      if (data.still_active_until_restart) {
        alert(`已從清單移除「${cidr}」，但目前仍在 FreeSWITCH 記憶體中生效，需重啟服務才會真正撤銷信任。`);
      }
      _aclPageLoad();
    } else {
      alert(`移除失敗：${data.detail || '未知錯誤'}`);
    }
  } catch (e) {
    alert(`移除失敗：${e.message}`);
  }
}

async function aclPageRestart(confirmed = false) {
  if (!confirmed && !confirm('確定要重啟 FreeSWITCH 服務嗎？\n這會中斷所有進行中的通話，請確認已安排維護時間。')) return;

  try {
    const res  = await fetch(`${API_BASE}/api/acl/apply-restart`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'Authorization': `Bearer ${getToken()}` },
      body: JSON.stringify({ confirm: confirmed }),
    });
    const data = await res.json();
    const detailText = Array.isArray(data.detail)
      ? data.detail.map(d => d.msg || JSON.stringify(d)).join('; ')
      : (data.detail || '未知錯誤');

    if (res.status === 409) {
      if (confirm(detailText)) return aclPageRestart(true);
      return;
    }
    if (res.ok && data.ok) {
      alert(`✓ 重啟指令已送出（中斷了 ${data.active_calls_dropped} 通通話），約 15-30 秒後自動重新整理狀態`);
      setTimeout(() => _aclPageLoad(), 20000);
    } else {
      alert(`✗ 重啟失敗：${detailText}`);
    }
  } catch (e) {
    alert(`✗ 重啟失敗：${e.message}`);
  }
}
