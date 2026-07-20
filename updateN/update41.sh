#!/bin/bash
# update41.sh — 接續完成 update40.sh
#
# update40.sh 執行到 routers/files.py 那步時，因為該檔案的實際空行位置跟預期
# （import 區塊後、router = APIRouter() 後的空行數量）不一致，整份覆寫的完整比對
# assert 失敗而中止。core/auth.py、routers/logs.py/sounds.py/backup.py/recordings.py
# 這 5 個檔案當時已經修改完成（尚未 commit），本腳本確認這 5 個檔案的改動還在，
# 接著用「分段精確比對」（不要求整份檔案逐字相同，只鎖定 import 區塊與函式本體
# 兩個獨立區塊）完成 routers/files.py，最後補齊 6 支前端檔案共 10 處 ?token=，
# 一次全部 commit。

set -euo pipefail
cd /opt/fs-dashboard

# ── 前置驗證：確認 update40.sh 已完成的 5 個檔案改動還在（未被還原）──────────
echo "🔍 前置驗證中..."

grep -q 'def require_permission_media(module: str, action: Action):' core/auth.py \
  || { echo "❌ core/auth.py 尚未包含 require_permission_media，狀態與預期不符，中止" >&2; exit 1; }

grep -q 'require_permission_media(Module.LOGS, "read")' routers/logs.py \
  || { echo "❌ routers/logs.py 尚未完成改名，中止" >&2; exit 1; }

grep -q 'require_permission_media(Module.SOUNDS, "read")' routers/sounds.py \
  || { echo "❌ routers/sounds.py 尚未完成改名，中止" >&2; exit 1; }

grep -q 'require_permission_media(Module.BACKUP, "read")' routers/backup.py \
  || { echo "❌ routers/backup.py 尚未完成改名，中止" >&2; exit 1; }

grep -q 'require_permission_media(Module.RECORDINGS, "read")' routers/recordings.py \
  || { echo "❌ routers/recordings.py 尚未完成改名，中止" >&2; exit 1; }

# files.py 應該還是原始未修改狀態
grep -q 'def download_file(path: str):$' routers/files.py \
  || { echo "❌ routers/files.py 狀態與預期不符（可能已被改過），中止" >&2; exit 1; }
grep -q 'from core.auth import get_current_user_media' routers/files.py \
  && { echo "❌ routers/files.py 似乎已經改過了，中止避免重複修改" >&2; exit 1; }

for f in static/js/ivr.js static/js/settings-vars.js static/js/sounds.js static/js/logs.js static/js/backup.js static/js/recordings.js; do
  grep -q 'token=\${encodeURIComponent(getToken())}' "$f" \
    && { echo "❌ $f 似乎已經改過 token，中止避免重複修改" >&2; exit 1; } || true
done

echo "✅ 前置驗證通過"

# ── 自動歸檔既有 updateN.sh ────────────────────────────────────────────────
ARCHIVE_DIR="updateN"
SELF="$(basename "$0")"

mkdir -p "$ARCHIVE_DIR"
for f in update*.sh; do
  [ "$f" = "$SELF" ] && continue
  [ -f "$f" ] || continue
  git mv "$f" "${ARCHIVE_DIR}/$f" 2>/dev/null || mv "$f" "${ARCHIVE_DIR}/$f"
done
git add update*.sh "${ARCHIVE_DIR}/" 2>/dev/null || true
if ! git diff --cached --quiet; then
  git commit -m "chore: 歸檔已執行的 updateN.sh 腳本"
  echo "✅ 已歸檔既有 updateN.sh"
else
  echo "ℹ️  沒有需要歸檔的腳本"
fi

# ── routers/files.py：分段精確比對，避開空行位置差異 ────────────────────────
echo "🔧 修改 routers/files.py..."
python3 << 'PYEOF'
path = "routers/files.py"
with open(path, "r", encoding="utf-8") as f:
    content = f.read()

# 區塊 1：import
old_imports = '''import os
from fastapi import APIRouter, HTTPException
from fastapi.responses import FileResponse'''

