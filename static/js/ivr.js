// ivr.js — IVR 互動語音應答管理（表單編輯器 + SVG 流程圖）

// ════════════════════════════════════════════════════════════════════════════
// IVR 管理（互動語音應答）
// ════════════════════════════════════════════════════════════════════════════

let _ivrList       = [];   // 全部 IVR 清單（含子選單）
let _ivrEditing    = null; // 正在編輯的 IVR 物件
let _ivrSounds     = [];   // 可用語音檔清單
let _ivrExts       = [];   // 可用分機清單
let _ivrGroups     = [];   // 可用群組清單
let _ivrCurrentTab = 'list'; // list | edit

// ── ACTION 類型顯示設定 ───────────────────────────────────────────────────────
const IVR_ACTION_LABELS = {
  extension: { icon: '⊟', label: '轉接分機', color: '#0288d1', hasTarget: true,  targetLabel: '分機號碼' },
  group:     { icon: '▣', label: '轉接群組', color: '#6a1b9a', hasTarget: true,  targetLabel: '群組號碼' },
  ivr:       { icon: '🎛', label: '子選單',   color: '#2e7d32', hasTarget: true,  targetLabel: 'IVR ID'  },
  voicemail: { icon: '📬', label: '語音信箱', color: '#e65100', hasTarget: true,  targetLabel: '分機號碼' },
  playback:  { icon: '🔊', label: '播放後掛斷', color: '#4a148c', hasTarget: true,  targetLabel: '音檔路徑' },
  hangup:    { icon: '✕',  label: '掛斷',     color: '#c62828', hasTarget: false, targetLabel: ''        },
};

const IVR_SPECIAL_DIGITS = {
  t: '⏱ 超時 (t)',
  i: '❌ 無效鍵 (i)',
};

// ── 新 IVR 物件工廠 ───────────────────────────────────────────────────────────
function _ivrNewObj(parentId = '') {
  return {
    id: '', name: '', number: '', greeting: '', menu_sound: '',
    invalid_sound: '', exit_sound: '',
    timeout: 10, retries: 3, inter_digit_timeout: 2000, digit_len: 1,
	direct_ext_dialing: false, direct_ext_digits: 4, direct_ext_prefix: '',
    invalid_retries: 1, invalid_final_sound: '',
    timeout_retries: 1, timeout_final_sound: '',
    // [NEW] 直接轉接：進入 IVR 後立即轉接（跳過語音與按鍵）
    auto_transfer: { enabled: false, action_type: 'extension', target: '' },
    // [NEW] 播後轉接：播完 greeting 後自動轉接（不等按鍵）
    post_greeting_transfer: { enabled: false, action_type: 'extension', target: '' },
    keys: {
      i: { action_type: 'hangup', target: '' },
      t: { action_type: 'hangup', target: '' },
    },
    schedule: {
      enabled: false, work_start: '09:00', work_end: '18:00',
      work_days: [1,2,3,4,5], work_target: '', offhour_target: '',
      offhour_sound: '', holiday_dates: [], holiday_target: '',
      // [NEW] 下班/假日直轉（支援所有 action_type，優先於舊式 *_target 字串）
      offhour_action: { action_type: 'hangup', target: '' },
      holiday_action: { action_type: '', target: '' },
    },
    context: 'default', parent_id: parentId,
  };
}

// ── 主渲染入口 ────────────────────────────────────────────────────────────────
async function renderIVR() {
  document.getElementById('mainContent').innerHTML =
    '<div style="padding:40px;text-align:center;color:var(--muted)">載入中…</div>';

  const [ivrData, extData, grpData, sndData] = await Promise.all([
    apiFetch('/api/ivr/list'),
    apiFetch('/api/extensions/list'),
    apiFetch('/api/groups/list'),
    apiFetch('/api/sounds/list?category=custom'),
  ]);

  _ivrList   = (ivrData  && ivrData.ivrs)        || [];
  _ivrExts   = (extData  && extData.extensions)   || [];
  _ivrGroups = (grpData  && grpData.groups)        || [];
  _ivrSounds = (sndData  && sndData.sounds)        || [];

  if (_ivrCurrentTab === 'edit' && _ivrEditing) {
    _ivrRenderEditor();
  } else {
    _ivrCurrentTab = 'list';
    _ivrRenderList();
  }
}

// ── 清單頁 ────────────────────────────────────────────────────────────────────
function _ivrRenderList() {
  const topLevel  = _ivrList.filter(v => !v.parent_id);
  const subMenus  = _ivrList.filter(v =>  v.parent_id);

  const rows = _ivrList.map(ivr => {
    const keyCount  = Object.keys(ivr.keys || {}).length;
    const hasEntry  = ivr.number ? `<code style="color:var(--accent-bright)">${ivr.number}</code>` : '<span style="color:var(--muted)">子選單</span>';
    const sched     = (ivr.schedule && ivr.schedule.enabled)
      ? `<span style="color:#2e7d32;font-size:11px">⏰ 時段路由</span>` : '';
    const parentLbl = ivr.parent_id
      ? `<span style="font-size:11px;color:var(--muted)">← ${ivr.parent_id}</span>` : '';
    return `
    <tr>
      <td style="font-weight:600">${ivr.name || ivr.id}</td>
      <td><code style="font-size:12px">${ivr.id}</code> ${parentLbl}</td>
      <td>${hasEntry}</td>
      <td style="color:var(--label)">${keyCount} 個按鍵</td>
      <td>${sched}</td>
      <td>
        <button class="btn" onclick="_ivrEdit('${ivr.id}')">✎ 編輯</button>
        <button class="btn" style="color:var(--red)" onclick="_ivrDelete('${ivr.id}','${ivr.name||ivr.id}')">✕</button>
      </td>
    </tr>`;
  }).join('');

  document.getElementById('mainContent').innerHTML = `
  <div style="padding:0 0 16px">
    <!-- 標題列 -->
    <div style="display:flex;align-items:center;gap:10px;padding:16px 20px 12px;border-bottom:1px solid var(--border)">
      <span style="font-size:18px;font-weight:700;color:var(--text)">🎛 IVR 管理</span>
      <button class="btn" style="margin-left:auto" onclick="_ivrNewTop()">＋ 新增 IVR</button>
      <button class="btn" onclick="renderIVR()">↺ 刷新</button>
    </div>

    ${_ivrList.length === 0 ? `
    <div style="padding:60px;text-align:center;color:var(--muted)">
      <div style="font-size:40px;margin-bottom:12px">🎛</div>
      <div style="font-size:16px;margin-bottom:8px">尚無 IVR 選單</div>
      <div style="font-size:13px;margin-bottom:20px">點擊「新增 IVR」建立第一個互動語音選單</div>
      <button class="btn" onclick="_ivrNewTop()">＋ 新增第一個 IVR</button>
    </div>` : `
    <div style="padding:12px 20px">
      <table style="width:100%;border-collapse:collapse">
        <thead>
          <tr style="border-bottom:2px solid var(--border)">
            <th style="text-align:left;padding:8px 10px;color:var(--label);font-size:12px;font-weight:600">名稱</th>
            <th style="text-align:left;padding:8px 10px;color:var(--label);font-size:12px;font-weight:600">ID</th>
            <th style="text-align:left;padding:8px 10px;color:var(--label);font-size:12px;font-weight:600">入口號碼</th>
            <th style="text-align:left;padding:8px 10px;color:var(--label);font-size:12px;font-weight:600">按鍵</th>
            <th style="text-align:left;padding:8px 10px;color:var(--label);font-size:12px;font-weight:600">時段路由</th>
            <th style="text-align:left;padding:8px 10px;color:var(--label);font-size:12px;font-weight:600">操作</th>
          </tr>
        </thead>
        <tbody id="ivr-tbody">
          ${rows}
        </tbody>
      </table>
    </div>`}

    <!-- 語音檔區塊 -->
    <div style="margin:12px 20px 0;padding:14px 16px;background:rgba(66,165,242,0.06);border:1px solid var(--border);border-radius:6px">
      <div style="display:flex;align-items:center;gap:8px;margin-bottom:10px">
        <span style="font-weight:600;color:var(--label)">🔊 語音檔管理</span>
        <span style="font-size:12px;color:var(--muted)">（${_ivrSounds.filter(s=>s.source==='custom').length} 個自定義）</span>
        <label class="btn" style="margin-left:auto;cursor:pointer">
          ＋ 上傳 WAV
          <input type="file" accept=".wav,.mp3,.ogg,.gsm" style="display:none" onchange="_ivrUploadSound(this)">
        </label>
      </div>
      <div style="display:flex;flex-wrap:wrap;gap:8px">
        ${_ivrSounds.filter(s=>s.source==='custom').length === 0
          ? '<span style="font-size:12px;color:var(--muted)">尚無自定義語音檔，請上傳 WAV 格式</span>'
          : _ivrSounds.filter(s=>s.source==='custom').map(s => `
            <div style="display:flex;align-items:center;gap:6px;background:var(--bg);border:1px solid var(--border);border-radius:4px;padding:4px 8px">
              <span style="font-size:12px;color:var(--text)">${s.filename}</span>
              <audio controls style="height:24px;width:140px" src="${API_BASE}/api/sounds/stream?path=${encodeURIComponent(s.path)}&token=${encodeURIComponent(getToken())}"></audio>
              <button class="btn" style="font-size:11px;padding:2px 6px;color:var(--red)"
                onclick="_ivrDeleteSound('${s.filename}')">✕</button>
            </div>`).join('')}
      </div>
    </div>

    <div style="padding:12px 20px;font-size:12px;color:var(--muted);line-height:1.8">
      💡 IVR 設定儲存後自動執行 <strong>reloadxml</strong>，立即生效。<br>
      📁 Dialplan 檔案存於 <code>/etc/freeswitch/dialplan/default/00_ivr_*.xml</code>，選單定義存於 <code>/etc/freeswitch/ivr-menus/</code>。<br>
      🔊 自定義語音檔存於 <code>/var/lib/freeswitch/sounds/custom/</code>（建議 8kHz 16bit Mono WAV）。
    </div>
  </div>`;
}

