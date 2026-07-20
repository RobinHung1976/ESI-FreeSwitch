#!/bin/bash
# update40.sh — 全站「瀏覽器原生機制無法帶 Authorization header」問題總清查修復
#
# 背景：update39.sh 修好即時日誌 SSE 之後，做了一次全站稽核，發現同一類問題
#      （EventSource/<audio src>/<a href> 直接下載，皆無法自訂 header）還有多處，
#      其中 /api/download 更是完全沒有掛任何認證，屬於資安缺口（任何人不用登入
#      即可用 ?path= 下載 /etc/freeswitch/、/var/log/freeswitch/、
#      /var/lib/freeswitch/recordings/、/usr/share/freeswitch/sounds/ 底下任意檔案），
#      且路徑白名單只用字面字串比對，未用 os.path.realpath() 正規化，有路徑穿越風險。
#
# 本次修復：
#   A. core/auth.py        require_permission_sse 更名為通用的 require_permission_media
#                           （不只給 SSE，audio/下載類端點都共用），routers/logs.py 同步改名
#   B. routers/files.py    /api/download 補上認證：依路徑前綴對應各自模組權限
#                           （recordings→RECORDINGS、sounds→SOUNDS、log→LOGS、其餘→SETTINGS）
#                           + os.path.realpath() 正規化路徑，修掉路徑穿越風險
#   C. routers/sounds.py / backup.py / recordings.py
#                           stream/download 端點從 require_permission 改為 require_permission_media
#   D. 前端 6 支檔案共 10 處：EventSource/<audio src>/下載連結補上 ?token=

set -euo pipefail
cd /opt/fs-dashboard

# ── 前置驗證 ──────────────────────────────────────────────────────────────
echo "🔍 前置驗證中..."

grep -q 'def require_permission_sse(module: str, action: Action):' core/auth.py \
  || { echo "❌ core/auth.py 找不到 require_permission_sse()，內容與預期不符，中止" >&2; exit 1; }

grep -q 'from core.auth import require_permission, require_permission_sse' routers/logs.py \
  || { echo "❌ routers/logs.py import 行與預期不符，中止" >&2; exit 1; }

for f in routers/sounds.py routers/backup.py routers/recordings.py routers/files.py; do
  [ -f "$f" ] || { echo "❌ 找不到 $f，中止" >&2; exit 1; }
done

grep -q '^from core.auth import require_permission$' routers/sounds.py \
  || { echo "❌ routers/sounds.py import 行與預期不符，中止" >&2; exit 1; }
grep -q '^from core.auth import require_permission$' routers/backup.py \
  || { echo "❌ routers/backup.py import 行與預期不符，中止" >&2; exit 1; }
grep -q '^from core.auth import require_permission, get_current_user, apply_scope$' routers/recordings.py \
  || { echo "❌ routers/recordings.py import 行與預期不符，中止" >&2; exit 1; }

grep -q 'def download_file(path: str):' routers/files.py \
  || { echo "❌ routers/files.py download_file() 簽名與預期不符，中止" >&2; exit 1; }

for f in static/js/ivr.js static/js/settings-vars.js static/js/sounds.js static/js/logs.js static/js/backup.js static/js/recordings.js; do
  [ -f "$f" ] || { echo "❌ 找不到 $f，中止" >&2; exit 1; }
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

# ── A. core/auth.py：require_permission_sse → require_permission_media ────
echo "🔧 修改 core/auth.py..."
python3 << 'PYEOF'
path = "core/auth.py"
with open(path, "r", encoding="utf-8") as f:
    content = f.read()

old_block = '''def get_current_user_sse(
    token: str | None = None,
    creds: HTTPAuthorizationCredentials | None = Depends(_security),
) -> dict:
    """
    SSE 專用認證：瀏覽器原生 EventSource 無法自訂 Authorization header，
    比照既有 WebSocket 認證作法（core/runtime.py ws_handler 的 ?token=），
    改為 header 或 query string token 兩者擇一皆可通過；一般 REST API
    仍只認 header（見 get_current_user），不受此函式影響。
    """
    raw_token = creds.credentials if creds is not None else token
    if not raw_token:
        raise HTTPException(401, "缺少登入憑證")
    try:
        payload = decode_access_token(raw_token)
    except TokenError as e:
        raise HTTPException(401, str(e))

    payload["permissions"] = {
        mod: Perm(**flags) for mod, flags in payload.get("permissions", {}).items()
    }
    return payload


def require_permission_sse(module: str, action: Action):
    """SSE 端點專用版本的 require_permission，認證走 get_current_user_sse"""
    def _dep(user: dict = Depends(get_current_user_sse)) -> dict:
        perm: Perm = user["permissions"].get(module, Perm())
        if not perm.allows(action):
            raise HTTPException(403, f"權限不足：{module} 需要 {action} 權限")
        return user
    return _dep'''

