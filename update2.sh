#!/usr/bin/env bash
set -euo pipefail

echo "===== update2.sh — 清理孤兒/重複檔案 + 修正 calls.router 重複掛載 ====="
echo "適用 repo：ESI-FreeSwitch"
echo "對照文件：server-snapshot-audit-20260710.md 第五節"
echo ""
echo "說明：update1.sh 已正式作廢、從未執行過（基於過時版本寫的），"
echo "      本腳本編號從 update2.sh 接續，不重用 update1 這個編號。"
echo ""

# ---------- 0. 自動歸檔：把非本次編號的 updateM.sh 搬進 update2/ ----------
CURRENT=2
mkdir -p "update${CURRENT}"
for f in update*.sh; do
  [ "$f" = "update${CURRENT}.sh" ] && continue
  [ -f "$f" ] || continue
  git mv "$f" "update${CURRENT}/$f" 2>/dev/null || mv "$f" "update${CURRENT}/$f"
done
git add -A
if ! git diff --cached --quiet; then
  git commit -m "chore: 歸檔已執行的 updateN.sh 腳本"
  echo "✅ 歸檔 commit 已產生（與本次功能改動分開）"
else
  echo "ℹ️  無舊腳本需要歸檔"
fi

# ---------- 1. 前置驗證：確認目前狀態符合稽核報告的描述 ----------
echo ""
echo "---------- 前置驗證 ----------"

for p in routers/runtime.py routers/cdr_db.py routers/migrate_cdr_backfill.py \
         core/runtime.py core/cdr_db.py migrate_cdr_backfill.py server.py; do
  if [ ! -f "$p" ]; then
    echo "❌ 找不到必要路徑：$p，現況與稽核報告不符，已中止（未寫入任何檔案）" >&2
    exit 1
  fi
done

# 確認 core/runtime.py 已含 WebSocket token 驗證（不然代表還沒做完前一項修復，不該繼續清理）
if ! grep -q "manager.authenticate(token)" core/runtime.py; then
  echo "❌ core/runtime.py 尚未包含 WebSocket token 驗證，代表前一項修復可能還沒真的套用到這個版本" >&2
  echo "   為避免刪掉還在用的 routers/runtime.py，已中止。" >&2
  exit 1
fi

# 確認 routers/runtime.py 與 core/runtime.py 確實不同（是舊版孤兒檔，不是誤判）
if diff -q routers/runtime.py core/runtime.py > /dev/null 2>&1; then
  echo "❌ routers/runtime.py 與 core/runtime.py 內容相同，跟稽核報告記錄的狀態不符，已中止。" >&2
  exit 1
fi

# 確認 cdr_db.py / migrate_cdr_backfill.py 兩組是逐字元相同的孤兒複本，才安全刪除
if ! diff -q routers/cdr_db.py core/cdr_db.py > /dev/null 2>&1; then
  echo "❌ routers/cdr_db.py 與 core/cdr_db.py 內容不同（跟稽核報告記錄的不一致），可能兩邊都被改過，已中止，請人工確認。" >&2
  exit 1
fi
if ! diff -q routers/migrate_cdr_backfill.py migrate_cdr_backfill.py > /dev/null 2>&1; then
  echo "❌ routers/migrate_cdr_backfill.py 與根目錄版本內容不同，可能兩邊都被改過，已中止，請人工確認。" >&2
  exit 1
fi

# 確認 server.py 確實有重複掛載（且剛好兩行，不多不少，避免誤刪其他行）
DUP_COUNT=$(grep -c "^app.include_router(calls.router)$" server.py || true)
if [ "$DUP_COUNT" -ne 2 ]; then
  echo "❌ server.py 中 'app.include_router(calls.router)' 出現 $DUP_COUNT 次，預期應為 2 次，現況與稽核報告不符，已中止。" >&2
  exit 1
fi

echo "✅ 現況與稽核報告一致，可以繼續清理"

