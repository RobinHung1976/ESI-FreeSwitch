// settings-vars.js — 系統設定頁（含全域變數 vars.xml、XML 編輯器殼層、CDR 歸檔管理）

// ── 設定頁面 ──────────────────────────────────────────────────────────────────

// 設定預設值
const SETTINGS_DEFAULTS = {
  fs_host:             '192.168.100.209',
  fs_port:             '8055',
  fs_password:         'FSPyAdmin',
  cdr_path:            '/var/log/freeswitch/cdr-csv/Master.csv',
  cdr_retain_days:     '30',
  cdr_summary_retain_days: '730',
  log_retain_days:     '30',
  reg_log_retain_days: '90',
  ui_language:         'zh-TW',
  backup_path:         '/opt/fs-dashboard/backups',
  backup_retain_days:  '30',
  backup_auto_enabled: false,
  backup_auto_time:    '00:01',
};

function loadSettings() {
  const saved = localStorage.getItem('esi_fs_settings');
  return saved ? { ...SETTINGS_DEFAULTS, ...JSON.parse(saved) } : { ...SETTINGS_DEFAULTS };
}

function saveSettings() {
  // 設定頁採樹狀結構，DOM 中同時只會渲染「目前選中分頁」的 [data-setting] 欄位。
  // 必須先合併既有設定，再覆蓋目前頁面送出的欄位，否則會把其他分頁已儲存的值清掉。
  const cfg = loadSettings();
  document.querySelectorAll('[data-setting]').forEach(el => {
    cfg[el.dataset.setting] = el.type === 'checkbox' ? el.checked : el.value;
  });
  localStorage.setItem('esi_fs_settings', JSON.stringify(cfg));

  // 顯示儲存成功訊息
  const msg = document.getElementById('settings-saved-msg');
  if (msg) { msg.style.opacity = '1'; setTimeout(() => msg.style.opacity = '0', 2500); }
}

async function saveSettingsWithBackend() {
  // 先存 localStorage
  saveSettings();

  // 把需要後端保存的設定同步到 server
  const cfg = loadSettings();
  await apiFetch('/api/settings', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      log_retain_days:     parseInt(cfg.log_retain_days)     || 30,
      reg_log_retain_days: parseInt(cfg.reg_log_retain_days) || 90,
      cdr_retain_days:     parseInt(cfg.cdr_retain_days)     || 30,
      cdr_summary_retain_days: parseInt(cfg.cdr_summary_retain_days) || 730,
      backup_path:         cfg.backup_path                   || '/opt/fs-dashboard/backups',
      backup_retain_days:  parseInt(cfg.backup_retain_days)  || 30,
      backup_auto_enabled: !!cfg.backup_auto_enabled,
    })
  });
}

// ── ISO 3166-1 alpha-2 國碼對照（常用國家，非完整清單）─────────────────────
const ISO_COUNTRY_MAP = {
  TW: '台灣', US: '美國', CN: '中國', JP: '日本', KR: '韓國', HK: '香港', MO: '澳門',
  SG: '新加坡', MY: '馬來西亞', TH: '泰國', VN: '越南', PH: '菲律賓', ID: '印尼', IN: '印度',
  GB: '英國', DE: '德國', FR: '法國', IT: '義大利', ES: '西班牙', NL: '荷蘭', CH: '瑞士',
  AU: '澳洲', NZ: '紐西蘭', CA: '加拿大', BR: '巴西', MX: '墨西哥', RU: '俄羅斯',
  AE: '阿拉伯聯合大公國', SA: '沙烏地阿拉伯', ZA: '南非', EG: '埃及',
};

function checkCountryCode(value, inputKey) {
  const el = document.getElementById(`country-check-${inputKey}`);
  if (!el) return;
  const code = (value || '').trim().toUpperCase();
  if (!code) {
    el.innerHTML = '';
    return;
  }
  const name = ISO_COUNTRY_MAP[code];
  if (name) {
    el.innerHTML = `<span style="color:var(--green)">✓ ${code} — ${name}</span>`;
  } else {
    el.innerHTML = `<span style="color:var(--yellow)">✗ 非標準 ISO 國碼（不在常用清單中）</span>
      <span style="color:var(--muted)">— 仍可儲存，僅供參考確認是否打錯</span>`;
  }
}

// ── hold_music 選擇音檔彈窗（music + custom 分類）────────────────────────
async function openHoldMusicPicker(varKey) {
  document.body.insertAdjacentHTML('beforeend', _dpModalHtml('🔊 選擇保留音樂',
    `<div id="hm-picker-body" style="min-height:200px">載入中...</div>`));

  const [musicRes, customRes] = await Promise.all([
    apiFetch('/api/sounds/list?category=' + encodeURIComponent('/usr/share/freeswitch/sounds/music')),
    apiFetch('/api/sounds/list?category=custom'),
  ]);

  const musicSounds  = (musicRes && musicRes.sounds) ? musicRes.sounds : [];
  const customSounds = (customRes && customRes.sounds) ? customRes.sounds : [];

  const renderGroup = (title, list) => {
    if (list.length === 0) return '';
    const rows = list.map(s => `
      <div style="display:flex;align-items:center;gap:10px;padding:8px 12px;border-bottom:1px solid var(--border)">
        <button class="btn" style="padding:3px 10px;font-size:12px;flex-shrink:0"
          onclick="_hmPickerPlay('${s.path.replace(/'/g, "\\'")}')">▶</button>
        <span style="font-size:13px;color:var(--text);flex:1;word-break:break-all">${s.filename}</span>
        <button class="btn primary" style="font-size:11px;padding:3px 10px;flex-shrink:0"
          onclick="_hmPickerSelect('${varKey}', '${s.path.replace(/'/g, "\\'")}')">選用</button>
      </div>`).join('');
    return `
      <div style="padding:10px 12px 4px;font-size:11px;font-weight:700;color:var(--label);
                  text-transform:uppercase;letter-spacing:1px">${title}</div>
      ${rows}`;
  };

  const body = document.getElementById('hm-picker-body');
  if (!body) return;

  const listHtml = renderGroup('保留音樂（MOH）', musicSounds) + renderGroup('自訂音檔', customSounds);
  body.innerHTML = `
    <div style="border:1px solid var(--border);border-radius:6px;max-height:50vh;overflow-y:auto">
      ${listHtml || '<div style="padding:30px;text-align:center;color:var(--muted)">沒有可用的音檔</div>'}
    </div>
    <audio id="hm-picker-audio" style="width:100%;margin-top:12px"></audio>
    <div style="margin-top:10px;font-size:11px;color:var(--muted)">
      💡 也可以直接在文字框手動輸入 <code>local_stream://moh</code> 這類特殊路徑
    </div>`;
}

