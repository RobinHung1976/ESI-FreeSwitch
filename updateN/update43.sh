#!/bin/bash
# update43.sh — 修復錄音播放（stream/stream_mono）404→實為 401 的問題
#
# update40~42.sh 只改了 @router.get(..., dependencies=[Depends(require_permission_media(...))])
# 這層 decorator 認證，但 routers/recordings.py 的 stream_recording()/stream_mono_recording()
# 函式簽名裡各自還有一個獨立的 user: dict = Depends(get_current_user)（header-only），
# 用來做 scope='own' 的錄音歸屬過濾。FastAPI 會把這個函式參數當成另一個獨立的依賴解析，
# 跟 decorator 那層各自要求認證，等於同一支端點疊了兩層認證，第二層沒改到，
# 所以帶 ?token= 的 <audio src> 呼叫，播放時仍然卡在 401。
#
# 修復：把這兩處函式簽名的 Depends(get_current_user) 改成 Depends(get_current_user_media)，
# decorator 跟函式內部認證統一，query token 才能真正一路通到底。

set -euo pipefail
cd /opt/fs-dashboard

# ── 前置驗證 ──────────────────────────────────────────────────────────────
echo "🔍 前置驗證中..."

grep -q 'async def stream_recording(path: str, user: dict = Depends(get_current_user)):' routers/recordings.py \
  || { echo "❌ stream_recording() 簽名與預期不符，中止" >&2; exit 1; }

grep -q 'async def stream_mono_recording(path: str, user: dict = Depends(get_current_user)):' routers/recordings.py \
  || { echo "❌ stream_mono_recording() 簽名與預期不符，中止" >&2; exit 1; }

grep -q '^from core.auth import require_permission, require_permission_media, get_current_user, apply_scope$' routers/recordings.py \
  || { echo "❌ routers/recordings.py import 行與預期不符，中止" >&2; exit 1; }

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

# ── routers/recordings.py：import 補上 get_current_user_media + 兩處函式簽名改用它 ──
echo "🔧 修改 routers/recordings.py..."
python3 << 'PYEOF'
path = "routers/recordings.py"
with open(path, "r", encoding="utf-8") as f:
    content = f.read()

old_import = "from core.auth import require_permission, require_permission_media, get_current_user, apply_scope"
new_import = "from core.auth import require_permission, require_permission_media, get_current_user, get_current_user_media, apply_scope"
assert content.count(old_import) == 1, "import 行比對失敗"
content = content.replace(old_import, new_import, 1)

old_stream = "async def stream_recording(path: str, user: dict = Depends(get_current_user)):"
new_stream = "async def stream_recording(path: str, user: dict = Depends(get_current_user_media)):"
assert content.count(old_stream) == 1, "stream_recording() 簽名比對失敗"
content = content.replace(old_stream, new_stream, 1)

old_mono = "async def stream_mono_recording(path: str, user: dict = Depends(get_current_user)):"
new_mono = "async def stream_mono_recording(path: str, user: dict = Depends(get_current_user_media)):"
assert content.count(old_mono) == 1, "stream_mono_recording() 簽名比對失敗"
content = content.replace(old_mono, new_mono, 1)

with open(path, "w", encoding="utf-8") as f:
    f.write(content)
print("✅ routers/recordings.py 修改完成")
PYEOF

# ── commit ──────────────────────────────────────────────────────────────
git add routers/recordings.py
git commit -m "fix: 錄音播放 stream/stream_mono 函式簽名內殘留 header-only 的 get_current_user，導致帶 query token 的 <audio src> 播放仍 401，改用 get_current_user_media 統一認證"

echo ""
echo "=================================================="
echo "✅ update43.sh 執行完成"
echo "=================================================="
git log --oneline -1
echo ""
echo "📋 驗證重點清單："
echo "1. systemctl restart fs-dashboard"
echo ""
echo "2. 後端直接驗證（帶 token，換一組新的，因為 30 分鐘會過期）："
echo '   TOKEN=$(curl -s -X POST http://127.0.0.1:3000/api/auth/login -H "Content-Type: application/json" -d '"'"'{"username":"admin","password":"<密碼>"}'"'"' | python3 -c "import sys,json;print(json.load(sys.stdin)['"'"'access_token'"'"'])")'
echo '   curl -v -G -o /tmp/test-stereo.wav --data-urlencode "path=/var/lib/freeswitch/recordings/20260720/1210_1126_20260720_102727_dc1f544a-4c9c-4625-b54e-79fcb3f54948.wav" --data-urlencode "token=${TOKEN}" "http://127.0.0.1:3000/api/recordings/stream"'
echo "   ls -la /tmp/test-stereo.wav   # 預期 200，檔案大小接近 234284 bytes"
echo ""
echo "3. 瀏覽器實測（Ctrl+Shift+R）：錄音管理頁播放（立體聲/單聲道切換）"
echo "4. 確認錄音下載、其他 media 端點（音檔試聽/日誌下載/備份下載）仍正常，未受這次改動影響"