count = content.count(old_block)
assert count == 1, f"預期找到 1 處錨點字串，實際找到 {count} 處，中止"

new_block = '''def get_current_user_media(
    token: str | None = None,
    creds: HTTPAuthorizationCredentials | None = Depends(_security),
) -> dict:
    """
    媒體/下載類端點專用認證：瀏覽器原生 EventSource／<audio src>／<a href> 直接下載
    皆無法自訂 Authorization header，比照既有 WebSocket 認證作法
    （core/runtime.py ws_handler 的 ?token=），改為 header 或 query string token
    兩者擇一皆可通過；一般 REST API 仍只認 header（見 get_current_user），不受此函式影響。
    """
    raw_token = creds.credentials if creds is not None else token
    if not raw_token:
        raise HTTPException(401, "缺少登入憑證")
    try:
        payload = decode_access_token(raw_token)
    except TokenError as e:
        raise HTTPException(401, str(e))

    payload["permissions"] = {
        mod: Perm(**flags) for mod, flags in payload.get("permissions", {}).items()
    }
    return payload


def require_permission_media(module: str, action: Action):
    """媒體/下載類端點專用版本的 require_permission，認證走 get_current_user_media"""
    def _dep(user: dict = Depends(get_current_user_media)) -> dict:
        perm: Perm = user["permissions"].get(module, Perm())
        if not perm.allows(action):
            raise HTTPException(403, f"權限不足：{module} 需要 {action} 權限")
        return user
    return _dep'''

content = content.replace(old_block, new_block)
with open(path, "w", encoding="utf-8") as f:
    f.write(content)
print("✅ core/auth.py 修改完成")
PYEOF

# ── routers/logs.py：同步改名 ───────────────────────────────────────────────
echo "🔧 修改 routers/logs.py..."
python3 << 'PYEOF'
path = "routers/logs.py"
with open(path, "r", encoding="utf-8") as f:
    content = f.read()

old_import = "from core.auth import require_permission, require_permission_sse"
new_import = "from core.auth import require_permission, require_permission_media"
assert content.count(old_import) == 1, "logs.py import 行比對失敗"
content = content.replace(old_import, new_import, 1)

old_stream = '@router.get("/api/logs/stream", dependencies=[Depends(require_permission_sse(Module.LOGS, "read"))])'
new_stream = '@router.get("/api/logs/stream", dependencies=[Depends(require_permission_media(Module.LOGS, "read"))])'
assert content.count(old_stream) == 1, "logs.py stream decorator 比對失敗"
content = content.replace(old_stream, new_stream, 1)

old_download = '@router.get("/api/logs/download", dependencies=[Depends(require_permission(Module.LOGS, "read"))])'
new_download = '@router.get("/api/logs/download", dependencies=[Depends(require_permission_media(Module.LOGS, "read"))])'
assert content.count(old_download) == 1, "logs.py download decorator 比對失敗"
content = content.replace(old_download, new_download, 1)

with open(path, "w", encoding="utf-8") as f:
    f.write(content)
print("✅ routers/logs.py 修改完成")
PYEOF

# ── routers/sounds.py ───────────────────────────────────────────────────────
echo "🔧 修改 routers/sounds.py..."
python3 << 'PYEOF'
path = "routers/sounds.py"
with open(path, "r", encoding="utf-8") as f:
    content = f.read()

old_import = "from core.auth import require_permission"
new_import = "from core.auth import require_permission, require_permission_media"
assert content.count(old_import) == 1, "sounds.py import 行比對失敗"
content = content.replace(old_import, new_import, 1)

