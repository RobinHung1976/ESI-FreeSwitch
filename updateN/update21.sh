#!/usr/bin/env bash
# update21.sh — 修復全站其餘 8 支前端檔案「寫入/下載操作缺少 Authorization header」的既有 bug
#
# 背景：update20.sh 已修復 gateway.js / dialplan.js；使用者依腳本附的自查指令
# （grep "await fetch(" 排除 apiFetch）找出還有 8 支檔案共約 29 處同樣問題：
# cdr.js、extensions-groups.js、ivr.js、logs.js、recordings.js、settings-vars.js、
# sip-profile.js、sounds.js。範圍與 Dialplan Context 功能無關，是權限系統上線
# （約 2026-07-10）後就存在的既有 bug，這次一併修復。
#
# 安全設計：本腳本採「先全部驗證比對成功，才真的寫入任何檔案」——
# 8 支檔案的所有比對都要 100% 通過，才會開始寫檔；只要有一處對不上，
# 全部 8 支檔案都不會被修改，並列出精確的失敗清單，方便回報調整。
set -e

cd "$(dirname "$0")"

# ════════════════════════════════════════════════════════════════════════════
# 0. 自動歸檔
# ════════════════════════════════════════════════════════════════════════════
ARCHIVE_DIR="updateN"
SELF="$(basename "$0")"

mkdir -p "$ARCHIVE_DIR"
for f in update*.sh; do
  [ "$f" = "$SELF" ] && continue
  [ -f "$f" ] || continue
  git mv "$f" "${ARCHIVE_DIR}/$f" 2>/dev/null || mv "$f" "${ARCHIVE_DIR}/$f"
done
git add "${ARCHIVE_DIR}"
if ! git diff --cached --quiet; then
  git commit -m "chore: 歸檔已執行的 updateN.sh 腳本"
fi

# ════════════════════════════════════════════════════════════════════════════
# 1. 前置驗證：8 支檔案都要存在
# ════════════════════════════════════════════════════════════════════════════
for f in cdr.js extensions-groups.js ivr.js logs.js recordings.js settings-vars.js sip-profile.js sounds.js; do
  if [ ! -f "static/js/$f" ]; then
    echo "❌ 找不到 static/js/$f，請確認執行路徑" >&2
    exit 1
  fi
done

TS=$(date +%Y%m%d%H%M%S)
for f in cdr.js extensions-groups.js ivr.js logs.js recordings.js settings-vars.js sip-profile.js sounds.js; do
  cp "static/js/$f" "static/js/$f.bak.$TS"
done

# ════════════════════════════════════════════════════════════════════════════
# 2. 先全部驗證，全部通過才寫入
# ════════════════════════════════════════════════════════════════════════════
python3 << 'AUTH_FIX2_PY_EOF'
import sys

AUTH_HDR = "'Authorization': `Bearer ${getToken()}`"

files = {}

# ── cdr.js ──────────────────────────────────────────────────────────────────
files["static/js/cdr.js"] = [
    ("archive/download 補 Authorization",
"""    const res = await fetch(`${API_BASE}/api/cdr/archive/download?filename=${encodeURIComponent(_archDate)}`);""",
"""    const res = await fetch(`${API_BASE}/api/cdr/archive/download?filename=${encodeURIComponent(_archDate)}`, {
      headers: { 'Authorization': `Bearer ${getToken()}` },
    });"""),
]

