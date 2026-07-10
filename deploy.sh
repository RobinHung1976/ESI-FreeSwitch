#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# deploy.sh — 從 GitHub 部署 ESI-FreeSwitch Dashboard 最新版本
# 使用前請確認以下變數符合您的實際環境
# ============================================================
REPO_DIR="/opt/fs-dashboard"     # git repo 所在路徑
SERVICE_NAME="fs-dashboard"      # systemd service 名稱
BRANCH="main"                    # 部署分支
SETTINGS_FILE="settings.json"    # 含 ESL 密碼 / JWT 金鑰等即時設定，不可被 repo 版本覆蓋
HEALTH_URL="http://localhost:3000/"

cd "$REPO_DIR"

echo "===== deploy.sh — 部署 ESI-FreeSwitch Dashboard ====="
echo "repo 路徑：$REPO_DIR"
echo "分支：$BRANCH"
echo "service：$SERVICE_NAME"
echo ""

# ---------- 0. 基本檢查 ----------
if [ ! -d .git ]; then
  echo "❌ $REPO_DIR 不是一個 git repo，請確認路徑是否正確，或先完成 git clone" >&2
  exit 1
fi

# ---------- 1. 部署前檢查工作目錄狀態 ----------
# 對應 SOP「孤兒檔案」教訓：git reset --hard 不會清掉 untracked 檔案，
# 先主動列出來讓使用者確認，不要悶著頭直接 reset。
echo "---------- 檢查工作目錄狀態 ----------"
DIRTY="$(git status --porcelain)"
if [ -n "$DIRTY" ]; then
  echo "⚠️  偵測到尚未提交的變動或未追蹤的檔案："
  echo "$DIRTY"
  echo ""
  echo "⚠️  接下來的 git reset --hard 只會還原「已追蹤」的檔案，"
  echo "   不會清除上面列出的未追蹤檔案（可能是先前中止的 updateN.sh 殘留）。"
  read -p "確認要忽略以上狀態、強制繼續部署嗎？(y/N) " -n 1 -r
  echo ""
  if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "已取消部署。建議先執行 git status 逐項確認，"
    echo "需要的話用 git add/commit 保留、或 git clean -fd 清掉孤兒檔案後再重跑本腳本。"
    exit 1
  fi
else
  echo "✅ 工作目錄乾淨，無未提交或未追蹤的檔案"
fi

# ---------- 2. 備份 settings.json（含即時設定，不能被 repo 版本覆蓋）----------
echo ""
echo "---------- 備份 $SETTINGS_FILE ----------"
BACKUP_TS="$(date +%Y%m%d_%H%M%S)"
if [ -f "$SETTINGS_FILE" ]; then
  cp "$SETTINGS_FILE" "/tmp/settings.json.bak.$BACKUP_TS"
  echo "✅ 已備份至 /tmp/settings.json.bak.$BACKUP_TS"
else
  echo "ℹ️  尚無 $SETTINGS_FILE（可能是全新部署），略過備份"
fi

# ---------- 3. 停止服務 ----------
echo ""
echo "---------- 停止服務 ----------"
systemctl stop "$SERVICE_NAME" 2>/dev/null || echo "⚠️  服務停止失敗或本來就未執行，繼續往下"

# ---------- 4. 拉取最新程式碼 ----------
echo ""
echo "---------- git fetch + reset --hard origin/$BRANCH ----------"
BEFORE_COMMIT="$(git rev-parse HEAD)"
git fetch origin
git reset --hard "origin/$BRANCH"
AFTER_COMMIT="$(git rev-parse HEAD)"
echo "✅ 由 ${BEFORE_COMMIT:0:7} 更新至 ${AFTER_COMMIT:0:7}"
echo ""
echo "最近 5 筆 commit："
git log --oneline -5

# ---------- 5. 還原 settings.json ----------
echo ""
echo "---------- 還原 $SETTINGS_FILE ----------"
if [ -f "/tmp/settings.json.bak.$BACKUP_TS" ]; then
  cp "/tmp/settings.json.bak.$BACKUP_TS" "$SETTINGS_FILE"
  echo "✅ 已還原原本的 $SETTINGS_FILE（ESL 密碼 / JWT 金鑰等即時設定維持不變）"
else
  echo "ℹ️  無本次備份可還原，將使用本次程式碼帶入的版本（如果有附帶預設檔）"
fi

# ---------- 6. 安裝/更新 Python 套件 ----------
echo ""
echo "---------- pip install -r requirements.txt ----------"
pip install -r requirements.txt --break-system-packages -q
echo "✅ 套件安裝/更新完成"

# ---------- 7. 重啟服務 ----------
echo ""
echo "---------- 重啟服務 ----------"
systemctl start "$SERVICE_NAME"
sleep 2
systemctl status "$SERVICE_NAME" --no-pager -l | head -10 || true

# ---------- 8. 健康檢查 ----------
echo ""
echo "---------- 健康檢查 ----------"
HTTP_CODE="$(curl -s -o /dev/null -w '%{http_code}' "$HEALTH_URL" || echo '000')"
if [ "$HTTP_CODE" = "200" ]; then
  echo "✅ $HEALTH_URL 回應 200"
else
  echo "⚠️  $HEALTH_URL 回應 $HTTP_CODE（非 200，請檢查 journalctl -u $SERVICE_NAME -n 50）"
fi

# ---------- 9. 驗證重點清單 ----------
echo ""
echo "===== 驗證重點清單 ====="
cat << CHECKLIST
1. systemctl status $SERVICE_NAME 應為 active (running)
2. journalctl -u $SERVICE_NAME -n 50 --no-pager 確認無 import 錯誤 / 500 錯誤
3. $SETTINGS_FILE 內容應是還原前的版本（ESL 密碼、JWT 金鑰等），不是本次 repo 帶的預設值
4. 瀏覽器打開首頁，確認登入頁正常顯示
5. 若本次部署含使用者權限功能：確認 /opt/fs-dashboard/data/auth.db 存在且未被清空
6. 若發現問題需要回滾，執行：
     cd $REPO_DIR
     git reset --hard $BEFORE_COMMIT
     systemctl restart $SERVICE_NAME
CHECKLIST

echo ""
echo "部署前 commit：$BEFORE_COMMIT"
echo "部署後 commit：$AFTER_COMMIT"
echo "settings.json 備份位置：/tmp/settings.json.bak.$BACKUP_TS"