old_stream = '@router.get("/api/sounds/stream", dependencies=[Depends(require_permission(Module.SOUNDS, "read"))])'
new_stream = '@router.get("/api/sounds/stream", dependencies=[Depends(require_permission_media(Module.SOUNDS, "read"))])'
assert content.count(old_stream) == 1, "sounds.py stream decorator 比對失敗"
content = content.replace(old_stream, new_stream, 1)

with open(path, "w", encoding="utf-8") as f:
    f.write(content)
print("✅ routers/sounds.py 修改完成")
PYEOF

# ── routers/backup.py ───────────────────────────────────────────────────────
echo "🔧 修改 routers/backup.py..."
python3 << 'PYEOF'
path = "routers/backup.py"
with open(path, "r", encoding="utf-8") as f:
    content = f.read()

old_import = "from core.auth import require_permission"
new_import = "from core.auth import require_permission, require_permission_media"
assert content.count(old_import) == 1, "backup.py import 行比對失敗"
content = content.replace(old_import, new_import, 1)

old_dl = '@router.get("/api/backup/download", dependencies=[Depends(require_permission(Module.BACKUP, "read"))])'
new_dl = '@router.get("/api/backup/download", dependencies=[Depends(require_permission_media(Module.BACKUP, "read"))])'
assert content.count(old_dl) == 1, "backup.py download decorator 比對失敗"
content = content.replace(old_dl, new_dl, 1)

with open(path, "w", encoding="utf-8") as f:
    f.write(content)
print("✅ routers/backup.py 修改完成")
PYEOF

# ── routers/recordings.py ────────────────────────────────────────────────────
echo "🔧 修改 routers/recordings.py..."
python3 << 'PYEOF'
path = "routers/recordings.py"
with open(path, "r", encoding="utf-8") as f:
    content = f.read()

old_import = "from core.auth import require_permission, get_current_user, apply_scope"
new_import = "from core.auth import require_permission, require_permission_media, get_current_user, apply_scope"
assert content.count(old_import) == 1, "recordings.py import 行比對失敗"
content = content.replace(old_import, new_import, 1)

old_stream = '@router.get("/api/recordings/stream", dependencies=[Depends(require_permission(Module.RECORDINGS, "read"))])'
new_stream = '@router.get("/api/recordings/stream", dependencies=[Depends(require_permission_media(Module.RECORDINGS, "read"))])'
assert content.count(old_stream) == 1, "recordings.py stream decorator 比對失敗"
content = content.replace(old_stream, new_stream, 1)

old_mono = '@router.get("/api/recordings/stream_mono", dependencies=[Depends(require_permission(Module.RECORDINGS, "read"))])'
new_mono = '@router.get("/api/recordings/stream_mono", dependencies=[Depends(require_permission_media(Module.RECORDINGS, "read"))])'
assert content.count(old_mono) == 1, "recordings.py stream_mono decorator 比對失敗"
content = content.replace(old_mono, new_mono, 1)

with open(path, "w", encoding="utf-8") as f:
    f.write(content)
print("✅ routers/recordings.py 修改完成")
PYEOF

# ── B. routers/files.py：/api/download 補認證 + 修路徑穿越風險（整份覆寫）────
echo "🔧 修改 routers/files.py..."
python3 << 'PYEOF'
path = "routers/files.py"
with open(path, "r", encoding="utf-8") as f:
    original = f.read()

expected_original = '''"""
routers/files.py — 通用檔案下載端點：/api/download（供「設定 > 檔案路徑」頁面下載 vars.xml / dialplan XML / CDR / log 等使用）
"""
import os
from fastapi import APIRouter, HTTPException
from fastapi.responses import FileResponse
router = APIRouter()
@router.get("/api/download")
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
    return FileResponse(path, filename=filename, media_type="application/octet-stream")
'''

assert original == expected_original, "routers/files.py 目前內容與預期不符（可能已被改過），中止，不覆寫"

