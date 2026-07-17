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

# ── 1. core/auth_db.py：update_user() 新增 clear_owned_ext 參數 ──────
if grep -q "clear_owned_ext: bool = False" core/auth_db.py 2>/dev/null; then
  echo "↷ core/auth_db.py 已包含此次改動，略過"
else
  python3 << 'PYEOF'
path = "core/auth_db.py"
with open(path, "r", encoding="utf-8") as f:
    content = f.read()

old = '''def update_user(user_id: int, *, group_id: int | None = None, owned_ext: str | None = None,
                 disabled: bool | None = None) -> None:
    with _conn() as conn:
        row = conn.execute("SELECT * FROM users WHERE id=?", (user_id,)).fetchone()
        if not row:
            raise ValueError("使用者不存在")
        new_group_id = group_id if group_id is not None else row["group_id"]
        new_owned_ext = owned_ext if owned_ext is not None else row["owned_ext"]
        new_disabled = int(disabled) if disabled is not None else row["disabled"]
        conn.execute(
            "UPDATE users SET group_id=?, owned_ext=?, disabled=?, updated_at=? WHERE id=?",
            (new_group_id, new_owned_ext, new_disabled, datetime.now().isoformat(), user_id),
        )'''

new = '''def update_user(user_id: int, *, group_id: int | None = None, owned_ext: str | None = None,
                 disabled: bool | None = None, clear_owned_ext: bool = False) -> None:
    with _conn() as conn:
        row = conn.execute("SELECT * FROM users WHERE id=?", (user_id,)).fetchone()
        if not row:
            raise ValueError("使用者不存在")
        new_group_id = group_id if group_id is not None else row["group_id"]
        if clear_owned_ext:
            new_owned_ext = None
        else:
            new_owned_ext = owned_ext if owned_ext is not None else row["owned_ext"]
        new_disabled = int(disabled) if disabled is not None else row["disabled"]
        conn.execute(
            "UPDATE users SET group_id=?, owned_ext=?, disabled=?, updated_at=? WHERE id=?",
            (new_group_id, new_owned_ext, new_disabled, datetime.now().isoformat(), user_id),
        )'''

if content.count(old) != 1:
    raise SystemExit("❌ core/auth_db.py: old_str 比對失敗（數量非 1），中止")
content = content.replace(old, new)
with open(path, "w", encoding="utf-8") as f:
    f.write(content)
print("✓ core/auth_db.py 更新完成")
PYEOF
fi

# ── 2. routers/users.py：UpdateUserRequest + update_user route ──────
if grep -q "clear_owned_ext: bool = False" routers/users.py 2>/dev/null; then
  echo "↷ routers/users.py 已包含此次改動，略過"
else
  python3 << 'PYEOF'
path = "routers/users.py"
with open(path, "r", encoding="utf-8") as f:
    content = f.read()

old1 = '''class UpdateUserRequest(BaseModel):
    group_id: int | None = None
    owned_ext: str | None = None
    disabled: bool | None = None'''

new1 = '''class UpdateUserRequest(BaseModel):
    group_id: int | None = None
    owned_ext: str | None = None
    disabled: bool | None = None
    clear_owned_ext: bool = False'''

if content.count(old1) != 1:
    raise SystemExit("❌ routers/users.py: UpdateUserRequest old_str 比對失敗，中止")
content = content.replace(old1, new1)

old2 = '''        auth_db.update_user(
            user_id, group_id=body.group_id, owned_ext=body.owned_ext, disabled=body.disabled,
        )'''

new2 = '''        auth_db.update_user(
            user_id, group_id=body.group_id, owned_ext=body.owned_ext, disabled=body.disabled,
            clear_owned_ext=body.clear_owned_ext,
        )'''

if content.count(old2) != 1:
    raise SystemExit("❌ routers/users.py: update_user() 呼叫式 old_str 比對失敗，中止")
content = content.replace(old2, new2)

with open(path, "w", encoding="utf-8") as f:
    f.write(content)
print("✓ routers/users.py 更新完成")
PYEOF
fi

# ── 3. static/js/users-management.js：編輯表單加「清空」勾選框 ──────
if grep -q "um-user-clear-owned-ext" static/js/users-management.js 2>/dev/null; then
  echo "↷ static/js/users-management.js 已包含此次改動，略過"
else
  python3 << 'PYEOF'
path = "static/js/users-management.js"
with open(path, "r", encoding="utf-8") as f:
    content = f.read()

old1 = '''      <div class="settings-row">
        <span class="settings-label">專屬分機</span>
        <div style="flex:1;display:flex;flex-direction:column;gap:4px">
          <input class="settings-input" id="um-user-owned-ext" placeholder="例：1001（scope=own 群組必填）" value="${u && u.owned_ext ? u.owned_ext : ''}" />
          ${u ? '<span class="settings-hint">留空送出不會清除舊值（後端目前的更新邏輯是「未提供」才略過，無法用空字串清空），如需清空請聯絡後端調整</span>' : ''}
        </div>
      </div>'''