# ── extensions-groups.js ─────────────────────────────────────────────────────
files["static/js/extensions-groups.js"] = [
    ("saveExt() 補 Authorization",
"""    const res  = await fetch(url, {
      method,
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(payload),
    });""",
"""    const res  = await fetch(url, {
      method,
      headers: { 'Content-Type': 'application/json', 'Authorization': `Bearer ${getToken()}` },
      body: JSON.stringify(payload),
    });"""),

    ("extensions 建立(改號流程) 補 Authorization",
"""    const createRes = await fetch(`${API_BASE}/api/extensions`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(payload),
    });""",
"""    const createRes = await fetch(`${API_BASE}/api/extensions`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'Authorization': `Bearer ${getToken()}` },
      body: JSON.stringify(payload),
    });"""),

    ("extensions 刪除(改號流程) 補 Authorization",
"""    const deleteRes = await fetch(`${API_BASE}/api/extensions/${oldId}`, { method: 'DELETE' });""",
"""    const deleteRes = await fetch(`${API_BASE}/api/extensions/${oldId}`, {
      method: 'DELETE',
      headers: { 'Authorization': `Bearer ${getToken()}` },
    });"""),

    ("deleteExt() 補 Authorization",
"""    const res = await fetch(`${API_BASE}/api/extensions/${encodeURIComponent(id)}${qs}`, { method: 'DELETE' });""",
"""    const res = await fetch(`${API_BASE}/api/extensions/${encodeURIComponent(id)}${qs}`, {
      method: 'DELETE',
      headers: { 'Authorization': `Bearer ${getToken()}` },
    });"""),

    ("saveGroup() 補 Authorization",
"""    const res    = await fetch(url, {
      method: isEdit ? 'PUT' : 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(payload),
    });""",
"""    const res    = await fetch(url, {
      method: isEdit ? 'PUT' : 'POST',
      headers: { 'Content-Type': 'application/json', 'Authorization': `Bearer ${getToken()}` },
      body: JSON.stringify(payload),
    });"""),

    ("groups 建立(改號流程) 補 Authorization",
"""    const createRes  = await fetch(`${API_BASE}/api/groups`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(payload),
    });""",
"""    const createRes  = await fetch(`${API_BASE}/api/groups`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'Authorization': `Bearer ${getToken()}` },
      body: JSON.stringify(payload),
    });"""),

    ("groups 刪除(改號流程) 補 Authorization",
"""    const deleteRes  = await fetch(`${API_BASE}/api/groups/${oldId}`, { method: 'DELETE' });""",
"""    const deleteRes  = await fetch(`${API_BASE}/api/groups/${oldId}`, {
      method: 'DELETE',
      headers: { 'Authorization': `Bearer ${getToken()}` },
    });"""),

    ("deleteGroup() 補 Authorization",
"""    const res  = await fetch(`${API_BASE}/api/groups/${id}`, { method: 'DELETE' });""",
"""    const res  = await fetch(`${API_BASE}/api/groups/${id}`, {
      method: 'DELETE',
      headers: { 'Authorization': `Bearer ${getToken()}` },
    });"""),
]

# ── ivr.js ──────────────────────────────────────────────────────────────────
files["static/js/ivr.js"] = [
    ("sounds/upload 補 Authorization",
"""    const res = await fetch(`${API_BASE}/api/sounds/upload`, {
      method: 'POST',
      body: formData,
    });""",
"""    const res = await fetch(`${API_BASE}/api/sounds/upload`, {
      method: 'POST',
      headers: { 'Authorization': `Bearer ${getToken()}` },
      body: formData,
    });"""),

    ("sounds 刪除 補 Authorization",
"""  let res = await fetch(`${API_BASE}/api/sounds/${encodeURIComponent(filename)}`, { method: 'DELETE' });""",
"""  let res = await fetch(`${API_BASE}/api/sounds/${encodeURIComponent(filename)}`, {
    method: 'DELETE',
    headers: { 'Authorization': `Bearer ${getToken()}` },
  });"""),

    ("sounds 強制刪除 補 Authorization",
"""    res  = await fetch(`${API_BASE}/api/sounds/${encodeURIComponent(filename)}?force=true`, { method: 'DELETE' });""",
"""    res  = await fetch(`${API_BASE}/api/sounds/${encodeURIComponent(filename)}?force=true`, {
      method: 'DELETE',
      headers: { 'Authorization': `Bearer ${getToken()}` },
    });"""),
]

# ── logs.js ─────────────────────────────────────────────────────────────────
files["static/js/logs.js"] = [
    ("logs/list（歷史日期選單）補 Authorization",
"""    const res  = await fetch(`${API_BASE}/api/logs/list`);
    const data = await res.json();
    const sel  = document.getElementById('hist-date-select');""",
"""    const res  = await fetch(`${API_BASE}/api/logs/list`, { headers: { 'Authorization': `Bearer ${getToken()}` } });
    const data = await res.json();
    const sel  = document.getElementById('hist-date-select');"""),

    ("logs/history 補 Authorization",
"""    const res  = await fetch(`${API_BASE}/api/logs/history?${params}`);""",
"""    const res  = await fetch(`${API_BASE}/api/logs/history?${params}`, { headers: { 'Authorization': `Bearer ${getToken()}` } });"""),

    ("logs/list（目前狀態）補 Authorization",
"""    const res  = await fetch(`${API_BASE}/api/logs/list`);
    const data = await res.json();

    // 目前 log 狀態
    if (curr) {""",
"""    const res  = await fetch(`${API_BASE}/api/logs/list`, { headers: { 'Authorization': `Bearer ${getToken()}` } });
    const data = await res.json();

    // 目前 log 狀態
    if (curr) {"""),

    ("logs/rotate 補 Authorization",
"""    const res  = await fetch(`${API_BASE}/api/logs/rotate`, { method: 'POST' });""",
"""    const res  = await fetch(`${API_BASE}/api/logs/rotate`, {
      method: 'POST',
      headers: { 'Authorization': `Bearer ${getToken()}` },
    });"""),
]

