// esl.js — ESL 終端機頁面 + 常用重載指令快捷區

function renderESL() {
  return `
  <div style="display:flex;flex-direction:column;gap:14px;height:calc(100vh - 120px)">

    <!-- 常用重載指令（原設定頁 Dialplan 設定 > 重載指令 移至此處） -->
    <div class="panel" style="flex-shrink:0">
      <div class="panel-header">
        <span class="panel-title">↺ 常用重載指令</span>
      </div>
      <div style="padding:12px 16px;display:flex;flex-wrap:wrap;gap:10px">
        ${[
          ['重載所有 XML 設定',    'reloadxml',                    '套用所有 XML 變更（分機、Dialplan、Gateway）'],
          ['重載 Dialplan',        'reload mod_dialplan_xml',       '只重載 Dialplan 模組'],
          ['重載 Sofia',           'reload mod_sofia',              '重載 SIP 模組（短暫中斷）'],
          ['重掃 Internal Profile','sofia profile internal rescan', '重新掃描 internal SIP profile'],
          ['重掃 External Profile','sofia profile external rescan', '重新掃描 external SIP profile'],
        ].map(([label, cmd, desc]) => `
          <button class="btn" style="font-size:11px;padding:6px 12px;text-align:left" title="${desc}"
                  onclick="eslCmdToast('${cmd}')">
            ${label}<br><code style="font-size:10px;opacity:0.7">${cmd}</code>
          </button>`).join('')}
      </div>
      <div id="cmd-result" style="margin:0 16px 14px;padding:10px 12px;background:#ffffff;border:1px solid var(--border);
           border-radius:4px;font-size:12px;font-weight:600;color:var(--green);display:none;white-space:pre-wrap"></div>
    </div>

    <div class="panel" style="flex:1;display:flex;flex-direction:column;min-height:0">
      <div class="panel-header">
        
      </div>
      <div class="esl-terminal" style="flex:1;min-height:0">
        <div class="esl-output" id="eslOut">
Content-Type: auth/request<br>
<br>
auth ClueCon<br>
Content-Type: command/reply<br>
Reply-Text: +OK accepted<br>
<br>
> sofia status<br>
                     Name    Type                                       Data      State<br>
=========================================================================================<br>
               external  profile            sip:mod_sofia@0.0.0.0:5080  RUNNING (0)<br>
               internal  profile            sip:mod_sofia@0.0.0.0:5060  RUNNING (0)<br>
        </div>
        <div class="esl-input-row">
          <span class="esl-prompt">freeswitch@debian13></span>
          <input class="esl-input" id="eslInput" placeholder="輸入 ESL 指令，例如：show calls, sofia status, reloadxml" onkeydown="eslSubmit(event)" />
          <button class="btn primary" onclick="eslRun()">執行</button>
        </div>
        <div style="display:flex;gap:8px;flex-wrap:wrap">
          ${['show calls','show channels','sofia status','reloadxml','status','show registrations','hupall'].map(c=>`<button class="btn" style="font-size:10px" onclick="eslInsert('${c}')">${c}</button>`).join('')}
        </div>
      </div>
    </div>
  </div>`;
}

// 全域：記錄目前的 log SSE 連線，切換頁面時關閉


// ── ESL ───────────────────────────────────────────────────────────────────────
function eslInsert(cmd) {
  const inp = document.getElementById('eslInput');
  if (inp) inp.value = cmd;
}
function eslSubmit(e) { if (e.key === 'Enter') eslRun(); }
async function eslRun() {
  const inp = document.getElementById('eslInput');
  const out = document.getElementById('eslOut');
  if (!inp || !out) return;
  const cmd = inp.value.trim();
  if (!cmd) return;
  out.innerHTML += `<br><span style="color:var(--accent)">></span> ${cmd}<br><span style="color:var(--muted)" id="eslWait">執行中...</span><br>`;
  out.scrollTop = out.scrollHeight;
  inp.value = '';
  const result = await runESLCommand(cmd);
  const waitEl = document.getElementById('eslWait');
  if (waitEl) waitEl.remove();
  out.innerHTML += `<span style="color:var(--green)">${(result.result || '').replace(/\n/g,'<br>')}</span><br>`;
  out.scrollTop = out.scrollHeight;
}

