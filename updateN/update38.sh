#!/bin/bash
set -e

echo "===== update38.sh 開始 ====="
echo "（編號說明：update37 曾提議但使用者決定跳過未建立，此次沿用 38，與既有慣例的編號缺口一致，不影響歸檔）"

# ---------- 0. 自動歸檔（固定寫法） ----------
ARCHIVE_DIR="updateN"
SELF="$(basename "$0")"

mkdir -p "$ARCHIVE_DIR"
for f in update*.sh; do
  [ "$f" = "$SELF" ] && continue
  [ -f "$f" ] || continue
  git mv "$f" "${ARCHIVE_DIR}/$f" 2>/dev/null || mv "$f" "${ARCHIVE_DIR}/$f"
done
# 2026-07-17 已知問題修正：只 add 明確路徑，不用 -A 全掃，避免夾帶其他正在編輯中的檔案
git add update*.sh "$ARCHIVE_DIR"/ 2>/dev/null || true
if ! git diff --cached --quiet; then
  git commit -m "chore: 歸檔已執行的 updateN.sh 腳本"
fi

# ---------- 1. 前置驗證 ----------
HTML_FILE="static/index.html"

if [ ! -f "$HTML_FILE" ]; then
  echo "❌ 找不到 $HTML_FILE，請確認在專案根目錄（/opt/fs-dashboard）執行" >&2
  exit 1
fi

if ! grep -q 'data-page="numbers"' "$HTML_FILE"; then
  echo "❌ 找不到號碼目錄的 nav-item（data-page=\"numbers\"），檔案內容可能與預期不符" >&2
  exit 1
fi

if grep -q '話務功能' "$HTML_FILE"; then
  echo "❌ 偵測到本次改動已套用過（找到「話務功能」標籤），為避免重複插入直接中止" >&2
  exit 1
fi

echo "✅ 前置驗證通過，開始寫入"

# ---------- 2. 精確編輯（python3 字串比對，逐一確認唯一命中） ----------
python3 << 'PYEOF'
path = "static/index.html"
with open(path, "r", encoding="utf-8") as f:
    content = f.read()

# --- 2-1. 搬移「號碼目錄」nav-item：從系統群組移到話務功能群組（音檔庫之後） ---
numbers_block = '''          <div class="nav-item" data-page="numbers" onclick="switchPage('numbers')">
            <span class="nav-icon">☎</span> 號碼目錄
          </div>
'''
count = content.count(numbers_block)
if count != 1:
    print(f"❌ 號碼目錄 nav-item 區塊出現 {count} 次，預期剛好 1 次，中止", flush=True)
    raise SystemExit(1)

# 從系統群組移除
content = content.replace(numbers_block, "", 1)

sounds_block = '''          <div class="nav-item" data-page="sounds" onclick="switchPage('sounds')">
            <span class="nav-icon">🔊</span> 音檔庫
          </div>
'''
count = content.count(sounds_block)
if count != 1:
    print(f"❌ 音檔庫 nav-item 區塊出現 {count} 次，預期剛好 1 次，中止", flush=True)
    raise SystemExit(1)

# 插入到話務功能群組（原「管理」群組）的音檔庫之後
content = content.replace(sounds_block, sounds_block + numbers_block, 1)

# --- 2-2. 分類標題改名 ---
manage_label = '<span class="nav-section-label">管理</span>'
count = content.count(manage_label)
if count != 1:
    print(f"❌ 「管理」分類標題出現 {count} 次，預期剛好 1 次，中止", flush=True)
    raise SystemExit(1)
content = content.replace(manage_label, '<span class="nav-section-label">話務功能</span>', 1)

system_label = '<span class="nav-section-label">系統</span>'
count = content.count(system_label)
if count != 1:
    print(f"❌ 「系統」分類標題出現 {count} 次，預期剛好 1 次，中止", flush=True)
    raise SystemExit(1)
content = content.replace(system_label, '<span class="nav-section-label">系統維運</span>', 1)

with open(path, "w", encoding="utf-8") as f:
    f.write(content)

print("✅ index.html 寫入完成")
PYEOF

# ---------- 3. 驗證寫入結果 ----------
if ! grep -q '話務功能' "$HTML_FILE"; then
  echo "❌ 寫入後找不到「話務功能」標籤，改名失敗" >&2
  exit 1
fi
if ! grep -q '系統維運' "$HTML_FILE"; then
  echo "❌ 寫入後找不到「系統維運」標籤，改名失敗" >&2
  exit 1
fi
if ! grep -q 'data-page="numbers"' "$HTML_FILE"; then
  echo "❌ 寫入後找不到號碼目錄的 nav-item，搬移過程可能誤刪" >&2
  exit 1
fi

# ---------- 4. Commit ----------
git add "$HTML_FILE"
if git diff --cached --quiet; then
  echo "⚠️ 沒有偵測到任何 staged 變更，略過 commit"
else
  git commit -m "refactor: 側邊欄分類重整（管理→話務功能、系統→系統維運，號碼目錄搬到話務功能）"
fi

echo ""
echo "===== 完成，最新 commit： ====="
git log --oneline -1

echo ""
echo "===== 驗證重點清單 ====="
echo "1. 瀏覽器強制重新整理（純前端檔案，不需 systemctl restart）"
echo "2. 側邊欄第二個分類標題應顯示「話務功能」，第三個應顯示「系統維運」"
echo "3. 「號碼目錄」應出現在「話務功能」分類底下（音檔庫之後），不再出現在「系統維運」分類"
echo "4. 「號碼目錄」點擊功能應正常（data-page 屬性未變，僅搬動 DOM 位置）"
echo "5. accordion 收合、active 色條、字級對比度應維持不變"
echo "===== update38.sh 結束 ====="