# ── recordings.js ───────────────────────────────────────────────────────────
files["static/js/recordings.js"] = [
    ("recordings 刪除 補 Authorization",
"""    const res = await fetch(`${API_BASE}/api/recordings`, {
      method: 'DELETE',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ path })
    });""",
"""    const res = await fetch(`${API_BASE}/api/recordings`, {
      method: 'DELETE',
      headers: { 'Content-Type': 'application/json', 'Authorization': `Bearer ${getToken()}` },
      body: JSON.stringify({ path })
    });"""),
]

# ── settings-vars.js ────────────────────────────────────────────────────────
files["static/js/settings-vars.js"] = [
    ("cdr/rotate 補 Authorization",
"""    const res = await fetch(`${API_BASE}/api/cdr/rotate`, { method: 'POST' });""",
"""    const res = await fetch(`${API_BASE}/api/cdr/rotate`, {
      method: 'POST',
      headers: { 'Authorization': `Bearer ${getToken()}` },
    });"""),

    ("cdr/archive 刪除 補 Authorization",
"""    const res = await fetch(`${API_BASE}/api/cdr/archive/${filename}`, { method: 'DELETE' });""",
"""    const res = await fetch(`${API_BASE}/api/cdr/archive/${filename}`, {
      method: 'DELETE',
      headers: { 'Authorization': `Bearer ${getToken()}` },
    });"""),

    ("dialplan/file 手動編輯儲存 補 Authorization",
"""    const res = await fetch(`${API_BASE}/api/dialplan/file`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ path: _editingPath, content: area.value })
    });""",
"""    const res = await fetch(`${API_BASE}/api/dialplan/file`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'Authorization': `Bearer ${getToken()}` },
      body: JSON.stringify({ path: _editingPath, content: area.value })
    });"""),

    ("backup/restore 補 Authorization",
"""    const resp = await fetch(`${API_BASE}/api/backup/restore`, { method: 'POST', body: form });""",
"""    const resp = await fetch(`${API_BASE}/api/backup/restore`, {
      method: 'POST',
      headers: { 'Authorization': `Bearer ${getToken()}` },
      body: form,
    });"""),
]

# ── sip-profile.js ──────────────────────────────────────────────────────────
files["static/js/sip-profile.js"] = [
    ("sip-profile 參數更新 補 Authorization",
"""    const res = await fetch(`${API_BASE}/api/sip-profile/${name}`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(updates),
    });""",
"""    const res = await fetch(`${API_BASE}/api/sip-profile/${name}`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'Authorization': `Bearer ${getToken()}` },
      body: JSON.stringify(updates),
    });"""),

    ("acl/apply-restart 補 Authorization",
"""    const res  = await fetch(`${API_BASE}/api/acl/apply-restart`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ confirm: confirmed }),
    });""",
"""    const res  = await fetch(`${API_BASE}/api/acl/apply-restart`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'Authorization': `Bearer ${getToken()}` },
      body: JSON.stringify({ confirm: confirmed }),
    });"""),

    ("ACL 項目儲存 補 Authorization",
"""    const res  = await fetch(url, {
      method: isEdit ? 'PUT' : 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ cidr, note }),
    });""",
"""    const res  = await fetch(url, {
      method: isEdit ? 'PUT' : 'POST',
      headers: { 'Content-Type': 'application/json', 'Authorization': `Bearer ${getToken()}` },
      body: JSON.stringify({ cidr, note }),
    });"""),

    ("trusted-sbc 刪除 補 Authorization",
"""    const res = await fetch(`${API_BASE}/api/acl/trusted-sbc/${encodeURIComponent(cidr)}`, { method: 'DELETE' });""",
"""    const res = await fetch(`${API_BASE}/api/acl/trusted-sbc/${encodeURIComponent(cidr)}`, {
      method: 'DELETE',
      headers: { 'Authorization': `Bearer ${getToken()}` },
    });"""),

    ("sip-profile/nat-wizard 補 Authorization",
"""    const res = await fetch(`${API_BASE}/api/sip-profile/nat-wizard`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(payload),
    });""",
"""    const res = await fetch(`${API_BASE}/api/sip-profile/nat-wizard`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'Authorization': `Bearer ${getToken()}` },
      body: JSON.stringify(payload),
    });"""),
]

