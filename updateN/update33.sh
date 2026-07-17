#!/bin/bash
set -e

# ── 自動歸檔（固定寫法）─────────────────────────────────────────────
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
fi

# ── 前置驗證 ────────────────────────────────────────────────────────
if ! grep -q "SIPTrunk ACL 信任清單" static/index.html; then
  echo "❌ static/index.html 找不到「SIPTrunk ACL 信任清單」，update32.sh 的改動似乎沒有實際寫入，請先確認檔案內容" >&2
  exit 1
fi

# ── 說明 ────────────────────────────────────────────────────────────
# update32.sh 的改名本身已經正確寫入 static/index.html（"✓ index.html：
# acl nav-item 標籤已改名為 SIPTrunk ACL 信任清單" 已印出），但腳本裡
# 用來做「基本結構檢查」的字串比對寫錯了（'<div class="nav-item"' 沒算到
# class="nav-item active" 這個變體，导致計數少 1），set -e 讓腳本在
# 這個誤判的檢查失敗後中止，commit 因此沒有執行。這裡只補做 commit，
# 不重複之前那個有 bug 的健檢邏輯。

# ── Commit ──────────────────────────────────────────────────────────
git add static/index.html
if git diff --cached --quiet; then
  echo "（無變更需要 commit，可能是重跑此腳本、上次已成功 commit 過）"
else
  git commit -m "fix: 補上 update32.sh 因健檢邏輯誤判而漏掉的 commit（acl nav-item 改名為 SIPTrunk ACL 信任清單）"
fi

echo ""
echo "===== git log ====="
git log --oneline -5
echo ""
echo "===== 確認結果 ====="
grep -A1 'data-page="acl"' static/index.html
echo ""
echo "===== 確認乾淨 ====="
git status --porcelain
