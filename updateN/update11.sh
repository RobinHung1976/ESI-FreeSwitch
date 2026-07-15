#!/bin/bash
# update11.sh — 修正上一支 update10.sh 的問題：
#   1) 移除誤被 commit 的 .bak 備份檔，加入 .gitignore
#   2) 確認 common.js / runtime.py 已是新版（上次已被連帶 commit，本次不重複處理）
#   3) 修改 static/login.html（API_BASE 改相對路徑），並視情況一併處理 change-password.html
#
# 使用方式：
#   cd /opt/fs-dashboard
#   chmod +x update11.sh
#   ./update11.sh

set -e
cd "$(dirname "$0")"

echo "=== [1/4] 自動歸檔：把舊的 updateN.sh 搬進固定資料夾 updateN/（僅限 update*.sh，不動其他檔案）==="
ARCHIVE_DIR="updateN"
SELF="$(basename "$0")"

mkdir -p "$ARCHIVE_DIR"
for f in update*.sh; do
  [ "$f" = "$SELF" ] && continue
  [ -f "$f" ] || continue
  git mv "$f" "${ARCHIVE_DIR}/$f" 2>/dev/null || mv "$f" "${ARCHIVE_DIR}/$f"
done
git add "${ARCHIVE_DIR}"
if ! git diff --cached --quiet -- "${ARCHIVE_DIR}"; then
  git commit -m "chore: 歸檔已執行的 updateN.sh 腳本"
  echo "已建立歸檔 commit。"
else
  echo "沒有需要歸檔的舊腳本，略過。"
fi

echo ""
echo "=== [2/4] 清理不該進 git 的 .bak 備份檔，加入 .gitignore ==="
REMOVED=0
if git ls-files --error-unmatch core/runtime.py.bak >/dev/null 2>&1; then
  git rm --cached -f core/runtime.py.bak
  REMOVED=1
fi
if git ls-files --error-unmatch static/js/common.js.bak >/dev/null 2>&1; then
  git rm --cached -f static/js/common.js.bak
  REMOVED=1
fi
rm -f core/runtime.py.bak static/js/common.js.bak

if ! grep -qxF "*.bak" .gitignore 2>/dev/null; then
  echo "*.bak" >> .gitignore
  REMOVED=1
fi

git add .gitignore
if [ "$REMOVED" = "1" ] && ! git diff --cached --quiet; then
  git commit -m "chore: 移除 .bak 備份檔的 git 追蹤並加入 .gitignore（git 本身即版本備份，不需額外 .bak 檔）"
  echo "已建立清理 commit。"
else
  echo "沒有 .bak 殘留需要清理，略過。"
fi

echo ""
echo "=== [3/4] 確認 common.js / runtime.py 現況（預期：上次已連帶套用完成，本次僅檢查不重改）==="
if grep -q 'const WS_URL = `${WS_PROTOCOL}//${location.host}/ws`;' static/js/common.js; then
  echo "ℹ️  static/js/common.js 已是新版內容，略過。"
else
  echo "⚠️  static/js/common.js 內容跟預期不符，請人工確認，本腳本不處理這支檔案。"
fi
if grep -q 'websockets.serve(ws_handler, "127.0.0.1", 8080)' core/runtime.py; then
  echo "ℹ️  core/runtime.py 已是新版內容，略過。"
else
  echo "⚠️  core/runtime.py 內容跟預期不符，請人工確認，本腳本不處理這支檔案。"
fi

echo ""
echo "=== [4/4] 修改 static/login.html（API_BASE 改相對路徑），並檢查 change-password.html ==="
python3 << 'PYEOF'
import pathlib, sys

old = "const API_BASE = 'http://192.168.100.209:3000';"
new = "const API_BASE = '';"

path = pathlib.Path("static/login.html")
content = path.read_text(encoding="utf-8")

if old not in content:
    print("ℹ️  static/login.html 沒有找到舊字串，可能已經改過，略過。")
else:
    count = content.count(old)
    if count != 1:
        print(f"❌ static/login.html 比對次數異常（預期 1，實際 {count}），為安全起見未修改，請人工確認", file=sys.stderr)
        sys.exit(1)
    content = content.replace(old, new)
    path.write_text(content, encoding="utf-8")
    print("✅ static/login.html 修改完成")

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
            print(f"⚠️  static/change-password.html 比對次數異常（{cnt} 次），為安全起見未修改，請人工確認")
    else:
        print("ℹ️  static/change-password.html 沒有找到寫死的 API_BASE 字串，略過")
else:
    print("ℹ️  static/change-password.html 不存在，略過")
PYEOF

git add static/login.html
[ -f static/change-password.html ] && git add static/change-password.html
if ! git diff --cached --quiet; then
  git commit -m "fix: login.html/change-password.html 的 API_BASE 改相對路徑，配合 Nginx HTTPS 避免 mixed content"
  echo "已建立修正 commit。"
else
  echo "沒有變更需要 commit（可能已經改過）。"
fi

echo ""
echo "=== 完成，最近 3 筆 commit： ==="
git log --oneline -3

echo ""
echo "=========================================="
echo "驗證重點清單："
echo "1. git log --oneline -5 確認本次 commit 只包含 .bak 清理 + login.html 修改，沒有混進其他不相關檔案"
echo "2. 靜態檔案不用重啟服務，直接重新整理 https://192.168.100.209/login.html 測試登入"
echo "3. F12 Console 確認不再出現 Mixed Content 錯誤"
echo "4. 確認 core/runtime.py.bak、static/js/common.js.bak 已從 git 追蹤移除：git ls-files | grep '\\.bak'（應無輸出）"
echo "=========================================="
