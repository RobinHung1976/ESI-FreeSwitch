// dialplan.js — Dialplan 路由設定 Hub（路由規則 / 系統內建 / 自定義 三個子模組）

// Dialplan 路由設定 — 統一入口（合併 路由規則／系統內建／自定義 3 個子頁）
// ════════════════════════════════════════════════════════════════════════════
// 版面仿照「系統設定」頁：左窄欄子項選單 + 右側內容。
// 3 個子頁的 render function 保留原本邏輯，只改成掛載到 dialplan-hub-content
// 而非直接寫死 mainContent，因此各子頁內部既有的 switchPage('dialplan_xxx')
// 刷新呼叫完全不用修改，仍會經由 pages 物件正確導回本 Hub。
const DIALPLAN_HUB_TREE = [
  { id: 'dialplan_routes',     icon: '🛣', label: '路由規則' },
  { id: 'dialplan_system_ext', icon: '🔒', label: '系統內建' },
  { id: 'dialplan_custom',     icon: '📋', label: '自定義' },
];

let _dialplanHubNode = 'dialplan_routes';

async function renderDialplanHub(node) {
  _dialplanHubNode = node || _dialplanHubNode;

  const treeHtml = DIALPLAN_HUB_TREE.map(item => `
    <div class="stree-item ${_dialplanHubNode === item.id ? 'active' : ''}"
         onclick="switchPage('${item.id}')">
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
        🛣 Dialplan 路由設定
      </div>
      <div class="stree">${treeHtml}</div>
    </div>
    <div id="dialplan-hub-content" style="flex:1;min-width:0;margin-left:12px;overflow-y:auto"></div>
  </div>`;

  const renderers = {
    dialplan_routes:     renderDialplanRoutes,
    dialplan_system_ext: renderSystemExtensions,
    dialplan_custom:     renderDialplanCustom,
  };
  await renderers[_dialplanHubNode]('dialplan-hub-content');
}



const PATTERN_TYPE_META = {
  prefix:        { label: '開頭為...',          example: '輸入「6,7」→ 符合 6xxx、7xxx 開頭的所有號碼' },
  exact:         { label: '完全符合',            example: '輸入「0912345678」→ 只符合這一個號碼' },
  any:           { label: '任意（攔截所有）',     example: '不需輸入內容，符合所有撥出的號碼（建議放在最後、優先序設最大）' },
  custom_regex:  { label: '自訂正規式',          example: '例：^00(\\d+)$ → 符合 00 開頭的國際電話，可用 $1 取得括號內容' },
};

let _routeGatewayCache = null;   // /api/gateway/list 快取
let _routeEditingId    = null;   // 目前編輯中的路由 id（新增模式為 null）
let _routeConflictTimer = null;  // debounce timer
let _routeContextCache   = [];      // /api/dialplan/contexts 快取
let _routeAllRoutesCache = [];      // 最近一次 /api/dialplan/routes 回應，供前端篩選/分組用
let _routeCurrentFilter  = 'default'; // 目前選取的 context，或 '__all__'
let _routeCameFromOverview = false;   // 是否是從「全部 context」總覽點卡片下鑽進來的

// ── 頁面進入點 ──────────────────────────────────────────────────────────────
async function renderDialplanRoutes(mountId = 'mainContent') {
  document.getElementById(mountId).innerHTML =
    '<div style="padding:40px;text-align:center;color:var(--muted)">載入中...</div>';

  const [routeData, gwData, contexts] = await Promise.all([
    apiFetch('/api/dialplan/routes'),
    apiFetch('/api/gateway/list'),
    loadDialplanContexts(),
  ]);

  const routes = (routeData && routeData.routes) ? routeData.routes : [];
  _routeGatewayCache   = (gwData && gwData.gateways) ? gwData.gateways : [];
  _routeContextCache   = contexts;
  _routeAllRoutesCache = routes;
  _routeCurrentFilter  = _routeDefaultFilterContext(routes);

  document.getElementById(mountId).innerHTML = `
  <!-- 列表面板 -->
  <div id="route-list-panel">

    <!-- 路由測試工具 -->
    <div class="panel" style="margin-bottom:14px">
      <div class="panel-header">
        <span class="panel-title">🔍 路由測試</span>
        <span style="font-size:11px;color:var(--muted);margin-left:8px">
          輸入號碼，模擬撥打時會命中哪一條路由規則
        </span>
      </div>
      <div style="padding:16px;display:flex;flex-direction:column;gap:10px">
        <div style="display:flex;gap:8px;align-items:center">
          <input class="settings-input" id="route-test-number" placeholder="輸入測試號碼，例：0912345678"
            style="max-width:280px" onkeydown="if(event.key==='Enter') testRouteNumber()">
          <button class="btn primary" onclick="testRouteNumber()">▶ 測試</button>
        </div>
        <div id="route-test-result"></div>
      </div>
    </div>

    <!-- 規則列表 -->
    <div class="panel">
      <div class="panel-header">
        <span class="panel-title">外撥路由規則</span>
        <span class="panel-badge">${routes.length} 條規則</span>
        <div class="panel-actions">
          ${_routeFilterSelectHtml()}
          <button class="btn" onclick="switchPage('dialplan_routes')">↺ 刷新</button>
          <button class="btn primary" onclick="openRouteEditor(null)">+ 新增路由規則</button>
        </div>
      </div>
      <div id="route-table-region"></div>
      <div style="padding:10px 16px;font-size:11px;color:var(--muted)">
        ℹ️ 規則依優先序（數字越小越優先）由上而下比對，第一個符合的規則即生效。
        若多條規則的號碼範圍重疊，新增/編輯時會即時提示衝突（僅同一 context 內的規則視為衝突，跨 context 僅供參考）。
      </div>
    </div>
  </div>

  <!-- 編輯面板 -->
  <div id="route-editor-panel" style="display:none">
    <div class="panel" style="max-width:680px;margin:0 auto">
      <div class="panel-header">
        <span class="panel-title" id="route-editor-title">新增路由規則</span>
      </div>
      <div style="padding:20px;display:flex;flex-direction:column;gap:14px">

        <div id="route-upgrade-notice"></div>

        <div class="settings-row">
          <span class="settings-label">規則名稱 *</span>
          <input class="settings-input" id="route-name" placeholder="例：市話手機外撥">
        </div>

        <div class="settings-row">
          <span class="settings-label">號碼樣式 *</span>
          <select class="settings-select" id="route-pattern-type" onchange="onRoutePatternTypeChange()">
            ${Object.entries(PATTERN_TYPE_META).map(([k, v]) =>
              `<option value="${k}">${v.label}</option>`).join('')}
          </select>
        </div>

        <div id="route-pattern-value-row" class="settings-row">
          <span class="settings-label" id="route-pattern-value-label">開頭數字 *</span>
          <input class="settings-input" id="route-pattern-value"
            placeholder="例：6,7（多個開頭請用逗號分隔）"
            oninput="onRoutePatternInput()">
        </div>

        <div style="margin-left:164px;font-size:11px;color:var(--muted)" id="route-pattern-example"></div>

        <!-- 衝突警告區 -->
        <div id="route-conflict-warning" style="margin-left:164px"></div>

        <!-- 即時測試（在表單內，輸入完 pattern 後可立即測） -->
        <div class="settings-row" id="route-inline-test-row">
          <span class="settings-label">快速測試</span>
          <input class="settings-input" id="route-inline-test-number"
            placeholder="輸入號碼測試是否符合此樣式" style="max-width:240px"
            oninput="onRouteInlineTest()">
          <span id="route-inline-test-result" style="font-size:12px"></span>
        </div>

        <div class="settings-row">
          <span class="settings-label">目標 Gateway *</span>
          <select class="settings-select" id="route-gateway-name">
            <option value="">請選擇 Gateway</option>
            ${_routeGatewayCache.map(g =>
              `<option value="${g.name}">${g.name}${g.proxy ? ' (' + g.proxy + ')' : ''}</option>`).join('')}
          </select>
        </div>
        ${_routeGatewayCache.length === 0 ? `
        <div style="margin-left:164px;font-size:11px;color:var(--red)">
          ⚠️ 尚未設定任何 Gateway，請先到「Gateway / SIP Trunk」頁面新增後再回來設定路由。
        </div>` : ''}

        <div class="settings-row">
          <span class="settings-label">Context *</span>
          <select class="settings-select" id="route-context" style="max-width:200px" onchange="onRoutePatternInput()"></select>
          <span style="font-size:11px;color:var(--muted)">決定寫入哪個 dialplan context 資料夾；新增 context 請到「自定義 Dialplan」頁面</span>
        </div>

        <div class="settings-row">
          <span class="settings-label">來電顯示覆寫</span>
          <input class="settings-input" id="route-caller-id" placeholder="留空則使用預設來電顯示">
        </div>

        <div class="settings-row">
          <span class="settings-label">Toll Allow</span>
          <select class="settings-select" id="route-toll-allow">
            <option value="">不限制</option>
            <option value="local">local（市話）</option>
            <option value="domestic">domestic（國內）</option>
            <option value="international">international（國際）</option>
            <option value="domestic,international,local">全部</option>
          </select>
        </div>

        <div class="settings-row">
          <span class="settings-label">優先順序 *</span>
          <input class="settings-input" id="route-priority" type="number" min="1" max="999" value="100"
            style="max-width:120px">
          <span style="font-size:11px;color:var(--muted)">數字越小越優先比對（建議：精確規則用較小數字，catch-all 用較大數字）</span>
        </div>

        <div class="settings-row">
          <span class="settings-label">啟用狀態</span>
          <select class="settings-select" id="route-enabled" style="max-width:160px">
            <option value="true">啟用</option>
            <option value="false">停用</option>
          </select>
        </div>

        <!-- 進階：XML 預覽 -->
        <div>
          <button class="btn" style="font-size:12px" onclick="toggleRouteXmlPreview()">
            ▾ 進階：檢視產生的 Dialplan XML
          </button>
          <pre id="route-xml-preview" style="display:none;margin-top:8px;padding:12px;
              background:var(--panel2);border:1px solid var(--border);border-radius:4px;
              font-size:11px;color:var(--label);overflow-x:auto;white-space:pre-wrap"></pre>
        </div>

        <div style="display:flex;gap:8px;margin-top:8px;align-items:center">
          <button class="btn" onclick="closeRouteEditor()">← 取消</button>
          <button class="btn primary" onclick="saveRoute()" style="flex:1">💾 儲存路由規則</button>
          <span id="route-save-msg" style="font-size:12px;opacity:0;transition:opacity 0.3s"></span>
        </div>
        <div style="font-size:11px;color:var(--muted)">
          ✓ 儲存後自動執行 <code style="color:var(--accent-bright)">reloadxml</code>，無需重啟 FreeSwitch。
          覆寫既有規則前會自動備份原檔。
        </div>
      </div>
    </div>
  </div>`;

  _renderRouteListRegion();
  onRoutePatternTypeChange();
}

function _routeRowsHtml(routes) {
  if (routes.length === 0) {
    return `<tr><td colspan="8" style="text-align:center;color:var(--muted);padding:20px">尚無路由規則</td></tr>`;
  }
  return routes.map(r => {
    const ptMeta = PATTERN_TYPE_META[r.pattern_type] || { label: r.pattern_type };
    const patternDisplay = r.pattern_type === 'any'
      ? '任意號碼'
      : `${ptMeta.label}：${r.pattern_value}`;
    const ctxLabel = r.context || 'default';

    if (r.legacy) {
      return `<tr style="background:rgba(230,81,0,0.06)">
        <td style="color:var(--accent-bright);font-weight:600">${r.priority}</td>
        <td style="color:#fff;font-weight:600">
          ${_escHtml(r.name)}
          <span style="display:block;font-size:10px;color:var(--yellow);font-weight:400">
            ⚠️ 未納入管理（來源：${_escHtml(r.filename)}）
          </span>
        </td>
        <td style="font-size:11px;color:var(--label)">${_escHtml(ctxLabel)}</td>
        <td style="font-size:12px;color:var(--label)">${_escHtml(patternDisplay)}</td>
        <td style="font-size:12px">${_escHtml(r.gateway_name)}</td>
        <td style="font-size:11px;color:var(--muted)">${_escHtml(r.caller_id_override) || '—'}</td>
        <td><span class="call-status status-hold"><span class="dot"></span>舊有檔案</span></td>
        <td style="display:flex;gap:4px;flex-wrap:wrap">
          <button class="btn primary" style="padding:3px 8px;font-size:11px" onclick="openRouteUpgradeEditor('${r.id}')">
            ⬆ 升級並納入管理
          </button>
        </td>
      </tr>`;
    }

    const statusBadge = r.enabled
      ? `<span class="call-status status-active"><span class="dot"></span>啟用</span>`
      : `<span class="call-status status-hold"><span class="dot"></span>停用</span>`;
    return `<tr>
      <td style="color:var(--accent-bright);font-weight:600">${r.priority}</td>
      <td style="color:#fff;font-weight:600">${_escHtml(r.name)}</td>
      <td style="font-size:11px;color:var(--label)">${_escHtml(ctxLabel)}</td>
      <td style="font-size:12px;color:var(--label)">${_escHtml(patternDisplay)}</td>
      <td style="font-size:12px">${_escHtml(r.gateway_name)}</td>
      <td style="font-size:11px;color:var(--muted)">${_escHtml(r.caller_id_override) || '—'}</td>
      <td>${statusBadge}</td>
      <td style="display:flex;gap:4px;flex-wrap:wrap">
        <button class="btn" style="padding:3px 8px;font-size:11px" onclick="openRouteEditor('${r.id}')">✏ 編輯</button>
        <button class="btn" style="padding:3px 8px;font-size:11px" onclick="toggleRouteEnabled('${r.id}', ${!r.enabled})">
          ${r.enabled ? '⏸ 停用' : '▶ 啟用'}
        </button>
        <button class="btn danger" style="padding:3px 8px;font-size:11px" onclick="deleteRoute('${r.id}', '${_escAttr(r.name)}')">✕ 刪除</button>
      </td>
    </tr>`;
  }).join('');
}

function _escHtml(s) {
  if (s === null || s === undefined) return '';
  return String(s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');
}
function _escAttr(s) {
  return _escHtml(s).replace(/'/g, '&#39;');
}

// ── Context 篩選／全部總覽卡片／下鑽／麵包屑 ─────────────────────────────────
function _routeContextCounts(routes) {
  const counts = {};
  routes.forEach(r => {
    const c = r.context || 'default';
    counts[c] = (counts[c] || 0) + 1;
  });
  return counts;
}

function _routeDefaultFilterContext(routes) {
  const counts = _routeContextCounts(routes);
  const contexts = Object.keys(counts);
  if (contexts.length <= 1) return contexts[0] || 'default';
  // 有多個 context 時，預設顯示規則數最多的那個，維持接近單一 context 時的既有體驗
  return contexts.sort((a, b) => counts[b] - counts[a])[0];
}

function _routeContextOptionsHtml(selected) {
  const list = _routeContextCache.length ? _routeContextCache : ['default'];
  return list.map(c =>
    `<option value="${_escAttr(c)}" ${c === selected ? 'selected' : ''}>${_escHtml(c)}</option>`
  ).join('');
}

function _routeFilterSelectHtml() {
  const counts = _routeContextCounts(_routeAllRoutesCache);
  const known  = _routeContextCache.length ? _routeContextCache : Object.keys(counts);
  const opts = known.map(c =>
    `<option value="${_escAttr(c)}" ${c === _routeCurrentFilter ? 'selected' : ''}>${_escHtml(c)}（${counts[c] || 0}）</option>`
  ).join('');
  return `
    <select class="settings-select" id="route-context-filter" style="max-width:200px" onchange="onRouteContextFilterChange()">
      ${opts}
      <option value="__all__" ${_routeCurrentFilter === '__all__' ? 'selected' : ''}>🗂 全部 context</option>
    </select>`;
}

function onRouteContextFilterChange() {
  const sel = document.getElementById('route-context-filter');
  if (!sel) return;
  _routeCurrentFilter = sel.value;
  _routeCameFromOverview = false;
  _renderRouteListRegion();
}

function _renderRouteListRegion() {
  const region = document.getElementById('route-table-region');
  if (!region) return;
  region.innerHTML = _routeCurrentFilter === '__all__'
    ? _routeOverviewCardsHtml()
    : _routeFlatTableHtml(_routeCurrentFilter);
}

function _routeOverviewCardsHtml() {
  const counts = _routeContextCounts(_routeAllRoutesCache);
  const contexts = Object.keys(counts).sort();
  if (contexts.length === 0) {
    return `<div style="padding:30px;text-align:center;color:var(--muted)">尚無路由規則</div>`;
  }
  const cards = contexts.map(ctx => {
    const rs = _routeAllRoutesCache.filter(r => (r.context || 'default') === ctx);
    const enabledCount = rs.filter(r => r.enabled !== false).length;
    return `
    <div style="border:1px solid var(--border);border-radius:8px;padding:16px;cursor:pointer;
                background:var(--panel2);transition:border-color .15s"
      onmouseover="this.style.borderColor='var(--accent)'"
      onmouseout="this.style.borderColor='var(--border)'"
      onclick="_routeDrillIntoContext('${_escAttr(ctx)}')">
      <div style="font-weight:600;font-size:14px;color:var(--text);margin-bottom:4px">📁 ${_escHtml(ctx)}</div>
      <div style="font-size:12px;color:var(--muted)">${rs.length} 條規則・${enabledCount} 啟用</div>
    </div>`;
  }).join('');
  return `<div style="padding:16px;display:grid;grid-template-columns:repeat(auto-fill,minmax(200px,1fr));gap:12px">${cards}</div>`;
}

function _routeDrillIntoContext(ctx) {
  _routeCurrentFilter = ctx;
  _routeCameFromOverview = true;
  const sel = document.getElementById('route-context-filter');
  if (sel) sel.value = ctx;
  _renderRouteListRegion();
}

function _routeBackToOverview() {
  _routeCurrentFilter = '__all__';
  _routeCameFromOverview = false;
  const sel = document.getElementById('route-context-filter');
  if (sel) sel.value = '__all__';
  _renderRouteListRegion();
}

function _routeFlatTableHtml(ctx) {
  const filtered = _routeAllRoutesCache.filter(r => (r.context || 'default') === ctx);
  const breadcrumb = _routeCameFromOverview ? `
    <div style="padding:8px 16px;font-size:12px;color:var(--muted);display:flex;align-items:center;gap:8px;
                border-bottom:1px solid var(--border)">
      🛣 路由規則 <span style="color:var(--muted)">›</span> <strong style="color:#fff">${_escHtml(ctx)}</strong>
      <button class="btn" style="padding:2px 8px;font-size:11px;margin-left:auto" onclick="_routeBackToOverview()">← 返回總覽</button>
    </div>` : '';
  return `
    ${breadcrumb}
    <div class="table-wrap">
      <table>
        <thead>
          <tr>
            <th>優先序</th><th>名稱</th><th>Context</th><th>號碼樣式</th><th>目標 Gateway</th>
            <th>來電顯示</th><th>狀態</th><th>操作</th>
          </tr>
        </thead>
        <tbody>${_routeRowsHtml(filtered)}</tbody>
      </table>
    </div>`;
}

// ── 編輯面板：開啟/關閉 ──────────────────────────────────────────────────────
let _routeUpgradingLegacyId = null;   // 非 null 表示目前是「升級舊有檔案」模式，而非一般新增/編輯

async function openRouteEditor(id) {
  _routeEditingId = id;
  _routeUpgradingLegacyId = null;
  document.getElementById('route-list-panel').style.display   = 'none';
  document.getElementById('route-editor-panel').style.display = 'block';

  const title = document.getElementById('route-editor-title');
  const upgradeNotice = document.getElementById('route-upgrade-notice');
  if (upgradeNotice) upgradeNotice.innerHTML = '';

  if (id) {
    if (title) title.textContent = '編輯路由規則';
    const data = await apiFetch(`/api/dialplan/routes/${id}`);
    if (!data || data.detail) {
      alert('讀取規則失敗：' + (data ? data.detail : '未知錯誤'));
      closeRouteEditor();
      return;
    }
    document.getElementById('route-name').value          = data.name || '';
    document.getElementById('route-pattern-type').value  = data.pattern_type || 'prefix';
    document.getElementById('route-pattern-value').value = data.pattern_value || '';
    document.getElementById('route-gateway-name').value  = data.gateway_name || '';
    document.getElementById('route-caller-id').value     = data.caller_id_override || '';
    document.getElementById('route-toll-allow').value    = data.toll_allow || '';
    document.getElementById('route-priority').value      = data.priority || 100;
    document.getElementById('route-enabled').value       = String(data.enabled !== false);
    document.getElementById('route-context').innerHTML   = _routeContextOptionsHtml(data.context || 'default');
  } else {
    if (title) title.textContent = '新增路由規則';
    document.getElementById('route-name').value          = '';
    document.getElementById('route-pattern-type').value  = 'prefix';
    document.getElementById('route-pattern-value').value = '';
    document.getElementById('route-gateway-name').value  = '';
    document.getElementById('route-caller-id').value     = '';
    document.getElementById('route-toll-allow').value    = '';
    document.getElementById('route-priority').value      = 100;
    document.getElementById('route-enabled').value       = 'true';
    document.getElementById('route-context').innerHTML   =
      _routeContextOptionsHtml(_routeCurrentFilter && _routeCurrentFilter !== '__all__' ? _routeCurrentFilter : 'default');
  }

  document.getElementById('route-inline-test-number').value = '';
  document.getElementById('route-inline-test-result').textContent = '';
  document.getElementById('route-conflict-warning').innerHTML = '';
  document.getElementById('route-xml-preview').style.display = 'none';
  onRoutePatternTypeChange();
}

// ── 升級舊有手寫 dialplan 檔案（如 DP_AC220.xml）：沿用同一個表單，但走升級 API ──
async function openRouteUpgradeEditor(legacyId) {
  _routeEditingId = null;
  _routeUpgradingLegacyId = legacyId;
  document.getElementById('route-list-panel').style.display   = 'none';
  document.getElementById('route-editor-panel').style.display = 'block';

  const title = document.getElementById('route-editor-title');
  if (title) title.textContent = '⬆ 升級舊有 Dialplan 檔案並納入管理';

  const data = await apiFetch(`/api/dialplan/routes/${legacyId}`);
  if (!data || data.detail) {
    alert('讀取舊有檔案失敗：' + (data ? data.detail : '未知錯誤'));
    closeRouteEditor();
    return;
  }

  document.getElementById('route-name').value          = data.name || '';
  document.getElementById('route-pattern-type').value  = data.pattern_type || 'custom_regex';
  document.getElementById('route-pattern-value').value = data.pattern_value || data.legacy_raw_expression || '';
  document.getElementById('route-gateway-name').value  = data.gateway_name || '';
  document.getElementById('route-caller-id').value     = data.caller_id_override || '';
  document.getElementById('route-toll-allow').value    = data.toll_allow || '';
  document.getElementById('route-priority').value      = data.priority || 100;
  document.getElementById('route-enabled').value       = 'true';
  document.getElementById('route-context').innerHTML   = _routeContextOptionsHtml(data.context || 'default');

  const upgradeNotice = document.getElementById('route-upgrade-notice');
  if (upgradeNotice) {
    upgradeNotice.innerHTML = `
      <div style="padding:10px 12px;background:#fff3e0;border:1px solid #ffcc80;border-radius:4px;margin-bottom:14px">
        <div style="font-size:12px;color:#e65100;font-weight:600">⚠️ 正在升級舊有檔案：${_escHtml(data.filename)}</div>
        <div style="font-size:11px;color:#e65100;margin-top:4px">
          此檔案原本不是用此介面建立的，內容已盡力自動解析為下方表單欄位，請仔細核對後再儲存。<br>
          原始 destination_number 條件：<code style="font-size:10px">${_escHtml(data.legacy_raw_expression || '')}</code><br>
          原始 bridge 動作：<code style="font-size:10px">${_escHtml(data.legacy_raw_bridge || '')}</code><br>
          儲存後會自動備份原始檔案（不刪除，副檔名加 .bak.upgraded.*），並轉換成標準格式納入管理。
          <strong>升級後請務必重新測試一次撥號行為。</strong>
        </div>
      </div>`;
  }

  document.getElementById('route-inline-test-number').value = '';
  document.getElementById('route-inline-test-result').textContent = '';
  document.getElementById('route-conflict-warning').innerHTML = '';
  document.getElementById('route-xml-preview').style.display = 'none';
  onRoutePatternTypeChange();
}

function closeRouteEditor() {
  document.getElementById('route-list-panel').style.display   = 'block';
  document.getElementById('route-editor-panel').style.display = 'none';
  _routeEditingId = null;
  _routeUpgradingLegacyId = null;
}

// ── 號碼樣式切換：動態調整欄位顯示/說明文字 ──────────────────────────────────
function onRoutePatternTypeChange() {
  const pt = document.getElementById('route-pattern-type').value;
  const meta = PATTERN_TYPE_META[pt];
  const valueRow   = document.getElementById('route-pattern-value-row');
  const valueInput = document.getElementById('route-pattern-value');
  const valueLabel = document.getElementById('route-pattern-value-label');
  const exampleDiv = document.getElementById('route-pattern-example');

  exampleDiv.textContent = '💡 ' + meta.example;

  if (pt === 'any') {
    valueRow.style.display = 'none';
    valueInput.value = '';
  } else {
    valueRow.style.display = 'flex';
    if (pt === 'prefix') {
      valueLabel.textContent = '開頭數字 *';
      valueInput.placeholder = '例：6,7（多個開頭請用逗號分隔）';
    } else if (pt === 'exact') {
      valueLabel.textContent = '完整號碼 *';
      valueInput.placeholder = '例：0912345678';
    } else if (pt === 'custom_regex') {
      valueLabel.textContent = '正規式 *';
      valueInput.placeholder = '例：^00(\\d+)$';
    }
  }
  onRoutePatternInput();
}

// ── 即時衝突檢查（debounce）+ XML 預覽更新 ───────────────────────────────────
function onRoutePatternInput() {
  if (_routeConflictTimer) clearTimeout(_routeConflictTimer);
  _routeConflictTimer = setTimeout(_checkRouteConflict, 400);
  _updateRouteXmlPreview();
  onRouteInlineTest();
}

async function _checkRouteConflict() {
  const div = document.getElementById('route-conflict-warning');
  const patternType  = document.getElementById('route-pattern-type').value;
  const patternValue = document.getElementById('route-pattern-value').value.trim();
  const context      = document.getElementById('route-context')?.value || 'default';

  if (patternType !== 'any' && !patternValue) {
    div.innerHTML = '';
    return;
  }

  try {
    const res = await fetch(`${API_BASE}/api/dialplan/routes/check-conflict`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'Authorization': `Bearer ${getToken()}` },
      body: JSON.stringify({
        pattern_type: patternType,
        pattern_value: patternValue,
        context,
        self_id: _routeUpgradingLegacyId || _routeEditingId || '',
      }),
    });
    const data = await res.json();

    if (!res.ok) {
      div.innerHTML = `<div style="font-size:12px;color:var(--red)">⚠️ ${_escHtml(data.detail || '正規式錯誤')}</div>`;
      return;
    }

    let html = '';

    if (!data.has_conflict) {
      html += `<span style="font-size:11px;color:var(--green)">✓ 號碼樣式未與同一 context 的既有規則重疊</span>`;
    } else {
      const list = data.conflicts.map(c =>
        `<li>「${_escHtml(c.name)}」（優先序 ${c.priority}，${c.enabled ? '啟用中' : '已停用'}）— ${_escHtml(c.pattern_value || '任意')}</li>`
      ).join('');
      html += `
      <div style="padding:8px 10px;background:#ffebee;border:1px solid #ef9a9a;border-radius:4px">
        <div style="font-size:12px;color:#c62828;font-weight:600">⚠️ 此號碼樣式與下列同 context 規則重疊：</div>
        <ul style="margin:4px 0 4px 18px;font-size:12px;color:#c62828">${list}</ul>
        ${data.note ? `<div style="font-size:11px;color:#c62828;margin-top:2px">${_escHtml(data.note)}</div>` : ''}
        <div style="font-size:11px;color:#c62828;margin-top:4px">
          可用下方「快速測試」欄位輸入實際號碼，確認目前會被哪一條規則攔截。
        </div>
      </div>`;
    }

    if (data.other_context_matches && data.other_context_matches.length) {
      const otherList = data.other_context_matches.map(c =>
        `<li>「${_escHtml(c.name)}」（context: ${_escHtml(c.context)}，優先序 ${c.priority}）</li>`
      ).join('');
      html += `
      <div style="padding:8px 10px;background:#e3f2fd;border:1px solid #90caf9;border-radius:4px;margin-top:6px">
        <div style="font-size:11px;color:#1565c0">ℹ️ 以下規則號碼樣式相同，但屬於其他 context，不影響本次判斷：</div>
        <ul style="margin:4px 0 0 18px;font-size:11px;color:#1565c0">${otherList}</ul>
      </div>`;
    }

    div.innerHTML = html;
  } catch (e) {
    div.innerHTML = `<div style="font-size:12px;color:var(--red)">⚠️ 衝突檢查失敗：${e.message}</div>`;
  }
}

// ── 表單內「快速測試」：用既有的 test-number API，但只關注目前正在編輯的 pattern ──
async function onRouteInlineTest() {
  const numInput = document.getElementById('route-inline-test-number');
  const resultEl = document.getElementById('route-inline-test-result');
  const num = numInput.value.trim();
  if (!num) { resultEl.textContent = ''; return; }

  const patternType  = document.getElementById('route-pattern-type').value;
  const patternValue = document.getElementById('route-pattern-value').value.trim();
  if (patternType !== 'any' && !patternValue) { resultEl.textContent = ''; return; }

  // 直接在前端做簡易比對（與後端 build_regex 邏輯一致的精簡版），避免每個字元輸入都打 API
  let regexStr;
  try {
    if (patternType === 'any') regexStr = '^(.*)$';
    else if (patternType === 'exact') regexStr = '^' + patternValue.replace(/[.*+?^${}()|[\]\\]/g, '\\$&') + '$';
    else if (patternType === 'prefix') {
      const prefixes = patternValue.split(',').map(s => s.trim()).filter(Boolean);
      if (prefixes.every(p => p.length === 1)) regexStr = `^[${prefixes.join('')}](\\d*)$`;
      else regexStr = `^(${prefixes.join('|')})(\\d*)$`;
    } else regexStr = patternValue;

    const re = new RegExp(regexStr);
    const matched = re.test(num);
    resultEl.textContent = matched ? `✓ 符合此樣式` : `✗ 不符合此樣式`;
    resultEl.style.color = matched ? 'var(--green)' : 'var(--muted)';
  } catch (e) {
    resultEl.textContent = '正規式錯誤';
    resultEl.style.color = 'var(--red)';
  }
}

// ── XML 預覽 ────────────────────────────────────────────────────────────────
function toggleRouteXmlPreview() {
  const pre = document.getElementById('route-xml-preview');
  pre.style.display = pre.style.display === 'none' ? 'block' : 'none';
  if (pre.style.display === 'block') _updateRouteXmlPreview();
}

function _updateRouteXmlPreview() {
  const pre = document.getElementById('route-xml-preview');
  if (!pre || pre.style.display === 'none') return;

  const name          = document.getElementById('route-name').value.trim() || 'route_name';
  const patternType   = document.getElementById('route-pattern-type').value;
  const patternValue  = document.getElementById('route-pattern-value').value.trim();
  const gatewayName   = document.getElementById('route-gateway-name').value || 'GATEWAY_NAME';
  const callerId      = document.getElementById('route-caller-id').value.trim();
  const tollAllow     = document.getElementById('route-toll-allow').value;

  let regexStr;
  try {
    if (patternType === 'any') regexStr = '^(.*)$';
    else if (patternType === 'exact') regexStr = `^${patternValue}$`;
    else if (patternType === 'prefix') {
      const prefixes = patternValue.split(',').map(s => s.trim()).filter(Boolean);
      regexStr = prefixes.every(p => p.length === 1)
        ? `^[${prefixes.join('')}](\\d*)$`
        : `^(${prefixes.join('|')})(\\d*)$`;
    } else regexStr = patternValue || '^(.*)$';
  } catch (e) {
    regexStr = '(正規式產生失敗)';
  }

  const bridgeTarget = patternType === 'prefix'
    ? `sofia/gateway/${gatewayName}/$1`
    : `sofia/gateway/${gatewayName}/\${destination_number}`;

  const lines = [];
  if (tollAllow) lines.push(`      <action application="set" data="toll_allow=${tollAllow}"/>`);
  lines.push(`      <action application="set" data="effective_caller_id_number=${callerId || '${outbound_caller_id_number}'}"/>`);
  lines.push(`      <action application="set" data="effective_caller_id_name=\${effective_caller_id_name}"/>`);
  lines.push(`      <action application="bridge" data="${bridgeTarget}"/>`);

  pre.textContent =
`<include>
  <extension name="route_${name.replace(/[^\w]+/g, '_')}">
    <condition field="destination_number" expression="${regexStr}">
${lines.join('\n')}
    </condition>
  </extension>
</include>`;
}

// ── 儲存 ────────────────────────────────────────────────────────────────────
async function saveRoute() {
  const msg = document.getElementById('route-save-msg');

  const name          = document.getElementById('route-name').value.trim();
  const patternType   = document.getElementById('route-pattern-type').value;
  const patternValue  = document.getElementById('route-pattern-value').value.trim();
  const gatewayName   = document.getElementById('route-gateway-name').value;
  const callerId      = document.getElementById('route-caller-id').value.trim();
  const tollAllow     = document.getElementById('route-toll-allow').value;
  const priority      = parseInt(document.getElementById('route-priority').value, 10);
  const enabled       = document.getElementById('route-enabled').value === 'true';

  if (!name) { alert('請輸入規則名稱'); return; }
  if (patternType !== 'any' && !patternValue) { alert('請輸入號碼樣式內容'); return; }
  if (!gatewayName) { alert('請選擇目標 Gateway'); return; }
  if (!priority || priority < 1 || priority > 999) { alert('優先順序須介於 1-999'); return; }

  const context = document.getElementById('route-context')?.value || 'default';
  const payload = {
    name, pattern_type: patternType, pattern_value: patternValue,
    gateway_name: gatewayName, caller_id_override: callerId,
    toll_allow: tollAllow, priority, enabled, context,
  };

  if (msg) { msg.textContent = '儲存中...'; msg.style.opacity = '1'; msg.style.color = 'var(--yellow)'; }

  let method, url, body;
  if (_routeUpgradingLegacyId) {
    method = 'POST';
    url    = `${API_BASE}/api/dialplan/routes/legacy/upgrade`;
    body   = JSON.stringify({ legacy_id: _routeUpgradingLegacyId, data: payload });
  } else {
    method = _routeEditingId ? 'PUT' : 'POST';
    url    = _routeEditingId
      ? `${API_BASE}/api/dialplan/routes/${_routeEditingId}`
      : `${API_BASE}/api/dialplan/routes`;
    body   = JSON.stringify(payload);
  }

  try {
    const res  = await fetch(url, {
      method,
      headers: { 'Content-Type': 'application/json', 'Authorization': `Bearer ${getToken()}` },
      body,
    });
    const data = await res.json();
    if (res.ok && data.ok) {
      if (data.warning) {
        msg.textContent = '✓ 已升級';
        msg.style.color = 'var(--green)';
        alert(`✓ 升級成功！\n\n${data.warning}`);
      } else if (msg) {
        msg.textContent = '✓ 已儲存'; msg.style.color = 'var(--green)';
      }
      setTimeout(() => { closeRouteEditor(); switchPage('dialplan_routes'); }, 800);
    } else {
      if (msg) { msg.textContent = `✗ ${data.detail || '失敗'}`; msg.style.color = 'var(--red)'; }
    }
  } catch (e) {
    if (msg) { msg.textContent = `✗ ${e.message}`; msg.style.color = 'var(--red)'; }
  }
}

// ── 刪除 ────────────────────────────────────────────────────────────────────
async function deleteRoute(id, name) {
  if (!confirm(`確定要刪除路由規則「${name}」？\n（原檔案會備份保留，不影響其他規則）`)) return;
  try {
    const res  = await fetch(`${API_BASE}/api/dialplan/routes/${id}`, {
      method: 'DELETE',
      headers: { 'Authorization': `Bearer ${getToken()}` },
    });
    const data = await res.json();
    if (res.ok && data.ok) {
      switchPage('dialplan_routes');
    } else {
      alert(`刪除失敗：${data.detail || '未知錯誤'}`);
    }
  } catch (e) {
    alert(`刪除失敗：${e.message}`);
  }
}

// ── 快速啟用/停用 ────────────────────────────────────────────────────────────
async function toggleRouteEnabled(id, newEnabled) {
  try {
    const res  = await fetch(`${API_BASE}/api/dialplan/routes/${id}/toggle`, {
      method: 'PATCH',
      headers: { 'Content-Type': 'application/json', 'Authorization': `Bearer ${getToken()}` },
      body: JSON.stringify({ enabled: newEnabled }),
    });
    const data = await res.json();
    if (res.ok && data.ok) {
      switchPage('dialplan_routes');
    } else {
      alert(`操作失敗：${data.detail || '未知錯誤'}`);
    }
  } catch (e) {
    alert(`操作失敗：${e.message}`);
  }
}

// ── 列表頁的獨立路由測試工具 ──────────────────────────────────────────────────
async function testRouteNumber() {
  const input    = document.getElementById('route-test-number');
  const resultEl = document.getElementById('route-test-result');
  const num = input.value.trim();
  if (!num) { resultEl.innerHTML = ''; return; }

  resultEl.innerHTML = `<span style="font-size:12px;color:var(--muted)">測試中...</span>`;

  try {
    const res  = await fetch(`${API_BASE}/api/dialplan/routes/test-number`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'Authorization': `Bearer ${getToken()}` },
      body: JSON.stringify({ number: num }),
    });
    const data = await res.json();

    if (!res.ok) {
      resultEl.innerHTML = `<span style="font-size:12px;color:var(--red)">✗ ${_escHtml(data.detail || '測試失敗')}</span>`;
      return;
    }

    const checkedRows = (data.all_checked || []).map(c => {
      const icon = c.error ? '⚠️' : (c.matched ? '✓' : '✗');
      const color = c.error ? 'var(--red)' : (c.matched ? 'var(--green)' : 'var(--muted)');
      const disabledTag = c.enabled === false ? '（已停用）' : '';
      return `<div style="font-size:11px;color:${color};padding:2px 0">
        ${icon} ${_escHtml(c.name)}${disabledTag} — 優先序 ${c.priority}
        <code style="color:var(--muted);font-size:10px">${_escHtml(c.pattern || '')}</code>
        ${c.error ? `<span style="color:var(--red)">（${_escHtml(c.error)}）</span>` : ''}
      </div>`;
    }).join('');

    let summaryHtml;
    if (data.matched_route) {
      const m = data.matched_route;
      summaryHtml = `
        <div style="padding:10px;background:#e8f5e9;border:1px solid #a5d6a7;border-radius:4px;margin-bottom:8px">
          <span style="font-size:13px;color:#2e7d32">
            ✓ 號碼「${_escHtml(num)}」會命中路由「<strong>${_escHtml(m.name)}</strong>」
            （優先序 ${m.priority}）→ 轉接 Gateway: <strong>${_escHtml(m.gateway_name)}</strong>
            ${m.caller_id_override ? `，來電顯示覆寫為 ${_escHtml(m.caller_id_override)}` : ''}
          </span>
        </div>`;
    } else {
      summaryHtml = `
        <div style="padding:10px;background:#fff3e0;border:1px solid #ffcc80;border-radius:4px;margin-bottom:8px">
          <span style="font-size:13px;color:#e65100">
            ⚠️ 號碼「${_escHtml(num)}」沒有命中任何啟用中的路由規則，
            撥打時會繼續往下比對 dialplan 內其他既有的 extension（例如分機、IVR 或其他自定義規則）。
          </span>
        </div>`;
    }

    resultEl.innerHTML = `
      ${summaryHtml}
      <details>
        <summary style="cursor:pointer;font-size:12px;color:var(--accent-bright)">展開查看完整比對過程</summary>
        <div style="margin-top:6px;padding:8px 10px;background:var(--panel2);border-radius:4px">
          ${checkedRows || '<span style="font-size:11px;color:var(--muted)">尚無任何路由規則</span>'}
        </div>
      </details>`;
  } catch (e) {
    resultEl.innerHTML = `<span style="font-size:12px;color:var(--red)">✗ 測試失敗：${e.message}</span>`;
  }
}

