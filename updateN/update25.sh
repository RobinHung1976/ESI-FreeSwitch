#!/usr/bin/env bash
# update25.sh — 登錄記錄（reg_log）去重：分機定期自動刷新註冊（SIP REGISTER keepalive）
# 不再視為「新登入」重複寫入 reg_log，只有下列情況才真正寫入一筆記錄：
#   1. 該分機第一次註冊（服務啟動後首次看到）
#   2. 該分機先前是 UNREGISTER，這次重新 REGISTER（真正的重新登入）
#   3. 該分機 REGISTER 的來源 IP 或協定跟上一筆不同（換裝置/換網路）
#   4. UNREGISTER 一律照寫（狀態改變）
#
# 背景：分機話機/App 為維持 NAT 穿透與註冊有效，會在到期前自動送出 REGISTER
# 刷新請求，FreeSwitch 每收到一次都會觸發 ESL REGISTER 事件，導致「登錄記錄」
# 頁面同一分機每隔幾分鐘就多一筆，其實使用者只登入了一次。
#
# 編號說明：先前一度誤編號為 update23.sh，與 server 上實際已使用的
# update23.sh（Dialplan Context UI 文件收尾，內容完全不同）撞號，
# 本腳本改為 update25.sh 銜接在 update24.sh（導覽列權限稽核結案）之後。
set -euo pipefail
cd "$(dirname "$0")"

# ── 0. 自動歸檔：把非本次腳本的其他 updateM.sh 搬進固定資料夾 updateN/ ─────────
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

# ── 1. 前置驗證 ────────────────────────────────────────────────────────────
# 1a. 確認上一支腳本（update24.sh，導覽列權限稽核結案）已套用
#     PROJECT-OVERVIEW.md/CHANGELOG.md 實際位於 reorg/ 底下，非 repo 根目錄
if ! grep -q "20260716-nav-permission-audit.md" reorg/CHANGELOG.md 2>/dev/null; then
  echo "❌ reorg/CHANGELOG.md 尚未包含 update24.sh 的改動，請先確認 update24.sh 是否已成功套用" >&2
  exit 1
fi

# 1b. 確認 core/runtime.py 目前是「尚未去重」的原始版本，避免重複套用
if ! grep -q 'def write_reg_log(ext: str, event: str, ip: str, proto: str, ts_ms: int):' core/runtime.py; then
  echo "❌ core/runtime.py 找不到 write_reg_log() 原始函式簽章，請確認檔案內容是否已被手動修改" >&2
  exit 1
fi
if grep -q '_last_reg_state' core/runtime.py; then
  echo "❌ core/runtime.py 似乎已經套用過本次去重改動（找到 _last_reg_state），略過以避免重複套用" >&2
  exit 1
fi

# ── 2. 修改 core/runtime.py：write_reg_log() 加上去重邏輯 ─────────────────
python3 << 'PYEOF'
import sys

path = "core/runtime.py"
with open(path, "r", encoding="utf-8") as f:
    content = f.read()

old = '''def write_reg_log(ext: str, event: str, ip: str, proto: str, ts_ms: int):
    """Write registration event to persistent SQLite log（core/reg_log_db.py）。
    2026-07-15：取代原本的記憶體 list（服務重啟即歸零）。
    """
    import datetime as _dt
    time_str = _dt.datetime.fromtimestamp(ts_ms / 1000).strftime('%Y-%m-%d %H:%M:%S')
    proto_up = proto.upper() if proto else "UDP"
    try:
        reg_log_db.insert_log(ext, event, ip, proto_up, ts_ms, time_str)
    except Exception as e:
        print(f"[REG_LOG] SQLite 寫入失敗：{e}")
    print(f"[REG_LOG] {event} ext={ext} ip={ip} at {time_str}")'''

new = '''# 2026-07-16：分機定期自動刷新 SIP 註冊（keepalive）不視為新登入，
# 只有「首次註冊 / 先前已登出後重新登入 / IP 或協定變動」才真正寫入 reg_log。
# 服務重啟後歸零屬預期行為（跟 state.ext_status 等其他記憶體狀態一致）。
_last_reg_state: dict = {}


def write_reg_log(ext: str, event: str, ip: str, proto: str, ts_ms: int):
    """Write registration event to persistent SQLite log（core/reg_log_db.py）。
    2026-07-15：取代原本的記憶體 list（服務重啟即歸零）。
    2026-07-16：新增去重，過濾掉分機定期自動刷新註冊造成的重複記錄。
    """
    import datetime as _dt
    time_str = _dt.datetime.fromtimestamp(ts_ms / 1000).strftime('%Y-%m-%d %H:%M:%S')
    proto_up = proto.upper() if proto else "UDP"

    # ── 去重：同分機、同 IP/協定的連續 REGISTER 視為單純 keepalive 刷新 ──
    prev = _last_reg_state.get(ext)
    if (event == "REGISTER" and prev and prev.get("event") == "REGISTER"
            and prev.get("ip") == ip and prev.get("proto") == proto_up):
        return
    _last_reg_state[ext] = {"event": event, "ip": ip, "proto": proto_up}

    try:
        reg_log_db.insert_log(ext, event, ip, proto_up, ts_ms, time_str)
    except Exception as e:
        print(f"[REG_LOG] SQLite 寫入失敗：{e}")
    print(f"[REG_LOG] {event} ext={ext} ip={ip} at {time_str}")'''

if content.count(old) != 1:
    print(f"❌ 比對字串出現 {content.count(old)} 次（預期 1 次），中止", file=sys.stderr)
    sys.exit(1)

content = content.replace(old, new)
with open(path, "w", encoding="utf-8") as f:
    f.write(content)

print("✅ core/runtime.py 已套用 write_reg_log() 去重邏輯")
PYEOF

# ── 3. 語法檢查 ────────────────────────────────────────────────────────────
python3 -m py_compile core/runtime.py
echo "✅ py_compile 通過"

# ── 4. Commit ──────────────────────────────────────────────────────────────
git add core/runtime.py
git commit -m "fix: 登錄記錄（reg_log）去重，過濾分機定期自動刷新註冊造成的重複記錄"

echo ""
echo "=== git log ==="
git --no-pager log --oneline -3

cat << 'EOF'

=== 部署步驟（server 上執行）===
python3 -m py_compile core/runtime.py
sudo systemctl restart fs-dashboard

=== 驗證重點清單 ===
1. journalctl -u fs-dashboard -f，確認服務正常啟動、無 500 / import 錯誤
2. 保持某分機（如 1210）長時間上線（跨過它的註冊刷新週期，例如觀察 10~15 分鐘）
3. 瀏覽器「系統 → 系統日誌 → 🔐 登錄記錄」，該分機不應再每隔幾分鐘多一筆 REGISTER
4. 手動測試「真正的重新登入」仍會被記錄：
   - 話機/軟體電話登出（UNREGISTER）→ 應正常寫入一筆 UNREGISTER
   - 再重新登入（REGISTER）→ 應正常寫入一筆 REGISTER
5. 手動測試「換網路/換裝置」仍會被記錄：
   - 同一分機從不同 IP 或不同協定（UDP/TCP）重新註冊 → 應正常寫入新的一筆 REGISTER
6. 服務重啟後，該分機下一次收到的 REGISTER（不論是否為刷新）會照寫一筆，
   之後才會恢復去重（屬預期行為，因為去重狀態存在記憶體，重啟即歸零）

確認無誤後，手動執行：
  git push
EOF
