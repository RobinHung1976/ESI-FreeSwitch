"""
core/cdr_db.py — CDR SQLite 儲存層：取代逐日 CSV 全量掃描。

架構（兩層保留策略）：
- cdr                 原始通話明細（依 cdr_retain_days 保留，短期，供逐通明細/未接通清單使用）
- cdr_daily_summary   每日彙總統計（依 cdr_summary_retain_days 保留，長期，供長區間報表使用）

寫入來源：FreeSwitch mod_cdr_csv 持續寫入 Master.csv，本模組負責把
Master.csv／已歸檔的 cdr-YYYY-MM-DD.csv 同步（INSERT OR IGNORE，以 uuid 去重）進 SQLite。
"""
import os
import csv
import json
import sqlite3
from collections import defaultdict
from datetime import datetime, timedelta
from contextlib import contextmanager

DB_DIR  = "/opt/fs-dashboard/data"
DB_PATH = os.path.join(DB_DIR, "cdr.db")


# ── 共用邏輯（與前端 cdr.js / 原本 routers/cdr.py 保持一致）──────────────────────

def _cdr_direction(context: str, caller_num: str, destination: str) -> str:
    """判斷通話方向：inbound / outbound / internal"""
    ctx = (context or "").strip().lower()
    if ctx == "public":
        return "inbound"
    caller_is_ext = bool(caller_num and len(caller_num) <= 4 and caller_num.isdigit())
    dest_is_ext   = bool(destination and len(destination) <= 4 and destination.isdigit())
    if caller_is_ext and dest_is_ext:
        return "internal"
    if caller_is_ext:
        return "outbound"
    return "inbound"


def _cdr_status_label(hangup_cause: str, billsec: int) -> str:
    """對應前端 cdr.js::cdrStatus() 的分類邏輯，確保新舊資料統計口徑一致"""
    cause = hangup_cause or ""
    if cause in ("NORMAL_CLEARING", "NORMAL_UNSPECIFIED"):
        return "ANSWERED" if billsec > 0 else "NO_ANSWER"
    if cause in ("ORIGINATOR_CANCEL", "NO_ANSWER"):
        return "NO_ANSWER"
    if cause == "USER_BUSY":
        return "BUSY"
    return "OTHER"


