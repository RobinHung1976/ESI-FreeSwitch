#!/bin/bash
# update17.sh — 登錄記錄（reg_log）持久化：記憶體 list → SQLite
# 依 ops-github-workflow.md SOP：前置驗證 → 固定歸檔 updateN/ → 精確字串比對（全部驗證通過才寫入）
#                               → 新增 core/reg_log_db.py（完整覆寫）→ feat: commit
set -euo pipefail

echo "=== update17.sh：登錄記錄(reg_log) SQLite 持久化 ==="

# ── 0. 前置驗證：確認 baseline 至少包含 update11（nginx bind 127.0.0.1 修正）───
if ! grep -q 'websockets.serve(ws_handler, "127.0.0.1", 8080)' core/runtime.py 2>/dev/null; then
  echo "❌ core/runtime.py 未包含 update11.sh 的改動（127.0.0.1 bind），請先確認 baseline 是否正確" >&2
  exit 1
fi
if [ -f core/reg_log_db.py ]; then
  echo "❌ core/reg_log_db.py 已存在，本腳本只應執行一次，請確認是否已套用過" >&2
  exit 1
fi
echo "✅ 前置驗證通過"

# ── 1. 固定歸檔（chore commit，只 add 歸檔資料夾本身，不用 -A）───────────────
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
  echo "✅ 已歸檔既有 updateN.sh"
else
  echo "ℹ 無需歸檔（updateN/ 已是最新狀態）"
fi

# ── 2. 新增 core/reg_log_db.py（完整覆寫，新檔案）────────────────────────────
cat > core/reg_log_db.py << 'REGLOGDB_EOF'
"""
core/reg_log_db.py — 登錄記錄（reg_log）SQLite 儲存層。

2026-07-15：取代原本 core/state.py 的記憶體 list（reg_log / REG_LOG_MAX），
服務重啟不再歸零。架構沿用 core/cdr_db.py 的 _conn() pattern，但只有單層
（reg_log 是輕量事件記錄，沒有 CDR 那種「明細 vs 彙總」拆分的必要）。

寫入來源：core/runtime.py 的 write_reg_log()，由 ESL REGISTER/UNREGISTER
事件觸發時呼叫。
"""
import os
import sqlite3
from contextlib import contextmanager
from datetime import datetime

DB_DIR  = "/opt/fs-dashboard/data"
DB_PATH = os.path.join(DB_DIR, "reg_log.db")


@contextmanager
def _conn():
    os.makedirs(DB_DIR, exist_ok=True)
    conn = sqlite3.connect(DB_PATH, timeout=10)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA busy_timeout=5000")
    try:
        yield conn
        conn.commit()
    finally:
        conn.close()


def init_db():
    """建立 table/index，服務啟動時呼叫一次（idempotent，可重複執行）。"""
    with _conn() as conn:
        conn.execute("""
            CREATE TABLE IF NOT EXISTS reg_log (
                id        INTEGER PRIMARY KEY AUTOINCREMENT,
                ext       TEXT NOT NULL,
                event     TEXT NOT NULL,
                ip        TEXT,
                proto     TEXT,
                ts_ms     INTEGER NOT NULL,
                time_str  TEXT NOT NULL,
                date_str  TEXT NOT NULL
            )
        """)
        conn.execute("CREATE INDEX IF NOT EXISTS idx_reg_log_ts ON reg_log(ts_ms)")
        conn.execute("CREATE INDEX IF NOT EXISTS idx_reg_log_date ON reg_log(date_str)")
        conn.execute("CREATE INDEX IF NOT EXISTS idx_reg_log_ext ON reg_log(ext)")


def insert_log(ext: str, event: str, ip: str, proto: str, ts_ms: int, time_str: str) -> None:
    """寫入一筆登錄事件。time_str 格式 'YYYY-MM-DD HH:MM:SS'，date_str 從中截取。"""
    date_str = time_str[:10] if time_str else datetime.fromtimestamp(ts_ms / 1000).strftime("%Y-%m-%d")
    with _conn() as conn:
        conn.execute("""
            INSERT INTO reg_log (ext, event, ip, proto, ts_ms, time_str, date_str)
            VALUES (?, ?, ?, ?, ?, ?, ?)
        """, (ext, event, ip, proto, ts_ms, time_str, date_str))