new_imports = '''import os
from fastapi import APIRouter, HTTPException, Depends
from fastapi.responses import FileResponse

from core.auth import get_current_user_media
from core.permissions import Module, Perm'''

count = content.count(old_imports)
assert count == 1, f"import 區塊比對失敗，找到 {count} 處，中止"
content = content.replace(old_imports, new_imports, 1)

# 區塊 2：整個端點函式（decorator ~ 函式結尾，這段先前已確認無內部空行）
old_func = '''@router.get("/api/download")
def download_file(path: str):
    """下載指定檔案"""
    allowed_dirs = [
        "/etc/freeswitch/",
        "/var/log/freeswitch/",
        "/var/lib/freeswitch/recordings/",
        "/usr/share/freeswitch/sounds/",
    ]
    if not any(path.startswith(d) for d in allowed_dirs):
        raise HTTPException(status_code=403, detail="不允許存取此路徑")
    if not os.path.isfile(path):
        raise HTTPException(status_code=404, detail="檔案不存在")
    filename = os.path.basename(path)
    return FileResponse(path, filename=filename, media_type="application/octet-stream")'''

new_func = '''# 路徑前綴 → 對應模組權限（依序比對，符合哪個前綴就要求該模組的 read 權限）
_DIR_MODULE_MAP = [
    ("/var/lib/freeswitch/recordings/", Module.RECORDINGS),
    ("/usr/share/freeswitch/sounds/", Module.SOUNDS),
    ("/var/log/freeswitch/", Module.LOGS),
    ("/etc/freeswitch/", Module.SETTINGS),
]


def _resolve_dir(d: str) -> str:
    return os.path.realpath(d).rstrip(os.sep)


def _required_module(real_path: str):
    for prefix, module in _DIR_MODULE_MAP:
        allowed_real = _resolve_dir(prefix)
        if real_path == allowed_real or real_path.startswith(allowed_real + os.sep):
            return module
    return None


@router.get("/api/download")
def download_file(path: str, user: dict = Depends(get_current_user_media)):
    """下載指定檔案，路徑先正規化再比對白名單，並依前綴要求對應模組的讀取權限

    2026-07-20 修復：原本此端點完全沒有認證檢查，任何人不用登入即可用 ?path=
    下載白名單目錄底下任意檔案；且路徑比對只用字面字串 startswith()，未用
    os.path.realpath() 正規化，有路徑穿越風險（例如 path 帶 ../ 繞過前綴檢查）。
    見 changelog-details/20260720-download-endpoint-auth-fix.md
    """
    real_path = os.path.realpath(path)

    module = _required_module(real_path)
    if module is None:
        raise HTTPException(status_code=403, detail="不允許存取此路徑")

    perm: Perm = user["permissions"].get(module, Perm())
    if not perm.allows("read"):
        raise HTTPException(status_code=403, detail=f"權限不足：{module} 需要 read 權限")

    if not os.path.isfile(real_path):
        raise HTTPException(status_code=404, detail="檔案不存在")

    filename = os.path.basename(real_path)
    return FileResponse(real_path, filename=filename, media_type="application/octet-stream")'''

count = content.count(old_func)
assert count == 1, f"函式本體比對失敗，找到 {count} 處，中止"
content = content.replace(old_func, new_func, 1)

with open(path, "w", encoding="utf-8") as f:
    f.write(content)
print("✅ routers/files.py 修改完成")
PYEOF

# ── 前端 6 支檔案，共 10 處補 ?token= ────────────────────────────────────────

echo "🔧 修改 static/js/ivr.js..."
python3 << 'PYEOF'
path = "static/js/ivr.js"
with open(path, "r", encoding="utf-8") as f:
    content = f.read()
