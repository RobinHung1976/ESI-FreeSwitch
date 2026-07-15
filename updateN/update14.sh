#!/bin/bash
# update14.sh —
#   修正 update13.sh 的路徑問題：PROJECT-OVERVIEW.md / CHANGELOG.md / changelog-details/
#   實際位於 reorg/ 底下，且從未被 git 追蹤過。
#   1) 把 reorg/ 下這三個路徑一併納入 git 版控（首次追蹤）
#   2) 新增 reorg/changelog-details/20260715-nginx-https-feature.md
#   3) reorg/CHANGELOG.md 新增一筆索引
#   4) reorg/PROJECT-OVERVIEW.md checklist 打勾 + 已知待處理事項更新
#
# 使用方式：
#   cd /opt/fs-dashboard
#   chmod +x update14.sh
#   ./update14.sh

set -e
cd "$(dirname "$0")"

DOCS_DIR="reorg"

echo "=== [1/4] 自動歸檔：把舊的 updateN.sh 搬進固定資料夾 updateN/ ==="
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
echo "=== [2/4] 前置驗證 ==="
if [ ! -f "${DOCS_DIR}/PROJECT-OVERVIEW.md" ]; then
  echo "❌ 找不到 ${DOCS_DIR}/PROJECT-OVERVIEW.md，中止" >&2
  exit 1
fi
if [ ! -f "${DOCS_DIR}/CHANGELOG.md" ]; then
  echo "❌ 找不到 ${DOCS_DIR}/CHANGELOG.md，中止" >&2
  exit 1
fi
if [ -f "${DOCS_DIR}/changelog-details/20260715-nginx-https-feature.md" ]; then
  echo "❌ ${DOCS_DIR}/changelog-details/20260715-nginx-https-feature.md 已存在，可能已執行過本腳本，中止" >&2
  exit 1
fi
if ! grep -q -- "- \[ \] Nginx reverse proxy + HTTPS" "${DOCS_DIR}/PROJECT-OVERVIEW.md"; then
  echo "❌ 找不到 ${DOCS_DIR}/PROJECT-OVERVIEW.md 預期的待辦字串，中止" >&2
  exit 1
fi
if ! grep -q "Nginx reverse proxy + HTTPS" "${DOCS_DIR}/PROJECT-OVERVIEW.md"; then
  echo "❌ 找不到 ${DOCS_DIR}/PROJECT-OVERVIEW.md 已知待處理事項相關字串，中止" >&2
  exit 1
fi
echo "前置驗證通過。"

echo ""
echo "=== [3/4] 建立 changelog-details，更新 CHANGELOG.md / PROJECT-OVERVIEW.md ==="
mkdir -p "${DOCS_DIR}/changelog-details"
cat > "${DOCS_DIR}/changelog-details/20260715-nginx-https-feature.md" << 'MDEOF'
# Nginx Reverse Proxy + HTTPS 上線（2026-07-15）

## 背景

`PROJECT-OVERVIEW.md` 高優先待辦「Nginx reverse proxy + HTTPS」，本次完成部署。環境：內網（`192.168.100.209`），目前沒有可用網域名稱，未來可能開放外網。

## 架構

```
瀏覽器 --443(TLS, 自簽憑證)--> nginx
                                ├─ /api/logs/stream --127.0.0.1:3000--> FastAPI（SSE，關閉緩衝）
                                ├─ /ws/             --127.0.0.1:8080--> websockets 伺服器（WS）
                                └─ /（其餘）         --127.0.0.1:3000--> FastAPI（REST + 靜態頁面）
```

## 決策紀錄

| 項目 | 決定 | 原因 |
|---|---|---|
| 憑證 | 自簽憑證（`openssl req -x509`，3650 天，CN/SAN = `192.168.100.209`） | 目前無網域名稱，Let's Encrypt HTTP-01/DNS-01 皆無法使用；未來若取得網域，再換受信任憑證 |
| WebSocket 路由 | 前端改走 `wss://<host>/ws/`，統一由 nginx 轉發到 `127.0.0.1:8080` | 一旦頁面用 https 開啟，瀏覽器會擋掉 `ws://`（mixed content），這是協定安全限制，跟內網/外網無關，屬必要修正而非可選項 |
| 後端 bind 位址 | `fs-dashboard.service` 的 `--host 0.0.0.0` 改成 `--host 127.0.0.1`；`core/runtime.py` 的 `websockets.serve()` 同步從 `0.0.0.0` 改 `127.0.0.1` | 對外流量統一由 nginx 443 進出，3000/8080 沒必要再對外開放，降低攻擊面 |
| nginx 設定檔位置 | 複製進 repo 的 `deploy/nginx/fs-dashboard.conf`，`/etc/nginx/sites-available/fs-dashboard.conf` 改為 symlink 指回 repo | 讓 nginx 設定有 git 版本歷史，改設定只需要改 repo 這份 + `nginx -t && systemctl reload nginx`，不用手動同步兩邊 |

