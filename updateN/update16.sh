#!/bin/bash
# update16.sh — 新增一份獨立的 changelog-details 文件，記錄「reorg/ 文件目錄
# 從未被 git 追蹤、後續全面稽核並補進版控」這件事本身（跟 20260715-nginx-https-feature.md
# 記錄的 Nginx+HTTPS 部署過程是兩件不同的事，分開記錄）。
#
# 使用方式：
#   cd /opt/fs-dashboard
#   chmod +x update16.sh
#   ./update16.sh

set -e
cd "$(dirname "$0")"

DOCS_DIR="reorg"
NEW_DOC="${DOCS_DIR}/changelog-details/20260715-reorg-git-tracking-fix.md"

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
if [ -f "$NEW_DOC" ]; then
  echo "❌ ${NEW_DOC} 已存在，可能已執行過本腳本，中止" >&2
  exit 1
fi
if [ ! -f "${DOCS_DIR}/CHANGELOG.md" ]; then
  echo "❌ 找不到 ${DOCS_DIR}/CHANGELOG.md，中止" >&2
  exit 1
fi
if ! grep -q "Nginx reverse proxy + HTTPS 上線" "${DOCS_DIR}/CHANGELOG.md"; then
  echo "❌ CHANGELOG.md 找不到預期的錨點條目（20260715-nginx-https-feature 那筆），中止" >&2
  exit 1
fi
echo "前置驗證通過。"

echo ""
echo "=== [3/3] 建立文件、更新 CHANGELOG.md ==="
cat > "$NEW_DOC" << 'MDEOF'
# reorg/ 文件目錄補進 git 版控（2026-07-15）

## 現象

在收尾「Nginx reverse proxy + HTTPS」項目、要把 `PROJECT-OVERVIEW.md` checklist 打勾時，
第一次執行 `update13.sh` 直接失敗：

```
grep: PROJECT-OVERVIEW.md: No such file or directory
```

`find` 後發現 `PROJECT-OVERVIEW.md`、`CHANGELOG.md`、`changelog-details/` 實際位於
`/opt/fs-dashboard/reorg/` 底下，而不是 repo 根目錄。

## 根本原因

進一步用 `git ls-files reorg/` 檢查發現**完全沒有輸出**——`reorg/` 這整個資料夾
（`archive/`、`changelog-details/`、`features/`、`ops/`、`reference/`，以及
`PROJECT-OVERVIEW.md`、`CHANGELOG.md` 本身）從頭到尾都不在 git 版控範圍內。

用 `git status --porcelain=v1 --ignored -- reorg/` 交叉確認，所有項目都顯示 `??`
（untracked），沒有任何一項是被 `.gitignore` 刻意排除的 `!!`——代表這不是設計上
特意讓文件目錄游離在 repo 之外，單純是建立 `reorg/` 資料夾當時忘了 `git add`，
之後也沒有人發現。

## 修復

分兩階段處理：

1. **`update14.sh`**：先只針對「Nginx reverse proxy + HTTPS」相關的三個檔案
   （`reorg/PROJECT-OVERVIEW.md`、`reorg/CHANGELOG.md`、新建的
   `reorg/changelog-details/20260715-nginx-https-feature.md`）修正路徑並 `git add`，
   讓當下要收尾的項目可以先完整完成。

2. **`update15.sh`**：完成上一項後，另外全面稽核一次，用
   `find /opt/fs-dashboard/reorg -type f` 對照 `git ls-files reorg/`，
   確認 `reorg/` 底下其餘 **96 個檔案**（`archive/` 37 個歷史文件、
   `features/` 18 個功能文件、`ops/` 4 個維運文件、`reference/` 1 個參考索引、
   `changelog-details/` 剩餘 36 個）全數未被追蹤，一次性 `git add reorg/` 補齊。

### 執行過程的小插曲

`update15.sh` 執行到 `git diff --cached --name-status -- reorg/` 這行時，因為輸出
筆數多（96 筆），觸發了系統預設的 pager（`less`），把腳本卡在等待使用者按 `q`
離開分頁檢視的狀態，導致同一支腳本裡後面的 `git commit` 沒有被執行到——`git add`
已經確實把檔案加進索引，只是還沒 commit。透過 `git log --oneline` 確認 commit
沒有產生後，手動補執行一次 `git commit` 即完成，沒有任何檔案遺失。

**教訓**：往後 `updateN.sh` 裡如果有 `git diff`/`git log` 這類輸出筆數可能很多的
指令，應該加上 `--no-pager`（例如 `git --no-pager diff --cached --name-status`），
避免腳本在非互動情境下被 pager 卡住。

## 驗證方式

```bash
git status --porcelain -- reorg/     # 應無任何輸出（全部已追蹤、無未提交變更）
git ls-files reorg/ | wc -l          # 應等於 find reorg -type f | wc -l
```

**測試結果**：`update14.sh`、`update15.sh` 皆已於 production server（`debian-freeswitch`）
實際執行並 `git push` 成功（`66d38d8..bac68bf..c25f47d`），`git status --porcelain -- reorg/`
確認乾淨無殘留 untracked 項目。
MDEOF

echo "✅ ${NEW_DOC} 建立完成"

python3 << PYEOF
import pathlib, sys

changelog_path = pathlib.Path("${DOCS_DIR}/CHANGELOG.md")
content = changelog_path.read_text(encoding="utf-8")

new_entry = "- 07-15 fix: reorg/ 文件目錄（PROJECT-OVERVIEW.md/CHANGELOG.md/changelog-details/archive/features/ops/reference）稽核發現從未被 git 追蹤，全數補進版控 → [詳情](changelog-details/20260715-reorg-git-tracking-fix.md)"

anchor = "## 2026-07"
count = content.count(anchor)
if count != 1:
    sys.exit(f"❌ CHANGELOG.md 錨點「## 2026-07」比對次數異常（預期 1，實際 {count}），中止且不寫入")

content = content.replace(anchor, anchor + "\n\n" + new_entry, 1)
changelog_path.write_text(content, encoding="utf-8")
print("✅ CHANGELOG.md 新增條目完成")
PYEOF

git add "$NEW_DOC" "${DOCS_DIR}/CHANGELOG.md"
if ! git diff --cached --quiet; then
  git commit -m "docs: 新增 20260715-reorg-git-tracking-fix.md，記錄 reorg/ 文件目錄補進版控的過程"
  echo "已建立 commit。"
else
  echo "沒有變更需要 commit。"
fi

echo ""
echo "=== 完成，最新 commit： ==="
git --no-pager log --oneline -1

echo ""
echo "=========================================="
echo "驗證重點清單："
echo "1. cat ${NEW_DOC} 檢查內容正確"
echo "2. grep -n 'reorg-git-tracking-fix' ${DOCS_DIR}/CHANGELOG.md 確認索引已加入"
echo "3. 確認沒問題後：git push"
echo "=========================================="