# ── sounds.js ───────────────────────────────────────────────────────────────
files["static/js/sounds.js"] = [
    ("sounds/upload 補 Authorization",
"""    const res = await fetch(`${API_BASE}/api/sounds/upload`, { method: 'POST', body: formData });""",
"""    const res = await fetch(`${API_BASE}/api/sounds/upload`, {
      method: 'POST',
      headers: { 'Authorization': `Bearer ${getToken()}` },
      body: formData,
    });"""),

    ("sounds 刪除 補 Authorization",
"""    let res = await fetch(`${API_BASE}/api/sounds/${encodeURIComponent(filename)}`, { method: 'DELETE' });""",
"""    let res = await fetch(`${API_BASE}/api/sounds/${encodeURIComponent(filename)}`, {
      method: 'DELETE',
      headers: { 'Authorization': `Bearer ${getToken()}` },
    });"""),

    ("sounds 強制刪除 補 Authorization",
"""        res = await fetch(`${API_BASE}/api/sounds/${encodeURIComponent(filename)}?force=true`, { method: 'DELETE' });""",
"""        res = await fetch(`${API_BASE}/api/sounds/${encodeURIComponent(filename)}?force=true`, {
          method: 'DELETE',
          headers: { 'Authorization': `Bearer ${getToken()}` },
        });"""),
]

# ── 階段一：全部驗證，不寫入任何檔案 ─────────────────────────────────────────
all_failures = []
plan = {}  # path -> (content_after_edits, applied_labels, skipped_labels)

for path, edits in files.items():
    try:
        with open(path, "r", encoding="utf-8") as f:
            content = f.read()
    except FileNotFoundError:
        all_failures.append((path, "檔案不存在", 0))
        continue

    applied, skipped = [], []
    for label, old, new in edits:
        if new in content:
            skipped.append(label)
            continue
        count = content.count(old)
        if count == 1:
            content = content.replace(old, new, 1)
            applied.append(label)
        else:
            all_failures.append((f"{path} :: {label}", "找到次數", count))

    plan[path] = (content, applied, skipped)

if all_failures:
    print("❌ 驗證階段發現比對失敗，未寫入任何檔案：", file=sys.stderr)
    for name, reason, count in all_failures:
        print(f"   - {name}：{reason}（{count}，預期剛好 1 次）", file=sys.stderr)
    sys.exit(1)

# ── 階段二：全部通過，才真的寫入 ──────────────────────────────────────────────
for path, (content, applied, skipped) in plan.items():
    with open(path, "w", encoding="utf-8") as f:
        f.write(content)
    print(f"✓ {path}：套用 {len(applied)} 項，{len(skipped)} 項已存在略過")
    for label in applied:
        print(f"   (已套用) {label}")
    for label in skipped:
        print(f"   (已存在，略過) {label}")
AUTH_FIX2_PY_EOF

if command -v node >/dev/null 2>&1; then
  for f in cdr.js extensions-groups.js ivr.js logs.js recordings.js settings-vars.js sip-profile.js sounds.js; do
    node --check "static/js/$f"
  done
  echo "✓ 8 支檔案 JS 語法檢查通過"
else
  echo "⚠️  找不到 node，略過 JS 語法檢查，建議手動確認"
fi

git add static/js/cdr.js static/js/extensions-groups.js static/js/ivr.js static/js/logs.js \
        static/js/recordings.js static/js/settings-vars.js static/js/sip-profile.js static/js/sounds.js

# ════════════════════════════════════════════════════════════════════════════
# 3. Commit
# ════════════════════════════════════════════════════════════════════════════
if ! git diff --cached --quiet; then
  git commit -m "fix: 全站其餘 8 支檔案補上寫入/下載操作缺少的 Authorization header（既有 bug）"
else
  echo "ℹ️  沒有變更需要 commit（可能已經套用過）"
fi

echo ""
echo "════════════════════════════════════════════════════"
git log --oneline -5
echo "════════════════════════════════════════════════════"
echo ""
echo "驗證重點清單（瀏覽器 Ctrl+Shift+R 後逐一測試，確認不再出現 401）："
echo "  1. CDR：下載歸檔檔案"
echo "  2. 分機管理：新增/改號/刪除分機"
echo "  3. 分機群組：新增/改號/刪除群組"
echo "  4. IVR：上傳音檔、刪除音檔（含強制刪除）"
echo "  5. 系統日誌：歷史日期選單、查詢歷史、log rotate"
echo "  6. 錄音管理：刪除錄音"
echo "  7. 設定：CDR 歸檔/刪除歸檔、Dialplan 手動編輯儲存、備份還原"
echo "  8. SIP Profile 進階設定：儲存參數、ACL 套用重啟、ACL 新增/刪除、NAT 精靈"
echo "  9. 音檔庫：上傳/刪除（含強制刪除）"
echo " 10. journalctl -u fs-dashboard -f 全程觀察，確認無 401"
