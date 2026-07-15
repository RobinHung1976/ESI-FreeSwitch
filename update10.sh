#!/bin/bash
# update10.sh — 配合 Nginx reverse proxy + HTTPS 上線，修正前端/後端寫死 IP:port 的問題
#
# 背景：
#   - common.js / login.html 寫死 http://192.168.100.209:3000 與 ws://192.168.100.209:8080
#   - 上了 HTTPS 之後，瀏覽器會擋掉這些不安全連線（mixed content），造成登入失敗、WebSocket 連不上
#   - core/runtime.py 的 WebSocket 伺服器改成只 bind 127.0.0.1，統一由 nginx /ws/ 轉發，不再對外開放 8080
#
# 使用方式：
#   cd /opt/fs-dashboard
#   chmod +x update10.sh
#   ./update10.sh
#   (不管成功或中止，都把完整輸出貼回去給 Claude 核對)

set -e
cd "$(dirname "$0")"

echo "=== [1/5] 自動歸檔：把舊的 updateN.sh 搬進固定資料夾 updateN/ ==="
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
  echo "已建立歸檔 commit。"
else
  echo "沒有需要歸檔的舊腳本，略過。"
fi

echo ""
echo "=== [2/5] 前置驗證：確認目前檔案內容符合預期的「修改前」狀態 ==="

FAIL=0

if ! grep -q "const API_BASE = 'http://192.168.100.209:3000';" static/js/common.js; then
  echo "❌ static/js/common.js 沒有找到預期的舊 API_BASE 字串，可能已經改過或內容跟預期不符，中止" >&2
  FAIL=1
fi

if ! grep -q "const WS_URL   = 'ws://192.168.100.209:8080';" static/js/common.js; then
  echo "❌ static/js/common.js 沒有找到預期的舊 WS_URL 字串，中止" >&2
  FAIL=1
fi

if ! grep -q 'server = await websockets.serve(ws_handler, "0.0.0.0", 8080)' core/runtime.py; then
  echo "❌ core/runtime.py 沒有找到預期的 0.0.0.0:8080 綁定字串，中止" >&2
  FAIL=1
fi

if ! grep -q "const API_BASE = 'http://192.168.100.209:3000';" static/login.html; then
  echo "❌ static/login.html 沒有找到預期的舊 API_BASE 字串，中止" >&2
  FAIL=1
fi

if [ "$FAIL" = "1" ]; then
  echo "" >&2
  echo "前置驗證未通過，未寫入任何檔案，請確認檔案現況後再執行。" >&2
  exit 1
fi

echo "前置驗證通過，開始套用修改。"
echo ""
echo "=== [3/5] 修改 static/js/common.js（API_BASE 改相對路徑、WS_URL 跟隨頁面協定） ==="

python3 << 'PYEOF'
import pathlib

path = pathlib.Path("static/js/common.js")
content = path.read_text(encoding="utf-8")

old = """// ── 後端設定 ──────────────────────────────────────────────────────────────────
const API_BASE = 'http://192.168.100.209:3000';
const WS_URL   = 'ws://192.168.100.209:8080';"""

new = """// ── 後端設定 ──────────────────────────────────────────────────────────────────
// 統一透過 nginx 反向代理走同一個 origin（https:443），不再寫死 IP/port。
// 好處：內網/外網切換、換 IP 或改用網域，都不用再改這支檔案。
const API_BASE = '';   // 相對路徑，瀏覽器自動帶目前頁面的 protocol+host

// https 頁面禁止建立不安全的 ws:// 連線（mixed content），故跟隨目前頁面協定
// 對應 nginx 的 location /ws/ → 轉發到後端 127.0.0.1:8080
const WS_PROTOCOL = location.protocol === 'https:' ? 'wss:' : 'ws:';
const WS_URL = `${WS_PROTOCOL}//${location.host}/ws`;"""

count = content.count(old)
if count != 1:
    raise SystemExit(f"❌ static/js/common.js 比對次數異常（預期 1，實際 {count}），中止且不寫入")

