#!/bin/bash
set -e

echo "===== update36.sh 開始 ====="

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

if ! grep -q "20260717 sidebar visual refinement" "$CSS_FILE"; then
  echo "❌ 找不到 update35.sh 留下的標記，請先確認 update35.sh 是否已成功套用" >&2
  exit 1
fi

if grep -q "20260717 sidebar contrast adjustment v2" "$CSS_FILE"; then
  echo "❌ 偵測到本次改動已套用過（找到 v2 標記註解），為避免重複插入直接中止" >&2
  exit 1
fi

echo "✅ 前置驗證通過，開始寫入"

# ---------- 2. 精確插入覆蓋樣式（python3 字串比對，僅新增，疊在 update35 的規則之後） ----------
python3 << 'PYEOF'
path = "static/css/style.css"
with open(path, "r", encoding="utf-8") as f:
    content = f.read()

anchor = """  .nav-icon {
    width: 20px;
    display: inline-flex;
    justify-content: center;
    flex-shrink: 0;
  }"""

count = content.count(anchor)
if count != 1:
    print(f"❌ anchor 字串出現 {count} 次，預期剛好 1 次，中止", flush=True)
    raise SystemExit(1)

addition = anchor + """

  /* == 20260717 sidebar contrast adjustment v2 == */
  .nav-section-label {
    font-size: 13px;
    color: #012a44;
  }
  .nav-item {
    font-size: 13px;
    color: #4a6a8a;
  }
"""

content = content.replace(anchor, addition, 1)

with open(path, "w", encoding="utf-8") as f:
    f.write(content)

print("✅ style.css 寫入完成")
PYEOF

# ---------- 3. 驗證寫入結果 ----------
if ! grep -q "20260717 sidebar contrast adjustment v2" "$CSS_FILE"; then
  echo "❌ 寫入後找不到 v2 標記註解，插入失敗" >&2
  exit 1
fi

# ---------- 4. Commit ----------
git add "$CSS_FILE"
if git diff --cached --quiet; then
  echo "⚠️ 沒有偵測到任何 staged 變更，略過 commit"
else
  git commit -m "style: 側邊欄標題與項目字級對比度調整（v2，標題13px深色/項目13px淺色）"
fi

echo ""
echo "===== 完成，最新 commit： ====="
git log --oneline -1

echo ""
echo "===== 驗證重點清單 ====="
echo "1. 瀏覽器強制重新整理（純前端 CSS，不需 systemctl restart）"
echo "2. 「監控/管理/系統」大標題應變回可讀大小（13px），顏色明顯偏深"
echo "3. 底下各 nav-item 文字應變小（13px），顏色偏淺藍灰，與大標題形成明顯對比"
echo "4. hover/active 狀態應仍是原本的鮮豔藍色，不受本次調整影響"
echo "===== update36.sh 結束 ====="