function _hmPickerPlay(path) {
  const audio = document.getElementById('hm-picker-audio');
  if (!audio) return;
  audio.src = `${API_BASE}/api/sounds/stream?path=${encodeURIComponent(path)}`;
  audio.play().catch(() => {});
}

function _hmPickerSelect(varKey, path) {
  const input = document.getElementById(`varinput-${varKey}`);
  if (input) input.value = path;
  dpCloseModal();
}

function toggleVarPasswordVisibility(key, btn) {
  const input = document.getElementById(`varinput-${key}`);
  if (!input) return;
  const isHidden = input.type === 'password';
  input.type = isHidden ? 'text' : 'password';
  if (btn) btn.textContent = isHidden ? '🙈' : '👁';
}

async function saveVarsPage() {
  const inputs = document.querySelectorAll('[data-var-key]');
  const updates = {};
  inputs.forEach(el => { updates[el.dataset.varKey] = el.value; });

  if (Object.keys(updates).length === 0) return;

  // 高風險欄位（密碼、網域）需二次確認
  const riskyKeys = ['default_password', 'domain'];
  const touchedRisky = riskyKeys.filter(k => k in updates);
  if (touchedRisky.length > 0) {
    const labelMap = { default_password: '預設分機密碼', domain: '預設網域 (SIP Domain)' };
    const names = touchedRisky.map(k => labelMap[k] || k).join('、');
    if (!confirm(`即將變更「${names}」，這會影響所有分機的註冊/認證行為。確定要儲存嗎？`)) {
      return;
    }
  }

  const msg = document.getElementById('vars-saved-msg');
  if (msg) { msg.textContent = '儲存中...'; msg.style.color = 'var(--yellow)'; }

  const res = await apiFetch('/api/vars', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(updates)
  });

  if (res && res.ok) {
    if (msg) {
      msg.textContent = `✓ 已儲存並 reloadxml（備份：${(res.backup||'').split('/').pop()}）`;
      msg.style.color = 'var(--green)';
    }
  } else {
    if (msg) {
      msg.textContent = `✗ 儲存失敗：${(res && res.detail) || '未知錯誤'}`;
      msg.style.color = 'var(--red)';
    }
  }
}

async function rotateCDRNow() {
  const msg = document.getElementById('cdr-arch-msg');
  if (msg) msg.textContent = '執行中...';
  try {
    const res = await fetch(`${API_BASE}/api/cdr/rotate`, {
      method: 'POST',
      headers: { 'Authorization': `Bearer ${getToken()}` },
    });
    const data = await res.json();
    if (res.ok && data.ok) {
      if (msg) msg.textContent = `✓ 已歸檔 ${data.file}`;
      setTimeout(() => renderSettings('cdr'), 1000);
    } else {
      if (msg) msg.textContent = `✗ ${data.detail || data.error || '歸檔失敗'}`;
    }
  } catch(e) {
    if (msg) msg.textContent = '✗ 連線錯誤';
  }
}

async function deleteCDRArchive(filename) {
  if (!confirm(`確定刪除 ${filename}？`)) return;
  try {
    const res = await fetch(`${API_BASE}/api/cdr/archive/${filename}`, {
      method: 'DELETE',
      headers: { 'Authorization': `Bearer ${getToken()}` },
    });
    if (res.ok) {
      renderSettings('cdr');
    } else {
      const data = await res.json().catch(() => ({}));
      alert('刪除失敗：' + (data.detail || '未知錯誤'));
    }
  } catch(e) {
    alert('刪除失敗：連線錯誤');
  }
}

let _settingsNode = 'connection'; // 目前選中的設定節點

// 設定樹狀結構定義
const SETTINGS_TREE = [
  {
    id: 'connection', icon: '🔌', label: '連線設定', children: []
  },
  {
    id: 'cdr', icon: '📋', label: 'CDR 設定', children: []
  },
  {
    id: 'log_retain', icon: '🗒', label: '日誌保留設定', children: []
  },
  {
    id: 'ui', icon: '🖥', label: '介面設定', children: []
  },
  {
    id: 'vars', icon: '🔧', label: '全域變數', children: []
  },
  {
    id: 'dialplan_paths', icon: '📁', label: '檔案路徑', children: []
  },
];  // backup 已獨立為 page；Dialplan 相關管理已整併至左側「Dialplan 路由設定」，
   // 重載指令已搬到 ESL 終端機頁面，不在 settings tree