def query_logs(date_from: str = None, date_to: str = None, ext: str = None,
               event: str = None, limit: int = 200, offset: int = 0) -> dict:
    """查詢登錄記錄，新→舊排序，支援日期區間/分機/事件類型篩選 + 分頁。"""
    where, params = [], []
    if date_from:
        where.append("date_str >= ?"); params.append(date_from)
    if date_to:
        where.append("date_str <= ?"); params.append(date_to)
    if ext:
        where.append("ext = ?"); params.append(ext)
    if event:
        where.append("event = ?"); params.append(event.upper())
    where_sql = ("WHERE " + " AND ".join(where)) if where else ""

    with _conn() as conn:
        total = conn.execute(f"SELECT COUNT(*) FROM reg_log {where_sql}", params).fetchone()[0]
        rows = conn.execute(
            f"SELECT ext, event, ip, proto, ts_ms, time_str FROM reg_log {where_sql} "
            f"ORDER BY ts_ms DESC LIMIT ? OFFSET ?",
            params + [limit, offset]
        ).fetchall()

    result_rows = [{
        "ext": r["ext"], "event": r["event"], "ip": r["ip"], "proto": r["proto"],
        "ts": r["ts_ms"], "time_str": r["time_str"],
    } for r in rows]
    return {"total": total, "rows": result_rows}


def purge_before(cutoff_date_str: str) -> int:
    """刪除 date_str < cutoff 的記錄，回傳刪除筆數。"""
    with _conn() as conn:
        cur = conn.execute("DELETE FROM reg_log WHERE date_str < ?", (cutoff_date_str,))
        return cur.rowcount
REGLOGDB_EOF
echo "✅ 已建立 core/reg_log_db.py"

# ── 3. 既有檔案精確字串取代（全部驗證通過才會實際寫入任何一個檔案）──────────
python3 << 'PYEOF'
import sys

# 每筆：(檔案路徑, 舊字串, 新字串, 說明)
edits = []

# --- core/state.py：移除記憶體 reg_log / REG_LOG_MAX ---
edits.append(("core/state.py",
"""# Registration history log（最新事件在陣列尾端）
reg_log: list = []
REG_LOG_MAX = 500

# SSE log injection：每個連線 /api/logs/stream 的客戶端一個 Queue""",
"""# SSE log injection：每個連線 /api/logs/stream 的客戶端一個 Queue""",
"state.py：移除 reg_log/REG_LOG_MAX"))

# --- core/runtime.py：import reg_log_db ---
edits.append(("core/runtime.py",
"""from core import state
from core import cdr_db""",
"""from core import state
from core import cdr_db
from core import reg_log_db""",
"runtime.py：新增 reg_log_db import"))

# --- core/runtime.py：write_reg_log() 改寫進 SQLite ---
edits.append(("core/runtime.py",
'''def write_reg_log(ext: str, event: str, ip: str, proto: str, ts_ms: int):
    """Write registration event to in-memory log (max REG_LOG_MAX entries)"""
    import datetime as _dt
    time_str = _dt.datetime.fromtimestamp(ts_ms / 1000).strftime('%Y-%m-%d %H:%M:%S')
    entry = {
        "ext":       ext,
        "event":     event,
        "ip":        ip,
        "proto":     proto.upper() if proto else "UDP",
        "ts":        ts_ms,
        "time_str":  time_str,
    }
    state.reg_log.append(entry)
    if len(state.reg_log) > state.REG_LOG_MAX:
        state.reg_log.pop(0)
    print(f"[REG_LOG] {event} ext={ext} ip={ip} at {time_str}")''',
'''def write_reg_log(ext: str, event: str, ip: str, proto: str, ts_ms: int):
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
    print(f"[REG_LOG] {event} ext={ext} ip={ip} at {time_str}")''',
"runtime.py：write_reg_log 改寫進 SQLite"))

# --- core/runtime.py：load_server_settings 預設值新增 reg_log_retain_days ---
edits.append(("core/runtime.py",
'''    defaults = {
        "log_retain_days": 30,
        "cdr_retain_days": 30,
        "cdr_summary_retain_days": 730,   # 每日彙總（SQLite）長期保留天數，與 raw 明細分開計算
    }''',
'''    defaults = {
        "log_retain_days": 30,
        "cdr_retain_days": 30,
        "cdr_summary_retain_days": 730,   # 每日彙總（SQLite）長期保留天數，與 raw 明細分開計算
        "reg_log_retain_days": 90,        # 登錄記錄（reg_log，SQLite）保留天數，2026-07-15 起持久化
    }''',
"runtime.py：settings 預設值新增 reg_log_retain_days"))

