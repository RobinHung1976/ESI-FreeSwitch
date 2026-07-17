// sounds.js — 音檔庫頁面

// ── 音檔庫 ────────────────────────────────────────────────────────────────────
let _soundCategoryFilter = 'all';

function _soundFmtSize(bytes) {
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
  return `${(bytes / 1024 / 1024).toFixed(1)} MB`;
}

let _soundSearchTerm = '';
let _soundSearchDebounceTimer = null;

function _soundSearchInput(value) {
  _soundSearchTerm = value;
  _soundShownCount = 100;
  clearTimeout(_soundSearchDebounceTimer);
  // 等使用者停止輸入 300ms 後才重繪，避免每打一個字就整頁重建導致輸入框失焦
  _soundSearchDebounceTimer = setTimeout(() => renderSoundLibrary(), 300);
}
let _soundPageSize   = 100;   // 每次顯示筆數，避免一次塞入上千個 DOM 拖垮畫面
let _soundShownCount = 100;

function _soundSyncPlayingBtn() {
  // 依播放器目前真實狀態同步按鈕圖示，而不是靠各自猜測
  const player = document.getElementById('sound-shared-player');
  const currentPath = player ? player.dataset.currentPath : '';
  document.querySelectorAll('.sound-play-btn').forEach(b => {
    const playing = player && !player.paused && b.dataset.path === currentPath;
    b.classList.toggle('playing', !!playing);
    b.textContent = playing ? '⏸' : '▶';
  });
}

function soundPlay(path, btn) {
  const player = document.getElementById('sound-shared-player');
  if (!player) return;

  if (player.dataset.currentPath === path) {
    // 同一首歌再按一次 → 切換播放/暫停
    if (player.paused) player.play().catch(() => {});
    else player.pause();
  } else {
    player.dataset.currentPath = path;
    player.src = `${API_BASE}/api/sounds/stream?path=${encodeURIComponent(path)}`;
    player.play().catch(() => {});
  }
}

function _soundBindPlayerEvents() {
  const player = document.getElementById('sound-shared-player');
  if (!player || player.dataset.bound) return;
  player.dataset.bound = '1';
  ['play', 'pause', 'ended'].forEach(evt => player.addEventListener(evt, _soundSyncPlayingBtn));
}