async function renderSettings(node) {
  if (node) _settingsNode = node;
  const cfg = loadSettings();

  // 產生樹狀選單 HTML
  function treeItem(item, depth=0) {
    const isActive = _settingsNode === item.id;
    const hasChildren = item.children && item.children.length > 0;
    const isParentActive = hasChildren && item.children.some(c => c.id === _settingsNode);
    return `
      <div class="stree-item ${isActive?'active':''} ${isParentActive?'parent-active':''}"
           style="padding-left:${16 + depth*16}px"
           onclick="renderSettings('${item.id}')">
        <span class="stree-icon">${item.icon}</span>
        <span class="stree-label">${item.label}</span>
        ${hasChildren ? `<span class="stree-arrow">${isParentActive||isActive?'▾':'▸'}</span>` : ''}
      </div>
      ${hasChildren ? item.children.map(c => treeItem(c, depth+1)).join('') : ''}`;
  }

  const treeHtml = SETTINGS_TREE.map(item => treeItem(item)).join('');

  // 右側內容依節點渲染
  const contentHtml = await settingsContent(_settingsNode, cfg);

  document.getElementById('mainContent').innerHTML = `
  <div style="display:flex;height:calc(100vh - 120px);gap:0">

    <!-- 左側樹狀選單 -->
    <div style="width:250px;min-width:250px;background:var(--panel);border:1px solid var(--border);
                border-radius:6px;overflow-y:auto;flex-shrink:0">
      <div style="padding:14px 16px;border-bottom:1px solid var(--border);
                  font-family:'Syne',sans-serif;font-weight:700;font-size:15px;color:#fff;
                  background:rgba(66,165,245,0.06)">
        ⚙ 系統設定
      </div>
      <div class="stree">${treeHtml}</div>
    </div>

    <!-- 右側內容框架 -->
    <div style="flex:1;min-width:0;background:var(--panel);border:1px solid var(--border);
                border-radius:6px;overflow-y:auto;margin-left:12px;display:flex;flex-direction:column">
      ${contentHtml}
    </div>

  </div>`;

  // 頁面 render 後觸發需要即時載入的資料
  if (_settingsNode === 'cdr') loadCDRCount();
}

