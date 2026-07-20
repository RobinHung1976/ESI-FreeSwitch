"""
routers/logs.py — FreeSwitch log 即時串流／每日輪轉／歷史查詢：/api/logs/stream /api/logs/list /api/logs/rotate /api/logs/download /api/logs/grep /api/logs/history
"""
import os
import glob
import asyncio
from datetime import datetime
from fastapi import APIRouter, HTTPException, Query, Depends
from fastapi.responses import FileResponse, StreamingResponse

from core import state
from core.runtime import FS_LOG_DIR, FS_LOG_FILE, _rotate_log_now
from core.auth import require_permission, require_permission_media
from core.permissions import Module

router = APIRouter()


@router.get("/api/logs/stream", dependencies=[Depends(require_permission_media(Module.LOGS, "read"))])
async def stream_logs():
    """Live-stream FreeSwitch log via SSE, with ESL event injection"""
    import json as _json
    inject_q: asyncio.Queue = asyncio.Queue(maxsize=200)
    state.log_inject_queues.add(inject_q)

    async def generate():
        proc = await asyncio.create_subprocess_exec(
            "tail", "-n", "500", "-f", "/var/log/freeswitch/freeswitch.log",
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.DEVNULL
        )
        try:
            while True:
                tail_task   = asyncio.ensure_future(proc.stdout.readline())
                inject_task = asyncio.ensure_future(inject_q.get())
                done, pending = await asyncio.wait(
                    {tail_task, inject_task},
                    return_when=asyncio.FIRST_COMPLETED
                )
                for t in pending:
                    t.cancel()
                for t in done:
                    result = t.result()
                    if isinstance(result, bytes):
                        text = result.decode("utf-8", errors="replace").rstrip()
                    else:
                        text = result
                    if text:
                        yield f"data: {_json.dumps({'line': text})}\n\n"
        finally:
            proc.kill()
            state.log_inject_queues.discard(inject_q)

    return StreamingResponse(
        generate(),
        media_type="text/event-stream",
        headers={
            "Cache-Control": "no-cache",
            "X-Accel-Buffering": "no"
        }
    )


# ── Log 每日輪轉 API ───────────────────────────────────────────────────────────

@router.get("/api/logs/list", dependencies=[Depends(require_permission(Module.LOGS, "read"))])
def list_log_files():
    """列出所有已輪轉的每日 log 檔（freeswitch-YYYY-MM-DD.log）"""
    try:
        pattern = os.path.join(FS_LOG_DIR, "freeswitch-????-??-??.log")
        files = []
        for path in sorted(glob.glob(pattern), reverse=True):
            stat = os.stat(path)
            fname = os.path.basename(path)
            # 從檔名取得日期
            date_str = fname.replace("freeswitch-", "").replace(".log", "")
            files.append({
                "filename": fname,
                "path":     path,
                "date":     date_str,
                "size":     stat.st_size,
                "size_mb":  round(stat.st_size / 1024 / 1024, 2),
                "mtime":    datetime.fromtimestamp(stat.st_mtime).strftime("%Y-%m-%d %H:%M:%S"),
            })
        # 也回傳目前正在寫入的 log 大小
        current_size = os.path.getsize(FS_LOG_FILE) if os.path.isfile(FS_LOG_FILE) else 0
        return {
            "files":        files,
            "total":        len(files),
            "current_log":  FS_LOG_FILE,
            "current_size": current_size,
            "current_size_mb": round(current_size / 1024 / 1024, 2),
        }
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))



@router.post("/api/logs/rotate", dependencies=[Depends(require_permission(Module.LOGS, "update"))])
def rotate_log_now():
    """手動立即執行 log 輪轉（將今天以前的 log 另存為日期檔）"""
    result = _rotate_log_now()
    if not result["ok"]:
        raise HTTPException(status_code=400, detail=result["error"])
    return result


@router.get("/api/logs/download", dependencies=[Depends(require_permission_media(Module.LOGS, "read"))])
def download_log(date: str = Query(..., description="日期格式 YYYY-MM-DD")):
    """下載指定日期的 log 檔"""
    import re
    if not re.match(r'^\d{4}-\d{2}-\d{2}$', date):
        raise HTTPException(status_code=400, detail="日期格式錯誤，請使用 YYYY-MM-DD")
    filename = f"freeswitch-{date}.log"
    path = os.path.join(FS_LOG_DIR, filename)
    if not os.path.isfile(path):
        raise HTTPException(status_code=404, detail=f"{filename} 不存在")
    return FileResponse(path, filename=filename, media_type="text/plain; charset=utf-8")


@router.get("/api/logs/grep", dependencies=[Depends(require_permission(Module.LOGS, "read"))])
def grep_log(keyword: str = Query(..., description="search keyword"), lines: int = Query(default=100, ge=1, le=500)):
    """grep current log file - for debug"""
    import subprocess as sp
    try:
        result = sp.run(
            ["grep", "-i", "-m", str(lines), keyword, FS_LOG_FILE],
            capture_output=True, text=True, timeout=10
        )
        raw_lines = result.stdout.splitlines()
        return {"keyword": keyword, "count": len(raw_lines), "lines": raw_lines}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.get("/api/logs/history", dependencies=[Depends(require_permission(Module.LOGS, "read"))])
