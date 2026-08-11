#!/bin/bash
# ============================================================
# update43.sh
# core/backup_manager.py：restore_dashboard.sh 內嵌腳本補上
# Nginx reverse proxy + HTTPS 還原步驟（2026-07-15 架構上線後
# 一直漏掉，會導致新機還原完成後瀏覽器完全連不到 Dashboard）
# 同時修正過時的驗證指令、補上 data/ 已含在備份包內的說明。
# 對應：changelog-details/20260811-restore-guide-nginx-gap-fix.md
# ============================================================
set -e

cd "$(dirname "$0")"

TARGET="core/backup_manager.py"

# --- 0. 自動歸檔：把非本次腳本的其他 updateN.sh 搬進固定資料夾 ---
ARCHIVE_DIR="updateN"
SELF="$(basename "$0")"

mkdir -p "$ARCHIVE_DIR"
for f in update*.sh; do
  [ "$f" = "$SELF" ] && continue
  [ -f "$f" ] || continue
  git mv "$f" "${ARCHIVE_DIR}/$f" 2>/dev/null || mv "$f" "${ARCHIVE_DIR}/$f"
done
git add update*.sh "$ARCHIVE_DIR"/ 2>/dev/null || true
if ! git diff --cached --quiet 2>/dev/null; then
  git commit -m "chore: 歸檔已執行的 updateN.sh 腳本"
fi

# --- 1. 前置驗證 ---
echo "[前置驗證] 確認 $TARGET 目前內容符合預期（尚未套用本次改動）..."

if [ ! -f "$TARGET" ]; then
  echo "❌ 找不到 $TARGET" >&2
  exit 1
fi

if grep -q "NEEDS_NGINX" "$TARGET"; then
  echo "❌ 偵測到 $TARGET 已包含 NEEDS_NGINX，本次改動可能已套用過，中止避免重複套用" >&2
  exit 1
fi

if ! grep -q 'echo "  (略過：無 service 檔備份)"' "$TARGET"; then
  echo "❌ $TARGET 內容與預期的舊版不符（找不到比對錨點），請先確認檔案目前實際內容，不要假設等於文件記錄的版本" >&2
  exit 1
fi

echo "  ✓ 前置驗證通過"

# --- 2. 精確字串替換（python3，找不到就中止，不寫入任何檔案）---
echo "[Step 1] 套用 $TARGET 改動..."

python3 << 'PYEOF'
import sys

path = "core/backup_manager.py"
with open(path, "r", encoding="utf-8") as f:
    content = f.read()

edits = []

# --- Edit 1: docstring 補充 data/ 與 deploy/nginx 說明 ---
old1 = '''    """
    備份 A：fs-dashboard 設定 + 程式碼
    打包內容：
      dashboard/          → /opt/fs-dashboard/
      freeswitch-config/  → /etc/freeswitch/
      sounds-custom/      → /var/lib/freeswitch/sounds/custom/
      scripts/            → /usr/share/freeswitch/scripts/
      systemd/            → fs-dashboard.service
      pip-requirements.txt
      restore_dashboard.sh
    """'''

new1 = '''    """
    備份 A：fs-dashboard 設定 + 程式碼
    打包內容：
      dashboard/          → /opt/fs-dashboard/ 完整複本（含 core/、routers/、static/、
                             deploy/nginx/fs-dashboard.conf、data/ 底下的 auth.db／cdr.db／
                             reg_log.db 等所有 SQLite 資料庫，僅排除 backups/、__pycache__、*.pyc；
                             不含 Nginx 憑證/私鑰，這些不在 repo 版控範圍內，還原時會另外產生自簽憑證）
      freeswitch-config/  → /etc/freeswitch/
      sounds-custom/      → /var/lib/freeswitch/sounds/custom/
      scripts/            → /usr/share/freeswitch/scripts/
      systemd/            → fs-dashboard.service（備份當下的即時內容，含 --host 綁定設定）
      pip-requirements.txt
      restore_dashboard.sh
    """'''

edits.append(("docstring", old1, new1))

# --- Edit 2: Step 6 之後補上 Nginx 還原（Step 6.5），更新 Step 7/8 驗證清單 ---
old2 = '''# --- 6. systemd service ---
echo "[Step 6] 安裝 systemd service..."
if [ -f "$SCRIPT_DIR/systemd/fs-dashboard.service" ]; then
    cp "$SCRIPT_DIR/systemd/fs-dashboard.service" /etc/systemd/system/
    systemctl daemon-reload
    systemctl enable fs-dashboard
    echo "  ✓ fs-dashboard.service 已安裝並啟用"
else
    echo "  (略過：無 service 檔備份)"
fi

# --- 7. 重啟服務 ---
echo "[Step 7] 重啟服務..."
systemctl restart freeswitch || true
sleep 2
systemctl restart fs-dashboard || true
sleep 2

# --- 8. 驗證 ---
echo ""
echo "[驗證] 服務狀態："
systemctl status freeswitch --no-pager -l | head -5
systemctl status fs-dashboard --no-pager -l | head -5

echo ""
echo "======================================================"
echo " ✓ 還原完成！"
echo ""
echo " 驗證清單："
echo "  1. 開啟瀏覽器 http://<新機IP>:3000"
echo "  2. 確認分機列表正常"
echo "  3. fs_cli -H 127.0.0.1 -P 8055 -p FSPyAdmin -x 'status'"
echo "  4. curl http://localhost:3000/api/settings"
echo "======================================================"
"""'''