async function settingsContent(node, cfg) {
  switch(node) {

    case 'connection': return `
      <div class="settings-header">
        <span class="settings-icon">🔌</span>
        <span class="settings-title">連線設定</span>
      </div>
      <div class="settings-body" style="flex:1">
        <div class="settings-row">
          <span class="settings-label">FreeSwitch IP</span>
          <input class="settings-input" data-setting="fs_host" value="${cfg.fs_host}" placeholder="192.168.100.209" />
        </div>
        <div class="settings-row">
          <span class="settings-label">ESL Port</span>
          <input class="settings-input" data-setting="fs_port" value="${cfg.fs_port}" placeholder="8055" style="max-width:120px" />
        </div>
        <div class="settings-row">
          <span class="settings-label">ESL 密碼</span>
          <input class="settings-input" data-setting="fs_password" type="password" value="${cfg.fs_password}" placeholder="FSPyAdmin" />
        </div>
        <div class="settings-row">
          <span class="settings-label">後端 API 位址</span>
          <input class="settings-input" value="${API_BASE}" readonly style="color:var(--muted)" />
        </div>
        <div class="settings-hint" style="padding:0 0 8px">
          ⚠ 連線設定變更後需重啟後端 <code style="color:var(--accent-bright)">server.py</code> 才會生效
        </div>
      </div>
      <div class="settings-save-bar">
        <button class="btn primary" onclick="saveSettings()">💾 儲存設定</button>
        <button class="btn" onclick="testConnection()">🔗 測試連線</button>
        <span id="conn-test-result" style="font-size:12px;color:var(--muted)"></span>
        <span id="settings-saved-msg" class="settings-saved-msg" style="margin-left:auto">✓ 已儲存</span>
      </div>`;

    case 'cdr': {
      const archData = await apiFetch('/api/cdr/archives');
      const files = (archData && archData.files) ? archData.files : [];
      const fileRows = files.length === 0
        ? `<div style="padding:24px;text-align:center;color:var(--muted)">尚無歸檔檔案</div>`
        : files.map(f => `
          <div style="display:flex;align-items:center;gap:12px;padding:10px 16px;border-bottom:1px solid var(--border)">
            <span style="font-size:13px;flex:1;color:var(--text)">📄 ${f.filename}</span>
            <span style="font-size:12px;color:var(--muted)">${(f.size/1024).toFixed(1)} KB</span>
            <button class="btn danger" style="font-size:11px;padding:3px 10px"
              onclick="deleteCDRArchive('${f.filename}')">刪除</button>
          </div>`).join('');
      return `
      <div class="settings-header">
        <span class="settings-icon">📋</span>
        <span class="settings-title">CDR 設定</span>
      </div>
      <div class="settings-body" style="flex:1;overflow-y:auto">
        <div class="settings-row">
          <span class="settings-label">Master.csv 路徑</span>
          <input class="settings-input" data-setting="cdr_path" value="${cfg.cdr_path}" />
        </div>
        <div class="settings-row">
          <span class="settings-label">CDR 明細保留天數</span>
          <input class="settings-input" data-setting="cdr_retain_days" type="number"
            value="${cfg.cdr_retain_days}" min="1" max="365" style="max-width:80px" />
          <span style="font-size:12px;color:var(--muted)">天（逐通明細，含未接通清單。每日 00:00 自動歸檔，超過自動刪除）</span>
        </div>
        <div class="settings-row">
          <span class="settings-label">CDR 統計彙總保留天數</span>
          <input class="settings-input" data-setting="cdr_summary_retain_days" type="number"
            value="${cfg.cdr_summary_retain_days}" min="30" max="3650" style="max-width:80px" />
          <span style="font-size:12px;color:var(--muted)">天（每日彙總統計，不含逐通明細，佔用空間極小，可設較長）</span>
        </div>
        <div class="settings-hint">
          通話統計報表已改用 SQLite：超過「明細保留天數」的日期仍可查詢總量／接通率／每日趨勢圖（來自每日彙總），
          但無法再看到該日的逐通未接通清單（因為明細已被清除）。
        </div>
        <hr class="settings-divider">
        <div class="settings-row">
          <span class="settings-label">目前筆數</span>
          <span id="cdr-count" style="color:var(--accent-bright);font-size:14px">載入中...</span>
          <button class="btn" style="margin-left:12px" onclick="loadCDRCount()">重新統計</button>
        </div>
        <div class="settings-hint">CDR 路徑變更需重啟後端才會生效</div>
        <hr class="settings-divider">
        <div style="display:flex;align-items:center;gap:10px;padding:8px 0 12px">
          <span style="font-weight:600;color:var(--label)">歸檔管理</span>
          <span style="font-size:12px;color:var(--muted)">共 ${files.length} 個檔案</span>
          <button class="btn primary" style="margin-left:auto" onclick="rotateCDRNow()">⬇ 立即歸檔今日 CDR</button>
          <button class="btn" onclick="renderSettings('cdr')">↺ 重新整理</button>
          <span id="cdr-arch-msg" style="font-size:12px;color:var(--muted)"></span>
        </div>
        <div style="border:1px solid var(--border);border-radius:6px;overflow:hidden">
          ${fileRows}
        </div>
      </div>
      <div class="settings-save-bar">
        <button class="btn primary" onclick="saveSettingsWithBackend()">💾 儲存設定</button>
        <span id="settings-saved-msg" class="settings-saved-msg" style="margin-left:auto">✓ 已儲存</span>
      </div>`;
    }

    case 'log_retain': return `
      <div class="settings-header">
        <span class="settings-icon">🗒</span>
        <span class="settings-title">日誌保留設定</span>
      </div>
      <div class="settings-body" style="flex:1">
        <div class="settings-row">
          <span class="settings-label">日誌保留天數</span>
          <input class="settings-input" data-setting="log_retain_days" type="number"
            value="${cfg.log_retain_days}" min="1" max="365" style="max-width:80px" />
          <span style="font-size:12px;color:var(--muted)">天（每日 00:00 自動刪除超過天數的日誌）</span>
        </div>
        <div class="settings-row">
          <span class="settings-label">登錄記錄保留天數</span>
          <input class="settings-input" data-setting="reg_log_retain_days" type="number"
            value="${cfg.reg_log_retain_days}" min="1" max="3650" style="max-width:80px" />
          <span style="font-size:12px;color:var(--muted)">天（分機登入/登出記錄，2026-07-15 起改用 SQLite 持久化）</span>
        </div>
        <div class="settings-hint">
          系統每日 <strong>00:00:30</strong> 自動歸檔日誌並清除超過保留天數的舊檔。<br>
          日誌存放於 <code>/var/log/freeswitch/freeswitch-YYYY-MM-DD.log</code>
        </div>
      </div>
      <div class="settings-save-bar">
        <button class="btn primary" onclick="saveSettingsWithBackend()">💾 儲存設定</button>
        <span id="settings-saved-msg" class="settings-saved-msg" style="margin-left:auto">✓ 已儲存</span>
      </div>`;

    case 'ui': return `
      <div class="settings-header">
        <span class="settings-icon">🖥</span>
        <span class="settings-title">介面設定</span>
      </div>
      <div class="settings-body" style="flex:1">
        <div class="settings-row">
          <span class="settings-label">語言</span>
          <select class="settings-select" data-setting="ui_language" style="max-width:200px">
            <option value="zh-TW" ${cfg.ui_language==='zh-TW'?'selected':''}>繁體中文</option>
            <option value="zh-CN" ${cfg.ui_language==='zh-CN'?'selected':''}>简体中文</option>
            <option value="en"    ${cfg.ui_language==='en'?'selected':''}>English</option>
          </select>
        </div>
        <div class="settings-hint">
          📡 頁面狀態由 WebSocket 事件即時推播更新，無需輪詢刷新
        </div>
      </div>
      <div class="settings-save-bar">
        <button class="btn primary" onclick="saveSettings()">💾 儲存設定</button>
        <span id="settings-saved-msg" class="settings-saved-msg" style="margin-left:auto">✓ 已儲存</span>
      </div>`;

    case 'vars': {
      const varsData = await apiFetch('/api/vars');
      if (!varsData || varsData.detail) {
        return `
        <div class="settings-header">
          <span class="settings-icon">🔧</span>
          <span class="settings-title">全域變數</span>
        </div>
        <div style="padding:40px;text-align:center;color:var(--muted)">
          ⚠ 載入失敗${varsData && varsData.detail ? '：' + varsData.detail : ''}
        </div>`;
      }

      const rows = Object.entries(varsData).map(([key, v]) => {
        let inputHtml = '';
        if (v.type === 'bool') {
          inputHtml = `
            <select class="settings-select" data-var-key="${key}" style="max-width:160px">
              <option value="true"  ${v.value==='true'  ?'selected':''}>true（開啟）</option>
              <option value="false" ${v.value==='false' ?'selected':''}>false（關閉）</option>
            </select>`;
        } else if (v.type === 'select') {
          inputHtml = `
            <select class="settings-select" data-var-key="${key}" style="max-width:200px">
              ${(v.options||[]).map(o => `<option value="${o}" ${v.value===o?'selected':''}>${o}</option>`).join('')}
            </select>`;
        } else if (v.type === 'password') {
          inputHtml = `
            <div style="display:flex;gap:6px;align-items:center">
              <input class="settings-input" data-var-key="${key}" id="varinput-${key}"
                type="password"
                value="${(v.value||'').replace(/"/g,'&quot;')}" style="flex:1" />
              <button type="button" class="btn" style="font-size:11px;padding:4px 8px;flex-shrink:0"
                onclick="toggleVarPasswordVisibility('${key}', this)" title="顯示/隱藏">👁</button>
            </div>`;
        } else {
          let extra = '';
          if (key === 'hold_music') {
            extra = `
              <button type="button" class="btn" style="font-size:11px;padding:4px 8px;flex-shrink:0"
                onclick="openHoldMusicPicker('${key}')" title="從音檔庫選擇">🔊 選擇音檔</button>`;
          }
          inputHtml = `
            <div style="display:flex;gap:6px;align-items:center">
              <input class="settings-input" data-var-key="${key}" id="varinput-${key}"
                type="text" style="flex:1"
                value="${(v.value||'').replace(/"/g,'&quot;')}" />
              ${extra}
            </div>`;
        }
        return `
        <div class="settings-row" style="align-items:flex-start">
          <span class="settings-label" style="padding-top:8px">${v.label}</span>
          <div style="flex:1;max-width:340px">
            ${inputHtml}
            <code style="font-size:10px;color:var(--muted);display:block;margin-top:4px">${key}</code>
            ${v.warn ? `<div style="font-size:11px;color:var(--yellow);margin-top:4px">⚠ ${v.warn}</div>` : ''}
          </div>
        </div>`;
      }).join('');

      return `
      <div class="settings-header">
        <span class="settings-icon">🔧</span>
        <span class="settings-title">全域變數設定</span>
      </div>
      <div class="settings-body" style="flex:1">
        <div class="settings-hint" style="background:rgba(255,152,0,0.1);padding:10px;border-radius:4px;margin-bottom:14px">
          ⚠ 此頁僅開放編輯白名單內、可安全透過 <code>reloadxml</code> 套用的 vars.xml 變數；
          網路埠號、TLS、Codec 等需重啟服務的設定不開放於網頁編輯，請改用 SSH 修改。<br>
          儲存前會自動備份原檔（<code>vars.xml.bak.YYYYMMDD_HHMMSS</code>）。
        </div>
        ${rows || '<div style="padding:20px;text-align:center;color:var(--muted)">沒有可編輯的變數</div>'}
      </div>
      <div class="settings-save-bar">
        <button class="btn primary" onclick="saveVarsPage()">💾 儲存並套用</button>
        <span id="vars-saved-msg" style="margin-left:auto;font-size:12px"></span>
      </div>`;
    }

    // 內部保留節點：僅供 openVarsEditor() 借用 XML 編輯器殼層使用，
    // 不出現在 SETTINGS_TREE 選單中（Dialplan 檔案清單已整併至左側「Dialplan 路由設定」）
    case 'dialplan_list': {
      return `
      <!-- XML 編輯器 -->
      <div id="xml-editor-panel" style="display:flex;flex-direction:column;height:100%">
        <div class="settings-header" style="flex-shrink:0">
          <span class="settings-icon">✏</span>
          <span class="settings-title" id="xml-editor-title">XML 編輯器</span>
          <div style="margin-left:auto;display:flex;gap:8px;align-items:center">
            <span id="xml-save-msg" style="font-size:11px;color:var(--green);opacity:0;transition:opacity 0.3s"></span>
            <button class="btn" onclick="renderSettings('dialplan_paths')">← 返回檔案路徑</button>
            <button class="btn" onclick="reloadAfterSave()">↺ Reload XML</button>
            <button class="btn primary" onclick="saveXmlFile()">💾 儲存</button>
          </div>
        </div>
        <!-- 路徑顯示 -->
        <div style="padding:6px 16px;background:rgba(0,0,0,0.2);border-bottom:1px solid var(--border);
                    font-size:11px;color:var(--muted);flex-shrink:0">
          <span id="xml-editor-path"></span>
          <span id="xml-backup-info" style="color:var(--green);margin-left:16px"></span>
        </div>
        <!-- 工具列 -->
        <div style="padding:6px 16px;border-bottom:1px solid var(--border);display:flex;gap:8px;
                    flex-shrink:0;background:rgba(66,165,245,0.03)">
          <button class="btn" style="font-size:11px" onclick="xmlFormat()">⇥ 格式化</button>
          <button class="btn" style="font-size:11px" onclick="xmlFind()">🔍 搜尋</button>
          <span style="font-size:11px;color:var(--muted);align-self:center;margin-left:auto"
                id="xml-line-count"></span>
        </div>
        <!-- 編輯區 -->
        <div style="flex:1;display:flex;overflow:hidden;min-height:0">
          <!-- 行號 -->
          <div id="xml-line-nums" style="background:#0d1f35;color:var(--muted);font-family:'JetBrains Mono',monospace;
               font-size:12px;line-height:1.6;padding:12px 10px;text-align:right;
               min-width:50px;overflow:hidden;user-select:none;border-right:1px solid var(--border);
               white-space:pre"></div>
          <!-- textarea -->
          <textarea id="xml-editor-area"
            style="flex:1;background:#0d1f35;color:#e8f4ff;font-family:'JetBrains Mono',monospace;
                   font-size:12px;line-height:1.6;padding:12px;border:none;outline:none;
                   resize:none;tab-size:2;white-space:pre;overflow-wrap:normal;overflow-x:auto"
            oninput="updateLineNums()" onscroll="syncLineScroll()"
            onkeydown="handleEditorKey(event)"
            spellcheck="false"></textarea>
        </div>
      </div>`;
    }

    case 'dialplan_paths': return `
      <div class="settings-header">
        <span class="settings-icon">📁</span>
        <span class="settings-title">檔案路徑說明</span>
      </div>
      <div class="settings-body" style="flex:1">
        ${[
          {
            name: '系統變數',
            path: '/etc/freeswitch/',
            desc: 'vars.xml — 全域變數設定',
            files: [
              '/etc/freeswitch/vars.xml',
            ],
            editable: [
              '/etc/freeswitch/vars.xml',
            ]
          },
          {
            name: 'Dialplan XML',
            path: '/etc/freeswitch/dialplan/',
            desc: 'default.xml、public.xml 等',
            files: [
              '/etc/freeswitch/dialplan/default.xml',
              '/etc/freeswitch/dialplan/public.xml',
            ],
            editable: [
              '/etc/freeswitch/dialplan/default.xml',
              '/etc/freeswitch/dialplan/public.xml',
            ]
          },
          {
            name: '分機目錄',
            path: '/etc/freeswitch/directory/default/',
            desc: '每個分機一個 XML 檔案',
            files: []
          },
          {
            name: 'Gateway 設定',
            path: '/etc/freeswitch/sip_profiles/',
            desc: 'internal.xml、external.xml',
            files: [
              '/etc/freeswitch/sip_profiles/internal.xml',
              '/etc/freeswitch/sip_profiles/external.xml',
            ],
            editable: [
              '/etc/freeswitch/sip_profiles/internal.xml',
              '/etc/freeswitch/sip_profiles/external.xml',
            ]
          },
          {
            name: 'CDR CSV',
            path: '/var/log/freeswitch/cdr-csv/',
            desc: 'Master.csv 及各 domain CSV',
            files: [
              '/var/log/freeswitch/cdr-csv/Master.csv',
            ]
          },
          {
            name: '系統日誌',
            path: '/var/log/freeswitch/',
            desc: 'freeswitch.log',
            files: [
              '/var/log/freeswitch/freeswitch.log',
            ]
          },
          {
            name: '錄音檔案',
            path: '/var/lib/freeswitch/recordings/',
            desc: '通話錄音 WAV 檔',
            files: []
          },
          {
            name: '音樂保留',
            path: '/usr/share/freeswitch/sounds/',
            desc: 'MOH 及系統語音',
            files: []
          },
        ].map(item => `
          <div style="padding:12px 0;border-bottom:1px solid rgba(42,58,88,0.4)">
            <div style="display:flex;align-items:center;gap:10px;margin-bottom:6px">
              <span style="font-size:13px;color:#fff;font-weight:600;min-width:120px">${item.name}</span>
              <code style="font-size:12px;color:var(--accent-bright);background:rgba(66,165,245,0.08);
                    padding:2px 8px;border-radius:3px;flex:1">${item.path}</code>
            </div>
            <div style="padding-left:130px;display:flex;align-items:center;gap:8px;flex-wrap:wrap">
              <span style="font-size:11px;color:var(--muted)">${item.desc}</span>
              ${(item.files||[]).map(f => `
                <button class="btn" style="font-size:11px;padding:3px 10px"
                  onclick="downloadFile('${f}')">↓ ${f.split('/').pop()}</button>
              `).join('')}
              ${(item.editable||[]).map(f => `
                <button class="btn primary" style="font-size:11px;padding:3px 10px"
                  onclick="openVarsEditor('${f}')">✏ 編輯 ${f.split('/').pop()}</button>
              `).join('')}

            </div>
          </div>`).join('')}

        <div style="margin-top:16px;padding:12px;background:rgba(66,165,245,0.06);border-radius:4px;
             font-size:12px;color:var(--label);line-height:1.8">
          💡 修改 XML 後執行 <strong style="color:var(--accent-bright)">reloadxml</strong> 即可套用，
          無需重啟 FreeSwitch。<br>
          ⚠ 修改 <code>sip_profiles</code> 後需執行
          <strong style="color:var(--accent-bright)">sofia profile &lt;name&gt; restart</strong>。
        </div>
      </div>

      `;




    default: return `<div style="padding:40px;text-align:center;color:var(--muted)">請從左側選單選擇設定項目</div>`;
  }
}