# --- core/runtime.py：新增 _cleanup_old_reg_logs() ---
edits.append(("core/runtime.py",
'''    return deleted


async def log_rotate_scheduler():''',
'''    return deleted


def _cleanup_old_reg_logs():
    """刪除超過保留天數的登錄記錄（SQLite，2026-07-15 起持久化）"""
    settings = load_server_settings()
    retain_days = int(settings.get("reg_log_retain_days", 90))
    cutoff_str = (datetime.now() - timedelta(days=retain_days)).strftime("%Y-%m-%d")
    try:
        purged = reg_log_db.purge_before(cutoff_str)
        if purged:
            print(f"[reg-log-cleanup] 已清除 {purged} 筆（早於 {cutoff_str}）")
        return purged
    except Exception as e:
        print(f"[reg-log-cleanup] 清理失敗：{e}")
        return 0


async def log_rotate_scheduler():''',
"runtime.py：新增 _cleanup_old_reg_logs()"))

# --- core/runtime.py：排程呼叫清理 ---
edits.append(("core/runtime.py",
'''            print(f"[cdr-rotate] {_rotate_cdr_now()}")
            _cleanup_old_cdrs()
            cleanup_old_backups()''',
'''            print(f"[cdr-rotate] {_rotate_cdr_now()}")
            _cleanup_old_cdrs()
            _cleanup_old_reg_logs()
            cleanup_old_backups()''',
"runtime.py：排程掛勾 _cleanup_old_reg_logs()"))

# --- server.py：import reg_log_db ---
edits.append(("server.py",
'''from core.esl_client import esl
from core import state, auth_db''',
'''from core.esl_client import esl
from core import state, auth_db
from core import reg_log_db''',
"server.py：新增 reg_log_db import"))

# --- server.py：lifespan 建表 ---
edits.append(("server.py",
'''    auth_db.init_db()
    # 啟動前先載入持久化的 ESL 連線設定（若有）''',
'''    auth_db.init_db()
    # 登錄記錄（reg_log）SQLite 建表，2026-07-15 起持久化，取代原本的記憶體 list
    reg_log_db.init_db()
    # 啟動前先載入持久化的 ESL 連線設定（若有）''',
"server.py：lifespan 呼叫 reg_log_db.init_db()"))

# --- routers/calls.py：import reg_log_db ---
edits.append(("routers/calls.py",
'''from core.esl_client import esl
from core import state
from core.auth import require_permission, get_current_user, apply_scope
from core.permissions import Module''',
'''from core.esl_client import esl
from core import state
from core import reg_log_db
from core.auth import require_permission, get_current_user, apply_scope
from core.permissions import Module''',
"calls.py：新增 reg_log_db import"))

# --- routers/calls.py：/api/reg/log 端點改寫 ---
edits.append(("routers/calls.py",
'''@router.get("/api/reg/log", dependencies=[Depends(require_permission(Module.CALLS, "read"))])
def get_reg_log(limit: int = Query(default=200, ge=1, le=500)):
    """Return registration history log (newest first)"""
    return {"logs": list(reversed(state.reg_log[-limit:])), "total": len(state.reg_log)}''',
'''@router.get("/api/reg/log", dependencies=[Depends(require_permission(Module.CALLS, "read"))])
def get_reg_log(
    date_from: str = Query(default=None, description="\u8d77\u59cb\u65e5\u671f YYYY-MM-DD"),
    date_to:   str = Query(default=None, description="\u7d50\u675f\u65e5\u671f YYYY-MM-DD"),
    ext:       str = Query(default=None, description="\u4f9d\u5206\u6a5f\u7be9\u9078"),
    event:     str = Query(default=None, description="REGISTER / UNREGISTER"),
    page:      int = Query(default=1, ge=1),
    per_page:  int = Query(default=200, ge=1, le=1000),
    user: dict = Depends(get_current_user),
):
    """
    \u767b\u9304\u8a18\u9304\u67e5\u8a62\uff08SQLite \u6301\u4e45\u5316\uff0c2026-07-15 \u8d77\u53d6\u4ee3\u8a18\u61b6\u9ad4 list\uff0c\u898b core/reg_log_db.py\uff09\u3002
    """
    if user["scope"] == "own":
        ext = apply_scope(user, ext, Module.CALLS)
    offset = (page - 1) * per_page
    result = reg_log_db.query_logs(
        date_from=date_from, date_to=date_to, ext=ext, event=event,
        limit=per_page, offset=offset,
    )
    total = result["total"]
    total_pages = max(1, (total + per_page - 1) // per_page)
    return {
        "total": total, "page": page, "per_page": per_page,
        "total_pages": total_pages, "rows": result["rows"],
    }''',
"calls.py：/api/reg/log 改查 SQLite + 分頁/篩選"))