// ════════════════════════════════════════════════════════════════════════════
// Dialplan 系統內建 Extension（類型二：唯讀檢視）
// ════════════════════════════════════════════════════════════════════════════
// 依賴既有全域：API_BASE, apiFetch(), switchPage()
// 對應後端：dialplan_system_extensions.py（GET /api/dialplan/system-extensions）
//
// 安裝方式：
//   1. 將本檔內容貼到 index.html 的 SCRIPT 結尾前（dialplan-routes-ui.js 之後）
//   2. 在 nav 加入一個項目：
//        <div class="nav-item" data-page="dialplan_system_ext" onclick="switchPage('dialplan_system_ext')">
//          <span class="nav-icon">🔒</span> 系統內建
//        </div>
//   3. 在 pages 物件加入：
//        dialplan_system_ext: { render: renderSystemExtensions, title: '系統內建 Extension' },
//
// 純唯讀頁面：沒有任何寫入呼叫，前端也不提供編輯/刪除按鈕——
// 這只是第二道防線，真正擋寫入的是後端只有一個 GET 端點。
// ════════════════════════════════════════════════════════════════════════════

const SYS_EXT_CONTEXT_META = {
  default: { label: 'default', color: 'var(--accent-bright)' },
  public:  { label: 'public',  color: 'var(--yellow)' },
};

