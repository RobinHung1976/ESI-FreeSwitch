#!/usr/bin/env bash
#
# update9.sh — 修正 update8.sh 誤建的 update8/ 資料夾,統一歸檔進既有的 updateN/
#
# 背景：
#   ops-github-workflow.md 記載的「自動歸檔固定寫法」用 update${CURRENT} 當資料夾名稱，
#   等於每次執行都會用「當次腳本編號」建一個新資料夾。但這個專案實際上一直是把所有
#   執行過的 updateM.sh 統一歸檔進同一個固定資料夾 updateN/，兩者不一致。
#   update8.sh 執行時依文件字面寫法建立了 update8/ 資料夾（裡面只有 update7.sh），
#   這支腳本負責把它併回 updateN/，並把自己（update9.sh）之後也歸檔進同一個地方。

set -euo pipefail

cd "$(dirname "$0")"

SELF="$(basename "$0")"
ARCHIVE_DIR="updateN"

echo "=== update9.sh 開始 ==="

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "❌ 目前目錄不是 git repo，請確認是否在專案根目錄 (/opt/fs-dashboard) 執行。" >&2
    exit 1
fi

# ------------------------------------------------------------------
# 1. 前置驗證 + 冪等檢查
# ------------------------------------------------------------------
if [ ! -d "update8" ] && [ -d "$ARCHIVE_DIR" ]; then
    echo "ℹ️  沒有發現需要修正的 update8/ 資料夾（可能已經修正過），跳過搬移步驟。"
    SKIP_MOVE=1
elif [ -d "update8" ]; then
    SKIP_MOVE=0
else
    echo "❌ 找不到 update8/ 也找不到 ${ARCHIVE_DIR}/，檔案結構與預期不符，中止。" >&2
    exit 1
fi

# ------------------------------------------------------------------
# 2. 把 update8/ 底下的檔案併回 updateN/，刪除空資料夾
# ------------------------------------------------------------------
if [ "$SKIP_MOVE" -eq 0 ]; then
    mkdir -p "$ARCHIVE_DIR"
    for f in update8/*; do
        [ -e "$f" ] || continue
        basefile="$(basename "$f")"
        if [ -e "${ARCHIVE_DIR}/${basefile}" ]; then
            echo "⚠️  ${ARCHIVE_DIR}/${basefile} 已存在，跳過 ${f}（可能是先前已手動處理過）" >&2
        else
            git mv "$f" "${ARCHIVE_DIR}/${basefile}" 2>/dev/null || mv "$f" "${ARCHIVE_DIR}/${basefile}"
            echo "✅ 已搬移 ${f} → ${ARCHIVE_DIR}/${basefile}"
        fi
    done
    rmdir update8 2>/dev/null || git rm -r --cached update8 >/dev/null 2>&1 || true
    echo "✅ update8/ 資料夾已清空並移除"
fi

# ------------------------------------------------------------------
# 3. 標準歸檔步驟(改用固定資料夾名稱 updateN，不再用當次編號建資料夾)
# ------------------------------------------------------------------
mkdir -p "$ARCHIVE_DIR"
for f in update*.sh; do
    [ "$f" = "$SELF" ] && continue
    [ -f "$f" ] || continue
    git mv "$f" "${ARCHIVE_DIR}/$f" 2>/dev/null || mv "$f" "${ARCHIVE_DIR}/$f"
done

git add -A
if ! git diff --cached --quiet; then
    git commit -m "chore: 修正歸檔資料夾命名錯誤，統一使用 updateN/ 歸檔已執行的 updateM.sh"
    echo "✅ 已 commit"
else
    echo "ℹ️  沒有需要 commit 的變更"
fi

echo
echo "=== 最新 commit ==="
git log --oneline -1

echo
echo "=== 驗證重點清單 ==="
cat << 'CHECKLIST'
1. ls -la
   → 應只看到 updateN/ 資料夾，不應再有 update8/ 或其他 updateM/ 資料夾
2. ls updateN/
   → 應包含 update2.sh ~ update8.sh 全部歷史腳本，且每個檔名只出現一次
3. git status --porcelain
   → 應為乾淨（無殘留未提交變更）
4. git log --oneline -3
   → 確認本次 commit 訊息正確
5. 確認 update9.sh 本身也已經在同一次 commit 中被搬進 updateN/
   （腳本執行時的當下腳本檔案 update9.sh 會在下一支腳本執行時才被歸檔，
    這是正常行為，跟過去 update2.sh~update8.sh 的模式一致）
CHECKLIST