# --- static/js/settings-vars.js：SETTINGS_DEFAULTS ---
edits.append(("static/js/settings-vars.js",
'''  cdr_summary_retain_days: '730',
  log_retain_days:     '30',''',
'''  cdr_summary_retain_days: '730',
  log_retain_days:     '30',
  reg_log_retain_days: '90',''',
"settings-vars.js：SETTINGS_DEFAULTS 新增 reg_log_retain_days"))

# --- static/js/settings-vars.js：POST /api/settings body ---
edits.append(("static/js/settings-vars.js",
'''      log_retain_days:     parseInt(cfg.log_retain_days)     || 30,
      cdr_retain_days:     parseInt(cfg.cdr_retain_days)     || 30,''',
'''      log_retain_days:     parseInt(cfg.log_retain_days)     || 30,
      reg_log_retain_days: parseInt(cfg.reg_log_retain_days) || 90,
      cdr_retain_days:     parseInt(cfg.cdr_retain_days)     || 30,''',
"settings-vars.js：POST body 新增 reg_log_retain_days"))

# --- static/js/settings-vars.js：設定頁 UI ---
edits.append(("static/js/settings-vars.js",
'''        <div class="settings-row">
          <span class="settings-label">\u65e5\u8a8c\u4fdd\u7559\u5929\u6578</span>
          <input class="settings-input" data-setting="log_retain_days" type="number"
            value="${cfg.log_retain_days}" min="1" max="365" style="max-width:80px" />
          <span style="font-size:12px;color:var(--muted)">\u5929\uff08\u6bcf\u65e5 00:00 \u81ea\u52d5\u522a\u9664\u8d85\u904e\u5929\u6578\u7684\u65e5\u8a8c\uff09</span>
        </div>
        <div class="settings-hint">
          \u7cfb\u7d71\u6bcf\u65e5 <strong>00:00:30</strong> \u81ea\u52d5\u6b78\u6a94\u65e5\u8a8c\u4e26\u6e05\u9664\u8d85\u904e\u4fdd\u7559\u5929\u6578\u7684\u820a\u6a94\u3002<br>
          \u65e5\u8a8c\u5b58\u653e\u65bc <code>/var/log/freeswitch/freeswitch-YYYY-MM-DD.log</code>
        </div>''',
'''        <div class="settings-row">
          <span class="settings-label">\u65e5\u8a8c\u4fdd\u7559\u5929\u6578</span>
          <input class="settings-input" data-setting="log_retain_days" type="number"
            value="${cfg.log_retain_days}" min="1" max="365" style="max-width:80px" />
          <span style="font-size:12px;color:var(--muted)">\u5929\uff08\u6bcf\u65e5 00:00 \u81ea\u52d5\u522a\u9664\u8d85\u904e\u5929\u6578\u7684\u65e5\u8a8c\uff09</span>
        </div>
        <div class="settings-row">
          <span class="settings-label">\u767b\u9304\u8a18\u9304\u4fdd\u7559\u5929\u6578</span>
          <input class="settings-input" data-setting="reg_log_retain_days" type="number"
            value="${cfg.reg_log_retain_days}" min="1" max="3650" style="max-width:80px" />
          <span style="font-size:12px;color:var(--muted)">\u5929\uff08\u5206\u6a5f\u767b\u5165/\u767b\u51fa\u8a18\u9304\uff0c2026-07-15 \u8d77\u6539\u7528 SQLite \u6301\u4e45\u5316\uff09</span>
        </div>
        <div class="settings-hint">
          \u7cfb\u7d71\u6bcf\u65e5 <strong>00:00:30</strong> \u81ea\u52d5\u6b78\u6a94\u65e5\u8a8c\u4e26\u6e05\u9664\u8d85\u904e\u4fdd\u7559\u5929\u6578\u7684\u820a\u6a94\u3002<br>
          \u65e5\u8a8c\u5b58\u653e\u65bc <code>/var/log/freeswitch/freeswitch-YYYY-MM-DD.log</code>
        </div>''',
"settings-vars.js：log_retain 分頁新增登錄記錄保留天數列"))

