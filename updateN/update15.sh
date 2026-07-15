#!/bin/bash
# update15.sh — 把 reorg/ 整個文件目錄首次納入 git 版控
#   稽核發現 reorg/ 底下除了 update14.sh 新增的 3 個檔案外，
#   archive/、features/、ops/、reference/ 整個資料夾、以及 changelog-details/
#   裡其餘所有檔案，從頭到尾都是 untracked，且沒有被 .gitignore 排除。
#
# 使用方式：
#   cd /opt/fs-dashboard
#   chmod +x update15.sh
#   ./update15.sh

set -e
cd "$(dirname "$0")"

DOCS_DIR="reorg"

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
echo "=== [2/3] 前置驗證：確認 reorg/ 底下確實還有 untracked 檔案 ==="
UNTRACKED_COUNT=$(git status --porcelain=v1 -- "${DOCS_DIR}/" | grep -c '^??' || true)
if [ "$UNTRACKED_COUNT" -eq 0 ]; then
  echo "❌ reorg/ 底下沒有偵測到 untracked 檔案，可能已經處理過了，中止" >&2
  git status --porcelain=v1 -- "${DOCS_DIR}/"
  exit 1
fi
echo "偵測到 ${UNTRACKED_COUNT} 筆 untracked 項目，前置驗證通過。"

echo ""
echo "=== [3/3] 把 reorg/ 整個目錄加入 git 版控 ==="
git add "${DOCS_DIR}/"

echo ""
echo "本次將被新增進 git 的檔案清單："
git diff --cached --name-status -- "${DOCS_DIR}/"

git commit -m "chore: 把 reorg/ 整個文件目錄首次納入 git 版控（archive/、features/、ops/、reference/、剩餘 changelog-details/）"

echo ""
echo "=== 完成，最新 commit： ==="
git log --oneline -1

echo ""
echo "=========================================="
echo "驗證重點清單："
echo "1. git status --porcelain -- reorg/ 應該不再有任何 ?? 輸出（全部已追蹤）"
echo "2. git ls-files reorg/ | wc -l 應該等於 find reorg -type f | wc -l"
echo "3. 確認沒問題後：git push"
echo "=========================================="