new2 = '''# --- 6. systemd service ---
echo "[Step 6] 安裝 systemd service..."
if [ -f "$SCRIPT_DIR/systemd/fs-dashboard.service" ]; then
    cp "$SCRIPT_DIR/systemd/fs-dashboard.service" /etc/systemd/system/
    systemctl daemon-reload
    systemctl enable fs-dashboard
    echo "  ✓ fs-dashboard.service 已安裝並啟用"
    if grep -q -- "--host 127.0.0.1" /etc/systemd/system/fs-dashboard.service 2>/dev/null; then
        echo "  ℹ 偵測到服務綁定 127.0.0.1（Nginx 架構），將於 Step 6.5 設定反向代理"
        NEEDS_NGINX=1
    else
        NEEDS_NGINX=0
        echo "  ⚠ 服務綁定非 127.0.0.1，可能是舊版備份（Nginx 上線於 2026-07-15 前），略過 Nginx 設定"
    fi
else
    echo "  (略過：無 service 檔備份)"
    NEEDS_NGINX=0
fi

# --- 6.5 Nginx reverse proxy + HTTPS（2026-07-15 起架構，見 changelog-details/20260715-nginx-https-feature.md）---
if [ "$NEEDS_NGINX" = "1" ]; then
    echo "[Step 6.5] 設定 Nginx reverse proxy + HTTPS..."

    if ! command -v nginx >/dev/null 2>&1; then
        echo "  安裝 nginx..."
        apt-get update -qq
        apt-get install -y --no-install-recommends nginx openssl 2>/dev/null || true
    fi

    NGINX_CONF_SRC="/opt/fs-dashboard/deploy/nginx/fs-dashboard.conf"
    if [ -f "$NGINX_CONF_SRC" ]; then
        ln -sf "$NGINX_CONF_SRC" /etc/nginx/sites-available/fs-dashboard.conf
        ln -sf /etc/nginx/sites-available/fs-dashboard.conf /etc/nginx/sites-enabled/fs-dashboard.conf
        [ -f /etc/nginx/sites-enabled/default ] && rm -f /etc/nginx/sites-enabled/default
        echo "  ✓ nginx 設定已從 repo（$NGINX_CONF_SRC）連結"
    else
        echo "  ✗ 找不到 $NGINX_CONF_SRC，Nginx 設定未還原，需手動處理"
        echo "    參考 changelog-details/20260715-nginx-https-feature.md 的『修改的檔案』章節"
    fi

    # 自簽憑證（若尚不存在才產生；CN/SAN 需改成新機實際 IP 或網域）
    CERT_DIR="/etc/nginx/ssl"
    if [ ! -f "$CERT_DIR/fs-dashboard.crt" ]; then
        mkdir -p "$CERT_DIR"
        NEW_IP="$(hostname -I | awk '{print $1}')"
        echo "  尚未偵測到憑證，將產生自簽憑證（CN/SAN = ${NEW_IP:-<請手動指定>}）"
        echo "  ⚠ 若新機 IP 與此偵測結果不同，或未來改用網域名稱，請重新產生憑證並更新 nginx 設定"
        openssl req -x509 -nodes -days 3650 \\
            -newkey rsa:2048 \\
            -keyout "$CERT_DIR/fs-dashboard.key" \\
            -out "$CERT_DIR/fs-dashboard.crt" \\
            -subj "/CN=${NEW_IP:-localhost}" \\
            -addext "subjectAltName=IP:${NEW_IP:-127.0.0.1}" 2>/dev/null || \\
            echo "  ✗ 自簽憑證產生失敗，請手動執行（參考 20260715-nginx-https-feature.md）"
    else
        echo "  ✓ 偵測到既有憑證 $CERT_DIR/fs-dashboard.crt，沿用（未隨備份包還原，憑證與私鑰不在版控範圍內）"
    fi

    nginx -t && systemctl enable --now nginx && systemctl reload nginx \\
        && echo "  ✓ nginx 設定檢查通過並已啟用" \\
        || echo "  ✗ nginx -t 失敗，Dashboard 將無法透過瀏覽器存取，請手動排查（見常見問題排查章節）"
else
    echo "[Step 6.5] 略過 Nginx 設定（服務未偵測到 127.0.0.1 綁定）"
fi

# --- 7. 重啟服務 ---
echo "[Step 7] 重啟服務..."
systemctl restart freeswitch || true
sleep 2
systemctl restart fs-dashboard || true
sleep 2

# --- 8. 驗證 ---
echo ""
echo "[驗證] 服務狀態："
systemctl status freeswitch --no-pager -l | head -5
systemctl status fs-dashboard --no-pager -l | head -5
[ "$NEEDS_NGINX" = "1" ] && systemctl status nginx --no-pager -l | head -5

echo ""
echo "======================================================"
echo " ✓ 還原完成！"
echo ""
echo " 驗證清單："
if [ "$NEEDS_NGINX" = "1" ]; then
    NEW_IP="$(hostname -I | awk '{print $1}')"
    echo "  1. 開啟瀏覽器 https://${NEW_IP:-<新機IP>}/（自簽憑證會跳警告，屬預期行為）"
    echo "  2. 確認分機列表正常、登入身分/導覽列權限顯示正確"
    echo "  3. fs_cli -H 127.0.0.1 -P 8055 -p FSPyAdmin -x 'status'"
    echo "  4. 登入後用瀏覽器 F12 → Network 確認 WebSocket 走 wss://.../ws/?token=... 且狀態 101"
    echo "  5. 本機驗證後端存活（僅 loopback，瀏覽器連不到屬正常）：curl http://127.0.0.1:3000/api/settings（未帶 token 預期 401，非 000/連線失敗即代表服務有在跑）"
    echo "  6. 若 data/auth.db 已隨備份還原，直接用原帳號登入即可；僅在 data/ 遺失或全新資料庫時才需 curl -X POST https://${NEW_IP:-<新機IP>}/api/auth/bootstrap 建立內建帳號"
else
    echo "  1. 開啟瀏覽器 http://<新機IP>:3000"
    echo "  2. 確認分機列表正常"
    echo "  3. fs_cli -H 127.0.0.1 -P 8055 -p FSPyAdmin -x 'status'"
    echo "  4. curl http://localhost:3000/api/settings（權限系統上線後未帶 token 預期 401，非 000 即代表服務存活）"
fi
echo "======================================================"
"""'''