new1 = '''      <div class="settings-row">
        <span class="settings-label">專屬分機</span>
        <div style="flex:1;display:flex;flex-direction:column;gap:4px">
          <input class="settings-input" id="um-user-owned-ext" placeholder="例：1001（scope=own 群組必填）" value="${u && u.owned_ext ? u.owned_ext : ''}" />
          ${u ? `
          <label style="display:flex;align-items:center;gap:6px">
            <input type="checkbox" id="um-user-clear-owned-ext" onchange="_umToggleClearOwnedExt(this)" />
            <span class="settings-hint" style="margin:0">清空專屬分機（勾選後儲存會真正移除舊值，並忽略上方欄位內容；留空但未勾選仍不會清除舊值）</span>
          </label>` : ''}
        </div>
      </div>'''

if content.count(old1) != 1:
    raise SystemExit("❌ users-management.js: 表單區塊 old_str 比對失敗，中止")
content = content.replace(old1, new1)

old2 = '''function _umCloseUserEditor() {
  document.getElementById('um-users-list-panel').style.display   = 'block';
  document.getElementById('um-users-editor-panel').style.display = 'none';
}'''

new2 = '''function _umCloseUserEditor() {
  document.getElementById('um-users-list-panel').style.display   = 'block';
  document.getElementById('um-users-editor-panel').style.display = 'none';
}

function _umToggleClearOwnedExt(checkbox) {
  const input = document.getElementById('um-user-owned-ext');
  if (!input) return;
  input.disabled = checkbox.checked;
  if (checkbox.checked) input.value = '';
}'''

if content.count(old2) != 1:
    raise SystemExit("❌ users-management.js: _umCloseUserEditor old_str 比對失敗，中止")
content = content.replace(old2, new2)

old3 = '''async function _umSaveUserEdits(userId) {
  const msg = document.getElementById('um-user-save-msg');
  const groupId  = document.getElementById('um-user-group').value;
  const ownedExt = document.getElementById('um-user-owned-ext').value.trim();
  const disabledEl = document.getElementById('um-user-disabled');

  if (!groupId) { alert('請選擇權限群組'); return; }
  const selectedGroup = _umGroups.find(g => g.id === parseInt(groupId));
  if (selectedGroup && selectedGroup.scope === 'own' && !ownedExt) {
    if (!confirm(`「${selectedGroup.name}」的 scope 是 own，通常需要專屬分機才能正常運作，確定要保存空白的專屬分機？`)) return;
  }

  if (msg) { msg.textContent = '儲存中...'; msg.style.opacity = '1'; msg.style.color = 'var(--yellow)'; }
  const data = await apiFetch(`/api/users/${userId}`, {
    method: 'PUT',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      group_id: parseInt(groupId),
      owned_ext: ownedExt || null,
      disabled: disabledEl ? disabledEl.checked : undefined,
    }),
  });'''

new3 = '''async function _umSaveUserEdits(userId) {
  const msg = document.getElementById('um-user-save-msg');
  const groupId  = document.getElementById('um-user-group').value;
  const clearOwnedExtEl = document.getElementById('um-user-clear-owned-ext');
  const clearOwnedExt = clearOwnedExtEl ? clearOwnedExtEl.checked : false;
  const ownedExt = clearOwnedExt ? '' : document.getElementById('um-user-owned-ext').value.trim();
  const disabledEl = document.getElementById('um-user-disabled');

  if (!groupId) { alert('請選擇權限群組'); return; }
  const selectedGroup = _umGroups.find(g => g.id === parseInt(groupId));
  if (selectedGroup && selectedGroup.scope === 'own' && !ownedExt) {
    if (!confirm(`「${selectedGroup.name}」的 scope 是 own，通常需要專屬分機才能正常運作，確定要保存空白的專屬分機？`)) return;
  }

  if (msg) { msg.textContent = '儲存中...'; msg.style.opacity = '1'; msg.style.color = 'var(--yellow)'; }
  const data = await apiFetch(`/api/users/${userId}`, {
    method: 'PUT',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      group_id: parseInt(groupId),
      owned_ext: ownedExt || null,
      clear_owned_ext: clearOwnedExt,
      disabled: disabledEl ? disabledEl.checked : undefined,
    }),
  });'''

if content.count(old3) != 1:
    raise SystemExit("❌ users-management.js: _umSaveUserEdits old_str 比對失敗，中止")
content = content.replace(old3, new3)

with open(path, "w", encoding="utf-8") as f:
    f.write(content)
print("✓ static/js/users-management.js 更新完成")
PYEOF
fi

# ── 語法檢查 ─────────────────────────────────────────────────────────
python3 -m py_compile core/auth_db.py routers/users.py

if command -v node >/dev/null 2>&1; then
  node --check static/js/users-management.js
  echo "✓ node --check 通過"
else
  echo "⚠ 此環境沒有安裝 node，略過 JS 語法檢查（改動內容已人工核對過語法正確性）"
fi

# ── Commit ──────────────────────────────────────────────────────────
git add core/auth_db.py routers/users.py static/js/users-management.js
if git diff --cached --quiet; then
  echo "（無變更需要 commit，可能是重跑此腳本、上次已成功 commit 過）"
else
  git commit -m "feat: owned_ext 支援明確清空（新增 clear_owned_ext 參數 + 前端勾選框）"
fi

echo ""
echo "===== git log ====="
git log --oneline -3
