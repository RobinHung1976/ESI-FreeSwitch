"""
routers/cdr.py — CDR 查詢與每日歸檔：/api/cdr /api/cdr/stats /api/cdr/archives /api/cdr/archive/* /api/cdr/rotate

v2：查詢改走 SQLite（core/cdr_db.py），不再逐檔掃描 CSV。
    - /api/cdr        走 cdr table（raw 明細，受 cdr_retain_days 限制）
    - /api/cdr/stats  raw + cdr_daily_summary 混合，可查任意長區間（不受 cdr_retain_days 限制）
    每次請求前都會先把當天 Master.csv 增量同步進 DB（sync_today），確保「今天」永遠是最新資料。
"""

from fastapi import Depends
from core.auth import require_permission, get_current_user, apply_scope
from core.permissions import Module

import os
import re
import glob
from fastapi import APIRouter, HTTPException, Query
from fastapi.responses import StreamingResponse

from core.runtime import CDR_DIR, CDR_MASTER, _rotate_cdr_now
from core import cdr_db

router = APIRouter()


# ── CDR 歸檔 API（維持不變，歸檔 CSV 仍保留作為備援）─────────────────────────────

@router.get("/api/cdr/archives", dependencies=[Depends(require_permission(Module.CDR, "read"))])
def list_cdr_archives():
    """列出所有已歸檔的 CDR 檔案"""
    pattern = os.path.join(CDR_DIR, "cdr-????-??-??.csv")
    files = []
    for f in sorted(glob.glob(pattern), reverse=True):
        basename = os.path.basename(f)
        size = os.path.getsize(f)
        files.append({"filename": basename, "size": size, "path": f})
    return {"files": files, "count": len(files)}


@router.get("/api/cdr/archive/download", dependencies=[Depends(require_permission(Module.CDR, "read"))])
def download_cdr_archive(filename: str = Query(...)):
    """下載指定歸檔 CDR 檔案（純文字 CSV 回傳，供前端解析）"""
    if not re.match(r'^cdr-\d{4}-\d{2}-\d{2}\.csv$', filename):
        raise HTTPException(status_code=400, detail="檔名格式不正確")
    path = os.path.join(CDR_DIR, filename)
    if not os.path.isfile(path):
        raise HTTPException(status_code=404, detail="歸檔檔案不存在")
    return StreamingResponse(
        open(path, "rb"),
        media_type="text/csv; charset=utf-8",
        headers={"Content-Disposition": f'attachment; filename="{filename}"'}
    )


@router.post("/api/cdr/rotate", dependencies=[Depends(require_permission(Module.CDR, "update"))])
def rotate_cdr_now():
    """手動立即執行 CDR 歸檔（用今天日期）：同步進 DB → 建彙總 → 封存 CSV → 清空 Master.csv"""
    result = _rotate_cdr_now(use_today=True)
    if not result["ok"]:
        raise HTTPException(status_code=400, detail=result["error"])
    return result


@router.delete("/api/cdr/archive/{filename}", dependencies=[Depends(require_permission(Module.CDR, "delete"))])
def delete_cdr_archive(filename: str):
    """刪除指定歸檔 CDR 檔（僅刪 CSV 備援檔，DB 內資料不受影響）"""
    if not re.match(r'^cdr-\d{4}-\d{2}-\d{2}\.csv$', filename):
        raise HTTPException(status_code=400, detail="檔名格式不正確")
    path = os.path.join(CDR_DIR, filename)
    if not os.path.isfile(path):
        raise HTTPException(status_code=404, detail="檔案不存在")
    os.remove(path)
    return {"ok": True, "deleted": filename}


# ── CDR 查詢 API（SQLite）───────────────────────────────────────────────────────

def _sync_today():
    """每次查詢前先把今天的 Master.csv 增量同步進 DB（INSERT OR IGNORE，冪等、快速）。"""
    try:
        cdr_db.sync_today(CDR_MASTER)
    except Exception as e:
        print(f"[cdr-sync] 同步今日 CDR 失敗：{e}")


@router.get("/api/cdr", dependencies=[Depends(require_permission(Module.CDR, "read"))])
def get_cdr(
    limit:      int = Query(default=100),
    offset:     int = Query(default=0),
    date_from:  str = Query(default=None),
    date_to:    str = Query(default=None),
    user:       str = Query(default=None),
    current_user: dict = Depends(get_current_user),
):
    """讀取 CDR 明細（來自 SQLite raw table，受 cdr_retain_days 保留期限制）"""
    user = apply_scope(current_user, user, Module.CDR)
    _sync_today()
    try:
        return cdr_db.query_rows(date_from=date_from, date_to=date_to, user=user,
                                  limit=limit, offset=offset)
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.get("/api/cdr/stats", dependencies=[Depends(require_permission(Module.CDR, "read"))])
def get_cdr_stats(
    date_str: str = Query(default=None),
    date_to:  str = Query(default=None),   # 結束日期（含），空則單日模式
    user:     str = Query(default=None),
):
    """
    取得指定日期（範圍）的通話統計。任意天數區間皆可查詢：
    - 保留期內的日期：即時聚合 raw 明細（精確）
    - 保留期外的日期：回退用每日彙總（cdr_daily_summary），僅整體統計可用
    回傳新增 summary_fallback_used 欄位：true 代表區間內含有僅剩彙總資料的日期。
    """
    _sync_today()
    try:
        from datetime import datetime
        today     = datetime.now().strftime("%Y-%m-%d")
        date_from = date_str or today
        date_end  = date_to or date_from
        return cdr_db.query_stats(date_from, date_end, user=user)
    except ValueError as e:
        raise HTTPException(status_code=400, detail=f"日期格式錯誤：{e}")
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))