def get_log_history(
    date:    str = Query(...,        description="日期格式 YYYY-MM-DD"),
    level:   str = Query(default="ALL", description="ALL/ERR/WARNING/NOTICE/INFO/DEBUG/CALL"),
    keyword: str = Query(default="",    description="關鍵字搜尋（大小寫不敏感）"),
    page:    int = Query(default=1,     ge=1,  description="頁碼，從 1 開始"),
    per_page:int = Query(default=500,   ge=50, le=2000, description="每頁行數"),
):
    """
    分頁讀取歷史 log，支援等級過濾與關鍵字搜尋。
    後端用 grep 預過濾，大幅降低傳輸量。
    """
    import re, subprocess as sp

    if not re.match(r'^\d{4}-\d{2}-\d{2}$', date):
        raise HTTPException(status_code=400, detail="日期格式錯誤，請使用 YYYY-MM-DD")

    path = os.path.join(FS_LOG_DIR, f"freeswitch-{date}.log")
    if not os.path.isfile(path):
        raise HTTPException(status_code=404, detail=f"freeswitch-{date}.log 不存在")

    # ── FreeSwitch log 解析正規式 ──────────────────────────────────────────
    TS_RE  = re.compile(
        r'(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\.\d+\s+[\d.]+%\s+\[(\w+)\]\s+(.*)'
    )
    UUID_RE = re.compile(
        r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\s+', re.I
    )
    SRC_RE  = re.compile(r'^(\S+\.\w+:\d+)\s+(.*)')

    CALL_SOURCES = {
        'mod_sofia.c','sofia.c','sofia_media.c',
        'switch_core_state_machine.c','switch_channel.c',
        'switch_core_session.c','switch_core_media.c',
        'mod_dptools.c','mod_dialplan_xml.c',
        'switch_ivr_originate.c','switch_ivr.c',
    }
    CALL_KW = [
        'sofia/','CHANNEL_','Callstate Change','State Change CS_',
        'HANGUP','ROUTING','EXECUTE','Processing ','bridge',
        'New Channel','Close Channel',
    ]

    # 登入/登出相關
    REG_SOURCES = {'sofia_reg.c', 'mod_sofia.c', 'sofia.c'}
    REG_KW_LOWER = [
        'registered', 'un-registered', 'unregistered',
        'register sip', 'auth challenge', 'auth pass', 'auth fail',
        'authorization', 'registration expires', 'contact expires',
    ]

    def parse_line(raw: str) -> dict | None:
        line = UUID_RE.sub('', raw.strip())
        m = TS_RE.match(line)
        if m:
            time_str = m.group(1).split(' ')[1][:8]
            lvl  = m.group(2)
            rest = m.group(3)
            sm   = SRC_RE.match(rest)
            src  = sm.group(1) if sm else ''
            msg  = sm.group(2) if sm else rest
            return {'time': time_str, 'level': lvl, 'source': src, 'msg': msg}
        if line:
            return {'time': '', 'level': 'RAW', 'source': '', 'msg': line}
        return None

    def is_call(p: dict) -> bool:
        src = p['source'].lower()
        msg = p['msg']
        return (any(src.startswith(s.lower()) for s in CALL_SOURCES)
                or any(k in msg for k in CALL_KW))

    def is_reg(p: dict) -> bool:
        src = p['source'].lower()
        msg_lower = p['msg'].lower()
        src_match = any(src.startswith(s.lower()) for s in REG_SOURCES)
        kw_match  = any(k in msg_lower for k in REG_KW_LOWER)
        return src_match or kw_match

    # ── 讀取並過濾 ────────────────────────────────────────────────────────
    matched: list[dict] = []
    kw_lower = keyword.lower()
    level_up = level.upper()

    with open(path, 'r', encoding='utf-8', errors='replace') as f:
        for raw in f:
            p = parse_line(raw)
            if p is None:
                continue
            # 等級篩選
            if level_up == 'CALL':
                if not is_call(p):
                    continue
            elif level_up == 'REG':
                if not is_reg(p):
                    continue
            elif level_up != 'ALL':
                if p['level'] != level_up:
                    continue
            # 關鍵字篩選
            if kw_lower and kw_lower not in p['msg'].lower() and kw_lower not in p['source'].lower():
                continue
            matched.append(p)

    total      = len(matched)
    total_pages = max(1, (total + per_page - 1) // per_page)
    page       = min(page, total_pages)
    start      = (page - 1) * per_page
    rows       = matched[start: start + per_page]

    return {
        "date":        date,
        "total":       total,
        "page":        page,
        "per_page":    per_page,
        "total_pages": total_pages,
        "rows":        rows,
        "filter": {"level": level, "keyword": keyword},
    }