let _sysExtCache = [];      // 攤平後的完整清單（含 default + public），供搜尋/展開用
let _sysExtOpenRaw = new Set(); // 目前展開「原始 XML」的列（存 _sysExtCache 的 index）

// ── 頁面進入點 ──────────────────────────────────────────────────────────────
async function renderSystemExtensions(mountId = 'mainContent') {
  document.getElementById(mountId).innerHTML =
    '<div style="padding:40px;text-align:center;color:var(--muted)">載入中...</div>';

  const data = await apiFetch('/api/dialplan/system-extensions');
  const byContext = (data && data.extensions) ? data.extensions : {};

  _sysExtCache = [];
  for (const [ctx, list] of Object.entries(byContext)) {
    for (const ext of list) _sysExtCache.push(ext);
  }
  _sysExtOpenRaw = new Set();

  const total = data && typeof data.total === 'number' ? data.total : _sysExtCache.length;

  document.getElementById(mountId).innerHTML = `
  <div class="panel">
    <div class="panel-header">
      <span class="panel-title">🔒 系統內建 Extension</span>
      <span class="panel-badge">${total} 筆</span>
      <div class="panel-actions">
        <input class="settings-input" id="sysext-search" placeholder="搜尋號碼樣式 / 名稱 / 說明"
          style="max-width:260px" oninput="_filterSysExt()">
        <button class="btn" onclick="switchPage('dialplan_system_ext')">↺ 刷新</button>
      </div>
    </div>
    <div style="padding:10px 16px;font-size:11px;color:var(--muted);border-bottom:1px solid var(--border)">
      ℹ️ 這些是 FreeSwitch 原廠內建的 extension，唯讀顯示，避免誤改。
      需要知道哪些號碼已被系統佔用時，可在這裡查詢。若確實需要修改，請直接於伺服器編輯
      <code style="color:var(--accent-bright)">default.xml</code> / <code style="color:var(--accent-bright)">public.xml</code> 並自行 reloadxml。
    </div>
    <div class="table-wrap">
      <table>
        <thead>
          <tr>
            <th style="width:80px">Context</th>
            <th>號碼樣式</th>
            <th>名稱</th>
            <th>說明</th>
            <th style="width:110px">操作</th>
          </tr>
        </thead>
        <tbody id="sysext-tbody">${_sysExtRowsHtml(_sysExtCache)}</tbody>
      </table>
    </div>
  </div>`;
}