async function renderSoundLibrary(skipLoadingFlash) {
  if (!skipLoadingFlash) {
    document.getElementById('mainContent').innerHTML = `
    <div style="padding:40px;text-align:center;color:var(--muted)">載入中...</div>`;
  }

  const qs = _soundCategoryFilter !== 'all' ? `?category=${encodeURIComponent(_soundCategoryFilter)}` : '';
  const data = await apiFetch(`/api/sounds/list${qs}`);
  const allSounds = (data && data.sounds) ? data.sounds : [];
  const categories = (data && data.categories) ? data.categories : [];

  const term = _soundSearchTerm.trim().toLowerCase();
  const sounds = term ? allSounds.filter(s => s.filename.toLowerCase().includes(term)) : allSounds;

  const customSounds  = sounds.filter(s => s.source === 'custom');
  const builtinSounds = sounds.filter(s => s.source === 'builtin').slice(0, _soundShownCount);
  const builtinTotal  = sounds.filter(s => s.source === 'builtin').length;

  const filterOptions = [
    { path: 'all', label: '全部分類' },
    { path: 'custom', label: '自訂音檔' },
    ...categories,
  ];

  const renderRow = (s) => `
    <div style="display:flex;align-items:center;gap:10px;padding:8px 12px;border-bottom:1px solid var(--border)">
      <button class="btn sound-play-btn" data-path="${s.path.replace(/"/g, '&quot;')}"
        style="padding:3px 10px;font-size:12px;flex-shrink:0"
        onclick="soundPlay('${s.path.replace(/'/g, "\\'")}', this)">▶</button>
      <span style="font-size:13px;color:var(--text);flex:1;word-break:break-all">${s.filename}</span>
      <span style="font-size:11px;color:var(--muted);min-width:60px;text-align:right;flex-shrink:0">${_soundFmtSize(s.size)}</span>
      ${s.source === 'custom' ? `
        <button class="btn danger" style="padding:3px 8px;font-size:11px;flex-shrink:0" onclick="soundDelete('${s.filename}')">✕ 刪除</button>
      ` : `<span style="font-size:10px;color:var(--muted);min-width:46px;text-align:center;flex-shrink:0">唯讀</span>`}
    </div>`;

  document.getElementById('mainContent').innerHTML = `
  <div class="panel" style="display:flex;flex-direction:column;max-height:calc(100vh - 140px)">
    <div class="panel-header" style="flex-shrink:0;flex-wrap:wrap">
      <span class="panel-badge">${allSounds.length} 個音檔（自訂 ${allSounds.filter(s=>s.source==='custom').length} ／ 內建 ${allSounds.filter(s=>s.source==='builtin').length}）</span>
      <input id="sound-search-input" class="settings-input" placeholder="搜尋檔名..." value="${_soundSearchTerm}"
        style="width:160px;font-size:12px"
        oninput="_soundSearchInput(this.value)">
      <div class="panel-actions">
        <select class="settings-select" style="width:auto" onchange="_soundCategoryFilter=this.value;_soundShownCount=100;renderSoundLibrary()">
          ${filterOptions.map(c => `<option value="${c.path}" ${_soundCategoryFilter===c.path?'selected':''}>${c.label}</option>`).join('')}
        </select>
        <button class="btn" onclick="renderSoundLibrary()">↺ 刷新</button>
        <label class="btn primary" style="cursor:pointer;margin:0">
          ⬆ 上傳音檔
          <input type="file" accept=".wav,.mp3,.ogg,.gsm" style="display:none" onchange="soundUpload(this)">
        </label>
      </div>
    </div>
    <div style="padding:10px 16px;font-size:11px;color:var(--muted);border-bottom:1px solid var(--border);flex-shrink:0">
      💡 上傳格式建議 8kHz 16bit Mono WAV（FreeSwitch 最佳相容性），單檔上限 20MB。自訂音檔存放於
      <code style="color:var(--accent-bright)">/var/lib/freeswitch/sounds/custom/</code>，可在 IVR、分機、語音信箱等功能中選用。
    </div>
    <div style="padding:8px 16px;border-bottom:1px solid var(--border);display:flex;align-items:center;gap:10px;flex-shrink:0">
      <span style="font-size:11px;color:var(--label);flex-shrink:0">🎧 試聽播放器</span>
      <audio id="sound-shared-player" controls style="flex:1;height:32px"></audio>
    </div>
    <div id="sound-upload-msg" style="padding:0 16px;font-size:12px;min-height:0;flex-shrink:0"></div>

    <div style="flex:1;overflow-y:auto;min-height:0">
      ${sounds.length === 0 ? `
        <div style="padding:40px;text-align:center;color:var(--muted)">${term ? '查無符合的音檔' : '尚無音檔，請上傳或切換分類'}</div>
      ` : `
        ${customSounds.length ? `
          <div style="padding:10px 16px 4px;font-size:11px;font-weight:700;color:var(--label);text-transform:uppercase;letter-spacing:1px;position:sticky;top:0;background:var(--panel)">自訂音檔</div>
          ${customSounds.map(renderRow).join('')}
        ` : ''}
        ${builtinSounds.length ? `
          <div style="padding:14px 16px 4px;font-size:11px;font-weight:700;color:var(--label);text-transform:uppercase;letter-spacing:1px;position:sticky;top:0;background:var(--panel)">系統內建音檔</div>
          ${builtinSounds.map(renderRow).join('')}
          ${builtinTotal > builtinSounds.length ? `
            <div style="padding:12px 16px;text-align:center">
              <button class="btn" onclick="_soundShownCount+=200;renderSoundLibrary(true)">
                載入更多（已顯示 ${builtinSounds.length} / ${builtinTotal}）
              </button>
            </div>
          ` : ''}
        ` : ''}
      `}
    </div>
  </div>`;

  _soundBindPlayerEvents();
  _soundSyncPlayingBtn();

  // 若目前有搜尋字串，重繪後自動還原焦點到搜尋框（並把游標移到結尾），
  // 避免 debounce 重繪後使用者需要重新點擊輸入框才能繼續打字
  if (_soundSearchTerm) {
    const input = document.getElementById('sound-search-input');
    if (input) {
      input.focus();
      input.setSelectionRange(input.value.length, input.value.length);
    }
  }
}

async function soundUpload(input) {
  const file = input.files[0];
  if (!file) return;
  const msg = document.getElementById('sound-upload-msg');
  if (msg) { msg.textContent = '上傳中...'; msg.style.color = 'var(--yellow)'; }

  const formData = new FormData();
  formData.append('file', file);

  try {
    const res = await fetch(`${API_BASE}/api/sounds/upload`, { method: 'POST', body: formData });
    const data = await res.json();
    if (!res.ok || !data.ok) {
      if (msg) { msg.textContent = `✗ 上傳失敗：${data.detail || '未知錯誤'}`; msg.style.color = 'var(--red)'; }
      return;
    }
    if (msg) { msg.textContent = `✓ 已上傳 ${data.filename}`; msg.style.color = 'var(--green)'; }
    setTimeout(() => renderSoundLibrary(), 600);
  } catch (e) {
    if (msg) { msg.textContent = `✗ 錯誤：${e.message}`; msg.style.color = 'var(--red)'; }
  } finally {
    input.value = '';
  }
}

async function soundDelete(filename) {
  if (!confirm(`確定要刪除音檔「${filename}」？\n若此音檔正在被 IVR 等功能使用中，系統會先提醒您。`)) return;

  try {
    let res = await fetch(`${API_BASE}/api/sounds/${encodeURIComponent(filename)}`, { method: 'DELETE' });
    let data = await res.json();

    if (res.status === 409) {
      // 音檔使用中，詢問是否強制刪除
      if (confirm(`${data.detail}\n\n是否仍要強制刪除？（可能導致該功能播放失敗）`)) {
        res = await fetch(`${API_BASE}/api/sounds/${encodeURIComponent(filename)}?force=true`, { method: 'DELETE' });
        data = await res.json();
      } else {
        return;
      }
    }

    if (!res.ok || !data.ok) {
      alert(`刪除失敗：${data.detail || '未知錯誤'}`);
      return;
    }
    renderSoundLibrary();
  } catch (e) {
    alert(`刪除失敗：${e.message}`);
  }
}