## 修改的檔案

- **新增**：`/etc/nginx/sites-available/fs-dashboard.conf`（後改為 symlink）→ 內容存放於 repo `deploy/nginx/fs-dashboard.conf`
- **`static/js/common.js`**：`API_BASE` 從寫死 `http://192.168.100.209:3000` 改成相對路徑 `''`；`WS_URL` 從寫死 `ws://192.168.100.209:8080` 改成跟隨頁面協定的 `` `${WS_PROTOCOL}//${location.host}/ws` ``
- **`static/login.html`**、**`static/change-password.html`**：各自內嵌一份獨立的 `API_BASE`，同樣寫死 IP:port，一併修正為相對路徑（這兩支頁面沒有共用 `common.js` 的設定，是這次才發現的獨立踩雷點）
- **`core/runtime.py`**：`start_ws_server()` 的 `websockets.serve(ws_handler, "0.0.0.0", 8080)` 改成 `"127.0.0.1"`
- **`/etc/systemd/system/fs-dashboard.service`**：`ExecStart` 的 `--host 0.0.0.0` 改成 `--host 127.0.0.1`（repo 外，系統層級，未納入版控）

## 過程中踩到的坑

1. **終端機貼上多行 heredoc 被截斷**：透過 SSH 貼上大段多行 `cat > file << 'EOF' ...` 內容時，內容被打亂/截斷。改用「整份內容轉 base64 → 單行 `echo ... | base64 -d > file`」的方式解決。
2. **`updateN.sh` 自動歸檔誤把不相關改動一起 commit**：`update10.sh` 的歸檔步驟用了 `git add -A`，把使用者手動已套用、尚未 commit 的 `common.js`/`runtime.py` 改動與不該進 git 的 `.bak` 備份檔一起掃進了 `chore:` 歸檔 commit。修正：後續腳本的歸檔步驟一律只 `git add "${ARCHIVE_DIR}"`；`update11.sh` 補一個 `chore:` commit 移除 `.bak` 的 git 追蹤、加入 `.gitignore`。
3. **`login.html`/`change-password.html` 沒有跟 `common.js` 共用設定**：各自內嵌一份獨立的 `API_BASE`，沒有引用 `common.js`，一開始只改 `common.js` 導致登入頁仍然 mixed content 失敗。
4. **`PROJECT-OVERVIEW.md`/`CHANGELOG.md`/`changelog-details/` 實際位於 `reorg/` 子資料夾，且從未被 git 追蹤**：先前產生 `updateN.sh` 時誤以為這些文件在 repo 根目錄，實際路徑跟版控狀態都跟預期不同，執行前務必先 `find` 確認實際路徑，不能只憑既有文件記錄假設。

## 驗證方式

```bash
# HTTPS 對外正常
curl -k -s -o /dev/null -w "%{http_code}\n" https://192.168.100.209/     # 預期 200

# 3000 不再對外開放
curl -s -o /dev/null -w "%{http_code}\n" http://192.168.100.209:3000/    # 預期 000
curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:3000/          # 預期 200

# nginx 設定 symlink 正確
ls -la /etc/nginx/sites-available/fs-dashboard.conf
nginx -t
```

瀏覽器 F12：確認 Console 無 Mixed Content 錯誤；Network 分頁確認 WebSocket 請求網址為 `wss://192.168.100.209/ws/?token=...`，狀態 `101 Switching Protocols`；左下角「連線至 FreeSwitch」燈號為綠燈。

**測試結果**：已於 production server（`debian-freeswitch`）實際部署並逐項驗證通過。
MDEOF