# ---------- 2. 刪除孤兒/重複檔案 ----------
echo ""
echo "---------- 刪除孤兒/重複檔案 ----------"
git rm -q routers/runtime.py
echo "✅ 已刪除 routers/runtime.py（舊版孤兒檔，WebSocket 驗證修復已在 core/runtime.py 完成）"
git rm -q routers/cdr_db.py
echo "✅ 已刪除 routers/cdr_db.py（與 core/cdr_db.py 逐字元相同的誤複製）"
git rm -q routers/migrate_cdr_backfill.py
echo "✅ 已刪除 routers/migrate_cdr_backfill.py（與根目錄版本逐字元相同的誤複製）"

# ---------- 3. 修正 server.py 重複掛載（精確字串比對，只動這一小處）----------
echo ""
echo "---------- 修正 server.py：移除重複的 calls.router 掛載 ----------"
python3 << 'PYEOF'
path = "server.py"
with open(path, "r", encoding="utf-8") as f:
    content = f.read()

old = "app.include_router(calls.router)\napp.include_router(calls.router)\n"
new = "app.include_router(calls.router)\n"

count = content.count(old)
if count != 1:
    raise SystemExit(f"❌ 預期比對字串應剛好出現 1 次，實際出現 {count} 次，為避免誤改已中止，請人工確認 server.py 內容")

content = content.replace(old, new, 1)
with open(path, "w", encoding="utf-8") as f:
    f.write(content)
print("✅ server.py 已修正，calls.router 現在只掛載一次")
PYEOF

# ---------- 4. 驗證修正結果 ----------
echo ""
echo "---------- 驗證修正結果 ----------"
NEW_DUP_COUNT=$(grep -c "^app.include_router(calls.router)$" server.py || true)
if [ "$NEW_DUP_COUNT" -ne 1 ]; then
  echo "❌ 修正後 calls.router 出現 $NEW_DUP_COUNT 次，預期應為 1 次，異常，已中止，不會 commit。" >&2
  exit 1
fi
echo "✅ 確認 server.py 現在只有 1 次 calls.router 掛載"

for p in routers/runtime.py routers/cdr_db.py routers/migrate_cdr_backfill.py; do
  if [ -e "$p" ]; then
    echo "❌ $p 應該已被刪除但仍存在，異常，已中止，不會 commit。" >&2
    exit 1
  fi
done
echo "✅ 確認三個孤兒檔案皆已刪除"

# ---------- 5. git commit ----------
echo ""
echo "---------- git commit ----------"
git add -A
git commit -m "fix: 清理孤兒/重複檔案並修正 calls.router 重複掛載

- 刪除 routers/runtime.py（舊版孤兒檔，WebSocket token 驗證已在 core/runtime.py 完成並生效）
- 刪除 routers/cdr_db.py（與 core/cdr_db.py 逐字元相同的誤複製）
- 刪除 routers/migrate_cdr_backfill.py（與根目錄版本逐字元相同的誤複製）
- server.py：移除重複的 app.include_router(calls.router) 掛載

對照文件：server-snapshot-audit-20260710.md 第五節"

echo ""
echo "✅ commit 完成，最新 commit："
git log --oneline -1

echo ""
echo "===== 驗證重點清單（push/deploy 前請逐項核對）====="
cat << 'CHECKLIST'
1. git status 應為乾淨
2. git log --oneline -3 應可看到「chore: 歸檔」(若有)與「fix: 清理孤兒/重複檔案...」兩個獨立 commit
3. ls routers/ 確認 runtime.py、cdr_db.py、migrate_cdr_backfill.py 三個檔案都不在了
4. grep -c "include_router(calls.router)" server.py 應回傳 1
5. 部署後啟動服務，確認 journalctl -u <service> 沒有 ImportError
   （這三支被刪的檔案本來就沒有任何地方 import，理論上刪除不影響任何功能）
6. 瀏覽器測試「即時通話監控」頁面，確認 calls 相關功能正常（驗證 include_router 修正沒有副作用）
7. 確認無誤後，再自行 push 到 ESI-FreeSwitch 並執行 deploy.sh
CHECKLIST