# --- static/js/logs.js：登錄記錄 Tab HTML（加篩選列 + 分頁）---
edits.append(("static/js/logs.js",
'''    <!-- \u2500\u2500 Tab: \u767b\u9304\u8a18\u9304 \u2500\u2500 -->
    <div id="log-pane-reg" style="display:none;flex-direction:column;gap:12px;flex:1;min-height:0">
      <div class="panel" style="flex:1;display:flex;flex-direction:column;min-height:0">
        <div class="panel-header">
          <span class="panel-title">\u5206\u6a5f\u767b\u9304 / \u767b\u51fa\u8a18\u9304</span>
          <span class="panel-badge" id="reg-log-badge">\u8f09\u5165\u4e2d...</span>
          <div class="panel-actions">
            <button class="btn" onclick="loadRegLog()">\u21ba \u5237\u65b0</button>
          </div>
        </div>
        <div style="overflow-y:auto;flex:1;min-height:0" id="reg-log-body">
          <div style="padding:40px;text-align:center;color:var(--muted)">\u8f09\u5165\u4e2d...</div>
        </div>
      </div>
    </div>''',
'''    <!-- \u2500\u2500 Tab: \u767b\u9304\u8a18\u9304 \u2500\u2500 -->
    <div id="log-pane-reg" style="display:none;flex-direction:column;gap:12px;flex:1;min-height:0">

      <!-- \u67e5\u8a62\u5217 -->
      <div class="panel" style="padding:14px 16px">
        <div style="display:flex;align-items:center;gap:10px;flex-wrap:wrap">
          <label style="font-weight:600;color:var(--label);white-space:nowrap">\u8d77\u59cb\u65e5\u671f\uff1a</label>
          <input id="reg-date-from" type="date"
            style="padding:6px 10px;border:1px solid var(--border);border-radius:6px;
              background:var(--panel2);color:var(--text);font-family:inherit;font-size:13px">

          <label style="font-weight:600;color:var(--label);white-space:nowrap">\u7d50\u675f\u65e5\u671f\uff1a</label>
          <input id="reg-date-to" type="date"
            style="padding:6px 10px;border:1px solid var(--border);border-radius:6px;
              background:var(--panel2);color:var(--text);font-family:inherit;font-size:13px">

          <label style="font-weight:600;color:var(--label);white-space:nowrap">\u5206\u6a5f\uff1a</label>
          <input id="reg-ext-filter" type="text" placeholder="\u4f8b\u5982 1126"
            style="padding:6px 10px;border:1px solid var(--border);border-radius:6px;
              background:var(--panel2);color:var(--text);font-family:inherit;font-size:13px;min-width:100px"
            onkeydown="if(event.key==='Enter') loadRegLog(1)">

          <label style="font-weight:600;color:var(--label);white-space:nowrap">\u4e8b\u4ef6\uff1a</label>
          <select id="reg-event-filter" style="padding:6px 10px;border:1px solid var(--border);border-radius:6px;
            background:var(--panel2);color:var(--text);font-family:inherit;font-size:13px">
            <option value="">\u5168\u90e8</option>
            <option value="REGISTER">\u767b\u9304</option>
            <option value="UNREGISTER">\u767b\u51fa</option>
          </select>

          <button class="btn primary" onclick="loadRegLog(1)">\U0001F50D \u67e5\u8a62</button>
          <button class="btn" onclick="resetRegLogFilter()">\u21ba \u6e05\u9664\u7be9\u9078</button>
        </div>
      </div>

      <div class="panel" style="flex:1;display:flex;flex-direction:column;min-height:0">
        <div class="panel-header">
          <span class="panel-title">\u5206\u6a5f\u767b\u9304 / \u767b\u51fa\u8a18\u9304</span>
          <span class="panel-badge" id="reg-log-badge">\u8f09\u5165\u4e2d...</span>
          <div class="panel-actions" id="reg-pager" style="display:none;align-items:center;gap:6px">
            <button class="btn" id="reg-prev" onclick="regPageGo(-1)">\u25c0 \u4e0a\u4e00\u9801</button>
            <span id="reg-page-label" style="font-size:12px;color:var(--muted)">1 / 1</span>
            <button class="btn" id="reg-next" onclick="regPageGo(1)">\u4e0b\u4e00\u9801 \u25b6</button>
          </div>
        </div>
        <div style="overflow-y:auto;flex:1;min-height:0" id="reg-log-body">
          <div style="padding:40px;text-align:center;color:var(--muted)">\u8f09\u5165\u4e2d...</div>
        </div>
      </div>
    </div>''',
"logs.js：登錄記錄 Tab 加篩選列與分頁 UI"))