// ── 搜尋（局部更新 tbody，輸入焦點不丟失） ─────────────────────────────────────
function _filterSysExt() {
  const input = document.getElementById('sysext-search');
  const kw = (input.value || '').trim().toLowerCase();
  const filtered = !kw ? _sysExtCache : _sysExtCache.filter(e =>
    (e.destination_number || '').toLowerCase().includes(kw) ||
    (e.name || '').toLowerCase().includes(kw) ||
    (e.description || '').toLowerCase().includes(kw)
  );
  document.getElementById('sysext-tbody').innerHTML = _sysExtRowsHtml(filtered);
}

// ── 表格列 ──────────────────────────────────────────────────────────────────
function _sysExtRowsHtml(list) {
  if (list.length === 0) {
    return `<tr><td colspan="5" style="text-align:center;color:var(--muted);padding:20px">查無符合的項目</td></tr>`;
  }
  return list.map(e => {
    const idx = _sysExtCache.indexOf(e);
    const ctxMeta = SYS_EXT_CONTEXT_META[e.context] || { label: e.context, color: 'var(--muted)' };
    const desc = e.description
      ? _escHtml(e.description)
      : `<span style="color:var(--muted)">尚無說明，請展開查看原始 XML</span>`;
    const isOpen = _sysExtOpenRaw.has(idx);

    const mainRow = `<tr>
      <td><span style="font-size:11px;font-weight:600;color:${ctxMeta.color}">${ctxMeta.label}</span></td>
      <td style="font-size:12px;font-family:monospace;color:var(--label)">${_escHtml(e.destination_number)}</td>
      <td style="color:#fff;font-weight:600">${_escHtml(e.name)}</td>
      <td style="font-size:12px;color:var(--label)">${desc}</td>
      <td>
        <button class="btn" style="padding:3px 8px;font-size:11px" onclick="_toggleSysExtRaw(${idx})">
          ${isOpen ? '▴ 收合' : '▾ 原始 XML'}
        </button>
      </td>
    </tr>`;

    if (!isOpen) return mainRow;

    return mainRow + `<tr>
      <td colspan="5" style="padding:0">
        <pre style="margin:0;padding:12px 16px;background:var(--panel2);
            border-top:1px solid var(--border);border-bottom:1px solid var(--border);
            font-size:11px;color:var(--label);overflow-x:auto;white-space:pre-wrap">${_escHtml(e.raw_xml)}</pre>
      </td>
    </tr>`;
  }).join('');
}