// ── 編輯器主體 ────────────────────────────────────────────────────────────────
function _ivrEdit(ivr_id) {
  const found = _ivrList.find(v => v.id === ivr_id);
  if (!found) return;
  // 深拷貝
  _ivrEditing = JSON.parse(JSON.stringify(found));
  // 補齊 schedule 預設值（相容舊版資料缺欄位）
  const defSched = _ivrNewObj().schedule;
  if (!_ivrEditing.schedule) {
    _ivrEditing.schedule = defSched;
  } else {
    for (const k of Object.keys(defSched)) {
      if (_ivrEditing.schedule[k] === undefined) _ivrEditing.schedule[k] = defSched[k];
    }
  }
  if (!_ivrEditing.keys) _ivrEditing.keys = {};
  // 確保整合卡片有預設動作
  if (!_ivrEditing.keys.i) _ivrEditing.keys.i = { action_type: 'hangup', target: '' };
  if (!_ivrEditing.keys.t) _ivrEditing.keys.t = { action_type: 'hangup', target: '' };
  // 補齊頂層新增欄位預設值
  if (_ivrEditing.invalid_retries  === undefined) _ivrEditing.invalid_retries  = 1;
  if (_ivrEditing.invalid_final_sound === undefined) _ivrEditing.invalid_final_sound = '';
  if (_ivrEditing.timeout_retries   === undefined) _ivrEditing.timeout_retries   = 1;
  if (_ivrEditing.timeout_final_sound === undefined) _ivrEditing.timeout_final_sound = '';
  if (_ivrEditing.direct_ext_dialing === undefined) _ivrEditing.direct_ext_dialing = false;
  if (_ivrEditing.direct_ext_digits  === undefined) _ivrEditing.direct_ext_digits  = 4;
  if (_ivrEditing.direct_ext_prefix  === undefined) _ivrEditing.direct_ext_prefix  = '';
  // [NEW] 補齊 auto_transfer / post_greeting_transfer
  const def = _ivrNewObj();
  if (!_ivrEditing.auto_transfer)          _ivrEditing.auto_transfer          = { ...def.auto_transfer };
  if (!_ivrEditing.post_greeting_transfer) _ivrEditing.post_greeting_transfer = { ...def.post_greeting_transfer };
  // [NEW] 補齊 schedule offhour_action / holiday_action
  if (!_ivrEditing.schedule.offhour_action) _ivrEditing.schedule.offhour_action = { ...def.schedule.offhour_action };
  if (!_ivrEditing.schedule.holiday_action) _ivrEditing.schedule.holiday_action = { ...def.schedule.holiday_action };
  _ivrCurrentTab = 'edit';
  _ivrRenderEditor();
}

function _ivrNewTop() {
  _ivrEditing    = _ivrNewObj();
  _ivrCurrentTab = 'edit';
  _ivrRenderEditor();
}

function _ivrNewSub() {
  const parentId = _ivrEditing ? _ivrEditing.id : '';
  _ivrEditing    = _ivrNewObj(parentId);
  _ivrRenderEditor();
}

// ── 編輯器渲染 ────────────────────────────────────────────────────────────────
function _ivrRenderEditor() {
  const ivr     = _ivrEditing;
  const isNew   = !_ivrList.find(v => v.id === ivr.id);
  const title   = isNew ? '新增 IVR 選單' : `編輯 IVR：${ivr.name || ivr.id}`;

  document.getElementById('mainContent').innerHTML = `
  <div style="display:flex;height:calc(100vh - 120px);gap:0;overflow:hidden">

    <!-- 左側：表單編輯器 60% -->
    <div style="flex:3;min-width:0;overflow-y:auto;border-right:1px solid var(--border);display:flex;flex-direction:column">

      <!-- 標題列 -->
      <div style="padding:14px 16px;border-bottom:1px solid var(--border);background:rgba(66,165,245,0.05);display:flex;align-items:center;gap:8px;flex-shrink:0">
        <button class="btn" onclick="_ivrBackToList()">← 返回</button>
        <span style="font-weight:700;font-size:14px;color:var(--text)">${title}</span>
      </div>

      <div style="padding:16px;flex:1">

        <!-- 基本資訊 -->
        <div style="margin-bottom:18px">
          <div style="font-size:11px;font-weight:700;color:var(--label);text-transform:uppercase;letter-spacing:1px;margin-bottom:10px;padding-bottom:4px;border-bottom:1px solid var(--border)">基本資訊</div>
          <div style="display:grid;grid-template-columns:1fr 1fr;gap:10px">
            <div>
              <label style="font-size:12px;color:var(--label);display:block;margin-bottom:4px">IVR ID <span style="color:var(--red)">*</span></label>
              <input id="ivr-id" class="settings-input" value="${ivr.id}" placeholder="main_menu"
                ${!isNew ? 'readonly style="background:var(--bg);opacity:.7"' : ''}
                oninput="_ivrUpdateFlowDebounced()">
            </div>
            <div>
              <label style="font-size:12px;color:var(--label);display:block;margin-bottom:4px">顯示名稱</label>
              <input id="ivr-name" class="settings-input" value="${ivr.name}" placeholder="主選單"
                oninput="_ivrUpdateFlowDebounced()">
            </div>
            <div>
              <label style="font-size:12px;color:var(--label);display:block;margin-bottom:4px">入口號碼</label>
              <input id="ivr-number" class="settings-input" value="${ivr.number}" placeholder="9000（空=子選單）"
                oninput="_ivrUpdateFlowDebounced();numCheckConflict('ivr-number','ivr-number-conflict',this.value,'ivr')"
                onblur="numCheckConflict('ivr-number','ivr-number-conflict',this.value,'ivr')">
              <div id="ivr-number-conflict" style="margin-top:4px"></div>
            </div>
            <div style="display:flex;gap:8px">
              <div style="flex:1">
                <label style="font-size:12px;color:var(--label);display:block;margin-bottom:4px">
                  等待按鍵秒數
                  <span style="font-weight:400;color:var(--muted)">（每次播完後等待）</span>
                </label>
                <input id="ivr-timeout" class="settings-input" type="number" value="${ivr.timeout}" min="3" max="60"
                  oninput="_ivrUpdateFlowDebounced()">
              </div>
              <div style="flex:1">
                <label style="font-size:12px;color:var(--label);display:block;margin-bottom:4px">
                  整體重試上限
                  <span style="font-weight:400;color:var(--muted)">（安全停損）</span>
                </label>
                <input id="ivr-retries" class="settings-input" type="number" value="${ivr.retries}" min="1" max="20">
              </div>
            </div>
          </div>
        </div>

        <!-- 語音設定 -->
        <div style="margin-bottom:18px">
          <div style="font-size:11px;font-weight:700;color:var(--label);text-transform:uppercase;letter-spacing:1px;margin-bottom:10px;padding-bottom:4px;border-bottom:1px solid var(--border)">語音檔設定</div>
          ${_ivrSoundRow('ivr-greeting',     '歡迎語（長版，首次播放）', ivr.greeting)}
          ${_ivrSoundRow('ivr-menu-sound',   '選單提示（短版，重複播放）', ivr.menu_sound)}
          ${_ivrSoundRow('ivr-invalid-sound','按鍵無效提示音（每次無效都播）', ivr.invalid_sound)}
          ${_ivrSoundRow('ivr-exit-sound',   '離開 IVR 提示音', ivr.exit_sound)}
        </div>
		
		<!-- 直撥分機設定 -->
        <div style="margin-bottom:18px">
          <div style="display:flex;align-items:center;gap:8px;margin-bottom:10px;padding-bottom:4px;border-bottom:1px solid var(--border)">
            <span style="font-size:11px;font-weight:700;color:var(--label);text-transform:uppercase;letter-spacing:1px">直撥分機</span>
            <label style="margin-left:auto;display:flex;align-items:center;gap:6px;cursor:pointer">
              <input type="checkbox" id="ivr-direct-ext-dialing" ${ivr.direct_ext_dialing?'checked':''}
                onchange="_ivrToggleDirectDial(this.checked)">
              <span style="font-size:12px">啟用直撥分機</span>
            </label>
          </div>
          <div id="ivr-direct-dial-panel" style="${ivr.direct_ext_dialing?'':'display:none'}">
            <div style="display:grid;grid-template-columns:1fr 1fr;gap:10px;padding:10px;background:var(--bg);border:1px solid var(--border);border-radius:6px">
              <div>
                <label style="font-size:12px;color:var(--label);display:block;margin-bottom:4px">
                  分機位數 <span style="font-weight:400;color:var(--muted)">（決定等待幾位才觸發）</span>
                </label>
                <input id="ivr-direct-ext-digits" class="settings-input" type="number" min="2" max="6"
                  value="${ivr.direct_ext_digits||4}"
                  oninput="_ivrEditing.direct_ext_digits=parseInt(this.value)||4;_ivrUpdateFlowDebounced()">
              </div>
              <div>
                <label style="font-size:12px;color:var(--label);display:block;margin-bottom:4px">
                  限定前綴 <span style="font-weight:400;color:var(--muted)">（空=任意，如填 1 只允許 1xx）</span>
                </label>
                <input id="ivr-direct-ext-prefix" class="settings-input"
                  value="${ivr.direct_ext_prefix||''}" placeholder="留空=不限前綴"
                  oninput="_ivrEditing.direct_ext_prefix=this.value;_ivrUpdateFlowDebounced()">
              </div>
            </div>
            <div style="margin-top:6px;font-size:11px;color:var(--muted)">
              💡 啟用後，來電者可直接輸入完整分機號碼轉接。單鍵選單仍可使用（按鍵比對優先）。
            </div>
          </div>
        </div>

        <!-- [NEW] 直接轉接設定 -->
        <div style="margin-bottom:18px">
          <div style="display:flex;align-items:center;gap:8px;margin-bottom:10px;padding-bottom:4px;border-bottom:1px solid var(--border)">
            <span style="font-size:11px;font-weight:700;color:var(--label);text-transform:uppercase;letter-spacing:1px">直接轉接</span>
            <label style="margin-left:auto;display:flex;align-items:center;gap:6px;cursor:pointer">
              <input type="checkbox" id="ivr-auto-transfer-enabled" ${ivr.auto_transfer&&ivr.auto_transfer.enabled?'checked':''}
                onchange="_ivrEditing.auto_transfer.enabled=this.checked;document.getElementById('ivr-auto-transfer-panel').style.display=this.checked?'':'none';_ivrUpdateFlowDebounced()">
              <span style="font-size:12px">啟用直接轉接</span>
            </label>
          </div>
          <div id="ivr-auto-transfer-panel" style="${ivr.auto_transfer&&ivr.auto_transfer.enabled?'':'display:none'}">
            <div style="padding:10px;background:var(--bg);border:1px solid var(--border);border-radius:6px">
              <label style="font-size:12px;color:var(--label);display:block;margin-bottom:6px">接通後立即轉至</label>
              <div id="ivr-at">${_ivrRenderActionSelector('ivr-at', ivr.auto_transfer||{action_type:'extension',target:''}, '_ivrAutoTransferChange')}</div>
            </div>
            <div style="margin-top:6px;font-size:11px;color:var(--muted)">
              💡 啟用後，時段路由通過即直接轉接，完全跳過語音播放與按鍵等待。優先順序：時段路由 → 直接轉接。
            </div>
          </div>
        </div>

        <!-- [NEW] 播後轉接設定 -->
        <div style="margin-bottom:18px">
          <div style="display:flex;align-items:center;gap:8px;margin-bottom:10px;padding-bottom:4px;border-bottom:1px solid var(--border)">
            <span style="font-size:11px;font-weight:700;color:var(--label);text-transform:uppercase;letter-spacing:1px">播後轉接</span>
            <label style="margin-left:auto;display:flex;align-items:center;gap:6px;cursor:pointer">
              <input type="checkbox" id="ivr-pgt-enabled" ${ivr.post_greeting_transfer&&ivr.post_greeting_transfer.enabled?'checked':''}
                onchange="_ivrEditing.post_greeting_transfer.enabled=this.checked;document.getElementById('ivr-pgt-panel-wrap').style.display=this.checked?'':'none';_ivrUpdateFlowDebounced()">
              <span style="font-size:12px">啟用播後轉接</span>
            </label>
          </div>
          <div id="ivr-pgt-panel-wrap" style="${ivr.post_greeting_transfer&&ivr.post_greeting_transfer.enabled?'':'display:none'}">
            <div style="padding:10px;background:var(--bg);border:1px solid var(--border);border-radius:6px">
              <label style="font-size:12px;color:var(--label);display:block;margin-bottom:6px">播完歡迎語後轉至</label>
              <div id="ivr-pgt-panel">${_ivrRenderActionSelector('ivr-pgt', ivr.post_greeting_transfer||{action_type:'extension',target:''}, '_ivrPgtChange')}</div>
            </div>
            <div style="margin-top:6px;font-size:11px;color:var(--muted)">
              💡 啟用後，播完歡迎語（greeting）即自動轉接，不等待按鍵輸入。語音將完整播放完畢後才轉接。
            </div>
          </div>
        </div>

        <!-- 按鍵設定 -->
        <div style="margin-bottom:18px">
          <div style="display:flex;align-items:center;gap:8px;margin-bottom:10px;padding-bottom:4px;border-bottom:1px solid var(--border)">
            <span style="font-size:11px;font-weight:700;color:var(--label);text-transform:uppercase;letter-spacing:1px">按鍵動作設定</span>
            <div style="margin-left:auto;display:flex;align-items:center;gap:4px">
              <select id="ivr-add-key-select" class="settings-input" style="width:80px;padding:3px 6px;font-size:12px">
                ${[1,2,3,4,5,6,7,8,9,0,'*','#'].map(k=>`<option value="${k}">${k}</option>`).join('')}
              </select>
              <button class="btn" style="font-size:11px;padding:2px 8px" onclick="_ivrAddKey()">＋ 新增按鍵</button>
            </div>
          </div>
          <div id="ivr-keys-container">
            ${_ivrRenderKeys(ivr.keys)}
          </div>
        </div>

        <!-- 無效鍵 / 超時 整合設定卡片 -->
        <div style="margin-bottom:18px">
          <div style="font-size:11px;font-weight:700;color:var(--label);text-transform:uppercase;letter-spacing:1px;margin-bottom:10px;padding-bottom:4px;border-bottom:1px solid var(--border)">
            無效鍵 / 超時 行為設定
          </div>

          ${_ivrRenderSpecialKeyCard('i', ivr)}
          ${_ivrRenderSpecialKeyCard('t', ivr)}
        </div>


        <div style="margin-bottom:18px">
          <div style="display:flex;align-items:center;gap:8px;margin-bottom:10px;padding-bottom:4px;border-bottom:1px solid var(--border)">
            <span style="font-size:11px;font-weight:700;color:var(--label);text-transform:uppercase;letter-spacing:1px">時段路由</span>
            <label style="margin-left:auto;display:flex;align-items:center;gap:6px;cursor:pointer">
              <input type="checkbox" id="ivr-sched-enabled" ${ivr.schedule.enabled?'checked':''}
                onchange="_ivrToggleSchedule(this.checked)">
              <span style="font-size:12px">啟用時段路由</span>
            </label>
          </div>
          <div id="ivr-schedule-panel" style="${ivr.schedule.enabled?'':'display:none'}">
            ${_ivrRenderSchedule(ivr.schedule)}
          </div>
        </div>

      </div><!-- /padding -->

      <!-- 底部按鈕 -->
      <div style="padding:12px 16px;border-top:1px solid var(--border);background:var(--bg);display:flex;gap:8px">
        <button class="btn" onclick="_ivrSave()" style="background:var(--accent);color:#fff;font-weight:600;padding:6px 20px">
          💾 ${isNew ? '建立 IVR' : '儲存更新'}
        </button>
        <button class="btn" onclick="_ivrNewSub()" style="font-size:12px">＋ 新增子選單</button>
        <span id="ivr-save-msg" style="font-size:12px;color:var(--green);align-self:center;margin-left:4px"></span>
        <div style="flex:1"></div>
        ${!isNew ? `<button class="btn" style="color:var(--red);font-size:12px"
            onclick="_ivrDelete('${ivr.id}','${ivr.name||ivr.id}')">✕ 刪除此 IVR</button>` : ''}
      </div>
    </div><!-- /left -->

    <!-- 右側：即時流程圖預覽 40% -->
    <div style="flex:2;min-width:280px;max-width:480px;overflow:hidden;background:var(--bg);display:flex;flex-direction:column">
      <!-- 流程圖標題列 -->
      <div style="padding:10px 14px;border-bottom:1px solid var(--border);display:flex;align-items:center;gap:8px;flex-shrink:0;background:var(--panel)">
        <span style="font-size:12px;font-weight:700;color:var(--label)">📊 流程圖預覽</span>
        <span style="font-size:11px;color:var(--muted)">（即時同步）</span>
        <button class="btn" style="margin-left:auto;font-size:11px;padding:2px 8px" onclick="_ivrToggleFlowFullscreen(this)">⛶ 展開</button>
      </div>
      <!-- 流程圖容器：overflow:auto 讓大流程圖可捲動 -->
      <div id="ivr-flow-canvas" style="flex:1;overflow:auto;padding:12px">
        ${_ivrRenderFlow()}
      </div>
    </div><!-- /right -->

  </div>

  <!-- 流程圖全螢幕遮罩 -->
  <div id="ivr-flow-fullscreen" style="display:none;position:fixed;inset:0;background:rgba(0,0,0,0.88);z-index:9000;flex-direction:column" onclick="if(event.target===this)_ivrCloseFlowFullscreen()">
    <div style="display:flex;align-items:center;gap:10px;padding:12px 20px;background:var(--panel);border-bottom:2px solid var(--accent);flex-shrink:0">
      <span style="font-size:15px;font-weight:700;color:var(--text)">📊 IVR 流程圖</span>
      <span id="ivr-flow-fullscreen-title" style="font-size:12px;color:var(--muted)"></span>
      <button class="btn" style="margin-left:auto;background:var(--red);color:#fff;font-weight:600" onclick="_ivrCloseFlowFullscreen()">✕ 關閉</button>
    </div>
    <div id="ivr-flow-fullscreen-canvas" style="flex:1;overflow:auto;padding:32px;display:flex;align-items:flex-start;justify-content:center;background:var(--bg)"></div>
  </div>`;

  // 初始流程圖已在 HTML 中渲染，設定 debounce timer
  // 初始化重試次數 hint 說明文字
  setTimeout(_ivrInitRetryHints, 50);
}