# --- static/js/logs.js：loadRegLog() 改讀新回應格式 + 分頁 ---
edits.append(("static/js/logs.js",
'''async function loadRegLog() {
  const body  = document.getElementById('reg-log-body');
  const badge = document.getElementById('reg-log-badge');
  if (!body) return;
  body.innerHTML = '<div style="padding:24px;text-align:center;color:var(--muted)">\u8f09\u5165\u4e2d...</div>';
  try {
    const data = await apiFetch('/api/reg/log');
    const logs = (data && data.logs) ? data.logs : [];
    if (badge) badge.textContent = `\u5171 ${data.total || 0} \u7b46`;
    if (!logs.length) {
      body.innerHTML = '<div style="padding:40px;text-align:center;color:var(--muted)">\u5c1a\u7121\u767b\u9304\u8a18\u9304\uff08\u5206\u6a5f\u767b\u5165/\u767b\u51fa\u5f8c\u6703\u81ea\u52d5\u8a18\u9304\uff09</div>';
      return;
    }
    const rows = logs.map(r => {
      const isReg = r.event === 'REGISTER';
      const dotColor = isReg ? 'var(--green)' : 'var(--muted)';
      const label    = isReg ? '\u767b\u9304' : '\u767b\u51fa';
      const labelColor = isReg ? 'var(--green)' : 'var(--red)';
      return `<tr>
        <td style="font-size:12px;color:var(--muted);white-space:nowrap">${r.time_str}</td>
        <td style="font-weight:700;color:var(--accent-bright)">${r.ext}</td>
        <td>
          <span style="display:inline-flex;align-items:center;gap:5px">
            <span style="width:7px;height:7px;border-radius:50%;background:${dotColor};display:inline-block"></span>
            <span style="color:${labelColor};font-weight:600">${label}</span>
          </span>
        </td>
        <td style="font-size:12px;color:var(--muted)">${r.ip || '\u2014'}</td>
        <td style="font-size:12px;color:var(--muted)">${r.proto || '\u2014'}</td>
      </tr>`;
    }).join('');
    body.innerHTML = `
      <table style="width:100%">
        <thead>
          <tr>
            <th style="text-align:left;padding:8px 12px;font-size:12px;color:var(--label);border-bottom:1px solid var(--border)">\u6642\u9593</th>
            <th style="text-align:left;padding:8px 12px;font-size:12px;color:var(--label);border-bottom:1px solid var(--border)">\u5206\u6a5f</th>
            <th style="text-align:left;padding:8px 12px;font-size:12px;color:var(--label);border-bottom:1px solid var(--border)">\u4e8b\u4ef6</th>
            <th style="text-align:left;padding:8px 12px;font-size:12px;color:var(--label);border-bottom:1px solid var(--border)">IP</th>
            <th style="text-align:left;padding:8px 12px;font-size:12px;color:var(--label);border-bottom:1px solid var(--border)">\u5354\u5b9a</th>
          </tr>
        </thead>
        <tbody>${rows}</tbody>
      </table>`;
  } catch(e) {
    body.innerHTML = `<div style="padding:24px;color:var(--red)">\u8f09\u5165\u5931\u6557\uff1a${e.message}</div>`;
  }
}''',
'''let _regPage = 1;
let _regPerPage = 200;
let _regTotalPages = 1;

async function loadRegLog(page) {
  if (page) _regPage = page;
  const body  = document.getElementById('reg-log-body');
  const badge = document.getElementById('reg-log-badge');
  const pager = document.getElementById('reg-pager');
  if (!body) return;
  body.innerHTML = '<div style="padding:24px;text-align:center;color:var(--muted)">\u8f09\u5165\u4e2d...</div>';

  const dateFromEl = document.getElementById('reg-date-from');
  const dateToEl   = document.getElementById('reg-date-to');
  const extEl      = document.getElementById('reg-ext-filter');
  const eventEl    = document.getElementById('reg-event-filter');
  const dateFrom = dateFromEl ? dateFromEl.value : '';
  const dateTo   = dateToEl   ? dateToEl.value   : '';
  const ext      = extEl      ? extEl.value.trim() : '';
  const eventVal = eventEl    ? eventEl.value : '';

  const params = new URLSearchParams({ page: _regPage, per_page: _regPerPage });
  if (dateFrom) params.set('date_from', dateFrom);
  if (dateTo)   params.set('date_to', dateTo);
  if (ext)      params.set('ext', ext);
  if (eventVal) params.set('event', eventVal);

  try {
    const data = await apiFetch(`/api/reg/log?${params.toString()}`);
    const logs = (data && data.rows) ? data.rows : [];
    _regTotalPages = data.total_pages || 1;
    if (badge) badge.textContent = `\u5171 ${data.total || 0} \u7b46`;
    if (pager) {
      pager.style.display = _regTotalPages > 1 ? 'flex' : 'none';
      const label   = document.getElementById('reg-page-label');
      const prevBtn = document.getElementById('reg-prev');
      const nextBtn = document.getElementById('reg-next');
      if (label)   label.textContent = `${_regPage} / ${_regTotalPages}`;
      if (prevBtn) prevBtn.disabled = _regPage <= 1;
      if (nextBtn) nextBtn.disabled = _regPage >= _regTotalPages;
    }
    if (!logs.length) {
      body.innerHTML = '<div style="padding:40px;text-align:center;color:var(--muted)">\u5c1a\u7121\u767b\u9304\u8a18\u9304\uff08\u5206\u6a5f\u767b\u5165/\u767b\u51fa\u5f8c\u6703\u81ea\u52d5\u8a18\u9304\uff0c\u6216\u7be9\u9078\u689d\u4ef6\u7121\u7b26\u5408\u8cc7\u6599\uff09</div>';
      return;
    }
    const rows = logs.map(r => {
      const isReg = r.event === 'REGISTER';
      const dotColor = isReg ? 'var(--green)' : 'var(--muted)';
      const label    = isReg ? '\u767b\u9304' : '\u767b\u51fa';
      const labelColor = isReg ? 'var(--green)' : 'var(--red)';
      return `<tr>
        <td style="font-size:12px;color:var(--muted);white-space:nowrap">${r.time_str}</td>
        <td style="font-weight:700;color:var(--accent-bright)">${r.ext}</td>
        <td>
          <span style="display:inline-flex;align-items:center;gap:5px">
            <span style="width:7px;height:7px;border-radius:50%;background:${dotColor};display:inline-block"></span>
            <span style="color:${labelColor};font-weight:600">${label}</span>
          </span>
        </td>
        <td style="font-size:12px;color:var(--muted)">${r.ip || '\u2014'}</td>
        <td style="font-size:12px;color:var(--muted)">${r.proto || '\u2014'}</td>
      </tr>`;
    }).join('');
    body.innerHTML = `
      <table style="width:100%">
        <thead>
          <tr>
            <th style="text-align:left;padding:8px 12px;font-size:12px;color:var(--label);border-bottom:1px solid var(--border)">\u6642\u9593</th>
            <th style="text-align:left;padding:8px 12px;font-size:12px;color:var(--label);border-bottom:1px solid var(--border)">\u5206\u6a5f</th>
            <th style="text-align:left;padding:8px 12px;font-size:12px;color:var(--label);border-bottom:1px solid var(--border)">\u4e8b\u4ef6</th>
            <th style="text-align:left;padding:8px 12px;font-size:12px;color:var(--label);border-bottom:1px solid var(--border)">IP</th>
            <th style="text-align:left;padding:8px 12px;font-size:12px;color:var(--label);border-bottom:1px solid var(--border)">\u5354\u5b9a</th>
          </tr>
        </thead>
        <tbody>${rows}</tbody>
      </table>`;
  } catch(e) {
    body.innerHTML = `<div style="padding:24px;color:var(--red)">\u8f09\u5165\u5931\u6557\uff1a${e.message}</div>`;
  }
}

function regPageGo(delta) {
  const next = _regPage + delta;
  if (next < 1 || next > _regTotalPages) return;
  loadRegLog(next);
}

function resetRegLogFilter() {
  ['reg-date-from', 'reg-date-to', 'reg-ext-filter', 'reg-event-filter'].forEach(id => {
    const el = document.getElementById(id);
    if (el) el.value = '';
  });
  loadRegLog(1);
}''',
"logs.js：loadRegLog() 改讀新格式 + 分頁/篩選函式"))

