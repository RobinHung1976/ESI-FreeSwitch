"""
routers/recordings.py — 通話錄音管理（SQLite 索引 + mono 混音 + 串流播放）：/api/recordings*
"""
import os
import shutil
import sqlite3
import threading
import re as _re
from datetime import datetime
from fastapi import APIRouter, HTTPException, Query, Body, Depends
from fastapi.responses import FileResponse

from core.auth import require_permission, require_permission_media, get_current_user, apply_scope
from core.permissions import Module

router = APIRouter()


# ── 錄音管理 ────────────────────────────────────────────────────────────────────

RECORDINGS_DIR = "/var/lib/freeswitch/recordings"
REC_DB_PATH    = "/var/lib/freeswitch/recordings/.rec_index.db"
REC_MONO_DIR   = "/var/lib/freeswitch/recordings/.mono"
_AUDIO_EXTS    = {'.wav', '.mp3', '.ogg', '.gsm'}

_REC_FNAME_RE  = _re.compile(
    r'^(?P<caller>\+?\d+)_(?P<callee>\+?\d+)_(?P<date>\d{8})_(?P<time>\d{6})_(?P<uuid>[^.]+)\.\w+$'
)


def _merge_stereo_to_mono(src_path: str) -> str:
    """
    將立體聲 WAV 左右聲道平均混成 mono WAV（使用標準庫 wave + array，無需 ffmpeg）。
    輸出至 REC_MONO_DIR/{原檔名}_mono.wav。
    若已存在且來源未更新則直接回傳，避免重複處理。
    """
    import wave
    import array as _array
    os.makedirs(REC_MONO_DIR, exist_ok=True)
    out_name = os.path.splitext(os.path.basename(src_path))[0] + "_mono.wav"
    out_path = os.path.join(REC_MONO_DIR, out_name)

    if os.path.exists(out_path):
        if os.path.getmtime(out_path) >= os.path.getmtime(src_path):
            return out_path

    with wave.open(src_path, 'rb') as r:
        ch     = r.getnchannels()
        sw     = r.getsampwidth()
        fr     = r.getframerate()
        frames = r.readframes(r.getnframes())

    if ch == 1:
        import shutil as _sh
        _sh.copy2(src_path, out_path)
        return out_path

    if sw != 2:
        raise ValueError(f"不支援的 sample width: {sw} bytes（僅支援 16-bit WAV）")

    samps = _array.array('h', frames)
    mono  = _array.array('h', (
        (int(samps[i]) + int(samps[i + 1])) // 2
        for i in range(0, len(samps) - 1, 2)
    ))

    with wave.open(out_path, 'wb') as w:
        w.setnchannels(1)
        w.setsampwidth(sw)
        w.setframerate(fr)
        w.writeframes(mono.tobytes())

    return out_path


def _rec_db() -> sqlite3.Connection:
    conn = sqlite3.connect(REC_DB_PATH, check_same_thread=False)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("""
        CREATE TABLE IF NOT EXISTS recordings (
            id           INTEGER PRIMARY KEY AUTOINCREMENT,
            filename     TEXT NOT NULL,
            path         TEXT NOT NULL UNIQUE,
            caller       TEXT NOT NULL DEFAULT '',
            callee       TEXT NOT NULL DEFAULT '',
            rec_date     TEXT NOT NULL DEFAULT '',
            rec_time     TEXT NOT NULL DEFAULT '',
            rec_dt       TEXT NOT NULL DEFAULT '',
            size         INTEGER NOT NULL DEFAULT 0,
            duration_est REAL NOT NULL DEFAULT 0,
            mtime        TEXT NOT NULL DEFAULT '',
            mono_path    TEXT NOT NULL DEFAULT '',
            created_at   TEXT NOT NULL DEFAULT (strftime('%Y-%m-%d %H:%M:%S','now','localtime'))
        )
    """)
    existing_cols = {row[1] for row in conn.execute("PRAGMA table_info(recordings)").fetchall()}
    if 'mono_path' not in existing_cols:
        conn.execute("ALTER TABLE recordings ADD COLUMN mono_path TEXT NOT NULL DEFAULT ''")
    conn.execute("CREATE INDEX IF NOT EXISTS idx_caller   ON recordings(caller)")
    conn.execute("CREATE INDEX IF NOT EXISTS idx_callee   ON recordings(callee)")
    conn.execute("CREATE INDEX IF NOT EXISTS idx_rec_dt   ON recordings(rec_dt)")
    conn.execute("CREATE INDEX IF NOT EXISTS idx_rec_date ON recordings(rec_date)")
    conn.commit()
    return conn


def _parse_rec_filename(fname: str) -> dict:
    m = _REC_FNAME_RE.match(fname)
    if m:
        return {
            "caller": m.group("caller"),
            "callee": m.group("callee"),
            "rec_date": m.group("date"),
            "rec_time": m.group("time"),
            "rec_dt":   m.group("date") + "_" + m.group("time"),
        }
    return {"caller": "", "callee": "", "rec_date": "", "rec_time": "", "rec_dt": ""}