function _toggleSysExtRaw(idx) {
  if (_sysExtOpenRaw.has(idx)) {
    _sysExtOpenRaw.delete(idx);
  } else {
    _sysExtOpenRaw.add(idx);
  }
  // 只重繪目前搜尋結果對應的列，搜尋框內容跟捲動位置都不動
  document.getElementById('sysext-tbody').innerHTML = _sysExtRowsHtml(
    _currentSysExtFiltered()
  );
}

function _currentSysExtFiltered() {
  const input = document.getElementById('sysext-search');
  const kw = (input && input.value || '').trim().toLowerCase();
  if (!kw) return _sysExtCache;
  return _sysExtCache.filter(e =>
    (e.destination_number || '').toLowerCase().includes(kw) ||
    (e.name || '').toLowerCase().includes(kw) ||
    (e.description || '').toLowerCase().includes(kw)
  );
}

// _escHtml 沿用 dialplan-routes-ui.js 已定義的版本，此處不重複定義。

// ════════════════════════════════════════════════════════════════════════════
// Dialplan 自定義管理（類型三：範本 + XML 編輯器）
// ════════════════════════════════════════════════════════════════════════════
// 依賴既有全域：API_BASE, apiFetch(), switchPage(), _escHtml(),
//               _dpModalHtml(), dpCloseModal()（已存在於 index.html 主程式）
// 對應後端：dialplan_custom.py（/api/dialplan/custom/...）
// 手動編輯模式沿用既有通用端點：GET/POST/DELETE /api/dialplan/file、
//               POST /api/dialplan/create（server.py 既有實作，本檔不重複）
//
// 安裝方式：
//   1. 將本檔內容貼到 index.html 的 SCRIPT 結尾前
//   2. 在 nav 加入：
//        <div class="nav-item" data-page="dialplan_custom" onclick="switchPage('dialplan_custom')">
//          <span class="nav-icon">📋</span> Dialplan 自定義
//        </div>
//   3. 在 pages 物件加入：
//        dialplan_custom: { render: renderDialplanCustom, title: 'Dialplan 自定義' },
// ════════════════════════════════════════════════════════════════════════════