new_content = '''"""
routers/files.py — 通用檔案下載端點：/api/download（供「設定 > 檔案路徑」頁面下載 vars.xml / dialplan XML / CDR / log / 錄音 / 音檔共用）

⚠️ 2026-07-20 修復：原本此端點完全沒有認證檢查，任何人不用登入即可用 ?path= 下載
   白名單目錄底下任意檔案；且路徑比對只用字面字串 startswith()，未用 os.path.realpath()
   正規化，有路徑穿越風險（例如 path 帶 ../ 繞過前綴檢查）。現改為：
   1) 先用 os.path.realpath() 正規化路徑再比對白名單
   2) 依路徑前綴對應到各自模組權限，要求對應模組的 read 權限
   見 changelog-details/20260720-download-endpoint-auth-fix.md
"""
import os
from fastapi import APIRouter, HTTPException, Depends
from fastapi.responses import FileResponse

from core.auth import get_current_user_media
from core.permissions import Module, Perm

router = APIRouter()

# 路徑前綴 → 對應模組權限（依序比對，符合哪個前綴就要求該模組的 read 權限）
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
    """下載指定檔案，路徑先正規化再比對白名單，並依前綴要求對應模組的讀取權限"""
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
    return FileResponse(real_path, filename=filename, media_type="application/octet-stream")
'''

with open(path, "w", encoding="utf-8") as f:
    f.write(new_content)
print("✅ routers/files.py 修改完成（整份覆寫）")
PYEOF

# ── D. 前端 6 支檔案，共 10 處補 ?token= ──────────────────────────────────

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

# ── commit ──────────────────────────────────────────────────────────────
git add core/auth.py routers/logs.py routers/sounds.py routers/backup.py routers/recordings.py routers/files.py \
        static/js/ivr.js static/js/settings-vars.js static/js/sounds.js static/js/logs.js static/js/backup.js static/js/recordings.js

git commit -m "fix: 全站補齊瀏覽器原生機制(EventSource/audio src/下載連結)缺 Authorization 的問題，並修復 /api/download 完全無認證 + 路徑穿越的資安缺口"

echo ""
echo "=================================================="
echo "✅ update40.sh 執行完成"
echo "=================================================="
git log --oneline -1
echo ""
echo "📋 驗證重點清單："
echo "1. systemctl restart fs-dashboard   # 5 支 routers/*.py 有改動，務必重啟"
echo "2. 手動確認 core/auth.py 語法正確：/opt/myapp/venv/bin/python -c 'import server'"
echo ""
echo "3. 資安缺口驗證（最重要）：未帶 token 應該要 401，不能再直接下載成功"
echo '   curl -o /dev/null -s -w "%{http_code}\n" "http://127.0.0.1:3000/api/download?path=/etc/freeswitch/vars.xml"'
echo "   → 預期 401（修復前是 200，能直接下載）"
echo ""
echo "4. 帶正確 token + 對應模組權限，應該要能正常下載（以 admin 帳號測試 4 種路徑前綴各一次）："
echo '   TOKEN=$(curl -s -X POST http://127.0.0.1:3000/api/auth/login -H "Content-Type: application/json" -d '"'"'{"username":"admin","password":"<密碼>"}'"'"' | python3 -c "import sys,json;print(json.load(sys.stdin)['"'"'access_token'"'"'])")'
echo '   curl -o /dev/null -s -w "%{http_code}\n" "http://127.0.0.1:3000/api/download?path=/etc/freeswitch/vars.xml&token=${TOKEN}"        # 預期 200'
echo '   curl -o /dev/null -s -w "%{http_code}\n" "http://127.0.0.1:3000/api/download?path=/var/log/freeswitch/freeswitch.log&token=${TOKEN}"  # 預期 200'
echo ""
echo "5. 路徑穿越防護驗證（帶 token，但路徑試圖跳出白名單）："
echo '   curl -o /dev/null -s -w "%{http_code}\n" "http://127.0.0.1:3000/api/download?path=/etc/freeswitch/../passwd&token=${TOKEN}"'
echo "   → 預期 403（不是意外的 200）"
echo ""
echo "6. 瀏覽器實測（強制重新整理 Ctrl+Shift+R）："
echo "   - 音檔庫／IVR 音檔試聽正常播放"
echo "   - 系統設定 > 全域變數 的音檔試聽正常播放"
echo "   - 系統日誌歷史查詢下載正常"
echo "   - 設定頁備份下載正常"
echo "   - 備份管理頁「下載」按鈕正常"
echo "   - 錄音管理頁播放（立體聲/單聲道）與下載皆正常"
echo ""
echo "7. 確認一般 REST API（分機/CDR/Dialplan 等）登入操作未受影響（require_permission 本身未被動到）"
