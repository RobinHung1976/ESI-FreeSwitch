// backup.js — 備份管理頁面

let _backupNode = 'backup_settings'; // 預設顯示備份設定

const BACKUP_TREE = [
  { id: 'backup_settings', icon: '⚙', label: '備份設定' },
  { id: 'backup_list',     icon: '🗄', label: '備份清單' },
];

async function renderBackupPage(node) {
  if (node) _backupNode = node;
  const cfg = loadSettings();

  // 左側樹狀選單
  const treeHtml = BACKUP_TREE.map(item => `
    <div class="stree-item ${_backupNode === item.id ? 'active' : ''}"
         style="padding-left:16px"
         onclick="renderBackupPage('${item.id}')">
      <span class="stree-icon">${item.icon}</span>
      <span class="stree-label">${item.label}</span>
    </div>`).join('');

  const contentHtml = await backupPageContent(_backupNode, cfg);

  document.getElementById('mainContent').innerHTML = `
  <div style="display:flex;height:calc(100vh - 120px);gap:0">

    <!-- 左側選單 -->
    <div style="width:220px;min-width:220px;background:var(--panel);border:1px solid var(--border);
                border-radius:8px 0 0 8px;overflow-y:auto;flex-shrink:0">
      <div style="padding:14px 16px;border-bottom:1px solid var(--border);
                  font-size:11px;font-weight:700;color:var(--muted);
                  letter-spacing:.1em;text-transform:uppercase">備份管理</div>
      <div class="stree-nav">${treeHtml}</div>
    </div>

    <!-- 右側內容 -->
    <div style="flex:1;background:var(--panel);border:1px solid var(--border);
                border-left:none;border-radius:0 8px 8px 0;
                display:flex;flex-direction:column;overflow:hidden" id="backup-right-panel">
      ${contentHtml}
    </div>
  </div>`;
}