// ── XML 編輯器 ────────────────────────────────────────────────────────────────
let _editingPath = '';

async function openXmlEditor(path, relpath) {
  _editingPath = path;

  // 隱藏清單，顯示編輯器
  const list   = document.getElementById('dialplan-list-body');
  const editor = document.getElementById('xml-editor-panel');
  if (list)   list.style.display   = 'none';
  if (editor) editor.style.display = 'flex';

  // 更新標題
  const title = document.getElementById('xml-editor-title');
  const pathEl = document.getElementById('xml-editor-path');
  if (title)  title.textContent  = relpath;
  if (pathEl) pathEl.textContent = path;

  // 清除備份訊息
  const bkEl = document.getElementById('xml-backup-info');
  if (bkEl) bkEl.textContent = '';

  // 載入檔案內容
  const area = document.getElementById('xml-editor-area');
  if (area) area.value = '載入中...';

  const data = await apiFetch(`/api/dialplan/file?path=${encodeURIComponent(path)}`);
  if (data && data.content) {
    area.value = data.content;
    updateLineNums();
  } else {
    area.value = '// 無法載入檔案';
  }
}

function closeXmlEditor() {
  const list   = document.getElementById('dialplan-list-body');
  const editor = document.getElementById('xml-editor-panel');
  if (list)   list.style.display   = 'block';
  if (editor) editor.style.display = 'none';
}