// ── 語音欄位 row ──────────────────────────────────────────────────────────────
function _ivrSoundRow(inputId, label, value, onSelectCallback) {
  const customSounds = _ivrSounds.filter(s => s.source === 'custom');
  const afterSelect  = onSelectCallback ? `${onSelectCallback}(this.value);` : '';

  // 找目前已選的檔名（供 select 顯示用）
  const matched = customSounds.find(s => s.path === value);

  const opts = customSounds.map(s =>
    `<option value="${s.path}" ${value===s.path?'selected':''}>${s.filename}</option>`
  ).join('');

  return `
  <div style="margin-bottom:8px">
    ${label ? `<label style="font-size:12px;color:var(--label);display:block;margin-bottom:4px">${label}</label>` : ''}
    <div style="display:flex;gap:6px;align-items:center">
      <input id="${inputId}" class="settings-input" value="${value}"
        placeholder="留空 = 不使用"
        style="flex:1;min-width:0;font-size:12px"
        oninput="_ivrUpdateFlowDebounced();(function(v){const s=document.getElementById('${inputId}-sel');if(s){const o=[...s.options].find(o=>o.value===v);s.value=o?v:'';};})(this.value)">
      ${customSounds.length > 0 ? `
      <select id="${inputId}-sel"
        style="flex-shrink:0;padding:5px 6px;border:1px solid var(--border);border-radius:4px;
          background:var(--panel);color:var(--text);font-size:12px;max-width:180px"
        onchange="if(this.value){document.getElementById('${inputId}').value=this.value;${afterSelect}_ivrUpdateFlowDebounced();}">
        <option value="">📂 選擇音檔</option>${opts}
      </select>` : `<span style="font-size:11px;color:var(--muted);white-space:nowrap;flex-shrink:0">尚無自訂音檔</span>`}
    </div>
  </div>`;
}

// ── 按鍵動作渲染 ──────────────────────────────────────────────────────────────
function _ivrRenderKeys(keys) {
  // i/t 已移至整合卡片，此處只顯示一般按鍵
  const normalKeys = Object.entries(keys || {}).filter(([d]) => d !== 'i' && d !== 't');
  if (normalKeys.length === 0) {
    return '<div style="font-size:12px;color:var(--muted);padding:8px">尚無按鍵設定，點擊「＋ 新增按鍵」加入</div>';
  }

  // 排序：數字鍵在前
  normalKeys.sort(([a],[b]) => {
    const an = parseInt(a), bn = parseInt(b);
    if (!isNaN(an) && !isNaN(bn)) return an - bn;
    if (!isNaN(an)) return -1;
    if (!isNaN(bn)) return  1;
    return a.localeCompare(b);
  });

  return normalKeys.map(([digit, action]) => _ivrKeyRow(digit, action)).join('');
}

// ── 目標欄位 HTML 產生器（供 _ivrKeyRow 和整合卡片共用）─────────────────────
function _ivrBuildTargetHtml(digit, at, tgt, onchangeExtra) {
  const info = IVR_ACTION_LABELS[at] || IVR_ACTION_LABELS.hangup;
  const oc = onchangeExtra || '';
  if (!info.hasTarget) return '';

  const makeSearchable = (id, opts, placeholder) => _ivrSearchableSelect({
    id,
    options: opts,
    value: tgt,
    placeholder,
    onChange: `(v)=>{ _ivrKeyChange('${digit}','target',v);_ivrUpdateFlowDebounced();${oc} }`,
    style: 'width:100%;box-sizing:border-box'
  });

  if (at === 'extension') {
    return makeSearchable(
      `ivr-key-target-${digit}`,
      _ivrExts.map(e => ({ value: e.id, label: `${e.id}${e.caller_id_name?' ('+e.caller_id_name+')':''}` })),
      '選擇分機…'
    );
  } else if (at === 'group') {
    return makeSearchable(
      `ivr-key-target-${digit}`,
      _ivrGroups.map(g => ({ value: g.id, label: `${g.id}${g.name?' ('+g.name+')':''}` })),
      '選擇群組…'
    );
  } else if (at === 'ivr') {
    return makeSearchable(
      `ivr-key-target-${digit}`,
      _ivrList.filter(v => v.id !== (_ivrEditing||{}).id).map(v => ({ value: v.id, label: `${v.id}${v.name?' ('+v.name+')':''}` })),
      '選擇子選單 IVR…'
    );
  } else if (at === 'voicemail') {
    return makeSearchable(
      `ivr-key-target-${digit}`,
      _ivrExts.map(e => ({ value: e.id, label: `${e.id}${e.caller_id_name?' ('+e.caller_id_name+')':''}` })),
      '選擇語音信箱分機…'
    );
  } else if (at === 'playback') {
    const sndOpts = _ivrSounds.filter(s=>s.source==='custom').map(s =>
      `<option value="${s.path}" ${tgt===s.path?'selected':''}>${s.filename}</option>`
    ).join('');
    return `<div style="width:100%">
      <input id="ivr-key-target-${digit}" class="settings-input" style="width:100%;box-sizing:border-box"
        value="${tgt}" placeholder="/var/lib/freeswitch/sounds/custom/xxx.wav"
        onchange="_ivrKeyChange('${digit}','target',this.value);_ivrUpdateFlowDebounced()${oc}">
      ${sndOpts ? `<select style="width:100%;margin-top:4px;padding:4px;border:1px solid var(--border);border-radius:4px;background:var(--panel);color:var(--text);font-size:12px;box-sizing:border-box"
        onchange="document.getElementById('ivr-key-target-${digit}').value=this.value;_ivrKeyChange('${digit}','target',this.value);_ivrUpdateFlowDebounced()${oc}">
        <option value="">— 選擇音檔 —</option>${sndOpts}</select>` : ''}
    </div>`;
  } else {
    return `<input id="ivr-key-target-${digit}" class="settings-input" style="width:100%;box-sizing:border-box"
      value="${tgt}" placeholder="${info.targetLabel}"
      onchange="_ivrKeyChange('${digit}','target',this.value);_ivrUpdateFlowDebounced()${oc}">`;
  }
}