async function backupPageContent(node, cfg) {
  switch(node) {

    // ── 備份設定 ──────────────────────────────────────────────────────────
    case 'backup_settings': return `
      <div class="settings-header">
        <span class="settings-icon">⚙</span>
        <span class="settings-title">備份設定</span>
      </div>
      <div class="settings-body" style="flex:1;overflow-y:auto">

        <div class="settings-row">
          <span class="settings-label">備份存放路徑</span>
          <input class="settings-input" data-setting="backup_path" type="text"
            value="${cfg.backup_path || '/opt/fs-dashboard/backups'}"
            style="max-width:360px" placeholder="/opt/fs-dashboard/backups" />
        </div>
        <div class="settings-row">
          <span class="settings-label">備份保留天數</span>
          <input class="settings-input" data-setting="backup_retain_days" type="number"
            value="${cfg.backup_retain_days || 30}" min="1" max="365" style="max-width:80px" />
          <span style="font-size:12px;color:var(--muted)">天（超過自動刪除）</span>
        </div>
        <div class="settings-row">
          <span class="settings-label">每日自動備份</span>
          <label class="settings-toggle">
            <input type="checkbox" data-setting="backup_auto_enabled"
              ${cfg.backup_auto_enabled ? 'checked' : ''}>
            <span class="toggle-slider"></span>
          </label>
		  <input class="settings-input" data-setting="backup_auto_time" type="time"
			value="${cfg.backup_auto_time || '00:01'}"
			style="max-width:180px;margin-left:8px" />
          <span style="font-size:12px;color:var(--muted)">每日 00:01 自動備份 Dashboard 設定</span>
        </div>
        <div class="settings-hint">
          📁 NAS 請先在 OS 層執行 <code>mount</code>，再填入掛載路徑即可。<br>
          📦 FreeSwitch 套件備份（含 .deb）需下載套件，約需 1–5 分鐘，請耐心等候。
        </div>

        <hr class="settings-divider">

        <!-- 立即備份 -->
        <div style="font-size:12px;font-weight:700;color:var(--label);margin-bottom:12px">立即備份</div>
        <div style="display:flex;gap:8px;flex-wrap:wrap;margin-bottom:12px">
          <button class="btn primary" onclick="backupRun('config')">⚙ 備份 Dashboard 設定</button>
          <button class="btn" style="border-color:var(--yellow);color:var(--yellow)"
            onclick="backupRun('packages')">📦 備份 FreeSwitch 套件（含 .deb）</button>
          <button class="btn" onclick="backupRun('both')">🔄 兩者都備份</button>
        </div>
        <div id="backup-progress" style="display:none;padding:8px 12px;background:var(--panel2);
             border:1px solid var(--border);border-radius:5px;font-size:12px;
             color:var(--muted);margin-bottom:8px">⏳ 備份執行中，請稍候...</div>
        <div id="backup-result" style="margin-bottom:16px"></div>

        <hr class="settings-divider">

        <!-- 還原（情境A：Server 運行中） -->
        <div style="font-size:12px;font-weight:700;color:var(--label);margin-bottom:8px">還原設定（Server 運行中）</div>
        <div class="settings-hint" style="margin-bottom:10px">
          上傳 <code>fs-dashboard-config-*.tar.gz</code> 即可覆蓋還原 FreeSwitch 設定。<br>
          ⚠ 整台 Server 損毀時，請使用備份包內的 <code>restore_freeswitch.sh</code> +
          <code>restore_dashboard.sh</code> 在新機 CLI 執行。
        </div>
        <div style="display:flex;gap:10px;align-items:center;flex-wrap:wrap">
          <input type="file" id="backup-restore-input" accept=".tar.gz"
            style="display:none" onchange="backupRestoreUpload(this)" />
          <button class="btn" onclick="document.getElementById('backup-restore-input').click()">
            📂 選擇備份檔上傳還原
          </button>
          <span id="backup-restore-filename" style="font-size:12px;color:var(--muted)"></span>
        </div>
        <div id="backup-restore-result" style="margin-top:8px"></div>

      </div>
      <div class="settings-save-bar">
        <button class="btn primary" onclick="backupSaveSettings()">💾 儲存設定</button>
        <span id="settings-saved-msg" class="settings-saved-msg" style="margin-left:auto">✓ 已儲存</span>
      </div>`;

    // ── 備份清單 ──────────────────────────────────────────────────────────
    case 'backup_list': {
      let backups = [];
      try {
        const data = await apiFetch('/api/backup/list');
        backups = data.backups || [];
      } catch(e) { backups = []; }

      const fmtSize = mb => mb < 1 ? `${(mb*1024).toFixed(0)} KB` : `${mb.toFixed(1)} MB`;

      // 分類：設定備份 & 套件備份
      const configBaks  = backups.filter(b => b.type === 'config');
      const packageBaks = backups.filter(b => b.type === 'packages');

      function buildTable(list, emptyMsg) {
        if (!list.length) return `
          <tr><td colspan="4"
            style="padding:24px;text-align:center;color:var(--muted)">${emptyMsg}</td></tr>`;
        return list.map(b => `
          <tr style="border-bottom:1px solid var(--border)">
            <td style="padding:10px 14px;font-size:12px;color:var(--muted);white-space:nowrap">${b.mtime}</td>
            <td style="padding:10px 14px;font-family:'JetBrains Mono',monospace;font-size:11px;
                       color:var(--label);word-break:break-all">${b.filename}</td>
            <td style="padding:10px 14px;text-align:right;font-size:12px;
                       color:var(--muted);white-space:nowrap">${fmtSize(b.size_mb)}</td>
            <td style="padding:10px 14px;white-space:nowrap">
              <button class="btn" style="font-size:11px;padding:3px 10px"
                onclick="backupDownload('${b.filename}')">⬇ 下載</button>
              <button class="btn danger" style="font-size:11px;padding:3px 10px;margin-left:4px"
                onclick="backupDelete('${b.filename}', this)">🗑</button>
            </td>
          </tr>`).join('');
      }

      const thead = `
        <thead>
          <tr style="background:var(--panel2)">
            <th style="padding:8px 14px;text-align:left;font-size:12px;color:var(--label);font-weight:600;white-space:nowrap">時間</th>
            <th style="padding:8px 14px;text-align:left;font-size:12px;color:var(--label);font-weight:600">檔名</th>
            <th style="padding:8px 14px;text-align:right;font-size:12px;color:var(--label);font-weight:600;white-space:nowrap">大小</th>
            <th style="padding:8px 14px;text-align:left;font-size:12px;color:var(--label);font-weight:600">操作</th>
          </tr>
        </thead>`;

      return `
      <div class="settings-header">
        <span class="settings-icon">🗄</span>
        <span class="settings-title">備份清單</span>
        <span style="font-size:12px;color:var(--muted);margin-left:auto;margin-right:8px">共 ${backups.length} 個備份</span>
        <button class="btn" style="font-size:11px" onclick="renderBackupPage('backup_list')">↺ 重新整理</button>
      </div>
      <div style="flex:1;overflow-y:auto;padding:16px">

        <!-- ⚙ 設定備份 -->
        <div style="display:flex;align-items:center;gap:10px;margin-bottom:8px">
          <span style="font-size:12px;font-weight:700;color:var(--label)">⚙ Dashboard 設定備份</span>
          <span style="font-size:11px;color:var(--muted)">${configBaks.length} 個</span>
          <button class="btn primary" style="font-size:11px;margin-left:auto"
            onclick="backupRun('config').then(()=>setTimeout(()=>renderBackupPage('backup_list'),1000))">
            + 立即備份
          </button>
        </div>
        <div style="border:1px solid var(--border);border-radius:6px;overflow:hidden;margin-bottom:20px">
          <table style="width:100%;border-collapse:collapse">
            ${thead}
            <tbody>${buildTable(configBaks, '尚無設定備份')}</tbody>
          </table>
        </div>

        <!-- 📦 套件備份 -->
        <div style="display:flex;align-items:center;gap:10px;margin-bottom:8px">
          <span style="font-size:12px;font-weight:700;color:var(--label)">📦 FreeSwitch 套件備份（含 .deb）</span>
          <span style="font-size:11px;color:var(--muted)">${packageBaks.length} 個</span>
          <button class="btn" style="font-size:11px;margin-left:auto;border-color:var(--yellow);color:var(--yellow)"
            onclick="backupRun('packages').then(()=>setTimeout(()=>renderBackupPage('backup_list'),1000))">
            + 立即備份
          </button>
        </div>
        <div style="border:1px solid var(--border);border-radius:6px;overflow:hidden">
          <table style="width:100%;border-collapse:collapse">
            ${thead}
            <tbody>${buildTable(packageBaks, '尚無套件備份')}</tbody>
          </table>
        </div>

      </div>`;
    }

    default: return `<div style="padding:40px;text-align:center;color:var(--muted)">請從左側選單選擇</div>`;
  }
}

