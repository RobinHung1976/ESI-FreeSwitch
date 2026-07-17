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

echo ""
echo "===== 目前 git log（重寫歷史前）====="
git log --oneline -6

# ── 安全檢查 1：確認要動的那個 commit 就是 update33.sh 混在一起的那筆 ──
TARGET_COMMIT="$(git rev-parse HEAD~1)"
TARGET_MSG="$(git log -1 --format=%s "$TARGET_COMMIT")"

if [ "$TARGET_MSG" != "chore: 歸檔已執行的 updateN.sh 腳本" ]; then
  echo "❌ HEAD~1（$TARGET_COMMIT）的訊息不是預期的 chore 歸檔訊息（實際：$TARGET_MSG），為安全起見中止，不做任何歷史重寫" >&2
  exit 1
fi

if ! git show --stat "$TARGET_COMMIT" | grep -q "static/index.html"; then
  echo "❌ HEAD~1（$TARGET_COMMIT）沒有動到 static/index.html，跟預期的混合 commit 不符，中止" >&2
  exit 1
fi

if ! git show --stat "$TARGET_COMMIT" | grep -q "update32.sh"; then
  echo "❌ HEAD~1（$TARGET_COMMIT）沒有 update32.sh 的歸檔紀錄，跟預期的混合 commit 不符，中止" >&2
  exit 1
fi

echo ""
echo "===== 確認要拆分的 commit（$TARGET_COMMIT）內容 ====="
git show --stat "$TARGET_COMMIT"

# ── 安全檢查 2：確認這兩筆 commit 都還沒 push 過 ─────────────────────
git fetch origin --quiet 2>/dev/null || echo "⚠ git fetch origin 失敗（可能離線），僅依賴本機既有的 origin/main 參照繼續檢查"

if git merge-base --is-ancestor "$TARGET_COMMIT" origin/main 2>/dev/null; then
  echo "❌ 要拆分的 commit（$TARGET_COMMIT）已經是 origin/main 的祖先（代表已經 push 過），為安全起見中止，不做任何歷史重寫" >&2
  echo "   如果你確定要重寫已推送的歷史，需要自行手動處理並在 push 時使用 --force，這裡不會自動執行" >&2
  exit 1
fi

if git merge-base --is-ancestor HEAD origin/main 2>/dev/null; then
  echo "❌ 目前 HEAD 已經是 origin/main 的祖先（代表已經 push 過），為安全起見中止" >&2
  exit 1
fi

echo "✓ 確認 $TARGET_COMMIT 與目前 HEAD 都尚未 push 到 origin/main，可以安全重寫"

# ── 執行拆分 ────────────────────────────────────────────────────────
# HEAD    = 剛才本腳本自己的 chore 歸檔 commit（archive update33.sh + 新增 update34.sh）
# HEAD~1  = 混在一起的 commit（archive update32.sh + 新增 update33.sh + index.html 的 fix）
# 目標：把兩者的「歸檔類」內容合併成一個 chore commit，
#       把 index.html 的改動獨立成一個 fix commit。
git reset --soft HEAD~2
git add -A
git reset -- static/index.html
git commit -m "chore: 歸檔已執行的 updateN.sh 腳本"

git add static/index.html
git commit -m "fix: 補上先前腳本因健檢邏輯誤判而漏掉的 commit（acl nav-item 改名為 SIPTrunk ACL 信任清單）"

echo ""
echo "===== 拆分後 git log ====="
git log --oneline -6

echo ""
echo "===== 確認工作目錄乾淨 ====="
git status --porcelain