function _ivrKeyRow(digit, action) {
  const at   = action.action_type || 'hangup';
  const tgt  = action.target || '';
  const info = IVR_ACTION_LABELS[at] || IVR_ACTION_LABELS.hangup;
  const specialLabel = IVR_SPECIAL_DIGITS[digit] || `按鍵 [${digit}]`;

  const typeOpts = Object.entries(IVR_ACTION_LABELS).map(([k,v]) =>
    `<option value="${k}" ${at===k?'selected':''}>${v.icon} ${v.label}</option>`
  ).join('');

  const targetHtml = _ivrBuildTargetHtml(digit, at, tgt);

  return `
  <div data-digit="${digit}" style="margin-bottom:6px;padding:7px 9px;background:var(--bg);border:1px solid var(--border);border-radius:4px;border-left:3px solid ${info.color}">
    <div style="display:flex;align-items:center;gap:6px">
      <span style="font-size:12px;font-weight:700;color:${info.color};min-width:76px;flex-shrink:0">${specialLabel}</span>
      <select class="settings-input" style="flex:1;min-width:0" onchange="_ivrKeyChange('${digit}','action_type',this.value);_ivrUpdateFlowDebounced()">
        ${typeOpts}
      </select>
      <button class="btn" style="font-size:12px;padding:2px 8px;color:var(--red);flex-shrink:0;white-space:nowrap"
        onclick="_ivrRemoveKey('${digit}')">✕ 刪除</button>
    </div>
    ${targetHtml ? `<div style="margin-top:5px">${targetHtml}</div>` : ''}
  </div>`;
}

// ── 無效鍵 / 超時 整合設定卡片渲染 ──────────────────────────────────────────
function _ivrRenderSpecialKeyCard(digit, ivr) {
  const isI   = digit === 'i';
  const cfg   = {
    label:      isI ? '❌ 無效鍵 (i)' : '⏱ 超時 (t)',
    desc:       isI ? '按錯鍵時' : '等待按鍵逾時時',
    color:      isI ? '#c62828' : '#1565c0',
    retriesId:  isI ? 'ivr-invalid-retries'    : 'ivr-timeout-retries',
    hintId:     isI ? 'ivr-invalid-retries-hint': 'ivr-timeout-retries-hint',
    finalSndId: isI ? 'ivr-invalid-final-sound' : 'ivr-timeout-final-sound',
    onInput:    isI ? '_ivrUpdateInvalidLabel(this.value)' : '_ivrUpdateTimeoutLabel(this.value)',
    retries:    isI ? (ivr.invalid_retries ?? 1) : (ivr.timeout_retries ?? 1),
    finalSound: isI ? (ivr.invalid_final_sound || '') : (ivr.timeout_final_sound || ''),
  };

  // 目前此 digit 的動作設定
  const action = (ivr.keys || {})[digit] || { action_type: 'hangup', target: '' };
  const at     = action.action_type || 'hangup';
  const tgt    = action.target || '';

  // 最終動作只允許：hangup、extension、group、ivr、voicemail（不含 playback，音檔已在 final_sound 設定）
  const FINAL_ACTIONS = {
    hangup:    { icon: '✕',  label: '掛斷',     hasTarget: false },
    extension: { icon: '⊟', label: '轉接分機', hasTarget: true  },
    group:     { icon: '▣', label: '轉接群組', hasTarget: true  },
    ivr:       { icon: '🎛', label: '子選單',   hasTarget: true  },
    voicemail: { icon: '📬', label: '語音信箱', hasTarget: true  },
  };

  const typeOpts = Object.entries(FINAL_ACTIONS).map(([k,v]) =>
    `<option value="${k}" ${at===k?'selected':''}>${v.icon} ${v.label}</option>`
  ).join('');

  const targetHtml = _ivrBuildTargetHtml(digit, at, tgt);

  const retries  = parseInt(cfg.retries) || 1;
  const hintText = retries <= 1
    ? '第 1 次就執行下方最終行為'
    : `前 ${retries-1} 次重播選單，第 ${retries} 次執行最終行為`;

  const sndOpts = _ivrSounds.filter(s => s.source === 'custom').map(s =>
    `<option value="${s.path}" ${cfg.finalSound===s.path?'selected':''}>${s.filename}</option>`
  ).join('');

  return `
  <div style="background:var(--panel2);border:1px solid ${cfg.color}30;border-left:4px solid ${cfg.color};border-radius:6px;padding:13px;margin-bottom:10px">
    <div style="font-size:13px;font-weight:700;color:${cfg.color};margin-bottom:12px">${cfg.label}</div>

    <!-- 重播次數 -->
    <div style="display:grid;grid-template-columns:160px 1fr;gap:10px;align-items:start;margin-bottom:12px">
      <div>
        <label style="font-size:12px;color:var(--label);display:block;margin-bottom:4px">
          重播次數
        </label>
        <input id="${cfg.retriesId}" class="settings-input" type="number"
          value="${cfg.retries}" min="1" max="10"
          oninput="${cfg.onInput}">
        <div id="${cfg.hintId}" style="font-size:11px;color:${cfg.color};margin-top:4px;font-weight:600">${hintText}</div>
      </div>
      <div style="font-size:11px;color:var(--muted);padding-top:22px;line-height:1.7">
        ${cfg.desc}，播放選單讓使用者重新輸入。<br>
        達到設定次數後，執行下方的最終行為。
      </div>
    </div>

    <!-- 最終行為 -->
    <div style="border-top:1px dashed ${cfg.color}40;padding-top:12px">
      <div style="font-size:11px;font-weight:700;color:var(--label);margin-bottom:10px">
        ▸ 第 <span id="${cfg.retriesId}-badge">${retries}</span> 次觸發時的最終行為
      </div>

      <!-- ① 最後一次語音（選填） -->
      <div style="margin-bottom:10px;background:var(--bg);border:1px solid var(--border);border-radius:4px;padding:10px">
        <label style="font-size:12px;color:var(--label);display:block;margin-bottom:6px">
          ① 先播放語音 <span style="font-weight:400;color:var(--muted)">（選填）</span>
        </label>
        <div style="display:flex;gap:6px;align-items:center">
          <input id="${cfg.finalSndId}" class="settings-input"
            value="${cfg.finalSound}" placeholder="留空 = 不播放額外語音"
            style="flex:1;min-width:0;font-size:12px">
          ${sndOpts ? `
          <select style="flex-shrink:0;padding:5px 6px;border:1px solid var(--border);border-radius:4px;
            background:var(--panel);color:var(--text);font-size:12px;max-width:160px"
            onchange="if(this.value){document.getElementById('${cfg.finalSndId}').value=this.value;}this.value=''">
            <option value="">📂 選擇音檔</option>${sndOpts}</select>` : ''}
        </div>
      </div>

      <!-- ② 最終動作 -->
      <div style="background:var(--bg);border:1px solid var(--border);border-radius:4px;padding:10px">
        <label style="font-size:12px;color:var(--label);display:block;margin-bottom:4px">② 然後執行</label>
        <select id="ivr-special-action-type-${digit}" class="settings-input" style="width:100%;box-sizing:border-box"
          onchange="_ivrSpecialKeyActionChange('${digit}', this.value)">
          ${typeOpts}
        </select>
        <div id="ivr-special-target-${digit}" style="margin-top:6px">
          ${targetHtml || ''}
        </div>
      </div>
    </div>
  </div>`;
}

// 整合卡片的動作類型變更（更新目標欄位 + _ivrEditing.keys）
function _ivrSpecialKeyActionChange(digit, newType) {
  if (!_ivrEditing) return;
  if (!_ivrEditing.keys[digit]) _ivrEditing.keys[digit] = {};
  _ivrEditing.keys[digit].action_type = newType;
  _ivrEditing.keys[digit].target = '';
  // 重繪目標欄位
  const targetDiv = document.getElementById(`ivr-special-target-${digit}`);
  if (targetDiv) targetDiv.innerHTML = _ivrBuildTargetHtml(digit, newType, '');
  _ivrUpdateFlowDebounced();
}


function _ivrKeyChange(digit, field, value) {
  if (!_ivrEditing || !_ivrEditing.keys[digit]) return;
  _ivrEditing.keys[digit][field] = value;
  // 如果 action_type 改變，更新整個 keys container
  if (field === 'action_type') {
    _ivrEditing.keys[digit].target = '';
    document.getElementById('ivr-keys-container').innerHTML =
      _ivrRenderKeys(_ivrEditing.keys);
    _ivrUpdateFlow();
  }
}

function _ivrAddKey() {
  const sel = document.getElementById('ivr-add-key-select');
  const digit = sel ? sel.value : '1';
  if (!digit) return;
  if (_ivrEditing.keys[digit]) {
    // 已存在：閃爍提示
    const container = document.getElementById('ivr-keys-container');
    const rows = container ? container.querySelectorAll('div[data-digit="' + digit + '"]') : [];
    if (rows.length > 0) {
      rows[0].style.outline = '2px solid var(--accent)';
      setTimeout(() => rows[0].style.outline = '', 1200);
    }
    return;
  }
  _ivrEditing.keys[digit] = { action_type: 'extension', target: '' };
  document.getElementById('ivr-keys-container').innerHTML =
    _ivrRenderKeys(_ivrEditing.keys);
  _ivrUpdateFlow();
}

function _ivrAddSpecialKey(digit) {
  if (_ivrEditing.keys[digit]) return; // 已存在
  _ivrEditing.keys[digit] = { action_type: 'hangup', target: '' };
  document.getElementById('ivr-keys-container').innerHTML =
    _ivrRenderKeys(_ivrEditing.keys);
  _ivrUpdateFlow();
}

function _ivrRemoveKey(digit) {
  delete _ivrEditing.keys[digit];
  document.getElementById('ivr-keys-container').innerHTML =
    _ivrRenderKeys(_ivrEditing.keys);
  _ivrUpdateFlow();
}

// ── 無效鍵 / 超時 重播次數 hint ──────────────────────────────────────────────
function _ivrUpdateInvalidLabel(val) {
  const n = parseInt(val) || 1;
  const el = document.getElementById('ivr-invalid-retries-hint');
  if (el) el.textContent = n <= 1 ? '第 1 次就執行下方動作' : `前 ${n-1} 次重播選單，第 ${n} 次才執行下方動作`;
  const badge = document.getElementById('ivr-invalid-retries-badge');
  if (badge) badge.textContent = n;
}