echo "✅ ${DOCS_DIR}/changelog-details/20260715-nginx-https-feature.md 建立完成"

python3 << PYEOF
import pathlib, re, sys

docs_dir = pathlib.Path("${DOCS_DIR}")

# ── CHANGELOG.md：插入新條目在 2026-07 區塊最上方（用「## 2026-07」錨點，較不受既有條目順序影響）──
changelog_path = docs_dir / "CHANGELOG.md"
content = changelog_path.read_text(encoding="utf-8")

new_entry = "- 07-15 feat: Nginx reverse proxy + HTTPS 上線（自簽憑證、REST/WebSocket/SSE 統一走 443、login.html/change-password.html mixed content 修正、nginx 設定納入 git 版控、後端服務改 bind 127.0.0.1） → [詳情](changelog-details/20260715-nginx-https-feature.md)"

anchor = "## 2026-07"
count = content.count(anchor)
if count != 1:
    sys.exit(f"❌ CHANGELOG.md 錨點「## 2026-07」比對次數異常（預期 1，實際 {count}），中止且不寫入")

content = content.replace(anchor, anchor + "\n\n" + new_entry, 1)
changelog_path.write_text(content, encoding="utf-8")
print("✅ CHANGELOG.md 新增條目完成")

# ── PROJECT-OVERVIEW.md：checklist 打勾 ──
overview_path = docs_dir / "PROJECT-OVERVIEW.md"
content2 = overview_path.read_text(encoding="utf-8")

old1 = "- [ ] Nginx reverse proxy + HTTPS"
new1 = "- [x] Nginx reverse proxy + HTTPS（已完成，2026-07-15，見 \`changelog-details/20260715-nginx-https-feature.md\`）"
count1 = content2.count(old1)
if count1 != 1:
    sys.exit(f"❌ PROJECT-OVERVIEW.md checklist 比對次數異常（預期 1，實際 {count1}），中止且不寫入")
content2 = content2.replace(old1, new1)

# 已知待處理事項：用正則抓「4. **Nginx reverse proxy + HTTPS**<任意冒號>尚未導入。」整行，不假設冒號全形/半形
pattern = re.compile(r"4\.\s*\*\*Nginx reverse proxy \+ HTTPS\*\*[::]\s*尚未導入。")
matches = pattern.findall(content2)
if len(matches) != 1:
    sys.exit(f"❌ PROJECT-OVERVIEW.md 已知待處理事項比對次數異常（預期 1，實際 {len(matches)}），中止且不寫入")
replacement = "4. ~~**Nginx reverse proxy + HTTPS**：尚未導入。~~ → 已於 2026-07-15 完成，見 \`changelog-details/20260715-nginx-https-feature.md\`。"
content2 = pattern.sub(replacement, content2, count=1)

overview_path.write_text(content2, encoding="utf-8")
print("✅ PROJECT-OVERVIEW.md 修改完成")
PYEOF

echo ""
echo "=== [4/4] git add + commit（首次把 reorg/ 這三項路徑納入版控）==="
git add "${DOCS_DIR}/changelog-details/20260715-nginx-https-feature.md" "${DOCS_DIR}/CHANGELOG.md" "${DOCS_DIR}/PROJECT-OVERVIEW.md"
if ! git diff --cached --quiet; then
  git commit -m "docs: 新增 20260715-nginx-https-feature.md，CHANGELOG 索引 + PROJECT-OVERVIEW checklist 更新（reorg/ 文件首次納入 git 版控）"
  echo "已建立 commit。"
else
  echo "沒有變更需要 commit。"
fi

echo ""
echo "=== 完成，最新 commit： ==="
git log --oneline -1

echo ""
echo "=========================================="
echo "驗證重點清單："
echo "1. cat ${DOCS_DIR}/changelog-details/20260715-nginx-https-feature.md 檢查內容正確"
echo "2. grep -n 'Nginx reverse proxy' ${DOCS_DIR}/PROJECT-OVERVIEW.md ${DOCS_DIR}/CHANGELOG.md 確認都已更新"
echo "3. git status 確認 reorg/ 底下這三項現在都在 git 追蹤範圍內（git ls-files ${DOCS_DIR}/PROJECT-OVERVIEW.md 應有輸出）"
echo "4. 確認沒問題後：git push"
echo "=========================================="
