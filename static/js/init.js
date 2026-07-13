// init.js — App 啟動進入點，必須放在所有其他 js 檔「之後」載入，
// 因為這裡會呼叫 switchPage('overview') 等，依賴所有頁面 render 函式已經定義完成。

const pages = {
  overview:    { render: renderOverview,    title: '通話即時狀態' },
  report:      { render: renderReport,      title: '通話統計報表' },
  calls:       { render: renderCalls,       title: '即時通話監控' },
  extensions:  { render: renderExtensions,  title: '分機管理' },
  groups:      { render: renderGroups,      title: '分機群組管理' },
  ivr:         { render: renderIVR,         title: 'IVR 互動語音管理' },
  cdr:         { render: renderCDR,         title: '通話記錄 CDR' },
  gateway:     { render: renderGateway,     title: 'Gateway / SIP Trunk' },
  dialplan_routes:     { render: () => renderDialplanHub('dialplan_routes'),     title: 'Dialplan 路由設定' },
  dialplan_custom:     { render: () => renderDialplanHub('dialplan_custom'),     title: 'Dialplan 路由設定' },
  dialplan_system_ext: { render: () => renderDialplanHub('dialplan_system_ext'), title: 'Dialplan 路由設定' },
  sounds:      { render: renderSoundLibrary, title: '音檔庫' },
  recordings:  { render: renderRecordings,  title: '錄音管理' },
  esl:         { render: renderESL,         title: 'ESL 終端機' },
  numbers:     { render: renderNumbers,     title: '號碼目錄' },
  logs:        { render: renderLogs,        title: '系統日誌' },
  settings:    { render: () => renderSettings(_settingsNode), title: '系統設定' },
  backup:      { render: () => renderBackupPage(_backupNode),  title: '備份管理' },
  sip_profile: { render: renderSipProfile,  title: 'SIP Profile 進階設定' },
  users:       { render: renderUsersManagement, title: '使用者管理' },
};

let currentPage = 'overview';

// ── 依 JWT 權限矩陣調整畫面：隱藏無權限的導覽項目 + 顯示登入身分 ──────────────
// JWT payload 已快取整份權限矩陣（core/auth.py 設計如此），不需額外打 API。
// data-page 與 core/permissions.py 的 Module 常數大部分同名，Dialplan 三個子頁共用 'dialplan' 模組。
const NAV_PAGE_TO_MODULE = {
  dialplan_routes: 'dialplan', dialplan_custom: 'dialplan', dialplan_system_ext: 'dialplan',
};

function applyAuthUI() {
  const payload = getTokenPayload();
  if (!payload) return;

  const perms = payload.permissions;
  if (perms) {
    document.querySelectorAll('.nav-item[data-page]').forEach(el => {
      const page = el.dataset.page;
      const mod  = NAV_PAGE_TO_MODULE[page] || page;
      const p    = perms[mod];
      if (!p || !p.read) el.style.display = 'none';
    });
  }

  const userInfoEl = document.getElementById('sf-user-info');
  if (userInfoEl) {
    const name  = payload.username   || '';
    const group = payload.group_name || '';
    userInfoEl.textContent = name ? `登入身分：${name}${group ? '（' + group + '）' : ''}` : '';
  }
}

async function switchPage(id) {
  if (!pages[id]) return;

  // 離開日誌頁時關閉 SSE
  if (currentPage === 'logs' && id !== 'logs') {
    if (_logSSE) { _logSSE.close(); _logSSE = null; }
  }

  currentPage = id;

  try {
    const result = pages[id].render();
    if (result && typeof result.then === 'function') {
      await result;
    } else if (result) {
      document.getElementById('mainContent').innerHTML = result;
    }
  } catch(e) {
    console.error('switchPage error:', e);
    document.getElementById('mainContent').innerHTML =
      `<div style="padding:40px;text-align:center;color:var(--red)">頁面載入錯誤：${e.message}</div>`;
  }

  const titleEl = document.getElementById('pageTitle');
  if (titleEl) titleEl.textContent = pages[id].title;
  // 高亮側邊欄對應的 nav-item（Dialplan 3 個子頁共用同一個 nav-item）
  const DIALPLAN_HUB_IDS = ['dialplan_routes', 'dialplan_system_ext', 'dialplan_custom'];
  const navTargetId = DIALPLAN_HUB_IDS.includes(id) ? 'dialplan_routes' : id;
  document.querySelectorAll('.nav-item').forEach(el => {
    el.classList.toggle('active', el.dataset.page === navTargetId);
  });
}

async function refreshData() {
  await switchPage(currentPage);
}



initWebSocket();
initNavCollapse();
applyAuthUI();
switchPage('overview');
updateNavBadge();  // 初始載入取一次

// 自動請求瀏覽器通知權限（若尚未設定）
if ('Notification' in window && Notification.permission === 'default') {
  document.addEventListener('click', function askPerm() {
    Notification.requestPermission();
    document.removeEventListener('click', askPerm);
  }, { once: true });
}

// 頁面狀態完全由 WebSocket 事件驅動，不使用 setInterval 輪詢
// - 分機頁：EXT_STATUS_UPDATE 事件 → applyExtStatusUpdate() 局部更新 DOM
// - 總覽/通話頁：CHANNEL_* 事件 → switchPage() 重繪
// - 即時通話 badge：CHANNEL_* 事件 → updateNavBadge()