old = '<audio controls style="height:24px;width:140px" src="${API_BASE}/api/sounds/stream?path=${encodeURIComponent(s.path)}"></audio>'
new = '<audio controls style="height:24px;width:140px" src="${API_BASE}/api/sounds/stream?path=${encodeURIComponent(s.path)}&token=${encodeURIComponent(getToken())}"></audio>'
assert content.count(old) == 1, "ivr.js 比對失敗"
content = content.replace(old, new, 1)
with open(path, "w", encoding="utf-8") as f:
    f.write(content)
print("✅ ivr.js 修改完成")
PYEOF

echo "🔧 修改 static/js/settings-vars.js..."
python3 << 'PYEOF'
path = "static/js/settings-vars.js"
with open(path, "r", encoding="utf-8") as f:
    content = f.read()

old1 = "audio.src = `${API_BASE}/api/sounds/stream?path=${encodeURIComponent(path)}`;"
new1 = "audio.src = `${API_BASE}/api/sounds/stream?path=${encodeURIComponent(path)}&token=${encodeURIComponent(getToken())}`;"
assert content.count(old1) == 1, "settings-vars.js 音檔試聽比對失敗"
content = content.replace(old1, new1, 1)

old2 = "a.href  = `${API_BASE}/api/backup/download?filename=${encodeURIComponent(filename)}`;"
new2 = "a.href  = `${API_BASE}/api/backup/download?filename=${encodeURIComponent(filename)}&token=${encodeURIComponent(getToken())}`;"
assert content.count(old2) == 1, "settings-vars.js 備份下載比對失敗"
content = content.replace(old2, new2, 1)

with open(path, "w", encoding="utf-8") as f:
    f.write(content)
print("✅ settings-vars.js 修改完成")
PYEOF

echo "🔧 修改 static/js/sounds.js..."
python3 << 'PYEOF'
path = "static/js/sounds.js"
with open(path, "r", encoding="utf-8") as f:
    content = f.read()
old = "player.src = `${API_BASE}/api/sounds/stream?path=${encodeURIComponent(path)}`;"
new = "player.src = `${API_BASE}/api/sounds/stream?path=${encodeURIComponent(path)}&token=${encodeURIComponent(getToken())}`;"
assert content.count(old) == 1, "sounds.js 比對失敗"
content = content.replace(old, new, 1)
with open(path, "w", encoding="utf-8") as f:
    f.write(content)
print("✅ sounds.js 修改完成")
PYEOF

echo "🔧 修改 static/js/logs.js..."
python3 << 'PYEOF'
path = "static/js/logs.js"
with open(path, "r", encoding="utf-8") as f:
    content = f.read()
old = "a.href     = `${API_BASE}/api/logs/download?date=${_histDate}`;"
new = "a.href     = `${API_BASE}/api/logs/download?date=${_histDate}&token=${encodeURIComponent(getToken())}`;"
assert content.count(old) == 1, "logs.js 比對失敗"
content = content.replace(old, new, 1)
with open(path, "w", encoding="utf-8") as f:
    f.write(content)
print("✅ logs.js 修改完成")
PYEOF

echo "🔧 修改 static/js/backup.js..."
python3 << 'PYEOF'
path = "static/js/backup.js"
with open(path, "r", encoding="utf-8") as f:
    content = f.read()
old = "const url = `${API_BASE}/api/download?path=${encodeURIComponent(path)}`;"
new = "const url = `${API_BASE}/api/download?path=${encodeURIComponent(path)}&token=${encodeURIComponent(getToken())}`;"
assert content.count(old) == 1, "backup.js 比對失敗"
content = content.replace(old, new, 1)
with open(path, "w", encoding="utf-8") as f:
    f.write(content)
print("✅ backup.js 修改完成")
PYEOF

echo "🔧 修改 static/js/recordings.js..."
python3 << 'PYEOF'
path = "static/js/recordings.js"
with open(path, "r", encoding="utf-8") as f:
    content = f.read()