async function saveXmlFile() {
  const area = document.getElementById('xml-editor-area');
  const msg  = document.getElementById('xml-save-msg');
  const bkEl = document.getElementById('xml-backup-info');
  if (!area || !_editingPath) return;

  if (msg) { msg.textContent = '儲存中...'; msg.style.opacity = '1'; msg.style.color = 'var(--yellow)'; }

  try {
    const res = await fetch(`${API_BASE}/api/dialplan/file`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'Authorization': `Bearer ${getToken()}` },
      body: JSON.stringify({ path: _editingPath, content: area.value })
    });
    const data = await res.json();
    if (data.ok) {
      if (msg)  { msg.textContent = '✓ 已儲存'; msg.style.color = 'var(--green)'; }
      if (bkEl) bkEl.textContent  = `備份：${data.backup.split('/').pop()}`;
      setTimeout(() => { if (msg) msg.style.opacity = '0'; }, 3000);
    } else {
      if (msg)  { msg.textContent = '✗ 儲存失敗'; msg.style.color = 'var(--red)'; }
    }
  } catch(e) {
    if (msg) { msg.textContent = `✗ 錯誤：${e.message}`; msg.style.color = 'var(--red)'; }
  }
}

async function reloadAfterSave() {
  const msg = document.getElementById('xml-save-msg');
  if (msg) { msg.textContent = 'Reload XML...'; msg.style.opacity='1'; msg.style.color='var(--yellow)'; }
  const res = await runESLCommand('reloadxml');
  if (msg) {
    msg.textContent = res && res.result && res.result.includes('+OK') ? '✓ Reload 成功' : '⚠ Reload 完成';
    msg.style.color = 'var(--green)';
    setTimeout(() => { msg.style.opacity = '0'; }, 3000);
  }
}

