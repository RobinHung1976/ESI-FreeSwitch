#!/usr/bin/env bash
#
# userpwreset.sh — 透過既有 REST API 列出使用者 / 重設密碼
#
# ⚠️ 重要限制(已核對 routers/users.py + core/auth_db.py 原始碼,務必先讀):
#   - 密碼在 auth_db.py 使用 pbkdf2_hmac 單向雜湊儲存,無法「顯示」現有密碼,
#     本腳本只能「重設」成新密碼,不能還原/查看舊密碼。
#   - GET /api/users 實際回傳格式是 {"rows": [...]},每筆欄位:
#     id / username / group_id / group_name / group_scope / owned_ext /
#     disabled / must_change_password / created_at / updated_at
#   - reset-password 的 force_change 參數:
#     * 若 server 尚未部署 update8.sh → 後端寫死 force_change=True,
#       這裡傳什麼都無效,重設後一律強制改密碼。
#     * 若已部署 update8.sh(見 core/auth_db.py 的 reset_password() 本來就支援
#       此參數,只是 API 層過去沒開放)→ 這裡選「否」就會真的生效。
#   - 若忘記所有 admin 帳號密碼、完全無法登入,本腳本無法使用
#     (它需要先登入拿 JWT),請改用 admin-recover.py(直接在伺服器上跑,
#     繞過 HTTP 驗證)。
#
# 需求: bash, curl, jq (sudo apt install jq 或 yum install jq)

set -euo pipefail

# ------------------------------------------------------------------
# 設定區
# ------------------------------------------------------------------
BASE_URL="${BASE_URL:-http://localhost:3000}"

# ------------------------------------------------------------------
# 工具函式
# ------------------------------------------------------------------
die() { echo "❌ $*" >&2; exit 1; }

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "找不到指令: $1,請先安裝"
}

require_cmd curl
require_cmd jq

# ------------------------------------------------------------------
# 1. 登入取得 JWT(需要 System Admin 帳號,才有 users 模組的 CUD 權限)
# ------------------------------------------------------------------
login() {
    local username password resp token

    read -r -p "管理員帳號: " username
    read -r -s -p "管理員密碼: " password
    echo

    resp=$(curl -sS -X POST "${BASE_URL}/api/auth/login" \
        -H "Content-Type: application/json" \
        -d "$(jq -nc --arg u "$username" --arg p "$password" '{username:$u,password:$p}')") \
        || die "無法連線至 ${BASE_URL},請確認服務是否啟動"

    if echo "$resp" | jq -e '.detail' >/dev/null 2>&1; then
        die "登入失敗: $(echo "$resp" | jq -r '.detail')"
    fi

    token=$(echo "$resp" | jq -r '.access_token // empty')
    [ -n "$token" ] || die "登入回應沒有 access_token,回應內容: $resp"

    echo "$token"
}

# ------------------------------------------------------------------
# 2. 列出所有使用者
# ------------------------------------------------------------------
list_users() {
    local token="$1"
    curl -sS -X GET "${BASE_URL}/api/users" \
        -H "Authorization: Bearer ${token}" \
        || die "取得使用者清單失敗"
}

# ------------------------------------------------------------------
# 3. 產生隨機密碼(可選,亦可讓使用者自行輸入)
# ------------------------------------------------------------------
generate_password() {
    # 16 字元隨機密碼,含大小寫+數字+符號
    openssl rand -base64 16 | tr -d '=+/' | cut -c1-16
}

# ------------------------------------------------------------------
# 4. 呼叫 reset-password
#    需 server 已部署 update8.sh,force_change 欄位才會真正生效;
#    若尚未部署,後端仍會忽略此欄位、一律強制改密碼(見檔頭說明)。
# ------------------------------------------------------------------
reset_password() {
    local token="$1" user_id="$2" new_password="$3" force_change="$4"
    local body resp

    body=$(jq -nc --arg pw "$new_password" --argjson force "$force_change" \
        '{new_password: $pw, force_change: $force}')

    resp=$(curl -sS -w '\n%{http_code}' -X POST \
        "${BASE_URL}/api/users/${user_id}/reset-password" \
        -H "Authorization: Bearer ${token}" \
        -H "Content-Type: application/json" \
        -d "$body")

    local http_code body_only
    http_code=$(echo "$resp" | tail -n1)
    body_only=$(echo "$resp" | sed '$d')

    if [ "$http_code" -ge 200 ] && [ "$http_code" -lt 300 ]; then
        echo "✅ 密碼重設成功"
        if [ "$force_change" = "false" ]; then
            echo "ℹ️  若 server 尚未部署 update8.sh,此欄位會被忽略,對方下次登入仍會被要求改密碼。"
        fi
    else
        die "重設密碼失敗 (HTTP ${http_code}): ${body_only}"
    fi
}

# ------------------------------------------------------------------
# 主流程
# ------------------------------------------------------------------
main() {
    echo "=== 使用者密碼重設工具 (${BASE_URL}) ==="
    echo

    local token
    token=$(login)

    echo
    echo "── 目前所有使用者 ──"
    local users_json rows_json
    users_json=$(list_users "$token")
    rows_json=$(echo "$users_json" | jq -c '.rows // .')

    echo "$rows_json" | jq -r '.[] |
        "ID: \(.id)  帳號: \(.username)  群組: \(.group_name)  " +
        "分機: \(.owned_ext // "-")  狀態: \(if .disabled then "停用" else "啟用" end)  " +
        "待改密碼: \(if .must_change_password then "是" else "否" end)"'

    echo
    read -r -p "請輸入要重設密碼的使用者 ID: " target_id

    # 確認該 ID 存在
    if ! echo "$rows_json" | jq -e --arg id "$target_id" '.[] | select((.id|tostring) == $id)' >/dev/null 2>&1; then
        die "找不到 ID 為 ${target_id} 的使用者"
    fi

    echo
    echo "新密碼設定方式:"
    echo "  1) 自動產生隨機密碼"
    echo "  2) 手動輸入"
    read -r -p "請選擇 [1/2]: " pw_choice

    local new_password
    case "$pw_choice" in
        1)
            new_password=$(generate_password)
            echo "產生的新密碼: ${new_password}  (請妥善記錄,畫面關閉後無法再次顯示)"
            ;;
        2)
            read -r -s -p "請輸入新密碼: " new_password
            echo
            read -r -s -p "請再次輸入確認: " new_password_confirm
            echo
            [ "$new_password" = "$new_password_confirm" ] || die "兩次輸入的密碼不一致"
            ;;
        *)
            die "無效選項"
            ;;
    esac

    echo
    read -r -p "重設後是否強制使用者下次登入必須改密碼? [y/N]: " force_choice
    local force_change="false"
    [[ "$force_choice" =~ ^[Yy]$ ]] && force_change="true"

    echo
    echo "── 即將執行 ──"
    echo "使用者 ID: ${target_id}"
    echo "強制改密碼: ${force_change}"
    read -r -p "確認執行嗎? [y/N]: " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || die "已取消"

    reset_password "$token" "$target_id" "$new_password" "$force_change"
}

main "$@"