function _ivrUpdateTimeoutLabel(val) {
  const n = parseInt(val) || 1;
  const el = document.getElementById('ivr-timeout-retries-hint');
  if (el) el.textContent = n <= 1 ? '第 1 次就執行下方動作' : `前 ${n-1} 次重播選單，第 ${n} 次才執行下方動作`;
  const badge = document.getElementById('ivr-timeout-retries-badge');
  if (badge) badge.textContent = n;
}

// 編輯器載入後初始化 hint 文字
function _ivrInitRetryHints() {
  const iv = document.getElementById('ivr-invalid-retries');
  const tv = document.getElementById('ivr-timeout-retries');
  if (iv) _ivrUpdateInvalidLabel(iv.value);
  if (tv) _ivrUpdateTimeoutLabel(tv.value);
}


function _ivrRenderSchedule(sched) {
  const days = ['日','一','二','三','四','五','六'];
  const dayChecks = days.map((d, i) => `
    <label style="display:inline-flex;align-items:center;gap:3px;font-size:12px;cursor:pointer">
      <input type="checkbox" ${(sched.work_days||[]).includes(i)?'checked':''}
        onchange="_ivrToggleDay(${i},this.checked)"> ${d}
    </label>`).join(' ');

  const ivrOpts = (prefix) => _ivrList.map(v =>
    `<option value="${v.id}" ${(sched[prefix]||'')=== v.id?'selected':''}>${v.id} ${v.name?'('+v.name+')':''}</option>`
  ).join('');
  const extOpts = (prefix) => [
    ..._ivrExts.map(e => `<option value="${e.id}" ${(sched[prefix]||'')=== e.id?'selected':''}>${e.id} ${e.caller_id_name?'('+e.caller_id_name+')':''}</option>`),
    ..._ivrGroups.map(g => `<option value="${g.id}" ${(sched[prefix]||'')=== g.id?'selected':''}>${g.id} ${g.name?'('+g.name+')':''}</option>`),
  ].join('');

  const holidays = (sched.holiday_dates || []).map(d =>
    `<span style="display:inline-flex;align-items:center;gap:4px;background:var(--bg);border:1px solid var(--border);border-radius:3px;padding:2px 6px;font-size:12px">
      ${d} <button onclick="_ivrRemoveHoliday('${d}')" style="border:none;background:none;cursor:pointer;color:var(--red);font-size:14px;line-height:1">×</button>
    </span>`
  ).join('');

  return `
  <div style="background:rgba(46,125,50,0.05);border:1px solid rgba(46,125,50,0.2);border-radius:5px;padding:12px">

    <!-- 上班時段 -->
    <div style="margin-bottom:10px">
      <div style="font-size:12px;font-weight:600;color:var(--label);margin-bottom:6px">🕘 上班時段</div>
      <div style="display:flex;align-items:center;gap:8px;flex-wrap:wrap">
        <span style="font-size:12px">工作日：</span>
        ${dayChecks}
      </div>
      <div style="display:flex;align-items:center;gap:8px;margin-top:6px">
        <span style="font-size:12px">時間：</span>
        <input id="ivr-work-start" type="time" class="settings-input" style="width:110px" value="${sched.work_start||'09:00'}">
        <span style="font-size:12px">至</span>
        <input id="ivr-work-end" type="time" class="settings-input" style="width:110px" value="${sched.work_end||'18:00'}">
      </div>
      <div style="margin-top:6px">
        <label style="font-size:12px;display:block;margin-bottom:3px;color:var(--label)">上班時段導向</label>
        ${_ivrSearchableSelect({
          id: 'ivr-work-target',
          options: [
            { value: '', label: '─ 本選單 ─' },
            ..._ivrList.map(v => ({ value: v.id, label: `${v.id}${v.name?' ('+v.name+')':''}` })),
            ..._ivrExts.map(e => ({ value: e.id, label: `${e.id}${e.caller_id_name?' ('+e.caller_id_name+')':''}` })),
            ..._ivrGroups.map(g => ({ value: g.id, label: `${g.id}${g.name?' ('+g.name+')':''}` })),
          ],
          value: sched.work_target || '',
          placeholder: '─ 本選單 ─',
          onChange: `(v)=>{ if(_ivrEditing&&_ivrEditing.schedule)_ivrEditing.schedule.work_target=v;_ivrUpdateFlowDebounced(); }`,
          style: 'width:100%'
        })}
      </div>
    </div>

    <!-- 下班/假日 -->
    <div style="margin-bottom:10px">
      <div style="font-size:12px;font-weight:600;color:var(--label);margin-bottom:6px">🌙 下班/假日時段</div>
      <div style="margin-bottom:6px">
        <label style="font-size:12px;display:block;margin-bottom:3px;color:var(--label)">下班時段語音 <span style="font-weight:400;color:var(--muted)">（選填，接通後播放）</span></label>
        ${_ivrSoundRow('ivr-offhour-sound', '', sched.offhour_sound||'', '_ivrSetOffhourSound')}
      </div>
      <div>
        <label style="font-size:12px;display:block;margin-bottom:3px;color:var(--label)">下班時段轉接至</label>
        <div id="ivr-offhour-action-panel">${_ivrRenderActionSelector('ivr-oha', sched.offhour_action||{action_type:'hangup',target:''}, '_ivrOffhourActionChange')}</div>
      </div>
    </div>

    <!-- 假日 -->
    <div>
      <div style="font-size:12px;font-weight:600;color:var(--label);margin-bottom:6px">📅 特定假日</div>
      <div style="display:flex;gap:6px;margin-bottom:6px">
        <input type="date" id="ivr-holiday-input" class="settings-input" style="width:160px">
        <button class="btn" style="font-size:12px" onclick="_ivrAddHoliday()">＋ 加入</button>
      </div>
      <div id="ivr-holidays-list" style="display:flex;flex-wrap:wrap;gap:4px">
        ${holidays || '<span style="font-size:12px;color:var(--muted)">尚無特定假日</span>'}
      </div>
      <div style="margin-top:6px">
        <label style="font-size:12px;display:block;margin-bottom:3px;color:var(--label)">假日轉接至 <span style="font-weight:400;color:var(--muted)">（空=同下班時段）</span></label>
        <div id="ivr-holiday-action-panel">${_ivrRenderActionSelector('ivr-hda', sched.holiday_action||{action_type:'',target:''}, '_ivrHolidayActionChange')}</div>
      </div>
    </div>
  </div>`;
}

// 下班語音選擇回調：更新 _ivrEditing 並同步 input
function _ivrSetOffhourSound(val) {
  if (_ivrEditing && _ivrEditing.schedule) {
    _ivrEditing.schedule.offhour_sound = val;
  }
}

// 將 schedule panel 的 DOM 值同步回 _ivrEditing.schedule
function _ivrSyncScheduleFromDOM() {
  if (!_ivrEditing) return;
  const g = (id) => { const e = document.getElementById(id); return e ? e.value : null; };
  const s = _ivrEditing.schedule;
  const ws = g('ivr-work-start');     if (ws  !== null) s.work_start     = ws;
  const we = g('ivr-work-end');       if (we  !== null) s.work_end       = we;
  const wt = g('ivr-work-target');    if (wt  !== null) s.work_target    = wt;
  const os = g('ivr-offhour-sound');  if (os  !== null) s.offhour_sound  = os;
  // [NEW] offhour_action
  const ohat = g('ivr-oha-type');   if (ohat !== null) { if (!s.offhour_action) s.offhour_action = {}; s.offhour_action.action_type = ohat; }
  const ohtg = g('ivr-oha-target'); if (ohtg !== null) { if (!s.offhour_action) s.offhour_action = {}; s.offhour_action.target = ohtg; }
  // [NEW] holiday_action
  const hdat = g('ivr-hda-type');   if (hdat !== null) { if (!s.holiday_action) s.holiday_action = {}; s.holiday_action.action_type = hdat; }
  const hdtg = g('ivr-hda-target'); if (hdtg !== null) { if (!s.holiday_action) s.holiday_action = {}; s.holiday_action.target = hdtg; }
}

// ── Searchable Select helper ──────────────────────────────────────────────────
function _ivrSearchableSelect({ id, options, value, placeholder, onChange, style = '' }) {
  const selectedLabel = (options.find(o => o.value === value) || {}).label || '';
  return `
    <div class="ivr-ss-wrap" id="${id}-wrap" style="position:relative;flex:1;min-width:0;${style}">
      <div class="ivr-ss-display settings-input" id="${id}-display"
        style="display:flex;align-items:center;justify-content:space-between;cursor:pointer;user-select:none;padding-right:6px"
        onclick="_ivrSsToggle('${id}')">
        <span id="${id}-label" style="overflow:hidden;text-overflow:ellipsis;white-space:nowrap;flex:1">${
          selectedLabel
            ? selectedLabel
            : `<span style="opacity:.5">${placeholder}</span>`
        }</span>
        <span style="font-size:10px;margin-left:4px;opacity:.6">▼</span>
      </div>
      <div id="${id}-popup" style="display:none;position:absolute;z-index:9999;left:0;top:calc(100% + 2px);min-width:100%;max-width:320px;background:var(--panel);border:1px solid var(--border);border-radius:6px;box-shadow:0 4px 16px rgba(0,0,0,.18);overflow:hidden">
        <div style="padding:6px">
          <input class="settings-input" id="${id}-search" placeholder="🔍 輸入號碼或名稱…"
            style="width:100%;box-sizing:border-box;margin:0"
            oninput="_ivrSsFilter('${id}')"
            onclick="event.stopPropagation()">
        </div>
        <div id="${id}-list" style="max-height:220px;overflow-y:auto">
          ${options.map(o => `
            <div class="ivr-ss-opt${o.value === value ? ' ivr-ss-sel' : ''}"
              data-value="${o.value.replace(/"/g,'&quot;')}"
              data-label="${o.label.replace(/"/g,'&quot;')}"
              onclick="_ivrSsSelect('${id}', this.dataset.value, this.dataset.label, ${onChange})"
              style="padding:7px 10px;cursor:pointer;white-space:nowrap;overflow:hidden;text-overflow:ellipsis">
              ${o.label}
            </div>`).join('')}
        </div>
      </div>
      <input type="hidden" id="${id}" value="${value}">
    </div>`;
}

function _ivrSsToggle(id) {
  const popup = document.getElementById(id + '-popup');
  if (!popup) return;
  const isOpen = popup.style.display !== 'none';
  document.querySelectorAll('.ivr-ss-wrap [id$="-popup"]').forEach(p => { p.style.display = 'none'; });
  if (!isOpen) {
    popup.style.display = '';
    const search = document.getElementById(id + '-search');
    if (search) { search.value = ''; _ivrSsFilter(id); search.focus(); }
  }
}

function _ivrSsFilter(id) {
  const q = (document.getElementById(id + '-search') || {}).value || '';
  const ql = q.toLowerCase();
  document.querySelectorAll('#' + id + '-list .ivr-ss-opt').forEach(el => {
    el.style.display = el.textContent.toLowerCase().includes(ql) ? '' : 'none';
  });
}