// 行號更新
function updateLineNums() {
  const area  = document.getElementById('xml-editor-area');
  const nums  = document.getElementById('xml-line-nums');
  const count = document.getElementById('xml-line-count');
  if (!area || !nums) return;
  const lines = area.value.split('\n').length;
  nums.textContent = Array.from({length: lines}, (_, i) => i + 1).join('\n');
  if (count) count.textContent = `第 ${lines} 行`;
}

// 行號與 textarea 同步捲動
function syncLineScroll() {
  const area = document.getElementById('xml-editor-area');
  const nums = document.getElementById('xml-line-nums');
  if (area && nums) nums.scrollTop = area.scrollTop;
}

// Tab 鍵縮排支援
function handleEditorKey(e) {
  if (e.key === 'Tab') {
    e.preventDefault();
    const area  = document.getElementById('xml-editor-area');
    const start = area.selectionStart;
    const end   = area.selectionEnd;
    area.value  = area.value.substring(0, start) + '  ' + area.value.substring(end);
    area.selectionStart = area.selectionEnd = start + 2;
    updateLineNums();
  }
  // Ctrl+S 儲存
  if ((e.ctrlKey || e.metaKey) && e.key === 's') {
    e.preventDefault();
    saveXmlFile();
  }
}

// 簡單格式化（整理縮排）
function xmlFormat() {
  const area = document.getElementById('xml-editor-area');
  if (!area) return;
  try {
    const parser = new DOMParser();
    const doc    = parser.parseFromString(area.value, 'text/xml');
    const err    = doc.querySelector('parsererror');
    if (err) { alert('XML 格式錯誤，無法自動格式化'); return; }
    const s = new XMLSerializer();
    let xml = s.serializeToString(doc);
    // 簡單縮排處理
    let indent = 0;
    xml = xml.replace(/></g, '>\n<')
             .split('\n')
             .map(line => {
               line = line.trim();
               if (line.startsWith('</')) indent = Math.max(0, indent - 1);
               const pad = '  '.repeat(indent);
               if (!line.startsWith('</') && !line.endsWith('/>') && line.includes('<') && !line.includes('</')) indent++;
               return pad + line;
             }).join('\n');
    area.value = xml;
    updateLineNums();
  } catch(e) {
    alert('格式化失敗：' + e.message);
  }
}

function xmlFind() {
  const q = prompt('搜尋文字：');
  if (!q) return;
  const area = document.getElementById('xml-editor-area');
  if (!area) return;
  const idx = area.value.indexOf(q);
  if (idx === -1) { alert('找不到：' + q); return; }
  area.focus();
  area.setSelectionRange(idx, idx + q.length);
  // 捲動到該位置
  const linesBefore = area.value.substring(0, idx).split('\n').length;
  area.scrollTop = (linesBefore - 5) * 19.2;
}

function toggleDialplanFile(id) {
  const el = document.getElementById(id);
  const fname = id.replace('dpf-', '');
  const arrow = document.getElementById(`dpf-arrow-${fname}`);
  if (!el) return;
  const isHidden = el.style.display === 'none';
  el.style.display = isHidden ? 'block' : 'none';
  if (arrow) arrow.textContent = isHidden ? '▾' : '▸';
}

async function eslCmdToast(cmd) {
  const result = document.getElementById('cmd-result');
  if (result) { result.style.display='block'; result.textContent = '執行中...'; }
  const res = await runESLCommand(cmd);
  if (result) {
    result.textContent = res && res.result ? res.result : '無回應';
  }
}

async function openVarsEditor(path) {
  // 切換到 dialplan_list 節點，借用 XML 編輯器
  _settingsNode = 'dialplan_list';
  await renderSettings('dialplan_list');

  // 等 DOM 渲染完成後開啟編輯器
  setTimeout(() => {
    openXmlEditor(path, path.split('/').pop());
  }, 100);
}


// ── 備份管理函式 ──────────────────────────────────────────────────────────────

