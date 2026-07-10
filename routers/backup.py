"""
routers/backup.py — 備份/還原 API：/api/backup*（實際邏輯在 core/backup_manager.py，這裡只是 HTTP 端點）
"""
import os
import asyncio
from datetime import datetime
from fastapi import APIRouter, HTTPException, Query, UploadFile, File, Depends
from fastapi.responses import FileResponse
from pydantic import BaseModel

from core.backup_manager import (
    backup_dashboard_config, backup_freeswitch_packages,
    restore_dashboard_config, list_backups, delete_backup, get_backup_dir,
)
from core.auth import require_permission
from core.permissions import Module

router = APIRouter()


@router.get("/api/backup/list", dependencies=[Depends(require_permission(Module.BACKUP, "read"))])
def api_backup_list():
    """列出所有備份檔（config + packages），按時間倒序"""
    backups = list_backups()
    return {"backups": backups, "total": len(backups)}


# ── POST /api/backup/run ──────────────────────────────────────────────────────

class BackupRunRequest(BaseModel):
    type: str  # "config" | "packages" | "both"

@router.post("/api/backup/run", dependencies=[Depends(require_permission(Module.BACKUP, "create"))])
async def api_backup_run(body: BackupRunRequest):
    """
    觸發備份（在背景執行緒執行，避免 blocking event loop）
    type: "config"   → 備份 A（設定）
          "packages" → 備份 B（FreeSwitch .deb 套件，較耗時）
          "both"     → A + B
    """
    if body.type not in ("config", "packages", "both"):
        raise HTTPException(status_code=400, detail="type 必須是 config / packages / both")

    loop    = asyncio.get_event_loop()
    results = {}

    if body.type in ("config", "both"):
        res = await loop.run_in_executor(None, backup_dashboard_config)
        results["config"] = res

    if body.type in ("packages", "both"):
        res = await loop.run_in_executor(None, backup_freeswitch_packages)
        results["packages"] = res

    # 整體成功判斷
    all_ok = all(r.get("ok") for r in results.values())
    return {"ok": all_ok, "results": results}


# ── GET /api/backup/download ──────────────────────────────────────────────────

@router.get("/api/backup/download", dependencies=[Depends(require_permission(Module.BACKUP, "read"))])
def api_backup_download(filename: str = Query(...)):
    """下載指定備份檔"""
    import re
    if not re.match(
        r'^(fs-dashboard-config|freeswitch-packages)-\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}\.tar\.gz$',
        filename
    ):
        raise HTTPException(status_code=400, detail="檔名格式不正確")

    backup_dir = get_backup_dir()
    fpath      = os.path.join(backup_dir, filename)

    if not os.path.isfile(fpath):
        raise HTTPException(status_code=404, detail="備份檔不存在")

    return FileResponse(
        fpath,
        filename=filename,
        media_type="application/gzip",
        headers={"Content-Disposition": f'attachment; filename="{filename}"'},
    )


# ── DELETE /api/backup/{filename} ─────────────────────────────────────────────

@router.delete("/api/backup/{filename}", dependencies=[Depends(require_permission(Module.BACKUP, "delete"))])
def api_backup_delete(filename: str):
    """刪除指定備份檔"""
    result = delete_backup(filename)
    if not result["ok"]:
        raise HTTPException(status_code=400, detail=result["error"])
    return result


# ── POST /api/backup/restore ──────────────────────────────────────────────────

@router.post("/api/backup/restore", dependencies=[Depends(require_permission(Module.BACKUP, "update"))])
async def api_backup_restore(file: UploadFile = File(...)):
    """
    情境A 還原：上傳 fs-dashboard-config-*.tar.gz → 解壓覆蓋設定 → reloadxml
    （Server 仍在運行時使用；整台壞掉請用 restore_dashboard.sh）
    """
    if not file.filename.startswith("fs-dashboard-config-"):
        raise HTTPException(
            status_code=400,
            detail="只接受 fs-dashboard-config-*.tar.gz 備份檔（packages 備份請在新機用 shell 腳本還原）"
        )

    # 儲存上傳檔到暫存位置
    tmp_path = f"/tmp/restore-upload-{datetime.now().strftime('%Y%m%d%H%M%S')}.tar.gz"
    try:
        content = await file.read()
        with open(tmp_path, "wb") as f:
            f.write(content)

        loop   = asyncio.get_event_loop()
        result = await loop.run_in_executor(None, restore_dashboard_config, tmp_path)
    finally:
        if os.path.exists(tmp_path):
            os.remove(tmp_path)

    if not result["ok"]:
        raise HTTPException(status_code=500, detail=str(result))

    return result


# ── GET /api/backup/settings ─────────────────────────────────────────────────
# 備份設定透過現有 GET/POST /api/settings 統一管理，不需獨立 endpoint
# settings.json 新增欄位：
#   backup_path:         str  (預設 /opt/fs-dashboard/backups)
#   backup_retain_days:  int  (預設 30)
#   backup_auto_enabled: bool (預設 false，開啟後每日 00:01 自動備份 config)
