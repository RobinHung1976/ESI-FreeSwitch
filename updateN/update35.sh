#!/bin/bash
set -e

echo "===== update35.sh 開始 ====="

# ---------- 0. 自動歸檔（固定寫法） ----------
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

# ---------- 1. 前置驗證 ----------
CSS_FILE="static/css/style.css"

if [ ! -f "$CSS_FILE" ]; then
  echo "❌ 找不到 $CSS_FILE，請確認在專案根目錄（/opt/fs-dashboard）執行" >&2
  exit 1
fi

if ! grep -qF '.uc-subcall { opacity: 0.92; }' "$CSS_FILE"; then
  echo "❌ 未偵測到預期的檔案結尾特徵字串，style.css 內容可能與預期不符，請人工確認後再執行" >&2
  exit 1
fi

if grep -q "20260717 sidebar visual refinement" "$CSS_FILE"; then
  echo "❌ 偵測到本次改動已套用過（找到標記註解），為避免重複插入直接中止" >&2
  exit 1
fi

echo "✅ 前置驗證通過，開始寫入"

# ---------- 2. 精確插入新樣式（python3 字串比對，僅新增，不覆寫既有規則） ----------
python3 << 'PYEOF'
path = "static/css/style.css"
with open(path, "r", encoding="utf-8") as f:
    content = f.read()

anchor = "  .uc-subcall { opacity: 0.92; }"
count = content.count(anchor)
if count != 1:
    print(f"❌ anchor 字串出現 {count} 次，預期剛好 1 次，中止", flush=True)
    raise SystemExit(1)

addition = anchor + """

  /* == 20260717 sidebar visual refinement == */
  .nav-section-label {
    font-size: 11px;
    letter-spacing: 1px;
    text-transform: uppercase;
  }
  .nav-group + .nav-group {
    border-top: 1px solid rgba(2,119,189,0.12);
    margin-top: 6px;
    padding-top: 6px;
  }
  .nav-icon {
    width: 20px;
    display: inline-flex;
    justify-content: center;
    flex-shrink: 0;
  }
"""

content = content.replace(anchor, addition, 1)

with open(path, "w", encoding="utf-8") as f:
    f.write(content)

print("✅ style.css 寫入完成")
PYEOF

# ---------- 3. 驗證寫入結果 ----------
if ! grep -q "20260717 sidebar visual refinement" "$CSS_FILE"; then
  echo "❌ 寫入後找不到標記註解，插入失敗" >&2
  exit 1
fi

# ---------- 4. Commit ----------
git add "$CSS_FILE"
if git diff --cached --quiet; then
  echo "⚠️ 沒有偵測到任何 staged 變更，略過 commit"
else
  git commit -m "style: 側邊欄視覺優化（分類標題縮小、群組分隔線、icon 對齊統一）"
fi

echo ""
echo "===== 完成，最新 commit： ====="
git log --oneline -1

echo ""
echo "===== 驗證重點清單 ====="
echo "1. 瀏覽器強制重新整理（純前端 CSS，不需 systemctl restart）"
echo "2. 側邊欄「監控/管理/系統」標題應變小、變成大寫字距拉開"
echo "3. 三個分類之間應出現一條淡色分隔線"
echo "4. 各 nav-item 前方 icon（emoji 與符號混用）應該左右對齊整齊，不再參差不齊"
echo "5. 原本的 active 左側藍色色條、accordion 收合功能應維持不變"
echo "===== update35.sh 結束 ====="