edits.append(("step6_step8_block", old2, new2))

for name, old, new in edits:
    count = content.count(old)
    if count != 1:
        print(f"❌ 比對錨點「{name}」在檔案中出現 {count} 次（預期 1 次），中止，不寫入任何檔案", file=sys.stderr)
        sys.exit(1)
    content = content.replace(old, new)

with open(path, "w", encoding="utf-8") as f:
    f.write(content)

print("  ✓ 兩處改動皆已套用")
PYEOF

if [ $? -ne 0 ]; then
  echo "❌ python3 字串替換失敗，未寫入任何檔案" >&2
  exit 1
fi

# --- 3. 語法驗證 ---
echo "[Step 2] Python 語法檢查..."
if command -v python3 >/dev/null 2>&1; then
  python3 -c "import ast; ast.parse(open('$TARGET').read())" \
    && echo "  ✓ 語法檢查通過" \
    || { echo "❌ 語法檢查失敗，還原變更"; git checkout -- "$TARGET" 2>/dev/null; exit 1; }
else
  echo "  ⚠ 找不到 python3，略過語法檢查（不應發生，server 上應有 venv）"
fi

# --- 4. git commit（功能改動，與歸檔分開 commit）---
echo "[Step 3] git commit..."
git add "$TARGET"
git status
git commit -m "fix: restore_dashboard.sh 補上 Nginx/HTTPS 還原步驟，修正過時驗證指令，澄清 data/ 已含在備份包內"

echo ""
echo "======================================================"
echo " ✓ update43.sh 執行完成"
echo ""
git log --oneline -1
echo ""
echo " ⚠️ 本次修改的是 core/backup_manager.py（Pydantic 無關但仍是 core/ 模組），"
echo "    依慣例需要重啟服務讓改動生效："
echo "    systemctl restart fs-dashboard"
echo ""
echo " 驗證重點清單："
echo "  1. systemctl restart fs-dashboard 後，systemctl status fs-dashboard 確認正常啟動、無 500"
echo "  2. 進 Dashboard → 系統 → 備份管理 → 觸發一次 Dashboard 設定備份，下載後解壓確認："
echo "     tar tzf fs-dashboard-config-*.tar.gz | grep restore_dashboard.sh"
echo "     解壓後 grep -c NEEDS_NGINX fs-dashboard-config/restore_dashboard.sh   # 應 >0"
echo "  3. 若有測試機，建議實際跑一次 restore_dashboard.sh 驗證 Step 6.5 邏輯"
echo "     （本次為程式碼層面修正，尚未在任何機器上實際執行過還原流程）"
echo "  4. 確認 push 前 git status 乾淨、git log 看到本次 fix: commit"
echo "  5. push/deploy.sh 由你自己手動執行"
echo "======================================================"