# ── 連線 ──────────────────────────────────────────────────────────────────────

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
            CREATE TABLE IF NOT EXISTS cdr (
                uuid          TEXT PRIMARY KEY,
                caller_num    TEXT,
                destination   TEXT,
                context       TEXT,
                direction     TEXT,
                created       TEXT NOT NULL,
                created_date  TEXT NOT NULL,
                answered      TEXT,
                ended         TEXT,
                duration      INTEGER DEFAULT 0,
                billsec       INTEGER DEFAULT 0,
                hangup_cause  TEXT,
                read_codec    TEXT,
                write_codec   TEXT
            )
        """)
        conn.execute("CREATE INDEX IF NOT EXISTS idx_cdr_date ON cdr(created_date)")
        conn.execute("CREATE INDEX IF NOT EXISTS idx_cdr_caller ON cdr(caller_num)")
        conn.execute("CREATE INDEX IF NOT EXISTS idx_cdr_dest ON cdr(destination)")
        conn.execute("""
            CREATE TABLE IF NOT EXISTS cdr_daily_summary (
                date              TEXT PRIMARY KEY,
                total             INTEGER DEFAULT 0,
                answered          INTEGER DEFAULT 0,
                no_answer         INTEGER DEFAULT 0,
                busy              INTEGER DEFAULT 0,
                answered_duration INTEGER DEFAULT 0,
                hourly_json       TEXT,
                top_users_json    TEXT,
                built_at          TEXT
            )
        """)


# ── CSV 解析 / 匯入 ────────────────────────────────────────────────────────────

def _parse_csv_rows(csv_path: str) -> list:
    """解析單一 CDR CSV 檔（Master.csv 或歸檔檔），回傳 dict list。壞行直接跳過。"""
    rows = []
    try:
        with open(csv_path, "r", encoding="utf-8") as f:
            reader = csv.reader(f)
            for row in reader:
                if len(row) < 15:
                    continue
                caller_num  = row[1].strip()
                destination = row[2].strip()
                context     = row[3].strip()
                created     = row[4].strip()
                uuid        = row[10].strip()
                if not uuid or not created:
                    continue
                rows.append({
                    "uuid":         uuid,
                    "caller_num":   caller_num,
                    "destination":  destination,
                    "context":      context,
                    "direction":    _cdr_direction(context, caller_num, destination),
                    "created":      created,
                    "created_date": created[:10],
                    "answered":     row[5].strip(),
                    "ended":        row[6].strip(),
                    "duration":     int(row[7]) if row[7].strip().isdigit() else 0,
                    "billsec":      int(row[8]) if row[8].strip().isdigit() else 0,
                    "hangup_cause": row[9].strip(),
                    "read_codec":   row[13].strip() if len(row) > 13 else "",
                    "write_codec":  row[14].strip() if len(row) > 14 else "",
                })
    except FileNotFoundError:
        pass
    return rows


def import_csv_file(csv_path: str) -> int:
    """把單一 CSV 檔的內容 upsert 進 cdr table（以 uuid 去重），回傳實際新增筆數。"""
    rows = _parse_csv_rows(csv_path)
    if not rows:
        return 0
    with _conn() as conn:
        before_total = conn.total_changes
        conn.executemany("""
            INSERT OR IGNORE INTO cdr
                (uuid, caller_num, destination, context, direction, created, created_date,
                 answered, ended, duration, billsec, hangup_cause, read_codec, write_codec)
            VALUES (:uuid,:caller_num,:destination,:context,:direction,:created,:created_date,
                    :answered,:ended,:duration,:billsec,:hangup_cause,:read_codec,:write_codec)
        """, rows)
        inserted = conn.total_changes - before_total
    return inserted


def sync_today(master_csv_path: str) -> int:
    """把今天的 Master.csv 內容同步進 DB（增量、冪等）。供 /api/cdr* 每次請求時呼叫。"""
    return import_csv_file(master_csv_path)


# ── 每日彙總 ──────────────────────────────────────────────────────────────────

def build_daily_summary(date_str: str) -> dict:
    """依 cdr table 內指定日期的資料，計算並寫入 cdr_daily_summary（存在則覆蓋）。
    通常在該日 CDR 歸檔（rotate）時呼叫一次，之後即可安全 purge 該日的 raw 明細。
    """
    with _conn() as conn:
        rows = conn.execute(
            "SELECT caller_num, destination, direction, billsec, hangup_cause, created "
            "FROM cdr WHERE created_date = ?", (date_str,)
        ).fetchall()

    user_stats = defaultdict(lambda: {
        "total": 0, "answered": 0, "no_answer": 0,
        "total_duration": 0, "outbound": 0, "inbound": 0, "internal": 0
    })
    hourly = defaultdict(int)
    total = answered = no_answer = busy = answered_duration = 0

    for r in rows:
        total += 1
        billsec = r["billsec"] or 0
        s = user_stats[r["caller_num"]]
        s["total"] += 1
        s["total_duration"] += billsec

        label = _cdr_status_label(r["hangup_cause"], billsec)
        if label == "ANSWERED":
            answered += 1
            answered_duration += billsec
            s["answered"] += 1
        else:
            no_answer_delta = 1 if label != "BUSY" else 0  # BUSY 另計，不重複算進 no_answer
            no_answer += no_answer_delta
            if label == "BUSY":
                busy += 1
            s["no_answer"] += 1  # user_stats 沿用原本 stats API 的口徑（BUSY 也算未接通）

        d = r["direction"]
        if d == "outbound":   s["outbound"] += 1
        elif d == "inbound":  s["inbound"]  += 1
        else:                 s["internal"] += 1

        try:
            hour = int(r["created"].split(" ")[1].split(":")[0])
            hourly[hour] += 1
        except Exception:
            pass

    hourly_full = [{"hour": h, "count": hourly.get(h, 0)} for h in range(24)]
    top_users = sorted(
        [{"num": k, **v} for k, v in user_stats.items()],
        key=lambda x: x["total"], reverse=True
    )[:10]

    with _conn() as conn:
        conn.execute("""
            INSERT INTO cdr_daily_summary
                (date, total, answered, no_answer, busy, answered_duration, hourly_json, top_users_json, built_at)
            VALUES (?,?,?,?,?,?,?,?,?)
            ON CONFLICT(date) DO UPDATE SET
                total=excluded.total, answered=excluded.answered, no_answer=excluded.no_answer,
                busy=excluded.busy, answered_duration=excluded.answered_duration,
                hourly_json=excluded.hourly_json, top_users_json=excluded.top_users_json,
                built_at=excluded.built_at
        """, (date_str, total, answered, no_answer, busy, answered_duration,
              json.dumps(hourly_full), json.dumps(top_users), datetime.now().isoformat()))

    return {
        "date": date_str, "total": total, "answered": answered, "no_answer": no_answer,
        "busy": busy, "answered_duration": answered_duration,
        "hourly": hourly_full, "top_users": top_users,
    }


def has_summary(date_str: str) -> bool:
    with _conn() as conn:
        row = conn.execute("SELECT 1 FROM cdr_daily_summary WHERE date = ?", (date_str,)).fetchone()
    return row is not None


# ── 清理（兩層保留策略）─────────────────────────────────────────────────────────

def purge_raw_before(cutoff_date_str: str) -> int:
    """刪除 cdr table 中 created_date < cutoff 的明細列。呼叫前應確保該日 summary 已建立。"""
    with _conn() as conn:
        cur = conn.execute("DELETE FROM cdr WHERE created_date < ?", (cutoff_date_str,))
        return cur.rowcount


def purge_summary_before(cutoff_date_str: str) -> int:
    """刪除 cdr_daily_summary 中超過長期保留天數的彙總列（預設保留很久，通常不太會觸發）。"""
    with _conn() as conn:
        cur = conn.execute("DELETE FROM cdr_daily_summary WHERE date < ?", (cutoff_date_str,))
        return cur.rowcount


# ── 查詢：/api/cdr（明細列表）───────────────────────────────────────────────────

def query_rows(date_from: str = None, date_to: str = None, user: str = None,
               limit: int = 100, offset: int = 0) -> dict:
    """從 cdr table 查詢明細，僅涵蓋尚未被 purge 的保留期內資料（cdr_retain_days 內）。"""
    where, params = [], []
    if date_from:
        where.append("created_date >= ?"); params.append(date_from)
    if date_to:
        where.append("created_date <= ?"); params.append(date_to)
    if user:
        where.append("(caller_num = ? OR destination = ?)"); params.extend([user, user])
    where_sql = ("WHERE " + " AND ".join(where)) if where else ""

    with _conn() as conn:
        total = conn.execute(f"SELECT COUNT(*) FROM cdr {where_sql}", params).fetchone()[0]
        rows = conn.execute(
            f"SELECT * FROM cdr {where_sql} ORDER BY created DESC LIMIT ? OFFSET ?",
            params + [limit, offset]
        ).fetchall()

    result_rows = [{
        "caller_num": r["caller_num"], "destination": r["destination"], "context": r["context"],
        "direction": r["direction"], "created": r["created"], "answered": r["answered"],
        "ended": r["ended"], "duration": r["duration"], "billsec": r["billsec"],
        "hangup_cause": r["hangup_cause"], "uuid": r["uuid"],
        "read_codec": r["read_codec"], "write_codec": r["write_codec"],
    } for r in rows]
    return {"total": total, "rows": result_rows}


# ── 查詢：/api/cdr/stats（統計，raw + summary 混合）────────────────────────────

def query_stats(date_from: str, date_to: str, user: str = None) -> dict:
    """
    - 有 raw 明細的日期：從 cdr table 即時聚合（含精確 hourly、top_users、user 篩選）
    - raw 已被 purge 但 summary 仍在的日期：回退用 cdr_daily_summary
      （僅整體統計可用，無法依 user 篩選該日 hourly，因為明細已不在）
    """
    d_from = datetime.strptime(date_from, "%Y-%m-%d").date()
    d_end  = datetime.strptime(date_to,   "%Y-%m-%d").date()
    if d_end < d_from:
        d_from, d_end = d_end, d_from
    date_list = []
    cur = d_from
    while cur <= d_end:
        date_list.append(cur.strftime("%Y-%m-%d"))
        cur += timedelta(days=1)

    with _conn() as conn:
        raw_rows = conn.execute(
            "SELECT caller_num, destination, direction, billsec, hangup_cause, created, created_date "
            "FROM cdr WHERE created_date >= ? AND created_date <= ?",
            (date_list[0], date_list[-1])
        ).fetchall()

    dates_with_raw = {r["created_date"] for r in raw_rows}
    missing_dates  = [d for d in date_list if d not in dates_with_raw]

    user_stats = defaultdict(lambda: {
        "total": 0, "answered": 0, "no_answer": 0,
        "total_duration": 0, "outbound": 0, "inbound": 0, "internal": 0
    })
    daily_counts = defaultdict(int)   # date -> count（範圍模式圖表用）
    hourly_all   = defaultdict(int)   # (date, hour) -> count（單日模式圖表用）
    hourly_user  = defaultdict(int)
    total_calls = total_answered = total_no_answer = total_busy = total_answered_duration = 0

    for r in raw_rows:
        num, billsec = r["caller_num"], (r["billsec"] or 0)
        s = user_stats[num]
        s["total"] += 1
        s["total_duration"] += billsec

        label = _cdr_status_label(r["hangup_cause"], billsec)
        if label == "ANSWERED":
            total_answered += 1
            total_answered_duration += billsec
            s["answered"] += 1
        else:
            if label == "BUSY":
                total_busy += 1
            else:
                total_no_answer += 1
            s["no_answer"] += 1

        d = r["direction"]
        if d == "outbound":   s["outbound"] += 1
        elif d == "inbound":  s["inbound"]  += 1
        else:                 s["internal"] += 1

        total_calls += 1
        daily_counts[r["created_date"]] += 1
        try:
            hour = int(r["created"].split(" ")[1].split(":")[0])
            hourly_all[(r["created_date"], hour)] += 1
            if user and num == user:
                hourly_user[(r["created_date"], hour)] += 1
        except Exception:
            pass

    summary_fallback_used = False
    if missing_dates:
        with _conn() as conn:
            placeholders = ",".join("?" * len(missing_dates))
            srows = conn.execute(
                f"SELECT * FROM cdr_daily_summary WHERE date IN ({placeholders})",
                missing_dates
            ).fetchall()
        for sr in srows:
            summary_fallback_used = True
            total_calls             += sr["total"]
            total_answered          += sr["answered"]
            total_no_answer         += sr["no_answer"]
            total_busy              += sr["busy"]
            total_answered_duration += sr["answered_duration"]
            daily_counts[sr["date"]] += sr["total"]
            for h_entry in json.loads(sr["hourly_json"] or "[]"):
                hourly_all[(sr["date"], h_entry["hour"])] += h_entry["count"]
            for tu in json.loads(sr["top_users_json"] or "[]"):
                s = user_stats[tu["num"]]
                s["total"]          += tu["total"]
                s["answered"]       += tu["answered"]
                s["no_answer"]      += tu["no_answer"]
                s["total_duration"] += tu["total_duration"]
                s["outbound"]       += tu.get("outbound", 0)
                s["inbound"]        += tu.get("inbound", 0)
                s["internal"]       += tu.get("internal", 0)
            # summary 沒有逐通明細，user 篩選下該日 hourly 無法還原，維持 0（前端可由 fallback 提示告知）

    top_users = sorted(
        [{"num": k, **v} for k, v in user_stats.items()],
        key=lambda x: x["total"], reverse=True
    )[:10]
    all_users = sorted(
        [{"num": k, **v} for k, v in user_stats.items()],
        key=lambda x: x["total"], reverse=True
    )

    hourly_src = hourly_user if user else hourly_all
    is_range = (date_list[0] != date_list[-1])

    if is_range:
        hourly_full = [{"date": d, "hour": None, "count": daily_counts.get(d, 0)} for d in date_list]
    else:
        d0 = date_list[0]
        hourly_full = [{"date": d0, "hour": h, "count": hourly_src.get((d0, h), 0)} for h in range(24)]

    avg_duration_sec = round(total_answered_duration / total_answered) if total_answered > 0 else 0

    return {
        "date": date_list[0], "date_to": date_list[-1], "is_range": is_range,
        "total_calls": total_calls,
        "answered_total": total_answered, "no_answer_total": total_no_answer, "busy_total": total_busy,
        "avg_duration_sec": avg_duration_sec,
        "top_users": top_users, "hourly": hourly_full, "all_users": all_users,
        "summary_fallback_used": summary_fallback_used,
    }