content = content.replace(old, new)
path.write_text(content, encoding="utf-8")
print("✅ static/js/common.js 修改完成")
PYEOF

echo ""
echo "=== [4/5] 修改 core/runtime.py（WebSocket 只 bind 127.0.0.1） ==="

python3 << 'PYEOF'
import pathlib

path = pathlib.Path("core/runtime.py")
content = path.read_text(encoding="utf-8")

old = '''async def start_ws_server():
    """在 main event loop 內啟動 WebSocket server"""
    server = await websockets.serve(ws_handler, "0.0.0.0", 8080)
    print("WebSocket 啟動於 ws://0.0.0.0:8080")
    return server'''

new = '''async def start_ws_server():
    """在 main event loop 內啟動 WebSocket server
    只 bind 127.0.0.1：對外一律透過 nginx 的 /ws/ 反向代理轉發進來，
    8080 本身不再對外或對內網其他主機開放，降低攻擊面。
    """
    server = await websockets.serve(ws_handler, "127.0.0.1", 8080)
    print("WebSocket 啟動於 ws://127.0.0.1:8080（僅限本機，經 nginx /ws/ 轉發對外）")
    return server'''

count = content.count(old)
if count != 1:
    raise SystemExit(f"❌ core/runtime.py 比對次數異常（預期 1，實際 {count}），中止且不寫入")

content = content.replace(old, new)
path.write_text(content, encoding="utf-8")
print("✅ core/runtime.py 修改完成")
PYEOF

echo ""
echo "=== [5/5] 修改 static/login.html（API_BASE 改相對路徑），並檢查 change-password.html ==="

python3 << 'PYEOF'
import pathlib

path = pathlib.Path("static/login.html")
content = path.read_text(encoding="utf-8")

old = "const API_BASE = 'http://192.168.100.209:3000';"
new = "const API_BASE = '';"

count = content.count(old)
if count != 1:
    raise SystemExit(f"❌ static/login.html 比對次數異常（預期 1，實際 {count}），中止且不寫入")

content = content.replace(old, new)
path.write_text(content, encoding="utf-8")
print("✅ static/login.html 修改完成")

# change-password.html：不確定是否存在同樣寫死的字串，找到才改，找不到就跳過（不視為錯誤）
cp_path = pathlib.Path("static/change-password.html")
if cp_path.exists():
    cp_content = cp_path.read_text(encoding="utf-8")
    if old in cp_content:
        cnt = cp_content.count(old)
        if cnt == 1:
            cp_content = cp_content.replace(old, new)
            cp_path.write_text(cp_content, encoding="utf-8")
            print("✅ static/change-password.html 也找到同樣字串，已一併修改")
        else:
            print(f"⚠️ static/change-password.html 比對次數異常（{cnt} 次），為安全起見未修改，請人工確認")
    else:
        print("ℹ️ static/change-password.html 沒有找到寫死的 API_BASE 字串，略過（可能本來就沒有這個問題）")
else:
    print("ℹ️ static/change-password.html 不存在，略過")
PYEOF

echo ""
echo "=== git commit ==="
git add -A
git commit -m "fix: 配合 Nginx HTTPS 上線，common.js/login.html 改相對路徑、WS 改走 wss://+/ws/、WebSocket server 只 bind 127.0.0.1"

echo ""
echo "=== 完成，最新 commit： ==="
git log --oneline -1

echo ""
echo "=========================================="
echo "驗證重點清單："
echo "1. systemctl restart fs-dashboard 後 journalctl -u fs-dashboard -f 確認無錯誤"
echo "2. 瀏覽器開 https://192.168.100.209/login.html，F12 Console 確認無 Mixed Content 錯誤"
echo "3. 登入成功後左下角『連線至 FreeSwitch』應為綠燈"
echo "4. F12 Network 分頁確認 WebSocket 請求網址為 wss://192.168.100.209/ws/?token=... 且狀態為 101"
echo "5. git diff HEAD~1 HEAD 確認改動範圍符合預期，沒有動到不相關的檔案"
echo "=========================================="