let _dcTemplates   = null;   // /api/dialplan/custom/templates 快取
let _dcFiles       = [];     // /api/dialplan/custom/files 快取
let _dcContextsCache = [];   // /api/dialplan/contexts 快取
let _dcMode        = 'list'; // 'list' | 'pick' | 'form'
let _dcTemplateId  = null;   // 目前表單使用的範本 id
let _dcEditingPath = null;   // 編輯現有檔案時的路徑；新增時為 null
let _dcPreviewTimer = null;
let _dcMountId     = 'mainContent'; // 掛載容器 id（獨立頁為 mainContent，Hub 內為 dialplan-hub-content）

// ── 頁面進入點 ──────────────────────────────────────────────────────────────
async function renderDialplanCustom(mountId = 'mainContent') {
  _dcMountId = mountId;
  document.getElementById(_dcMountId).innerHTML =
    '<div style="padding:40px;text-align:center;color:var(--muted)">載入中...</div>';

  const [tplData, fileData, contexts] = await Promise.all([
    apiFetch('/api/dialplan/custom/templates'),
    apiFetch('/api/dialplan/custom/files'),
    loadDialplanContexts(),
  ]);

  _dcTemplates     = (tplData && tplData.templates) ? tplData.templates : [];
  _dcFiles         = (fileData && fileData.files) ? fileData.files : [];
  _dcContextsCache = contexts;
  _dcMode          = 'list';

  _dcRenderRoot();
}

function _dcRenderRoot() {
  const root = document.getElementById(_dcMountId);
  if (_dcMode === 'list') {
    root.innerHTML = _dcListPanelHtml();
  } else if (_dcMode === 'pick') {
    root.innerHTML = _dcPickerPanelHtml();
  } else {
    root.innerHTML = _dcFormPanelHtml();
    _dcBindFormEvents();
    _dcUpdatePreview();
  }
}

// ── 列表面板 ────────────────────────────────────────────────────────────────
function _dcListPanelHtml() {
  return `
  <div class="panel">
    <div class="panel-header">
      <span class="panel-title">自定義 Dialplan 檔案</span>
      <span class="panel-badge">${_dcFiles.length} 個檔案</span>
      <div class="panel-actions">
        <button class="btn" onclick="switchPage('dialplan_custom')">↺ 刷新</button>
        <button class="btn" onclick="dcOpenManualNew()">✎ 手動建立</button>
        <button class="btn primary" onclick="_dcMode='pick'; _dcRenderRoot()">+ 從範本建立</button>
      </div>
    </div>
    <div class="table-wrap">
      <table>
        <thead>
          <tr><th>檔名</th><th>Context</th><th>來源</th><th>Extension / 號碼</th><th>操作</th></tr>
        </thead>
        <tbody>${_dcFileRowsHtml()}</tbody>
      </table>
    </div>
    <div style="padding:10px 16px;font-size:11px;color:var(--muted)">
      ℹ️ 此列表只顯示未被「路由規則」「群組」「IVR」「系統內建」等頁面管理的自定義檔案。
      由範本建立的檔案可以回到表單編輯；手動建立的檔案則用原始 XML 編輯器編輯。
    </div>
  </div>`;
}

function _dcFileRowsHtml() {
  if (_dcFiles.length === 0) {
    return `<tr><td colspan="5" style="text-align:center;color:var(--muted);padding:20px">尚無自定義 Dialplan 檔案</td></tr>`;
  }
  return _dcFiles.map(f => {
    if (f.error) {
      return `<tr>
        <td>${_escHtml(f.filename)}</td><td>${_escHtml(f.context)}</td>
        <td colspan="2" style="color:var(--red)">讀取失敗：${_escHtml(f.error)}</td>
        <td><button class="btn" style="font-size:11px" onclick="dcDeleteFile('${_escHtml(f.path)}')">🗑 刪除</button></td>
      </tr>`;
    }
    const sourceTag = f.is_template
      ? `<span style="color:var(--accent-bright)">🧩 ${_escHtml(f.template_label || f.template_id)}</span>`
      : `<span style="color:var(--muted)">✎ 手動</span>`;
    const target = (f.extensions || []).join(', ') || '—';
    const dest = (f.destinations || []).join(', ') || '';
    return `<tr>
      <td><code style="font-size:12px">${_escHtml(f.filename)}</code></td>
      <td>${_escHtml(f.context)}</td>
      <td>${sourceTag}</td>
      <td style="font-size:12px">
        ${_escHtml(target)}
        ${dest ? `<br><span style="color:var(--muted);font-size:11px">${_escHtml(dest)}</span>` : ''}
      </td>
      <td style="white-space:nowrap">
        <button class="btn" style="font-size:11px" onclick="dcEditFile('${_escHtml(f.path)}')">✎ 編輯</button>
        <button class="btn" style="font-size:11px;color:var(--red)" onclick="dcDeleteFile('${_escHtml(f.path)}')">🗑 刪除</button>
      </td>
    </tr>`;
  }).join('');
}

// ── 範本選擇面板 ────────────────────────────────────────────────────────────
function _dcPickerPanelHtml() {
  const cards = _dcTemplates.map(t => `
    <div style="border:1px solid var(--border);border-radius:8px;padding:16px;cursor:pointer;
                background:var(--panel2);transition:border-color .15s"
      onmouseover="this.style.borderColor='var(--accent)'"
      onmouseout="this.style.borderColor='var(--border)'"
      onclick="dcOpenTemplateForm('${t.id}')">
      <div style="font-weight:600;font-size:14px;color:var(--text);margin-bottom:6px">${_escHtml(t.label)}</div>
      <div style="font-size:12px;color:var(--muted);line-height:1.5">${_escHtml(t.description || '')}</div>
    </div>`).join('');

  return `
  <div class="panel">
    <div class="panel-header">
      <span class="panel-title">選擇範本</span>
      <div class="panel-actions">
        <button class="btn" onclick="_dcMode='list'; _dcRenderRoot()">← 返回列表</button>
      </div>
    </div>
    <div style="padding:16px;display:grid;grid-template-columns:repeat(auto-fill,minmax(260px,1fr));gap:12px">
      ${cards || '<span style="color:var(--muted);font-size:13px">尚無可用範本</span>'}
    </div>
  </div>`;
}

function dcOpenTemplateForm(templateId) {
  _dcTemplateId  = templateId;
  _dcEditingPath = null;
  _dcMode = 'form';
  _dcRenderRoot();
}

// ── 表單面板（新增 / 編輯共用）────────────────────────────────────────────────
function _dcCurrentTemplate() {
  return (_dcTemplates || []).find(t => t.id === _dcTemplateId) || null;
}