async function backupRun(type) {
  const labelMap = { config: 'Dashboard 設定', packages: 'FreeSwitch 套件', both: '完整備份' };

  // 元素可能存在於「備份設定」或「備份清單」頁，也可能都不存在（從清單頁快捷按鈕呼叫）
  const progress = document.getElementById('backup-progress');
  const resultEl = document.getElementById('backup-result');

  // 找不到進度元素時用 toast 提示，不直接 return
  const showProgress = (msg) => {
    if (progress) { progress.style.display = 'block'; progress.textContent = msg; }
    else _backupToast(msg, 'info');
  };
  const hideProgress = () => {
    if (progress) progress.style.display = 'none';
    // 備份完成，清除執行中的 info toast
    if (_backupToastEl) { _backupToastEl.remove(); _backupToastEl = null; }
  };
  const showResult = (html) => {
    if (resultEl) { resultEl.innerHTML = html; return; }
    // 合併所有結果成單一 toast（避免多次呼叫造成閃爍覆蓋）
    const tmp = document.createElement('div');
    tmp.innerHTML = html;
    const hasError = html.includes('❌');
    _backupToast(tmp.textContent.trim(), hasError ? 'error' : 'ok');
  };

  // 收集所有結果再一次性顯示
  const collectAndShow = (data) => {
    let html = '';
    for (const [k, r] of Object.entries(data.results || {})) {
      const ok    = r.ok;
      const color = ok ? 'var(--green)' : 'var(--red)';
      const icon  = ok ? '✅' : '❌';
      const label = k === 'config' ? '設定備份' : '套件備份';
      const info  = ok
        ? `${r.filename}（${(r.size / 1024 / 1024).toFixed(1)} MB）`
        : (r.error || '未知錯誤');
      html += `<div style="color:${color};font-size:13px;margin:4px 0">${icon} ${label}：${info}</div>`;
      if (r.errors && r.errors.length) {
        html += `<div style="font-size:12px;color:var(--muted);margin-left:20px">
          ⚠ ${r.errors.join('<br>⚠ ')}</div>`;
      }
    }
    showResult(html);
  };

  showProgress(`⏳ ${labelMap[type]} 備份執行中，請稍候...（套件備份約需 1-5 分鐘）`);

  try {
    const data = await apiFetch('/api/backup/run', {
      method:  'POST',
      headers: { 'Content-Type': 'application/json' },
      body:    JSON.stringify({ type }),
    });

    hideProgress();
    collectAndShow(data);
    setTimeout(() => { if (currentPage === 'backup') renderBackupPage('backup_list'); }, 1000);
  } catch(e) {
    hideProgress();
    showResult(`<span style="color:var(--red)">❌ 備份失敗：${e.message}</span>`);
  }
}

// 簡易 toast（備份清單頁沒有 result 容器時使用）
let _backupToastEl = null;
function _backupToast(msg, type) {
  const colors = { ok: 'var(--green)', error: 'var(--red)', info: 'var(--muted)' };
  // 移除舊 toast（避免重疊）
  if (_backupToastEl) { _backupToastEl.remove(); _backupToastEl = null; }
  const t = document.createElement('div');
  t.textContent = msg;
  Object.assign(t.style, {
    position: 'fixed', bottom: '24px', right: '24px', zIndex: 9999,
    background: 'var(--panel2)', border: `1px solid ${colors[type] || colors.info}`,
    color: colors[type] || colors.info, padding: '10px 18px',
    borderRadius: '6px', fontSize: '13px', maxWidth: '380px',
    boxShadow: '0 4px 12px rgba(0,0,0,.4)',
  });
  document.body.appendChild(t);
  _backupToastEl = t;
  // ok/error 5 秒自動消失；info（執行中）不自動消失，等備份結束後由 hideProgress 清除
  if (type !== 'info') setTimeout(() => { t.remove(); if (_backupToastEl === t) _backupToastEl = null; }, 5000);
}

function backupDownload(filename) {
  const a = document.createElement('a');
  a.href  = `${API_BASE}/api/backup/download?filename=${encodeURIComponent(filename)}`;
  a.download = filename;
  document.body.appendChild(a);
  a.click();
  document.body.removeChild(a);
}

async function backupDelete(filename, btn) {
  if (!confirm(`確定刪除備份？\n${filename}`)) return;
  btn.disabled    = true;
  btn.textContent = '刪除中...';
  try {
    await apiFetch(`/api/backup/${encodeURIComponent(filename)}`, { method: 'DELETE' });
    renderBackupPage('backup_list');
  } catch(e) {
    alert('刪除失敗：' + e.message);
    btn.disabled    = false;
    btn.textContent = '🗑';
  }
}

async function backupRestoreUpload(input) {
  const file     = input.files[0];
  const nameEl   = document.getElementById('backup-restore-filename');
  const resultEl = document.getElementById('backup-restore-result');
  if (!file) return;

  if (nameEl) nameEl.textContent = file.name;

  if (!file.name.startsWith('fs-dashboard-config-')) {
    if (resultEl) resultEl.innerHTML =
      `<span style="color:var(--red)">❌ 只接受 fs-dashboard-config-*.tar.gz 備份檔</span>`;
    return;
  }

  if (!confirm(`確定從 "${file.name}" 還原設定？\n\n⚠ 這將覆蓋目前所有 FreeSwitch 設定，原設定會自動備份。`)) {
    input.value = '';
    if (nameEl) nameEl.textContent = '';
    return;
  }

  if (resultEl) resultEl.innerHTML = '<span style="color:var(--muted)">⏳ 上傳還原中...</span>';

  try {
    const form = new FormData();
    form.append('file', file);
    const resp = await fetch(`${API_BASE}/api/backup/restore`, {
      method: 'POST',
      headers: { 'Authorization': `Bearer ${getToken()}` },
      body: form,
    });
    const data = await resp.json();

    if (!resp.ok) {
      if (resultEl) resultEl.innerHTML =
        `<span style="color:var(--red)">❌ 還原失敗：${data.detail || JSON.stringify(data)}</span>`;
      return;
    }

    const restoredList = (data.restored || []).map(r => `• ${r}`).join('<br>');
    const errorList    = (data.errors   || []).map(e => `⚠ ${e}`).join('<br>');
    if (resultEl) resultEl.innerHTML = `
      <div style="color:var(--green);font-size:13px">✅ 還原完成<br>${restoredList}</div>
      ${errorList ? `<div style="color:var(--yellow);font-size:12px;margin-top:4px">${errorList}</div>` : ''}
      <div style="font-size:12px;color:var(--muted);margin-top:6px">建議重新整理頁面確認設定是否正確載入。</div>`;

    input.value = '';
    setTimeout(() => { if (currentPage === 'backup') renderBackupPage('backup_list'); }, 1200);
  } catch(e) {
    if (resultEl) resultEl.innerHTML = `<span style="color:var(--red)">❌ 還原失敗：${e.message}</span>`;
  }
}


// ════════════════════════════════════════════════════════════════════════════
// 備份管理 — 獨立頁面（類設定頁雙欄佈局）
// ════════════════════════════════════════════════════════════════════════════