# ── 全部驗證：每個 old 字串都必須「剛好出現 1 次」，否則整支中止 ──────────────
file_cache = {}
errors = []
for path, old, new, desc in edits:
    if path not in file_cache:
        try:
            with open(path, "r", encoding="utf-8") as f:
                file_cache[path] = f.read()
        except FileNotFoundError:
            errors.append(f"❌ 找不到檔案：{path}（{desc}）")
            continue
    count = file_cache[path].count(old)
    if count != 1:
        errors.append(f"❌ [{desc}] 在 {path} 中比對到 {count} 次（預期 1 次），中止")

if errors:
    for e in errors:
        print(e, file=sys.stderr)
    print("\n未寫入任何檔案，請確認上述比對失敗項目後再重試。", file=sys.stderr)
    sys.exit(1)

# 驗證全過，實際套用（同一檔案的多筆 edit 依序疊加套用）
applied_content = dict(file_cache)
for path, old, new, desc in edits:
    applied_content[path] = applied_content[path].replace(old, new, 1)
    print(f"✅ {desc}")

for path, content in applied_content.items():
    with open(path, "w", encoding="utf-8") as f:
        f.write(content)

print("\n✅ 所有精確字串取代完成")
PYEOF

# ── 4. Commit（只 add 本次實際改動的檔案）───────────────────────────────────
git add core/reg_log_db.py core/state.py core/runtime.py server.py \
        routers/calls.py static/js/settings-vars.js static/js/logs.js