old = '''  const streamUrl = `${API_BASE}/api/recordings/stream?path=${encodeURIComponent(f.path)}`;
  const monoUrl   = `${API_BASE}/api/recordings/stream_mono?path=${encodeURIComponent(f.path)}`;
  const dlUrl     = `${API_BASE}/api/download?path=${encodeURIComponent(f.path)}`;
  const monoFile  = f.mono_path ? f.mono_path.split('/').pop() : '';
  const dlMonoUrl = f.mono_path ? `${API_BASE}/api/download?path=${encodeURIComponent(f.mono_path)}` : '';'''

new = '''  const _tok = encodeURIComponent(getToken());
  const streamUrl = `${API_BASE}/api/recordings/stream?path=${encodeURIComponent(f.path)}&token=${_tok}`;
  const monoUrl   = `${API_BASE}/api/recordings/stream_mono?path=${encodeURIComponent(f.path)}&token=${_tok}`;
  const dlUrl     = `${API_BASE}/api/download?path=${encodeURIComponent(f.path)}&token=${_tok}`;
  const monoFile  = f.mono_path ? f.mono_path.split('/').pop() : '';
  const dlMonoUrl = f.mono_path ? `${API_BASE}/api/download?path=${encodeURIComponent(f.mono_path)}&token=${_tok}` : '';'''

assert content.count(old) == 1, "recordings.js 比對失敗"
content = content.replace(old, new, 1)
with open(path, "w", encoding="utf-8") as f:
    f.write(content)
print("✅ recordings.js 修改完成")
PYEOF

# ── commit（含 update40.sh 當時已修改但尚未 commit 的 5 個檔案）───────────────
git add core/auth.py routers/logs.py routers/sounds.py routers/backup.py routers/recordings.py routers/files.py \
        static/js/ivr.js static/js/settings-vars.js static/js/sounds.js static/js/logs.js static/js/backup.js static/js/recordings.js

git commit -m "fix: 全站補齊瀏覽器原生機制(EventSource/audio src/下載連結)缺 Authorization 的問題，並修復 /api/download 完全無認證 + 路徑穿越的資安缺口"

echo ""
echo "=================================================="
echo "✅ update41.sh 執行完成"
echo "=================================================="
git log --oneline -1
echo ""
echo "📋 驗證重點清單（與 update40.sh 相同，這次才是真正跑到底）："
echo "1. systemctl restart fs-dashboard"
echo "2. /opt/myapp/venv/bin/python -c 'import server'   # 確認語法/import 正確"
echo ""
echo "3. 資安缺口驗證（最重要）：未帶 token 應該要 401"
echo '   curl -o /dev/null -s -w "%{http_code}\n" "http://127.0.0.1:3000/api/download?path=/etc/freeswitch/vars.xml"'
echo "   → 預期 401"
echo ""
echo "4. 帶正確 token，應該要能正常下載："
echo '   TOKEN=$(curl -s -X POST http://127.0.0.1:3000/api/auth/login -H "Content-Type: application/json" -d '"'"'{"username":"admin","password":"<密碼>"}'"'"' | python3 -c "import sys,json;print(json.load(sys.stdin)['"'"'access_token'"'"'])")'
echo '   curl -o /dev/null -s -w "%{http_code}\n" "http://127.0.0.1:3000/api/download?path=/etc/freeswitch/vars.xml&token=${TOKEN}"        # 預期 200'
echo '   curl -o /dev/null -s -w "%{http_code}\n" "http://127.0.0.1:3000/api/download?path=/var/log/freeswitch/freeswitch.log&token=${TOKEN}"  # 預期 200'
echo ""
echo "5. 路徑穿越防護驗證（帶 token，但路徑試圖跳出白名單）："
echo '   curl -o /dev/null -s -w "%{http_code}\n" "http://127.0.0.1:3000/api/download?path=/etc/freeswitch/../passwd&token=${TOKEN}"'
echo "   → 預期 403"
echo ""
echo "6. 瀏覽器實測（Ctrl+Shift+R）：音檔庫/IVR試聽、全域變數音檔試聽、日誌歷史下載、備份下載(設定頁+備份頁)、錄音播放與下載"
echo "7. 確認一般 REST API 未受影響"