function _ivrSsSelect(id, value, label, onChangeFn) {
  const hidden = document.getElementById(id);
  if (hidden) hidden.value = value;
  const labelEl = document.getElementById(id + '-label');
  if (labelEl) labelEl.innerHTML = label || `<span style="opacity:.5">請選擇…</span>`;
  document.querySelectorAll('#' + id + '-list .ivr-ss-opt').forEach(el => {
    el.classList.toggle('ivr-ss-sel', el.dataset.value === value);
  });
  const popup = document.getElementById(id + '-popup');
  if (popup) popup.style.display = 'none';
  if (typeof onChangeFn === 'function') onChangeFn(value);
}

// 點擊選單外部時關閉所有 popup
document.addEventListener('click', function(e) {
  if (!e.target.closest('.ivr-ss-wrap')) {
    document.querySelectorAll('.ivr-ss-wrap [id$="-popup"]').forEach(p => { p.style.display = 'none'; });
  }
});
// ─────────────────────────────────────────────────────────────────────────────

function _ivrRenderActionSelector(idPrefix, obj, onChangeFn) {
  const at  = obj.action_type || 'extension';
  const tgt = obj.target || '';

  const onSelect = `(v)=>{ ${onChangeFn}(v,'target');_ivrUpdateFlowDebounced(); }`;

  let targetHtml = '';
  if (at === 'extension' || at === 'voicemail') {
    targetHtml = _ivrSearchableSelect({
      id: `${idPrefix}-target`,
      options: _ivrExts.map(e => ({ value: e.id, label: `${e.id}${e.caller_id_name?' ('+e.caller_id_name+')':''}` })),
      value: tgt, placeholder: '選擇分機…', onChange: onSelect,
      style: 'flex:1;min-width:0'
    });
  } else if (at === 'group') {
    targetHtml = _ivrSearchableSelect({
      id: `${idPrefix}-target`,
      options: _ivrGroups.map(g => ({ value: g.id, label: `${g.id}${g.name?' ('+g.name+')':''}` })),
      value: tgt, placeholder: '選擇群組…', onChange: onSelect,
      style: 'flex:1;min-width:0'
    });
  } else if (at === 'ivr') {
    targetHtml = _ivrSearchableSelect({
      id: `${idPrefix}-target`,
      options: _ivrList.map(v => ({ value: v.id, label: `${v.id}${v.name?' ('+v.name+')':''}` })),
      value: tgt, placeholder: '選擇 IVR 選單…', onChange: onSelect,
      style: 'flex:1;min-width:0'
    });
  } else {
    // hangup → 無 target
    targetHtml = `<input id="${idPrefix}-target" class="settings-input" style="flex:1;min-width:0"
      value="" placeholder="（不需要目標）" disabled>`;
  }

  return `<div style="display:flex;gap:6px;align-items:center">
    <select id="${idPrefix}-type" class="settings-input" style="width:120px;flex-shrink:0"
      onchange="${onChangeFn}(this.value,'action_type');_ivrUpdateFlowDebounced()">
      <option value="extension" ${at==='extension'?'selected':''}>📞 轉分機</option>
      <option value="group"     ${at==='group'    ?'selected':''}>👥 轉群組</option>
      <option value="ivr"       ${at==='ivr'      ?'selected':''}>🎛 IVR選單</option>
      <option value="voicemail" ${at==='voicemail'?'selected':''}>📬 語音信箱</option>
      <option value="hangup"    ${at==='hangup'   ?'selected':''}>📵 掛斷</option>
    </select>
    ${targetHtml}
  </div>`;
}

// ── [NEW] action selector onchange 回調 ──────────────────────────────────────
function _ivrAutoTransferChange(val, field) {
  if (!_ivrEditing.auto_transfer) _ivrEditing.auto_transfer = {};
  _ivrEditing.auto_transfer[field] = val;
  // action_type 改變時需重渲染 target selector
  if (field === 'action_type') {
    const panel = document.getElementById('ivr-auto-transfer-panel');
    if (panel) panel.innerHTML = _ivrRenderActionSelector('ivr-at', _ivrEditing.auto_transfer, '_ivrAutoTransferChange');
  }
}
function _ivrPgtChange(val, field) {
  if (!_ivrEditing.post_greeting_transfer) _ivrEditing.post_greeting_transfer = {};
  _ivrEditing.post_greeting_transfer[field] = val;
  if (field === 'action_type') {
    const panel = document.getElementById('ivr-pgt-panel');
    if (panel) panel.innerHTML = _ivrRenderActionSelector('ivr-pgt', _ivrEditing.post_greeting_transfer, '_ivrPgtChange');
  }
}
function _ivrOffhourActionChange(val, field) {
  if (!_ivrEditing.schedule.offhour_action) _ivrEditing.schedule.offhour_action = {};
  _ivrEditing.schedule.offhour_action[field] = val;
  if (field === 'action_type') {
    const panel = document.getElementById('ivr-offhour-action-panel');
    if (panel) panel.innerHTML = _ivrRenderActionSelector('ivr-oha', _ivrEditing.schedule.offhour_action, '_ivrOffhourActionChange');
  }
}
function _ivrHolidayActionChange(val, field) {
  if (!_ivrEditing.schedule.holiday_action) _ivrEditing.schedule.holiday_action = {};
  _ivrEditing.schedule.holiday_action[field] = val;
  if (field === 'action_type') {
    const panel = document.getElementById('ivr-holiday-action-panel');
    if (panel) panel.innerHTML = _ivrRenderActionSelector('ivr-hda', _ivrEditing.schedule.holiday_action, '_ivrHolidayActionChange');
  }
}

function _ivrToggleDirectDial(enabled) {
  _ivrEditing.direct_ext_dialing = enabled;
  document.getElementById('ivr-direct-dial-panel').style.display = enabled ? '' : 'none';
  _ivrUpdateFlowDebounced();
}

function _ivrToggleSchedule(enabled) {
  _ivrSyncScheduleFromDOM();   // 先把現有 DOM 值存回物件
  _ivrEditing.schedule.enabled = enabled;
  const panel = document.getElementById('ivr-schedule-panel');
  if (panel) {
    panel.style.display = enabled ? '' : 'none';
    if (enabled && panel.innerHTML.trim() === '') {
      panel.innerHTML = _ivrRenderSchedule(_ivrEditing.schedule);
    }
  }
  _ivrUpdateFlow();
}

function _ivrToggleDay(day, checked) {
  const days = _ivrEditing.schedule.work_days || [];
  if (checked) { if (!days.includes(day)) days.push(day); }
  else { const i = days.indexOf(day); if (i >= 0) days.splice(i,1); }
  _ivrEditing.schedule.work_days = days.sort();
  _ivrUpdateFlow();
}

function _ivrAddHoliday() {
  const inp = document.getElementById('ivr-holiday-input');
  if (!inp || !inp.value) return;
  const dates = _ivrEditing.schedule.holiday_dates || [];
  if (!dates.includes(inp.value)) {
    dates.push(inp.value);
    dates.sort();
    _ivrEditing.schedule.holiday_dates = dates;
    // 重繪假日列表
    const listEl = document.getElementById('ivr-holidays-list');
    if (listEl) {
      listEl.innerHTML = dates.map(d =>
        `<span style="display:inline-flex;align-items:center;gap:4px;background:var(--bg);border:1px solid var(--border);border-radius:3px;padding:2px 6px;font-size:12px">
          ${d} <button onclick="_ivrRemoveHoliday('${d}')" style="border:none;background:none;cursor:pointer;color:var(--red);font-size:14px;line-height:1">×</button>
        </span>`
      ).join('');
    }
  }
  inp.value = '';
}

function _ivrRemoveHoliday(date) {
  const dates = _ivrEditing.schedule.holiday_dates || [];
  const i = dates.indexOf(date);
  if (i >= 0) dates.splice(i,1);
  _ivrEditing.schedule.holiday_dates = dates;
  const listEl = document.getElementById('ivr-holidays-list');
  if (listEl) {
    listEl.innerHTML = dates.length > 0
      ? dates.map(d =>
          `<span style="display:inline-flex;align-items:center;gap:4px;background:var(--bg);border:1px solid var(--border);border-radius:3px;padding:2px 6px;font-size:12px">
            ${d} <button onclick="_ivrRemoveHoliday('${d}')" style="border:none;background:none;cursor:pointer;color:var(--red);font-size:14px;line-height:1">×</button>
          </span>`
        ).join('')
      : '<span style="font-size:12px;color:var(--muted)">尚無特定假日</span>';
  }
}

// ── 流程圖渲染（SVG-based）────────────────────────────────────────────────────
let _ivrFlowTimer = null;

function _ivrUpdateFlowDebounced() {
  clearTimeout(_ivrFlowTimer);
  _ivrFlowTimer = setTimeout(_ivrUpdateFlow, 300);
}

function _ivrUpdateFlow() {
  const canvas = document.getElementById('ivr-flow-canvas');
  if (!canvas) return;
  canvas.innerHTML = _ivrRenderFlow();
}

