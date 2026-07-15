#!/bin/bash
# update13.sh — PROJECT-OVERVIEW.md：
#   1) checklist 把「Nginx reverse proxy + HTTPS」從 [ ] 改成 [x]，補上完成日期
#   2) 「已知待處理事項」第 4 點同步更新為已完成狀態
#
# 使用方式：
#   cd /opt/fs-dashboard
#   chmod +x update13.sh
#   ./update13.sh

set -e
cd "$(dirname "$0")"

echo "=== [1/3] 自動歸檔：把舊的 updateN.sh 搬進固定資料夾 updateN/ ==="
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
echo "=== [2/3] 前置驗證 ==="
if ! grep -q -- "- \[ \] Nginx reverse proxy + HTTPS" PROJECT-OVERVIEW.md; then
  echo "❌ 找不到預期的待辦字串「- [ ] Nginx reverse proxy + HTTPS」，可能已經打勾過或內容跟預期不符，中止" >&2
  exit 1
fi
if ! grep -q "4\. \*\*Nginx reverse proxy + HTTPS\*\*：尚未導入。" PROJECT-OVERVIEW.md; then
  echo "❌ 找不到預期的已知待處理事項第 4 點，中止" >&2
  exit 1
fi
echo "前置驗證通過。"

echo ""
echo "=== [3/3] 修改 PROJECT-OVERVIEW.md ==="
python3 << 'PYEOF'
import pathlib, sys

path = pathlib.Path("PROJECT-OVERVIEW.md")
content = path.read_text(encoding="utf-8")

# ── checklist 打勾 ──
old1 = "- [ ] Nginx reverse proxy + HTTPS"
new1 = "- [x] Nginx reverse proxy + HTTPS（已完成，2026-07-15，見 `changelog-details/20260715-nginx-https-feature.md`）"
count1 = content.count(old1)
if count1 != 1:
    sys.exit(f"❌ checklist 字串比對次數異常（預期 1，實際 {count1}），中止且不寫入")
content = content.replace(old1, new1)

# ── 已知待處理事項第 4 點更新 ──
old2 = "4. **Nginx reverse proxy + HTTPS**：尚未導入。"
new2 = "4. ~~**Nginx reverse proxy + HTTPS**：尚未導入。~~ → 已於 2026-07-15 完成，自簽憑證 + WebSocket 統一走 `/ws/` 路徑，nginx 設定檔已納入 git 版控（`deploy/nginx/fs-dashboard.conf`）。"
count2 = content.count(old2)
if count2 != 1:
    sys.exit(f"❌ 已知待處理事項字串比對次數異常（預期 1，實際 {count2}），中止且不寫入")
content = content.replace(old2, new2)

path.write_text(content, encoding="utf-8")
print("✅ PROJECT-OVERVIEW.md 修改完成")
PYEOF

git add PROJECT-OVERVIEW.md
if ! git diff --cached --quiet; then
  git commit -m "docs: PROJECT-OVERVIEW.md 把 Nginx reverse proxy + HTTPS 標記為已完成"
  echo "已建立 commit。"
else
  echo "沒有變更需要 commit。"
fi

echo ""
echo "=== 完成，最新 commit： ==="
git log --oneline -1

echo ""
echo "=========================================="
echo "驗證重點清單："
echo "1. grep -n 'Nginx reverse proxy' PROJECT-OVERVIEW.md 確認兩處都已更新"
echo "2. git diff HEAD~1 HEAD 確認只改了 PROJECT-OVERVIEW.md 這兩處"
echo "=========================================="