// 備份設定儲存（同步 localStorage + 後端）
async function backupSaveSettings() {
  saveSettings();
  const cfg = loadSettings();
  try {
    await apiFetch('/api/settings', {
      method:  'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        backup_path:         cfg.backup_path        || '/opt/fs-dashboard/backups',
        backup_retain_days:  parseInt(cfg.backup_retain_days) || 30,
        backup_auto_enabled: !!cfg.backup_auto_enabled,
		backup_auto_time:    cfg.backup_auto_time    || '00:01',
      }),
    });
    const msg = document.getElementById('settings-saved-msg');
    if (msg) { msg.style.opacity = '1'; setTimeout(() => msg.style.opacity = '0', 2500); }
  } catch(e) {
    alert('儲存失敗：' + e.message);
  }
}

function downloadFile(path) {
  const url = `${API_BASE}/api/download?path=${encodeURIComponent(path)}&token=${encodeURIComponent(getToken())}`;
  const a   = document.createElement('a');
  a.href     = url;
  a.download = path.split('/').pop();
  document.body.appendChild(a);
  a.click();
  document.body.removeChild(a);
}

async function listAndDownload(dirPath) {
  const browser  = document.getElementById('dir-browser');
  const pathEl   = document.getElementById('dir-browser-path');
  const listEl   = document.getElementById('dir-browser-list');
  if (!browser || !listEl) return;

  browser.style.display = 'block';
  if (pathEl) pathEl.textContent = dirPath;
  listEl.innerHTML = '<span style="color:var(--muted);font-size:12px">載入中...</span>';

  // 透過 ESL 執行 ls 指令取得檔案清單
  const res = await runESLCommand(`system ls ${dirPath}`);
  const output = (res && res.result) ? res.result : '';

  const files = output.split('\n')
    .map(f => f.trim())
    .filter(f => f && !f.startsWith('total') && f !== '.' && f !== '..');

  if (files.length === 0) {
    listEl.innerHTML = '<span style="color:var(--muted);font-size:12px">目錄為空或無法存取</span>';
    return;
  }

  listEl.innerHTML = files.map(f => {
    const fullPath = dirPath.replace(/\/$/, '') + '/' + f;
    const ext = f.split('.').pop().toLowerCase();
    const icon = ext === 'xml' ? '📄' : ext === 'csv' ? '📊' : ext === 'log' ? '📋' : ext === 'wav' ? '🎵' : '📁';
    return `
    <div style="display:flex;align-items:center;gap:6px;background:var(--panel2);
                border:1px solid var(--border);border-radius:4px;padding:6px 10px">
      <span style="font-size:13px">${icon}</span>
      <span style="font-size:12px;color:var(--label);flex:1;word-break:break-all">${f}</span>
      <button class="btn" style="font-size:11px;padding:2px 8px;flex-shrink:0"
        onclick="downloadFile('${fullPath}')">↓</button>
    </div>`;
  }).join('');
}

async function loadCDRCount() {
  const el = document.getElementById('cdr-count');
  if (!el) return;
  const data = await apiFetch('/api/cdr?limit=1&offset=0');
  if (data) el.textContent = `${data.total} 筆`;
}

async function testConnection() {
  const resultEl = document.getElementById('conn-test-result');
  if (resultEl) resultEl.textContent = '測試中...';
  const res = await runESLCommand('status');
  if (resultEl) {
    if (res && res.result && res.result.includes('ready')) {
      resultEl.style.color = 'var(--green)';
      resultEl.textContent = '✓ 連線正常';
    } else {
      resultEl.style.color = 'var(--red)';
      resultEl.textContent = '✗ 連線失敗';
    }
  }
}

async function eslCmd(cmd) {
  const res = await runESLCommand(cmd);
  alert(`執行結果：\n${res && res.result ? res.result.substring(0,300) : '無回應'}`);
}

function openDialplanEditor() {
  alert('Dialplan 編輯器：\n\n請直接編輯 /etc/freeswitch/dialplan/ 目錄下的 XML 檔案，\n修改後點擊「Reload XML」套用。\n\n建議使用 SSH 連線進行編輯。');
}

async function loadDialplan() {
  switchPage('settings');
}

