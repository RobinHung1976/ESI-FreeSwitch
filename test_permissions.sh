#!/bin/bash
BASE="http://192.168.100.209:3000"
PW="ChangeMe!2026"

login() {
  curl -s -X POST "$BASE/api/auth/login" \
    -H "Content-Type: application/json" \
    -d "{\"username\":\"$1\",\"password\":\"$PW\"}" \
    | python3 -c "import sys,json; print(json.load(sys.stdin).get('access_token',''))"
}

ADMIN=$(login admin)
VIEWER=$(login viewer)
TSA=$(login admin_tech_support)
TS=$(login tech_support)
USER1001=$(login user1001)

check() {
  local desc="$1" expect="$2"; shift 2
  local code=$(curl -s -o /dev/null -w "%{http_code}" "$@")
  local mark="OK"; [ "$code" != "$expect" ] && mark="FAIL"
  printf "%-6s [%s] 預期 %s 實際 %s | %s\n" "$mark" "$code" "$expect" "$code" "$desc"
}

echo "=== 過渡期已鎖定 ==="
check "無 token 存取 users" 401 "$BASE/api/users"

echo "=== System Admin ==="
check "讀 users" 200 -H "Authorization: Bearer $ADMIN" "$BASE/api/users"

echo "=== System Viewer（唯讀）==="
check "讀 extensions" 200 -H "Authorization: Bearer $VIEWER" "$BASE/api/extensions/list"
check "寫 extensions 應 403" 403 -X POST -H "Authorization: Bearer $VIEWER" -H "Content-Type: application/json" -d "{}" "$BASE/api/extensions"

echo "=== Technical Support Admin（系統模組 RCU 無 D）==="
check "讀 settings" 200 -H "Authorization: Bearer $TSA" "$BASE/api/settings"
check "刪 users/999 應 403" 403 -X DELETE -H "Authorization: Bearer $TSA" "$BASE/api/users/999"

echo "=== Technical Support（系統模組完全 none）==="
check "讀 settings 應 403" 403 -H "Authorization: Bearer $TS" "$BASE/api/settings"
check "讀 cdr 應 200" 200 -H "Authorization: Bearer $TS" "$BASE/api/cdr"
check "讀 sip-profile 應 200" 200 -H "Authorization: Bearer $TS" "$BASE/api/sip-profile"
check "讀 acl 應 403" 403 -H "Authorization: Bearer $TS" "$BASE/api/acl/trusted-sbc"

echo "=== User（own scope）==="
check "讀 cdr 應 200" 200 -H "Authorization: Bearer $USER1001" "$BASE/api/cdr"
check "讀 extensions 應 403（非 scopable）" 403 -H "Authorization: Bearer $USER1001" "$BASE/api/extensions/list"

echo "=== 壞 token ==="
check "壞 token 應 401" 401 -H "Authorization: Bearer garbage.token.here" "$BASE/api/cdr"