function _dcFieldInputHtml(field, value) {
  const v = value !== undefined && value !== null ? value : '';
  const common = `id="dc-field-${field.key}" data-key="${field.key}" class="settings-input" style="max-width:320px"`;
  if (field.type === 'select') {
    const opts = (field.options || []).map(o =>
      `<option value="${_escHtml(o)}" ${o === v ? 'selected' : ''}>${_escHtml(o)}</option>`).join('');
    return `<select ${common} class="settings-select" style="max-width:320px">${opts}</select>`;
  }
  if (field.type === 'time') {
    return `<input type="time" ${common} value="${_escHtml(v)}">`;
  }
  if (field.type === 'number') {
    return `<input type="number" ${common} value="${_escHtml(v)}" placeholder="${_escHtml(field.placeholder || '')}">`;
  }
  return `<input type="text" ${common} value="${_escHtml(v)}" placeholder="${_escHtml(field.placeholder || '')}">`;
}

function _dcFormPanelHtml() {
  const tpl = _dcCurrentTemplate();
  if (!tpl) {
    return `<div class="panel"><div style="padding:20px">找不到範本，請
      <a href="#" onclick="_dcMode='list'; _dcRenderRoot(); return false">返回列表</a>。</div></div>`;
  }
  const isEdit = !!_dcEditingPath;
  const prefill = isEdit ? (_dcEditingValues || {}) : {};

  const fieldsHtml = tpl.fields.map(f => `
    <div class="settings-row">
      <span class="settings-label">${_escHtml(f.label)}${f.required ? ' *' : ''}</span>
      ${_dcFieldInputHtml(f, prefill[f.key])}
      ${f.help ? `<span style="font-size:11px;color:var(--muted);margin-left:8px">${_escHtml(f.help)}</span>` : ''}
    </div>`).join('');

  return `
  <div class="panel" style="max-width:680px;margin:0 auto">
    <div class="panel-header">
      <span class="panel-title">${isEdit ? '編輯' : '新增'}：${_escHtml(tpl.label)}</span>
    </div>
    <div style="padding:20px;display:flex;flex-direction:column;gap:14px">

      ${!isEdit ? `
      <div style="display:grid;grid-template-columns:1fr 1fr;gap:12px">
        <div>
          <label style="font-size:12px;color:var(--label);display:block;margin-bottom:4px">
            檔名 * <span style="font-size:11px;color:var(--muted)">(.xml，不含路徑)</span>
          </label>
          <input id="dc-filename" class="settings-input" style="width:100%;box-sizing:border-box"
            placeholder="例：time_route_9500.xml">
        </div>
        <div>
          <label style="font-size:12px;color:var(--label);display:block;margin-bottom:4px">Context</label>
          <select id="dc-context" class="settings-select" style="width:100%;box-sizing:border-box" onchange="_dcHandleContextChange(this)">
            ${_dcContextOptionsHtml('default')}
          </select>
        </div>
      </div>` : `
      <div style="font-size:12px;color:var(--muted)">
        檔案：<code>${_escHtml(_dcEditingPath)}</code>
      </div>`}

      ${fieldsHtml}

      <!-- 進階：XML 預覽 -->
      <div>
        <button class="btn" style="font-size:12px" onclick="dcTogglePreview()">
          ▾ 進階：檢視產生的 Dialplan XML
        </button>
        <pre id="dc-xml-preview" style="display:none;margin-top:8px;padding:12px;
            background:var(--panel2);border:1px solid var(--border);border-radius:4px;
            font-size:11px;color:var(--label);overflow-x:auto;white-space:pre-wrap"></pre>
      </div>

      <div style="display:flex;gap:8px;margin-top:8px;align-items:center">
        <button class="btn" onclick="_dcMode='list'; _dcRenderRoot()">← 取消</button>
        <button class="btn primary" onclick="dcSaveTemplateForm()" style="flex:1">💾 儲存</button>
        <span id="dc-save-msg" style="font-size:12px;opacity:0;transition:opacity .3s"></span>
      </div>
      <div style="font-size:11px;color:var(--muted)">
        ✓ 儲存後自動執行 <code style="color:var(--accent-bright)">reloadxml</code>，無需重啟 FreeSwitch。
        覆寫既有規則前會自動備份原檔；reload 失敗會自動還原並回報錯誤。
      </div>
    </div>
  </div>`;
}

function _dcBindFormEvents() {
  const tpl = _dcCurrentTemplate();
  if (!tpl) return;
  tpl.fields.forEach(f => {
    const el = document.getElementById(`dc-field-${f.key}`);
    if (el) el.addEventListener('input', _dcSchedulePreview);
  });
}

function _dcCollectValues() {
  const tpl = _dcCurrentTemplate();
  const values = {};
  (tpl?.fields || []).forEach(f => {
    const el = document.getElementById(`dc-field-${f.key}`);
    values[f.key] = el ? el.value.trim() : '';
  });
  return values;
}

// ── Context 選單：動態清單 + 就地建立新 context ───────────────────────────────
function _dcContextOptionsHtml(selected) {
  const list = _dcContextsCache.length ? _dcContextsCache : ['default', 'public'];
  const opts = list.map(c =>
    `<option value="${_escAttr(c)}" ${c === selected ? 'selected' : ''}>${_escHtml(c)}</option>`).join('');
  return opts + `<option value="__new__">+ 建立新 context...</option>`;
}

function _dcHandleContextChange(selectEl) {
  if (selectEl.value !== '__new__') return;
  _dcPromptNewContext(selectEl);
}

function _dcPromptNewContext(selectEl) {
  const fallback = _dcContextsCache[0] || 'default';
  document.body.insertAdjacentHTML('beforeend', _dpModalHtml('📁 建立新 Context', `
    <div style="margin-bottom:10px">
      <label style="font-size:12px;color:var(--label);display:block;margin-bottom:4px">
        Context 名稱 <span style="font-size:11px;color:var(--muted)">（英數字、底線、連字號）</span>
      </label>
      <input id="dc-new-context-name" class="settings-input" style="width:100%;box-sizing:border-box" placeholder="例：branch2">
    </div>
    <div style="padding:8px 10px;background:#fff3e0;border:1px solid #ffcc80;border-radius:4px;font-size:11px;color:#e65100;margin-bottom:10px">
      ⚠️ 建立後只是新增一個空的 dialplan 資料夾，還需要另外到 SIP Profile 或其他 dialplan 設定中，
      讓某個來源實際指向這個 context 名稱，通話才會真正進入此 context。
    </div>
    <div id="dc-new-context-msg" style="font-size:12px;min-height:18px;margin-bottom:8px"></div>
    <div style="display:flex;gap:8px">
      <button class="btn" onclick="_dcCreateNewContext('${selectEl.id}', '${fallback}')"
        style="background:var(--accent);color:#fff;font-weight:600;padding:6px 20px">建立</button>
      <button class="btn" onclick="dpCloseModal(); document.getElementById('${selectEl.id}').value='${fallback}'">取消</button>
    </div>
  `));
}

async function _dcCreateNewContext(selectId, fallbackValue) {
  const nameInput = document.getElementById('dc-new-context-name');
  const msg       = document.getElementById('dc-new-context-msg');
  const name = (nameInput?.value || '').trim();
  if (!name) { if (msg) { msg.textContent = '❌ 請輸入 context 名稱'; msg.style.color = 'var(--red)'; } return; }
  if (!/^[\w\-]+$/.test(name)) {
    if (msg) { msg.textContent = '❌ 僅能包含英數字、底線、連字號'; msg.style.color = 'var(--red)'; }
    return;
  }
  if (msg) { msg.textContent = '建立中...'; msg.style.color = 'var(--yellow)'; }
  try {
    const res  = await fetch(`${API_BASE}/api/dialplan/contexts`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'Authorization': `Bearer ${getToken()}` },
      body: JSON.stringify({ context: name }),
    });
    const data = await res.json();
    if (res.ok && data.ok) {
      if (!_dcContextsCache.includes(name)) _dcContextsCache.push(name);
      clearDialplanContextsCache();  // 讓分機管理/路由規則頁面下次載入抓到最新清單
      dpCloseModal();
      const sel = document.getElementById(selectId);
      if (sel) { sel.innerHTML = _dcContextOptionsHtml(name); sel.value = name; }
    } else {
      if (msg) { msg.textContent = `❌ ${data.detail || '建立失敗'}`; msg.style.color = 'var(--red)'; }
    }
  } catch (e) {
    if (msg) { msg.textContent = `❌ ${e.message}`; msg.style.color = 'var(--red)'; }
  }
}

function dcTogglePreview() {
  const pre = document.getElementById('dc-xml-preview');
  if (!pre) return;
  pre.style.display = pre.style.display === 'none' ? 'block' : 'none';
}

function _dcSchedulePreview() {
  clearTimeout(_dcPreviewTimer);
  _dcPreviewTimer = setTimeout(_dcUpdatePreview, 300);
}

async function _dcUpdatePreview() {
  const pre = document.getElementById('dc-xml-preview');
  if (!pre) return;
  const values = _dcCollectValues();
  try {
    const res = await fetch(`${API_BASE}/api/dialplan/custom/preview`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'Authorization': `Bearer ${getToken()}` },
      body: JSON.stringify({ template_id: _dcTemplateId, values }),
    });
    const data = await res.json();
    pre.textContent = res.ok ? data.xml : `(尚無法產生預覽：${data.detail || '欄位未填完整'})`;
  } catch (e) {
    pre.textContent = `(預覽失敗：${e.message})`;
  }
}