function _ivrRenderFlow() {
  if (!_ivrEditing) return '';
  const ivr = _ivrEditing;

  // 從表單讀取最新值（如果 DOM 存在）
  const V = (id, fallback='') => {
    const el = document.getElementById(id);
    return el ? el.value : fallback;
  };

  const ivrId     = V('ivr-id',     ivr.id);
  const ivrName   = V('ivr-name',   ivr.name);
  const ivrNumber = V('ivr-number', ivr.number);
  const timeout   = V('ivr-timeout', ivr.timeout);
  const sched     = ivr.schedule || {};

  // 建立節點列表
  const nodes = [];
  const edges = [];

  // 來電節點（如有入口號碼）
  if (ivrNumber) {
    nodes.push({ id: 'entry', type: 'entry', label: `📞 來電 ${ivrNumber}`, color: '#1565c0' });
    if (sched.enabled) {
      nodes.push({ id: 'sched', type: 'schedule', label: '⏰ 時段判斷', color: '#4a148c' });
      edges.push({ from: 'entry', to: 'sched' });
      if (sched.work_target) {
        nodes.push({ id: 'work_t', type: 'ivr', label: `🕘 上班\n${sched.work_target}`, color: '#2e7d32' });
        edges.push({ from: 'sched', to: 'work_t', label: '上班' });
      }
      // [NEW] 下班：優先顯示 offhour_action，fallback 舊 offhour_target
      const oha = sched.offhour_action;
      const offLabel = (oha && oha.target) ? oha.target : (sched.offhour_target || '掛斷');
      const offIcon  = (oha && oha.action_type === 'ivr') ? '🎛' : (oha && oha.action_type === 'extension') ? '📞' : '📵';
      nodes.push({ id: 'off_t', type: 'action', label: `🌙 下班\n${offIcon} ${offLabel}`, color: '#6a1b9a' });
      edges.push({ from: 'sched', to: 'off_t', label: '下班' });
      // [NEW] 假日：顯示 holiday_action（若有設定）
      const hda = sched.holiday_action;
      if (hda && hda.target) {
        const hdIcon = hda.action_type === 'ivr' ? '🎛' : hda.action_type === 'extension' ? '📞' : '📵';
        nodes.push({ id: 'hday_t', type: 'action', label: `📅 假日\n${hdIcon} ${hda.target}`, color: '#bf360c' });
        edges.push({ from: 'sched', to: 'hday_t', label: '假日' });
      }
      // IVR 選單節點
      nodes.push({ id: 'menu', type: 'menu', label: `🎛 ${ivrName||ivrId}\n選單播放`, color: '#0277bd' });
      if (sched.work_target === ivrId || !sched.work_target) {
        edges.push({ from: 'sched', to: 'menu', label: '進入選單' });
      }
    } else {
      nodes.push({ id: 'menu', type: 'menu', label: `🎛 ${ivrName||ivrId}\n選單播放`, color: '#0277bd' });
      edges.push({ from: 'entry', to: 'menu' });
    }
  } else {
    nodes.push({ id: 'menu', type: 'menu', label: `🎛 ${ivrName||ivrId}\n（子選單）`, color: '#0277bd' });
  }

  // [NEW] auto_transfer 節點（接在 menu 前）
  const atCfg = ivr.auto_transfer;
  if (atCfg && atCfg.enabled && atCfg.target) {
    const atIcon = atCfg.action_type === 'ivr' ? '🎛' : atCfg.action_type === 'extension' ? '📞' : '👥';
    nodes.push({ id: 'auto_t', type: 'action', label: `⚡ 直接轉接\n${atIcon} ${atCfg.target}`, color: '#0277bd' });
    edges.push({ from: 'menu', to: 'auto_t', label: '立即' });
  }

  // [NEW] post_greeting_transfer 節點
  const pgtCfg = ivr.post_greeting_transfer;
  if (pgtCfg && pgtCfg.enabled && pgtCfg.target) {
    const pgtIcon = pgtCfg.action_type === 'ivr' ? '🎛' : pgtCfg.action_type === 'extension' ? '📞' : '👥';
    nodes.push({ id: 'pgt_t', type: 'action', label: `🔊 播後轉接\n${pgtIcon} ${pgtCfg.target}`, color: '#006064' });
    edges.push({ from: 'menu', to: 'pgt_t', label: '播完' });
  }

  // 按鍵節點
  const keys = ivr.keys || {};
  Object.entries(keys).forEach(([digit, action]) => {
    const at   = action.action_type || 'hangup';
    const tgt  = action.target || '';
    const info = IVR_ACTION_LABELS[at] || IVR_ACTION_LABELS.hangup;
    const specialLabel = IVR_SPECIAL_DIGITS[digit] ? IVR_SPECIAL_DIGITS[digit].replace(' ('+digit+')','') : `[${digit}]`;
    // 第二行只顯示檔名（去掉路徑前綴），最多 16 字元
    const tgtShort = tgt ? tgt.replace(/^.*\//, '').slice(0, 16) + (tgt.replace(/^.*\//, '').length > 16 ? '…' : '') : '';
    const nodeLabel = tgtShort ? `${info.icon} ${specialLabel}\n${tgtShort}` : `${info.icon} ${specialLabel}\n${info.label}`;
    const nodeId = `key_${digit}`;
    nodes.push({ id: nodeId, type: at, label: nodeLabel, color: info.color });
    edges.push({ from: 'menu', to: nodeId, label: IVR_SPECIAL_DIGITS[digit] ? digit.toUpperCase() : digit });
  });

  return _ivrSVGFlow(nodes, edges);
}

function _ivrSVGFlow(nodes, edges) {
  return _ivrSVGFlowSized(nodes, edges, 130, 48, 24, 52);
}

function _ivrSVGFlowSized(nodes, edges, NODE_W, NODE_H, GAP_X, GAP_Y) {
  if (nodes.length === 0) {
    return '<div style="text-align:center;padding:40px;color:var(--muted);font-size:13px">填寫左側設定後，流程圖將在此即時顯示</div>';
  }

  const trunc = (s, maxLen) => {
    if (!s) return '';
    const short = s.replace(/^.*\//, '');
    return short.length > maxLen ? short.slice(0, maxLen) + '…' : short;
  };
  // 動態計算層號：依實際存在的節點決定優先序，確保無空洞
  const hasEntry = nodes.some(n => n.id === 'entry');
  const hasSched = nodes.some(n => n.id === 'sched');
  const hasSchedChildren = nodes.some(n => n.id === 'work_t' || n.id === 'off_t' || n.id === 'hd_t');
  let _layerSeq = 0;
  const _layerMap = {};
  if (hasEntry)         _layerMap['entry'] = _layerSeq++;
  if (hasSched)         _layerMap['sched'] = _layerSeq++;
  // schedule 子節點（上班/下班/假日）與 menu 同層（sched 存在時 menu 也在此層）
  if (hasSchedChildren) _layerMap['__sched_children__'] = _layerSeq++;
  // menu 層：若有 sched 子節點則單獨一層，否則緊接 entry/sched
  _layerMap['menu'] = _layerSeq++;
  const _keyLayer = _layerSeq; // key_* / auto_transfer / post_greeting_transfer 等末端節點

  const layerOf = (id) => {
    if (id in _layerMap) return _layerMap[id];
    if (id === 'work_t' || id === 'off_t' || id === 'hd_t') return _layerMap['__sched_children__'] ?? _layerMap['menu'];
    return _keyLayer; // key_*, auto_t, pgt_t 等
  };

  const layers = {};
  nodes.forEach(n => {
    const l = layerOf(n.id);
    if (!layers[l]) layers[l] = [];
    layers[l].push(n);
  });

  const maxLayerLen = Math.max(...Object.values(layers).map(l=>l.length));
  const svgW = Math.max(380, maxLayerLen * (NODE_W + GAP_X) + GAP_X * 2);
  // 用 Object.keys 排序後重新映射到連續索引，避免數字 key 有空洞
  const sortedLayerKeys = Object.keys(layers).map(Number).sort((a,b)=>a-b);
  const layerCount = sortedLayerKeys.length;
  const svgH = layerCount * (NODE_H + GAP_Y) + GAP_Y;

  // 計算每個節點座標（用排名索引 rank 取代原始 lIdx，確保連續）
  const pos = {};
  sortedLayerKeys.forEach((lIdx, rank) => {
    const lNodes = layers[lIdx];
    const totalW = lNodes.length * NODE_W + (lNodes.length-1) * GAP_X;
    const startX = (svgW - totalW) / 2;
    const y      = rank * (NODE_H + GAP_Y) + GAP_Y;
    lNodes.forEach((n, i) => {
      pos[n.id] = { x: startX + i * (NODE_W + GAP_X), y };
    });
  });

  // SVG 節點（第二行文字截斷，最多顯示 18 字元）
  const rectsSVG = nodes.map(n => {
    const p = pos[n.id];
    if (!p) return '';
    const rawLines = n.label.split('\n');
    const line1 = rawLines[0] || '';
    const line2 = rawLines[1] ? trunc(rawLines[1], 18) : '';
    const hasTwo = !!line2;
    const textY1 = p.y + NODE_H/2 - (hasTwo ? 9 : 0);
    const textY2 = p.y + NODE_H/2 + Math.round(NODE_H * 0.25);
    const isMenu = n.type === 'menu';
    const rx = isMenu ? Math.round(NODE_H * 0.5) : 7;
    const fs1 = Math.max(11, Math.round(NODE_H * 0.22));
    const fs2 = Math.max(10, Math.round(NODE_H * 0.19));
    return `
      <rect x="${p.x}" y="${p.y}" width="${NODE_W}" height="${NODE_H}" rx="${rx}"
        fill="${n.color}22" stroke="${n.color}" stroke-width="2"/>
      <text x="${p.x + NODE_W/2}" y="${textY1}" text-anchor="middle"
        fill="${n.color}" font-size="${fs1}" font-weight="600" font-family="sans-serif">${line1}</text>
      ${hasTwo ? `<text x="${p.x + NODE_W/2}" y="${textY2}" text-anchor="middle"
        fill="${n.color}" font-size="${fs2}" opacity=".85" font-family="sans-serif">${line2}</text>` : ''}`;
  }).join('');

  // SVG 邊線
  const edgesSVG = edges.map(e => {
    const fp = pos[e.from], tp = pos[e.to];
    if (!fp || !tp) return '';
    const x1 = fp.x + NODE_W/2, y1 = fp.y + NODE_H;
    const x2 = tp.x + NODE_W/2, y2 = tp.y;
    const mx = (x1 + x2) / 2, my = (y1 + y2) / 2;
    const col = '#90a4ae';
    const fs = Math.max(10, Math.round(NODE_H * 0.19));
    return `
      <path d="M${x1},${y1} C${x1},${y1+20} ${x2},${y2-20} ${x2},${y2}"
        stroke="${col}" stroke-width="1.5" fill="none" marker-end="url(#arrow)"/>
      ${e.label ? `<text x="${mx+6}" y="${my}" fill="${col}" font-size="${fs}" font-family="sans-serif">${e.label}</text>` : ''}`;
  }).join('');

  return `
  <svg width="100%" height="${svgH}" viewBox="0 0 ${svgW} ${svgH}"
       preserveAspectRatio="xMidYMin meet"
       style="min-width:${Math.min(svgW, 260)}px;display:block"
       xmlns="http://www.w3.org/2000/svg">
    <defs>
      <marker id="arrow" markerWidth="8" markerHeight="8" refX="6" refY="3" orient="auto">
        <path d="M0,0 L0,6 L8,3 z" fill="#90a4ae"/>
      </marker>
    </defs>
    ${edgesSVG}
    ${rectsSVG}
  </svg>`;
}

function _ivrToggleFlowFullscreen(btn) {
  const overlay = document.getElementById('ivr-flow-fullscreen');
  const canvas  = document.getElementById('ivr-flow-fullscreen-canvas');
  const titleEl = document.getElementById('ivr-flow-fullscreen-title');
  if (!overlay) return;
  overlay.style.display = 'flex';
  if (titleEl && _ivrEditing) titleEl.textContent = `${_ivrEditing.name || _ivrEditing.id}`;
  if (canvas) canvas.innerHTML = _ivrRenderFlowLarge();
}

function _ivrCloseFlowFullscreen() {
  const overlay = document.getElementById('ivr-flow-fullscreen');
  if (overlay) overlay.style.display = 'none';
}

// 全螢幕版本：節點尺寸恢復原始大小
function _ivrRenderFlowLarge() {
  if (!_ivrEditing) return '';
  const ivr = _ivrEditing;
  const V = (id, fallback='') => { const el = document.getElementById(id); return el ? el.value : fallback; };
  const ivrId = V('ivr-id', ivr.id), ivrName = V('ivr-name', ivr.name);
  const ivrNumber = V('ivr-number', ivr.number), sched = ivr.schedule || {};
  const nodes = [], edges = [];
  if (ivrNumber) {
    nodes.push({ id:'entry', type:'entry', label:`📞 來電 ${ivrNumber}`, color:'#1565c0' });
    if (sched.enabled) {
      nodes.push({ id:'sched', type:'schedule', label:'⏰ 時段判斷', color:'#4a148c' });
      edges.push({ from:'entry', to:'sched' });
      if (sched.work_target) { nodes.push({ id:'work_t', type:'ivr', label:`🕘 上班\n${sched.work_target}`, color:'#2e7d32' }); edges.push({ from:'sched', to:'work_t', label:'上班' }); }
      const oha = sched.offhour_action;
      const offLabel = (oha && oha.target) ? oha.target : (sched.offhour_target || '掛斷');
      const offIcon  = (oha && oha.action_type === 'ivr') ? '🎛' : (oha && oha.action_type === 'extension') ? '📞' : '📵';
      nodes.push({ id:'off_t', type:'action', label:`🌙 下班\n${offIcon} ${offLabel}`, color:'#6a1b9a' });
      edges.push({ from:'sched', to:'off_t', label:'下班' });
      const hda = sched.holiday_action;
      if (hda && hda.target) {
        const hdIcon = hda.action_type === 'ivr' ? '🎛' : hda.action_type === 'extension' ? '📞' : '📵';
        nodes.push({ id:'hday_t', type:'action', label:`📅 假日\n${hdIcon} ${hda.target}`, color:'#bf360c' });
        edges.push({ from:'sched', to:'hday_t', label:'假日' });
      }
      nodes.push({ id:'menu', type:'menu', label:`🎛 ${ivrName||ivrId}\n選單播放`, color:'#0277bd' });
      if (sched.work_target === ivrId || !sched.work_target) edges.push({ from:'sched', to:'menu', label:'進入選單' });
    } else {
      nodes.push({ id:'menu', type:'menu', label:`🎛 ${ivrName||ivrId}\n選單播放`, color:'#0277bd' });
      edges.push({ from:'entry', to:'menu' });
    }
  } else {
    nodes.push({ id:'menu', type:'menu', label:`🎛 ${ivrName||ivrId}\n（子選單）`, color:'#0277bd' });
  }
  const atCfg = ivr.auto_transfer;
  if (atCfg && atCfg.enabled && atCfg.target) {
    const atIcon = atCfg.action_type === 'ivr' ? '🎛' : atCfg.action_type === 'extension' ? '📞' : '👥';
    nodes.push({ id:'auto_t', type:'action', label:`⚡ 直接轉接\n${atIcon} ${atCfg.target}`, color:'#0277bd' });
    edges.push({ from:'menu', to:'auto_t', label:'立即' });
  }
  const pgtCfg = ivr.post_greeting_transfer;
  if (pgtCfg && pgtCfg.enabled && pgtCfg.target) {
    const pgtIcon = pgtCfg.action_type === 'ivr' ? '🎛' : pgtCfg.action_type === 'extension' ? '📞' : '👥';
    nodes.push({ id:'pgt_t', type:'action', label:`🔊 播後轉接\n${pgtIcon} ${pgtCfg.target}`, color:'#006064' });
    edges.push({ from:'menu', to:'pgt_t', label:'播完' });
  }
  const keys = ivr.keys || {};
  Object.entries(keys).forEach(([digit, action]) => {
    const at = action.action_type || 'hangup', tgt = action.target || '';
    const info = IVR_ACTION_LABELS[at] || IVR_ACTION_LABELS.hangup;
    const specialLabel = IVR_SPECIAL_DIGITS[digit] ? IVR_SPECIAL_DIGITS[digit].replace(' ('+digit+')','') : `[${digit}]`;
    const tgtShort = tgt ? tgt.replace(/^.*\//,'').slice(0,16)+(tgt.replace(/^.*\//,'').length>16?'…':'') : '';
    const nodeLabel = tgtShort ? `${info.icon} ${specialLabel}\n${tgtShort}` : `${info.icon} ${specialLabel}\n${info.label}`;
    nodes.push({ id:`key_${digit}`, type:at, label:nodeLabel, color:info.color });
    edges.push({ from:'menu', to:`key_${digit}`, label: IVR_SPECIAL_DIGITS[digit] ? digit.toUpperCase() : digit });
  });
  // 用大尺寸渲染（全螢幕版）
  return _ivrSVGFlowSized(nodes, edges, 200, 64, 48, 80);
}


async function _ivrSave() {
  const msg = document.getElementById('ivr-save-msg');
  if (msg) msg.textContent = '儲存中…';

  // 先把 schedule panel 的 DOM 值同步回 _ivrEditing（不論 panel 是否展開）
  _ivrSyncScheduleFromDOM();

  // 從表單讀取最新值
  const get = (id, def='') => { const e=document.getElementById(id); return e ? e.value : def; };

  const ivr = _ivrEditing;
  ivr.id                  = get('ivr-id',            ivr.id);
  ivr.name                = get('ivr-name',           ivr.name);
  ivr.number              = get('ivr-number',         ivr.number);
  ivr.greeting            = get('ivr-greeting',       ivr.greeting);
  ivr.menu_sound          = get('ivr-menu-sound',     ivr.menu_sound);
  ivr.invalid_sound       = get('ivr-invalid-sound',  ivr.invalid_sound);
  ivr.exit_sound          = get('ivr-exit-sound',     ivr.exit_sound);
  ivr.timeout             = parseInt(get('ivr-timeout', ivr.timeout)) || 10;
  ivr.retries             = parseInt(get('ivr-retries', ivr.retries)) || 3;
  ivr.invalid_retries     = parseInt(get('ivr-invalid-retries', ivr.invalid_retries ?? 1)) || 1;
  ivr.invalid_final_sound = get('ivr-invalid-final-sound', ivr.invalid_final_sound || '');
  ivr.timeout_retries     = parseInt(get('ivr-timeout-retries', ivr.timeout_retries ?? 1)) || 1;
  ivr.timeout_final_sound = get('ivr-timeout-final-sound', ivr.timeout_final_sound || '');
  const directEl = document.getElementById('ivr-direct-ext-dialing');
  if (directEl) ivr.direct_ext_dialing = directEl.checked;
  ivr.direct_ext_digits = parseInt(get('ivr-direct-ext-digits', ivr.direct_ext_digits||4))||4;
  ivr.direct_ext_prefix = get('ivr-direct-ext-prefix', ivr.direct_ext_prefix||'');

  // [NEW] auto_transfer
  const atEnabledEl = document.getElementById('ivr-auto-transfer-enabled');
  if (atEnabledEl) {
    if (!ivr.auto_transfer) ivr.auto_transfer = {};
    ivr.auto_transfer.enabled     = atEnabledEl.checked;
    ivr.auto_transfer.action_type = get('ivr-at-type',   ivr.auto_transfer.action_type||'extension');
    ivr.auto_transfer.target      = get('ivr-at-target', ivr.auto_transfer.target||'');
  }
  // [NEW] post_greeting_transfer
  const pgtEnabledEl = document.getElementById('ivr-pgt-enabled');
  if (pgtEnabledEl) {
    if (!ivr.post_greeting_transfer) ivr.post_greeting_transfer = {};
    ivr.post_greeting_transfer.enabled     = pgtEnabledEl.checked;
    ivr.post_greeting_transfer.action_type = get('ivr-pgt-type',   ivr.post_greeting_transfer.action_type||'extension');
    ivr.post_greeting_transfer.target      = get('ivr-pgt-target', ivr.post_greeting_transfer.target||'');
  }
  // 從整合卡片讀取 i / t 動作，寫入 keys（不管之前 keys 裡有沒有）
  for (const digit of ['i', 't']) {
    const atEl  = document.getElementById(`ivr-special-action-type-${digit}`);
    const tgtEl = document.getElementById(`ivr-key-target-${digit}`);
    const at    = atEl  ? atEl.value  : 'hangup';
    const tgt   = tgtEl ? tgtEl.value : '';
    if (at && at !== 'hangup' || tgt) {
      ivr.keys[digit] = { action_type: at, target: tgt };
    } else if (at === 'hangup') {
      ivr.keys[digit] = { action_type: 'hangup', target: '' };
    }
  }

  // schedule 值已由 _ivrSyncScheduleFromDOM() 同步到 _ivrEditing，直接使用
  // 只補讀 enabled checkbox（不在 sync 函數裡）
  const schedEnabledEl = document.getElementById('ivr-sched-enabled');
  if (schedEnabledEl) ivr.schedule.enabled = schedEnabledEl.checked;

  if (!ivr.id) {
    if (msg) { msg.textContent = '❌ ID 為必填'; msg.style.color = 'var(--red)'; }
    return;
  }

  const isNew  = !_ivrList.find(v => v.id === ivr.id);
  const method = isNew ? 'POST' : 'PUT';
  const url    = isNew ? '/api/ivr' : `/api/ivr/${ivr.id}`;

  const payload = JSON.stringify(ivr);

  const res = await apiFetch(url, {
    method,
    headers: { 'Content-Type': 'application/json' },
    body:    payload,
  });

  if (res && res.ok) {
    if (msg) { msg.textContent = '✓ 已儲存'; msg.style.color = 'var(--green)'; }
    numClearCache();
    setTimeout(async () => {
      await renderIVR();
      _ivrEdit(ivr.id);
    }, 800);
  } else {
    const errText = (res && res.detail) ? res.detail : JSON.stringify(res);
    if (msg) { msg.textContent = `❌ ${errText}`; msg.style.color = 'var(--red)'; }
  }
}

// ── 刪除 ──────────────────────────────────────────────────────────────────────
async function _ivrDelete(ivr_id, name) {
  if (!confirm(`確定要刪除 IVR「${name}」？\n\n操作將備份原始 XML 檔案。`)) return;
  const res = await apiFetch(`/api/ivr/${ivr_id}`, { method: 'DELETE' });
  if (res && res.ok) {
    _ivrCurrentTab = 'list';
    _ivrEditing    = null;
    await renderIVR();
  } else {
    alert('刪除失敗：' + JSON.stringify(res));
  }
}

function _ivrBackToList() {
  _ivrCurrentTab = 'list';
  _ivrEditing    = null;
  _ivrRenderList();
}

// ── 語音檔操作 ────────────────────────────────────────────────────────────────
async function _ivrUploadSound(input) {
  if (!input.files || !input.files[0]) return;
  const file = input.files[0];
  const formData = new FormData();
  formData.append('file', file);

  try {
    const res = await fetch(`${API_BASE}/api/sounds/upload`, {
      method: 'POST',
      headers: { 'Authorization': `Bearer ${getToken()}` },
      body: formData,
    });
    const data = await res.json();
    if (res.ok && data.ok) {
      await renderIVR();
    } else {
      alert('上傳失敗：' + (data.detail || JSON.stringify(data)));
    }
  } catch (e) {
    alert('上傳錯誤：' + e.message);
  } finally {
    input.value = '';
  }
}

async function _ivrDeleteSound(filename) {
  if (!confirm(`確定要刪除語音檔「${filename}」？`)) return;

  let res = await fetch(`${API_BASE}/api/sounds/${encodeURIComponent(filename)}`, {
    method: 'DELETE',
    headers: { 'Authorization': `Bearer ${getToken()}` },
  });
  let data = await res.json();

  if (res.status === 409) {
    if (!confirm(`${data.detail}\n\n是否仍要強制刪除？（可能導致該功能播放失敗）`)) return;
    res  = await fetch(`${API_BASE}/api/sounds/${encodeURIComponent(filename)}?force=true`, {
      method: 'DELETE',
      headers: { 'Authorization': `Bearer ${getToken()}` },
    });
    data = await res.json();
  }

  if (res.ok && data.ok) {
    await renderIVR();
  } else {
    alert('刪除失敗：' + (data.detail || JSON.stringify(data)));
  }
}

// ════════════════════════════════════════════════════════════════════════════
// 號碼衝突檢查（分機 / 群組 / IVR 新增時共用）
// ════════════════════════════════════════════════════════════════════════════

