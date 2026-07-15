#!/usr/bin/env bash
#
# update8.sh — 開放 reset-password API 的 force_change 參數
#
# 背景：
#   core/auth_db.py 的 reset_password(user_id, new_password, force_change=True)
#   本來就支援 force_change 參數，但 routers/users.py 的 ResetPasswordRequest
#   沒有開放這個欄位，呼叫時寫死 force_change=True，導致「重設密碼後是否強制
#   下次登入改密碼」目前無法選擇。本次只改 routers/users.py，不動 auth_db.py。
#
# 影響檔案：routers/users.py
# 執行位置：/opt/fs-dashboard（專案根目錄）
# 執行後需要：systemctl restart fs-dashboard（Pydantic 欄位變更必須重啟才生效）

set -euo pipefail

cd "$(dirname "$0")"

CURRENT=8
TARGET_FILE="routers/users.py"

echo "=== update8.sh 開始 ==="

# ------------------------------------------------------------------
# 0. 基本檢查
# ------------------------------------------------------------------
if [ ! -f "$TARGET_FILE" ]; then
    echo "❌ 找不到 ${TARGET_FILE}，請確認是否在專案根目錄 (/opt/fs-dashboard) 執行。" >&2
    exit 1
fi

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "❌ 目前目錄不是 git repo，請確認是否已依 ops-github-workflow.md 完成版控設定。" >&2
    exit 1
fi

# ------------------------------------------------------------------
# 1. 自動歸檔：把非本次編號的 updateM.sh 搬進 update8/
# ------------------------------------------------------------------
mkdir -p "update${CURRENT}"
for f in update*.sh; do
    [ "$f" = "update${CURRENT}.sh" ] && continue
    [ -f "$f" ] || continue
    git mv "$f" "update${CURRENT}/$f" 2>/dev/null || mv "$f" "update${CURRENT}/$f"
done
git add -A
if ! git diff --cached --quiet; then
    git commit -m "chore: 歸檔已執行的 updateN.sh 腳本"
    echo "✅ 已歸檔舊版 updateN.sh"
else
    echo "ℹ️  沒有需要歸檔的舊腳本"
fi

# ------------------------------------------------------------------
# 2. 前置驗證（含冪等檢查）
# ------------------------------------------------------------------
if grep -q "force_change: bool" "$TARGET_FILE"; then
    echo "ℹ️  ${TARGET_FILE} 已經套用過本次改動（偵測到 force_change 欄位），跳過功能修改步驟。"
    SKIP_PATCH=1
else
    SKIP_PATCH=0
    if ! grep -q 'class ResetPasswordRequest(BaseModel):' "$TARGET_FILE"; then
        echo "❌ 找不到 ResetPasswordRequest 類別定義，檔案內容與預期不符，中止（未寫入任何檔案）。" >&2
        exit 1
    fi
    if ! grep -q 'auth_db.reset_password(user_id, body.new_password, force_change=True)' "$TARGET_FILE"; then
        echo "❌ 找不到預期的 reset_password 呼叫字串，檔案內容與預期不符，中止（未寫入任何檔案）。" >&2
        echo "   請確認 routers/users.py 是否已被其他方式修改過。" >&2
        exit 1
    fi
    echo "✅ 前置驗證通過"
fi

# ------------------------------------------------------------------
# 3. 精確字串取代（僅 2 處，python3 heredoc，比對次數需剛好 1 次才動手）
# ------------------------------------------------------------------
if [ "$SKIP_PATCH" -eq 0 ]; then
    python3 << 'PYEOF'
import sys

path = "routers/users.py"
with open(path, "r", encoding="utf-8") as f:
    content = f.read()

# --- 修改點 1：ResetPasswordRequest 新增 force_change 欄位 ---
old1 = (
    "class ResetPasswordRequest(BaseModel):\n"
    "    new_password: str = Field(min_length=8)\n"
)
new1 = (
    "class ResetPasswordRequest(BaseModel):\n"
    "    new_password: str = Field(min_length=8)\n"
    "    force_change: bool = True  # 是否強制下次登入改密碼（預設 True，維持原行為）\n"
)

count1 = content.count(old1)
if count1 != 1:
    print(f"❌ 修改點 1 比對次數為 {count1}，預期為 1，中止且未寫入任何檔案", file=sys.stderr)
    sys.exit(1)

# --- 修改點 2：呼叫端改用 body.force_change ---
old2 = "auth_db.reset_password(user_id, body.new_password, force_change=True)"
new2 = "auth_db.reset_password(user_id, body.new_password, force_change=body.force_change)"

count2 = content.count(old2)
if count2 != 1:
    print(f"❌ 修改點 2 比對次數為 {count2}，預期為 1，中止且未寫入任何檔案", file=sys.stderr)
    sys.exit(1)

content = content.replace(old1, new1).replace(old2, new2)

with open(path, "w", encoding="utf-8") as f:
    f.write(content)

print("✅ routers/users.py 修改完成")
PYEOF

    # ------------------------------------------------------------------
    # 4. 語法檢查
    # ------------------------------------------------------------------
    python3 -m py_compile "$TARGET_FILE"
    echo "✅ 語法檢查通過"

    # ------------------------------------------------------------------
    # 5. commit
    # ------------------------------------------------------------------
    git add "$TARGET_FILE"
    git commit -m "feat: reset-password API 開放 force_change 可選參數（預設 True，向下相容）"
    echo "✅ 已 commit"
else
    echo "ℹ️  跳過修改與 commit（已套用過）"
fi

echo
echo "=== 最新 commit ==="
git log --oneline -1

echo
echo "=== 驗證重點清單 ==="
cat << 'CHECKLIST'
1. git status --porcelain              → 應為乾淨（無殘留未提交變更）
2. grep -n "force_change" routers/users.py
   → 應同時看到 ResetPasswordRequest 的欄位定義與呼叫端的 body.force_change
3. python3 -m py_compile routers/users.py  → 無錯誤
4. systemctl restart fs-dashboard      → Pydantic 欄位變更必須重啟才生效
5. journalctl -u fs-dashboard -n 30 --no-pager
   → 確認 Application startup complete，無 500/ImportError
6. 實測（需要一組 System Admin token）：
   curl -X POST http://localhost:3000/api/users/<某測試帳號ID>/reset-password \
     -H "Authorization: Bearer <token>" \
     -H "Content-Type: application/json" \
     -d '{"new_password":"TestPass1234","force_change":false}'
   → 回應 200 {"ok":true}
   → 用 sqlite3 檢查該帳號 must_change_password 欄位應為 0：
     sqlite3 /opt/fs-dashboard/data/auth.db \
       "SELECT username, must_change_password FROM users WHERE id=<ID>;"
7. 再測一次 force_change:true（或省略此欄位，測試預設值），
   確認 must_change_password 變回 1，向下相容沒有被破壞
CHECKLIST