// ── 儲存（新增 / 更新）───────────────────────────────────────────────────────
async function dcSaveTemplateForm() {
  const msg = document.getElementById('dc-save-msg');
  const values = _dcCollectValues();

  const setMsg = (text, color) => {
    if (!msg) return;
    msg.textContent = text; msg.style.color = color; msg.style.opacity = '1';
  };

  let url, method, body;
  if (_dcEditingPath) {
    url = `${API_BASE}/api/dialplan/custom/file`;
    method = 'PUT';
    body = JSON.stringify({ path: _dcEditingPath, template_id: _dcTemplateId, values });
  } else {
    const filename = (document.getElementById('dc-filename')?.value || '').trim();
    const context  = document.getElementById('dc-context')?.value || 'default';
    if (!filename) { setMsg('❌ 請輸入檔名', 'var(--red)'); return; }
    if (!/^[\w\-]+\.xml$/.test(filename)) {
      setMsg('❌ 檔名格式錯誤（英數字、底線、連字號，副檔名 .xml）', 'var(--red)');
      return;
    }
    url = `${API_BASE}/api/dialplan/custom/create`;
    method = 'POST';
    body = JSON.stringify({ template_id: _dcTemplateId, filename, context, values });
  }

  setMsg('儲存中...', 'var(--yellow)');
  try {
    const res  = await fetch(url, { method, headers: { 'Content-Type': 'application/json', 'Authorization': `Bearer ${getToken()}` }, body });
    const data = await res.json();
    if (res.ok && data.ok) {
      setMsg('✓ 已儲存', 'var(--green)');
      setTimeout(() => { _dcMode = 'list'; switchPage('dialplan_custom'); }, 700);
    } else {
      setMsg(`✗ ${data.detail || '儲存失敗'}`, 'var(--red)');
    }
  } catch (e) {
    setMsg(`✗ ${e.message}`, 'var(--red)');
  }
}

// ── 從列表進入編輯 ────────────────────────────────────────────────────────────
let _dcEditingValues = null;

async function dcEditFile(path) {
  const data = await apiFetch(`/api/dialplan/custom/file?path=${encodeURIComponent(path)}`);
  if (!data) { alert('讀取檔案失敗'); return; }

  if (data.editable_as_template) {
    _dcTemplateId    = data.template_id;
    _dcEditingPath   = path;
    _dcEditingValues = data.values || {};
    _dcMode = 'form';
    _dcRenderRoot();
    return;
  }
  // 非範本建立的檔案：退回手動 raw XML 編輯器
  dcOpenManualEdit(path, data.content || '');
}

// ── 刪除 ────────────────────────────────────────────────────────────────────
async function dcDeleteFile(path) {
  const fname = path.split('/').pop();
  if (!confirm(`確定要刪除「${fname}」？\n（原檔案會備份保留）`)) return;
  const res = await apiFetch('/api/dialplan/file', {
    method: 'DELETE',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ path }),
  });
  if (res && res.ok) {
    switchPage('dialplan_custom');
  } else {
    alert(`刪除失敗：${(res && res.detail) || '未知錯誤'}`);
  }
}

// ── 手動模式：新增（自帶 modal，不依賴既有 dpNewFile，避免其成功回呼跳轉到號碼目錄頁）──
function dcOpenManualNew() {
  const defaultXml =
`<include>
  <extension name="my_custom_extension">
    <condition field="destination_number" expression="^XXXX$">
      <action application="answer"/>
      <action application="hangup"/>
    </condition>
  </extension>
</include>`;

  document.body.insertAdjacentHTML('beforeend', _dpModalHtml('✎ 手動建立自定義 Dialplan', `
    <div style="display:grid;grid-template-columns:1fr 1fr;gap:12px;margin-bottom:12px">
      <div>
        <label style="font-size:12px;color:var(--label);display:block;margin-bottom:4px">
          檔名 * <span style="font-size:11px;color:var(--muted)">(.xml，不含路徑)</span>
        </label>
        <input id="dc-manual-filename" class="settings-input" style="width:100%;box-sizing:border-box"
          placeholder="例：custom_9001.xml">
      </div>
      <div>
        <label style="font-size:12px;color:var(--label);display:block;margin-bottom:4px">Context</label>
        <select id="dc-manual-context" class="settings-select" style="width:100%;box-sizing:border-box" onchange="_dcHandleContextChange(this)">
          ${_dcContextOptionsHtml('default')}
        </select>
      </div>
    </div>
    <label style="font-size:12px;color:var(--label);display:block;margin-bottom:6px">
      XML 內容 <span style="font-size:11px;color:var(--muted)">（儲存前自動驗證語法）</span>
    </label>
    <textarea id="dc-manual-content" spellcheck="false"
      style="width:100%;box-sizing:border-box;height:480px;font-family:monospace;font-size:13px;
             padding:10px;border:1px solid var(--border);border-radius:4px;
             background:var(--bg);color:var(--text);resize:vertical;line-height:1.6"
    >${defaultXml}</textarea>
    <div id="dc-manual-msg" style="margin-top:8px;font-size:12px;min-height:20px"></div>
    <div style="display:flex;gap:8px;margin-top:12px">
      <button class="btn" onclick="dcManualNewSave()"
        style="background:var(--accent);color:#fff;font-weight:600;padding:6px 20px">
        💾 建立並套用
      </button>
      <button class="btn" onclick="dpCloseModal()">取消</button>
    </div>
  `));
}

async function dcManualNewSave() {
  const filename = (document.getElementById('dc-manual-filename')?.value || '').trim();
  const context  =  document.getElementById('dc-manual-context')?.value  || 'default';
  const content  =  document.getElementById('dc-manual-content')?.value  || '';
  const msg      =  document.getElementById('dc-manual-msg');

  if (!filename) { if (msg) { msg.textContent = '❌ 請輸入檔名'; msg.style.color = 'var(--red)'; } return; }
  if (!/^[\w\-]+\.xml$/.test(filename)) {
    if (msg) { msg.textContent = '❌ 檔名格式錯誤（英數字、底線、連字號，副檔名 .xml）'; msg.style.color = 'var(--red)'; }
    return;
  }
  if (msg) { msg.textContent = '儲存中…'; msg.style.color = 'var(--muted)'; }

  const res = await apiFetch('/api/dialplan/create', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ filename, context, content }),
  });

  if (res && res.ok) {
    if (msg) { msg.textContent = `✓ 已建立 ${res.path}，reloadxml 完成`; msg.style.color = 'var(--green)'; }
    setTimeout(() => { dpCloseModal(); switchPage('dialplan_custom'); }, 800);
  } else {
    if (msg) { msg.textContent = `❌ ${(res && res.detail) || JSON.stringify(res)}`; msg.style.color = 'var(--red)'; }
  }
}

// ── 手動模式：編輯既有非範本檔案 ──────────────────────────────────────────────
function dcOpenManualEdit(path, content) {
  document.body.insertAdjacentHTML('beforeend', _dpModalHtml(
    `✎ 編輯 Dialplan：${path.split('/').pop()}`, `
    <div style="margin-bottom:6px">
      <code style="font-size:11px;color:var(--muted);word-break:break-all">${path}</code>
    </div>
    <label style="font-size:12px;color:var(--label);display:block;margin-bottom:6px">
      XML 內容 <span style="font-size:11px;color:var(--muted)">（儲存前自動驗證語法並備份原檔）</span>
    </label>
    <textarea id="dc-manual-edit-content" spellcheck="false" data-path="${path}"
      style="width:100%;box-sizing:border-box;height:520px;font-family:monospace;font-size:13px;
             padding:10px;border:1px solid var(--border);border-radius:4px;
             background:var(--bg);color:var(--text);resize:vertical;line-height:1.6"
    ></textarea>
    <div id="dc-manual-edit-msg" style="margin-top:8px;font-size:12px;min-height:20px"></div>
    <div style="display:flex;gap:8px;margin-top:12px">
      <button class="btn" onclick="dcManualEditSave()"
        style="background:var(--accent);color:#fff;font-weight:600;padding:6px 20px">
        💾 儲存並套用
      </button>
      <button class="btn" onclick="dpCloseModal()">取消</button>
    </div>
  `));
  const ta = document.getElementById('dc-manual-edit-content');
  if (ta) ta.value = content;
}

async function dcManualEditSave() {
  const ta   = document.getElementById('dc-manual-edit-content');
  const msg  = document.getElementById('dc-manual-edit-msg');
  const path = ta?.dataset?.path || '';
  const content = ta?.value || '';
  if (!path) return;

  if (msg) { msg.textContent = '儲存中…'; msg.style.color = 'var(--muted)'; }
  const res = await apiFetch('/api/dialplan/file', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ path, content }),
  });

  if (res && res.ok) {
    const backupNote = res.backup ? `（備份：${res.backup.split('/').pop()}）` : '';
    if (msg) { msg.textContent = `✓ 已儲存並 reloadxml ${backupNote}`; msg.style.color = 'var(--green)'; }
    setTimeout(() => { dpCloseModal(); switchPage('dialplan_custom'); }, 900);
  } else {
    if (msg) { msg.textContent = `❌ ${(res && res.detail) || JSON.stringify(res)}`; msg.style.color = 'var(--red)'; }
  }
}

