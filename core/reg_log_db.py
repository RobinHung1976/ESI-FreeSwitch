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
