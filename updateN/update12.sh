#!/bin/bash
# update12.sh — 把 nginx reverse proxy 設定檔納入 git 版控
#   複製進 repo 的 deploy/nginx/fs-dashboard.conf，
#   系統路徑 /etc/nginx/sites-available/fs-dashboard.conf 改成 symlink 指回 repo。
#
# 使用方式：
#   cd /opt/fs-dashboard
#   chmod +x update12.sh
#   ./update12.sh
#
# 注意：這支腳本會修改 /etc/nginx/sites-available/ 底下的檔案（系統路徑，repo 之外），
#      需要 root 權限，且會重新驗證 nginx 語法，但不會自動 reload/restart nginx。

set -e
cd "$(dirname "$0")"

NGINX_LIVE="/etc/nginx/sites-available/fs-dashboard.conf"
REPO_COPY="deploy/nginx/fs-dashboard.conf"
DEPLOY_PATH="/opt/fs-dashboard/${REPO_COPY}"

echo "=== [1/4] 自動歸檔：把舊的 updateN.sh 搬進固定資料夾 updateN/ ==="
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
echo "=== [2/4] 前置驗證 ==="
if [ ! -e "$NGINX_LIVE" ]; then
  echo "❌ 找不到 $NGINX_LIVE，中止" >&2
  exit 1
fi
if [ -L "$NGINX_LIVE" ]; then
  echo "ℹ️  $NGINX_LIVE 已經是 symlink，可能已執行過本腳本，中止避免重複處理：" >&2
  ls -la "$NGINX_LIVE"
  exit 1
fi

echo ""
echo "=== [3/4] 複製進 repo，原路徑改成 symlink 指回 repo ==="
mkdir -p "$(dirname "$REPO_COPY")"
cp "$NGINX_LIVE" "$REPO_COPY"
rm -f "$NGINX_LIVE"
ln -s "$DEPLOY_PATH" "$NGINX_LIVE"

echo "symlink 確認："
ls -la "$NGINX_LIVE"

echo ""
echo "nginx 語法驗證（symlink 後內容應完全一致）："
nginx -t

echo ""
echo "=== [4/4] git commit ==="
git add "$REPO_COPY"
git commit -m "chore: 把 nginx reverse proxy 設定檔納入 git 版控（deploy/nginx/fs-dashboard.conf），系統路徑改用 symlink"

echo ""
echo "=== 完成，最近 3 筆 commit： ==="
git log --oneline -3

echo ""
echo "=========================================="
echo "驗證重點清單："
echo "1. nginx -t 顯示 syntax ok（上面已測過一次）"
echo "2. ls -la /etc/nginx/sites-available/fs-dashboard.conf 應顯示 -> $DEPLOY_PATH"
echo "3. 之後要改 nginx 設定：改 repo 裡的 $REPO_COPY，然後 nginx -t && systemctl reload nginx 即可生效"
echo "4. curl -k -s -o /dev/null -w '%{http_code}\n' https://192.168.100.209/ 應仍回應 200"
echo "=========================================="