git commit -m "feat: 登錄記錄(reg_log) SQLite 持久化，取代記憶體 list

- 新增 core/reg_log_db.py（SQLite 儲存層，沿用 cdr_db.py 的 _conn() pattern）
- core/state.py 移除 reg_log/REG_LOG_MAX 記憶體 list
- core/runtime.py：write_reg_log() 改寫進 SQLite；新增 reg_log_retain_days
  設定（預設 90 天）+ 每日 00:00:30 排程自動清理
- server.py：lifespan 新增 reg_log_db.init_db() 建表
- routers/calls.py：GET /api/reg/log 改查 SQLite，擴充分頁 + 日期/分機/事件
  篩選，回應格式改為 {total, page, per_page, total_pages, rows}，並套用
  scope=own 權限限制（比照 get_calls()）
- static/js：設定頁新增登錄記錄保留天數欄位；登錄記錄 Tab 加篩選列與分頁 UI"

echo ""
echo "=== 最新 commit ==="
git log --oneline -1

cat << 'CHECKLIST'

=== 驗證重點清單 ===
1. pip install -r requirements.txt --break-system-packages（本次無新套件依賴，但仍建議跑一次確認環境一致）
2. python3 -m py_compile core/reg_log_db.py core/runtime.py core/state.py server.py routers/calls.py
3. node --check static/js/settings-vars.js static/js/logs.js
4. sudo systemctl restart fs-dashboard
5. journalctl -u fs-dashboard -f
   - 確認無 import 錯誤 / 500
   - 分機登入/登出後應看到 [REG_LOG] ... 且無 "SQLite 寫入失敗"
6. ls -la /opt/fs-dashboard/data/reg_log.db   # 確認資料庫檔案已建立
7. 瀏覽器開「系統 → 系統日誌 → 🔐 登錄記錄」Tab：
   - 分機登入/登出後記錄即時出現
   - 篩選（日期/分機/事件）與分頁功能正常
   - 重啟服務後（第 4 步）記錄仍在，不再歸零 ← 本次功能的核心驗證點
8. 設定頁「日誌保留設定」：確認可看到並儲存「登錄記錄保留天數」欄位
9. sqlite3 /opt/fs-dashboard/data/reg_log.db "SELECT COUNT(*) FROM reg_log;"
CHECKLIST
