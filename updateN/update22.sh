#!/usr/bin/env bash
# update22.sh — 修復 custom_regex vs custom_regex 衝突檢查永遠偵測不到重疊的 bug
#
# 根本原因：generate_sample_numbers() 對 pattern_type=custom_regex 一律回傳空陣列
# （regex 無法窮舉樣本），find_conflicts() 靠雙方樣本互測對方 regex 來偵測重疊，
# 當兩邊都是 custom_regex 時雙方樣本都是空的，永遠測不出重疊——即使兩條規則
# 字串完全相同也偵測不到。此限制在原本程式碼就存在，這次 Context 功能測試時
# 用 custom_regex 才實際踩到。
#
# 修法：至少攔截「兩條 custom_regex 規則字串完全相同」這種最常見的重複情形；
# 語意相同但寫法不同的正規式仍無法自動偵測，屬取樣比對法的已知限制，
# 已加強提示文字請使用者搭配路由測試工具人工確認。
set -e

cd "$(dirname "$0")"

# ════════════════════════════════════════════════════════════════════════════
# 0. 自動歸檔
# ════════════════════════════════════════════════════════════════════════════
ARCHIVE_DIR="updateN"
SELF="$(basename "$0")"

mkdir -p "$ARCHIVE_DIR"
for f in update*.sh; do
  [ "$f" = "$SELF" ] && continue
  [ -f "$f" ] || continue
  git mv "$f" "${ARCHIVE_DIR}/$f" 2>/dev/null || mv "$f" "${ARCHIVE_DIR}/$f"
done
git add "${ARCHIVE_DIR}"
if ! git diff --cached --quiet; then
  git commit -m "chore: 歸檔已執行的 updateN.sh 腳本"
fi

# ════════════════════════════════════════════════════════════════════════════
# 1. 前置驗證
# ════════════════════════════════════════════════════════════════════════════
if [ ! -f routers/dialplan_routes.py ]; then
  echo "❌ 找不到 routers/dialplan_routes.py，請確認執行路徑" >&2
  exit 1
fi
if ! grep -q "2026-07-15：新增多 context 支援" routers/dialplan_routes.py; then
  echo "❌ routers/dialplan_routes.py 尚未包含 update19.sh 的改動（多 context 支援），請先確認 update19.sh 已成功套用" >&2
  exit 1
fi

cp routers/dialplan_routes.py routers/dialplan_routes.py.bak.$(date +%Y%m%d%H%M%S)

# ════════════════════════════════════════════════════════════════════════════
# 2. 精確字串比對（改動範圍小，2 處）
# ════════════════════════════════════════════════════════════════════════════
python3 << 'CONFLICT_FIX_PY_EOF'
import sys

path = "routers/dialplan_routes.py"
with open(path, "r", encoding="utf-8") as f:
    content = f.read()

edits = [
    ("find_conflicts() 補上 custom_regex 完全相同時強制判定衝突",
"""        hit = any(exist_re.match(s) for s in new_samples) or \\
              any(new_re.match(s) for s in exist_samples)
        if not hit:
            continue

        entry = {""",
"""        hit = any(exist_re.match(s) for s in new_samples) or \\
              any(new_re.match(s) for s in exist_samples)
        # 特例：雙方都是 custom_regex 時，兩邊樣本都是空陣列，上面的取樣比對永遠測不出重疊
        # （custom_regex 無法窮舉樣本）。至少攔截「規則字串完全相同」這種最常見的重複情形；
        # 語意相同但字串不同的 regex（例如 ^6\\d{3}$ 與 ^(6\\d{3})$）仍無法偵測，
        # 屬取樣比對法的已知限制，需搭配路由測試工具人工確認。
        if not hit and pattern_type == "custom_regex" and route.get("pattern_type") == "custom_regex":
            if pattern_value.strip() == (route.get("pattern_value") or "").strip():
                hit = True
        if not hit:
            continue

        entry = {"""),

    ("check_conflict() note 文字加強說明取樣比對的限制範圍",
'''        "note": "自訂正規式採取樣比對，無法窮舉所有號碼，建議搭配下方路由測試工具手動驗證。" if pattern_type == "custom_regex" else None,''',
'''        "note": "自訂正規式採取樣比對，僅能偵測規則字串完全相同的重複；若是語意相同但寫法不同的正規式"
                "（例如 ^6\\\\d{3}$ 與 ^(6\\\\d{3})$）無法自動偵測，請務必搭配下方路由測試工具手動驗證。"
                if pattern_type == "custom_regex" else None,'''),
]

failures = []
already_applied = []
to_apply = []

for label, old, new in edits:
    if new in content:
        already_applied.append(label)
        continue
    count = content.count(old)
    if count == 1:
        to_apply.append((label, old, new))
    else:
        failures.append((label, count))

if failures:
    print("❌ 以下項目比對失敗，未寫入任何檔案：", file=sys.stderr)
    for label, count in failures:
        print(f"   - {label}：找到 {count} 次（預期剛好 1 次）", file=sys.stderr)
    sys.exit(1)

for label, old, new in to_apply:
    content = content.replace(old, new, 1)

with open(path, "w", encoding="utf-8") as f:
    f.write(content)

print(f"✓ 套用 {len(to_apply)} 項，{len(already_applied)} 項已存在略過")
for label in already_applied:
    print(f"   (已存在，略過) {label}")
for label, _, _ in to_apply:
    print(f"   (已套用) {label}")
CONFLICT_FIX_PY_EOF

python3 -m py_compile routers/dialplan_routes.py
echo "✓ routers/dialplan_routes.py 語法檢查通過"

git add routers/dialplan_routes.py

# ════════════════════════════════════════════════════════════════════════════
# 3. Commit
# ════════════════════════════════════════════════════════════════════════════
if ! git diff --cached --quiet; then
  git commit -m "fix: custom_regex 對 custom_regex 完全重複時，衝突檢查改為強制判定衝突"
else
  echo "ℹ️  沒有變更需要 commit（可能已經套用過）"
fi

echo ""
echo "════════════════════════════════════════════════════"
git log --oneline -3
echo "════════════════════════════════════════════════════"
echo ""
echo "驗證重點清單："
echo "  1. systemctl restart fs-dashboard"
echo "  2. 清掉剛才測試留下的兩條重複的路由規則（其中一條，或兩條都刪），避免殘留重複規則影響後續 dialplan 比對"
echo "  3. 重新用相同 pattern（例如 ^(6\\d{3})\$）新增一條路由規則，成功後再用同一 context、同一 pattern 新增第二條，"
echo "     這次應該要被紅色警告攔下、無法儲存"
echo "  4. 換一個 context 用同樣 pattern 新增，確認顯示藍色跨 context 提示、不阻擋儲存（沿用先前驗證過的行為，這次不動）"
echo "  5. journalctl -u fs-dashboard -f 確認無異常"