def _upsert_file_to_db(conn: sqlite3.Connection, fpath: str):
    fname = os.path.basename(fpath)
    try:
        stat = os.stat(fpath)
    except OSError:
        return
    size = stat.st_size
    mtime = datetime.fromtimestamp(stat.st_mtime).strftime("%Y-%m-%d %H:%M:%S")
    duration_est = round(size / 32000, 1)

    row = conn.execute("SELECT id, size, mono_path FROM recordings WHERE path=?", (fpath,)).fetchone()
    if row and row["size"] == size:
        if fname.lower().endswith('.wav') and not row["mono_path"]:
            try:
                mono_p = _merge_stereo_to_mono(fpath)
                conn.execute("UPDATE recordings SET mono_path=? WHERE path=?", (mono_p, fpath))
            except Exception as e:
                print(f"[mono-merge] skip {fname}: {e}")
        return

    parsed = _parse_rec_filename(fname)
    if row:
        conn.execute("""
            UPDATE recordings SET size=?, duration_est=?, mtime=? WHERE path=?
        """, (size, duration_est, mtime, fpath))
    else:
        conn.execute("""
            INSERT INTO recordings (filename, path, caller, callee, rec_date, rec_time, rec_dt, size, duration_est, mtime)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, (fname, fpath, parsed["caller"], parsed["callee"],
              parsed["rec_date"], parsed["rec_time"], parsed["rec_dt"],
              size, duration_est, mtime))

    if fname.lower().endswith('.wav'):
        try:
            mono_p = _merge_stereo_to_mono(fpath)
            conn.execute("UPDATE recordings SET mono_path=? WHERE path=?", (mono_p, fpath))
        except Exception as e:
            print(f"[mono-merge] skip {fname}: {e}")


def sync_recordings_to_db():
    os.makedirs(RECORDINGS_DIR, exist_ok=True)
    conn = _rec_db()
    try:
        disk_paths = set()
        for root, dirs, filenames in os.walk(RECORDINGS_DIR):
            dirs[:] = [d for d in dirs if d not in (".trash", ".mono")]
            for fname in filenames:
                if os.path.splitext(fname)[1].lower() not in _AUDIO_EXTS:
                    continue
                fpath = os.path.join(root, fname)
                disk_paths.add(fpath)
                _upsert_file_to_db(conn, fpath)

        db_paths = {r[0] for r in conn.execute("SELECT path FROM recordings").fetchall()}
        stale = db_paths - disk_paths
        if stale:
            conn.executemany("DELETE FROM recordings WHERE path=?", [(p,) for p in stale])

        conn.commit()
    finally:
        conn.close()


def _start_rec_sync_scheduler():
    def _loop():
        while True:
            try:
                sync_recordings_to_db()
            except Exception as e:
                print(f"[rec-sync] error: {e}")
            threading.Event().wait(300)
    t = threading.Thread(target=_loop, daemon=True)
    t.start()


_start_rec_sync_scheduler()


def _owns_recording(conn: sqlite3.Connection, path: str, owned_ext: str) -> bool:
    """scope='own' 檢查：該錄音的 caller/callee 是否包含使用者自己的分機"""
    row = conn.execute("SELECT caller, callee FROM recordings WHERE path=?", (path,)).fetchone()
    if not row:
        return False
    return owned_ext in (row["caller"], row["callee"])


@router.get("/api/recordings", dependencies=[Depends(require_permission(Module.RECORDINGS, "read"))])
def list_recordings(
    extension: str = Query(default=""),
    start_dt:  str = Query(default=""),
    end_dt:    str = Query(default=""),
    search:    str = Query(default=""),
    limit:     int = Query(default=200),
    offset:    int = Query(default=0),
    user: dict = Depends(get_current_user),
):
    """列出錄音（先同步新檔再查 DB）"""
    try:
        sync_recordings_to_db()
    except Exception:
        pass

    # scope='own' 強制鎖定成自己的分機，忽略前端傳入的 extension
    extension = apply_scope(user, extension, Module.RECORDINGS) or extension

    conn = _rec_db()
    try:
        where_clauses = []
        params: list = []

        if user["scope"] == "own":
            where_clauses.append("(caller = ? OR callee = ?)")
            params.extend([user["owned_ext"], user["owned_ext"]])
        elif extension:
            where_clauses.append("(caller = ? OR callee = ?)")
            params.extend([extension.strip(), extension.strip()])

        if start_dt:
            try:
                sdt = datetime.strptime(start_dt, "%Y-%m-%dT%H:%M")
                where_clauses.append("rec_dt >= ?")
                params.append(sdt.strftime("%Y%m%d_%H%M00"))
            except ValueError:
                pass

        if end_dt:
            try:
                edt = datetime.strptime(end_dt, "%Y-%m-%dT%H:%M")
                where_clauses.append("rec_dt <= ?")
                params.append(edt.strftime("%Y%m%d_%H%M59"))
            except ValueError:
                pass

        if search:
            where_clauses.append("filename LIKE ?")
            params.append(f"%{search}%")

        where_sql = ("WHERE " + " AND ".join(where_clauses)) if where_clauses else ""

        total = conn.execute(
            f"SELECT COUNT(*) FROM recordings {where_sql}", params
        ).fetchone()[0]

        rows = conn.execute(
            f"SELECT * FROM recordings {where_sql} ORDER BY rec_dt DESC, mtime DESC LIMIT ? OFFSET ?",
            params + [limit, offset]
        ).fetchall()

        files = []
        for r in rows:
            files.append({
                "filename":     r["filename"],
                "path":         r["path"],
                "caller":       r["caller"],
                "callee":       r["callee"],
                "rec_date":     r["rec_date"],
                "rec_time":     r["rec_time"],
                "size":         r["size"],
                "duration_est": r["duration_est"],
                "mtime":        r["mtime"],
                "mono_path":    r["mono_path"],
            })

        return {"total": total, "files": files}
    finally:
        conn.close()


@router.post("/api/recordings/sync", dependencies=[Depends(require_permission(Module.RECORDINGS, "update"))])
def force_sync_recordings():
    """手動觸發錄音索引同步"""
    try:
        sync_recordings_to_db()
        conn = _rec_db()
        total = conn.execute("SELECT COUNT(*) FROM recordings").fetchone()[0]
        conn.close()
        return {"ok": True, "indexed": total}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.get("/api/recordings/stream", dependencies=[Depends(require_permission_media(Module.RECORDINGS, "read"))])
async def stream_recording(path: str, user: dict = Depends(get_current_user)):
    """串流播放錄音檔"""
    if not path.startswith(RECORDINGS_DIR):
        raise HTTPException(status_code=403, detail="不允許存取此路徑")
    if not os.path.isfile(path):
        raise HTTPException(status_code=404, detail="錄音檔案不存在")

    if user["scope"] == "own":
        conn = _rec_db()
        owns = _owns_recording(conn, path, user["owned_ext"])
        conn.close()
        if not owns:
            raise HTTPException(status_code=403, detail="此帳號僅能存取自己分機的錄音")

    ext = path.rsplit(".", 1)[-1].lower()
    media_map = {"wav": "audio/wav", "mp3": "audio/mpeg", "ogg": "audio/ogg", "gsm": "audio/gsm"}
    return FileResponse(path, media_type=media_map.get(ext, "audio/octet-stream"), headers={
        "Accept-Ranges": "bytes",
        "Cache-Control": "no-cache",
    })


@router.get("/api/recordings/stream_mono", dependencies=[Depends(require_permission_media(Module.RECORDINGS, "read"))])
async def stream_mono_recording(path: str, user: dict = Depends(get_current_user)):
    """串流播放 mono 合併錄音；若尚未產生則即時補建"""
    if not path.startswith(RECORDINGS_DIR):
        raise HTTPException(status_code=403, detail="不允許存取此路徑")
    if not os.path.isfile(path):
        raise HTTPException(status_code=404, detail="原始錄音檔不存在")

    conn = _rec_db()
    if user["scope"] == "own" and not _owns_recording(conn, path, user["owned_ext"]):
        conn.close()
        raise HTTPException(status_code=403, detail="此帳號僅能存取自己分機的錄音")

    row  = conn.execute("SELECT mono_path FROM recordings WHERE path=?", (path,)).fetchone()
    conn.close()
    mono_p = row["mono_path"] if row else ""

    if not mono_p or not os.path.isfile(mono_p):
        try:
            mono_p = _merge_stereo_to_mono(path)
            conn2  = _rec_db()
            conn2.execute("UPDATE recordings SET mono_path=? WHERE path=?", (mono_p, path))
            conn2.commit()
            conn2.close()
        except Exception as e:
            raise HTTPException(status_code=500, detail=f"mono 產生失敗: {e}")

    return FileResponse(mono_p, media_type="audio/wav", headers={
        "Accept-Ranges": "bytes",
        "Cache-Control": "no-cache",
    })


@router.delete("/api/recordings", dependencies=[Depends(require_permission(Module.RECORDINGS, "delete"))])
def delete_recording(path: str = Body(..., embed=True), user: dict = Depends(get_current_user)):
    """刪除錄音檔（移至 .trash，並從 DB 移除）"""
    if not path.startswith(RECORDINGS_DIR):
        raise HTTPException(status_code=403, detail="不允許存取此路徑")
    if not os.path.isfile(path):
        raise HTTPException(status_code=404, detail="錄音檔案不存在")

    if user["scope"] == "own":
        raise HTTPException(status_code=403, detail="此帳號無刪除權限")  # User 群組 delete=False，此檢查為雙重保險

    trash_dir = os.path.join(RECORDINGS_DIR, ".trash")
    os.makedirs(trash_dir, exist_ok=True)
    dest = os.path.join(trash_dir, os.path.basename(path) + "." + datetime.now().strftime("%Y%m%d_%H%M%S"))
    shutil.move(path, dest)
    try:
        conn = _rec_db()
        conn.execute("DELETE FROM recordings WHERE path=?", (path,))
        conn.commit()
        conn.close()
    except Exception:
        pass
    return {"ok": True, "moved_to": dest}