#!/bin/bash
# update39.sh — 修復「即時日誌」SSE 串流因權限系統上線後被 401 擋住的問題
#
# 現象：/api/logs/stream 回傳 {"detail":"缺少登入憑證"}，前端「即時日誌」Tab 完全沒有訊息，
#      即使撥打測試電話、FreeSwitch 本身 log 檔案正常寫入也一樣。
# 根因：瀏覽器原生 EventSource API 無法自訂 Authorization header，但 /api/logs/stream
#      的 require_permission() dependency 只認 header，導致每次連線都直接 401。
# 解法：比照既有 WebSocket 認證作法（core/runtime.py 的 ?token= query string），
#      新增一個 SSE 專用的認證 dependency（header 或 query token 皆可通過），
#      不影響其他 18 個模組現有的 header-only 認證行為。
#
# 修改檔案：
#   - core/auth.py        新增 get_current_user_sse() / require_permission_sse()
#   - routers/logs.py     stream 端點改用 require_permission_sse()
#   - static/js/logs.js   EventSource 網址補上 ?token=

set -euo pipefail
cd /opt/fs-dashboard

# ── 前置驗證：確認要改的程式碼確實是預期的既有內容，對不上就直接中止 ──────────
echo "🔍 前置驗證中..."

grep -q 'def require_permission(module: str, action: Action):' core/auth.py \
  || { echo "❌ core/auth.py 找不到 require_permission()，內容與預期不符，中止" >&2; exit 1; }

grep -q 'from core.auth import require_permission$' routers/logs.py \
  || { echo "❌ routers/logs.py 的 import 寫法與預期不符，中止" >&2; exit 1; }

grep -q '@router.get("/api/logs/stream", dependencies=\[Depends(require_permission(Module.LOGS, "read"))\])' routers/logs.py \
  || { echo "❌ routers/logs.py 的 stream 端點 decorator 與預期不符，中止" >&2; exit 1; }

grep -q '_logSSE = new EventSource(`${API_BASE}/api/logs/stream`);' static/js/logs.js \
  || { echo "❌ static/js/logs.js 的 EventSource 建立方式與預期不符，中止" >&2; exit 1; }

echo "✅ 前置驗證通過"

# ── 自動歸檔既有 updateN.sh（固定資料夾名稱，不使用 git add -A 避免誤掃其他改動）──
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

# ── 1. core/auth.py：新增 SSE 專用認證 dependency ──────────────────────────
echo "🔧 修改 core/auth.py..."
python3 << 'PYEOF'
path = "core/auth.py"
with open(path, "r", encoding="utf-8") as f:
    content = f.read()

anchor = '''def require_permission(module: str, action: Action):
    """掛在 router 或單一 endpoint 的 dependencies=[]，403 時中斷請求"""
    def _dep(user: dict = Depends(get_current_user)) -> dict:
        perm: Perm = user["permissions"].get(module, Perm())
        if not perm.allows(action):
            raise HTTPException(403, f"權限不足：{module} 需要 {action} 權限")
        return user
    return _dep


def apply_scope(user: dict, requested_ext: str | None, module: str) -> str | None:'''

count = content.count(anchor)
assert count == 1, f"預期找到 1 處錨點字串，實際找到 {count} 處，中止（core/auth.py 內容可能已被改動過）"

new_functions = '''def require_permission(module: str, action: Action):
    """掛在 router 或單一 endpoint 的 dependencies=[]，403 時中斷請求"""
    def _dep(user: dict = Depends(get_current_user)) -> dict:
        perm: Perm = user["permissions"].get(module, Perm())
        if not perm.allows(action):
            raise HTTPException(403, f"權限不足：{module} 需要 {action} 權限")
        return user
    return _dep


def get_current_user_sse(
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
    return _dep


def apply_scope(user: dict, requested_ext: str | None, module: str) -> str | None:'''

content = content.replace(anchor, new_functions)
with open(path, "w", encoding="utf-8") as f:
    f.write(content)
print("✅ core/auth.py 修改完成")
PYEOF

# ── 2. routers/logs.py：import 補上 require_permission_sse + stream 端點改用它 ──
echo "🔧 修改 routers/logs.py..."
python3 << 'PYEOF'
path = "routers/logs.py"
with open(path, "r", encoding="utf-8") as f:
    content = f.read()

old_import = "from core.auth import require_permission"
new_import = "from core.auth import require_permission, require_permission_sse"
assert content.count(old_import) == 1, "import 行比對失敗，中止"
content = content.replace(old_import, new_import, 1)

old_decorator = '@router.get("/api/logs/stream", dependencies=[Depends(require_permission(Module.LOGS, "read"))])'
new_decorator = '@router.get("/api/logs/stream", dependencies=[Depends(require_permission_sse(Module.LOGS, "read"))])'
assert content.count(old_decorator) == 1, "stream 端點 decorator 比對失敗，中止"
content = content.replace(old_decorator, new_decorator, 1)

with open(path, "w", encoding="utf-8") as f:
    f.write(content)
print("✅ routers/logs.py 修改完成")
PYEOF

# ── 3. static/js/logs.js：EventSource 網址補上 ?token= ──────────────────────
echo "🔧 修改 static/js/logs.js..."
python3 << 'PYEOF'
path = "static/js/logs.js"
with open(path, "r", encoding="utf-8") as f:
    content = f.read()

old_line = "_logSSE = new EventSource(`${API_BASE}/api/logs/stream`);"
new_line = "_logSSE = new EventSource(`${API_BASE}/api/logs/stream?token=${encodeURIComponent(getToken())}`);"
assert content.count(old_line) == 1, "EventSource 建立行比對失敗，中止"
content = content.replace(old_line, new_line, 1)

with open(path, "w", encoding="utf-8") as f:
    f.write(content)
print("✅ static/js/logs.js 修改完成")
PYEOF

# ── commit ──────────────────────────────────────────────────────────────
git add core/auth.py routers/logs.py static/js/logs.js
git commit -m "fix: 即時日誌 SSE 串流補上 query token 認證，修復權限系統上線後 EventSource 401 導致無法收到訊息的問題"

echo ""
echo "=================================================="
echo "✅ update39.sh 執行完成"
echo "=================================================="
git log --oneline -1
echo ""
echo "📋 驗證重點清單："
echo "1. systemctl restart fs-dashboard   # core/routers 有改動，務必重啟"
echo "2. 瀏覽器強制重新整理（Ctrl+Shift+R）系統日誌頁面，確認「即時日誌」Tab 徽章顯示「LIVE · 已連線」"
echo "3. 撥打一通測試電話，確認即時日誌畫面即時出現對應行"
echo "4. 開發者工具 Network 分頁確認 /api/logs/stream 請求狀態為 200（非 401），網址帶有 ?token=..."
echo "5. 確認其他頁面（分機、CDR、Dialplan 等一般 REST API）登入/操作行為未受影響（require_permission 本身未被動到）"
echo "6. curl 快速驗證（需帶正確 token）："
echo '   curl -N "http://127.0.0.1:3000/api/logs/stream?token=<有效JWT>"'
