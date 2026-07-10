"""
routers/files.py — 通用檔案下載端點：/api/download（供「設定 > 檔案路徑」頁面下載 vars.xml / dialplan XML / CDR / log 等使用）
"""
import os
from fastapi import APIRouter, HTTPException
from fastapi.responses import FileResponse

router = APIRouter()


@router.get("/api/download")
def download_file(path: str):
    """下載指定檔案"""
    allowed_dirs = [
        "/etc/freeswitch/",
        "/var/log/freeswitch/",
        "/var/lib/freeswitch/recordings/",
        "/usr/share/freeswitch/sounds/",
    ]
    if not any(path.startswith(d) for d in allowed_dirs):
        raise HTTPException(status_code=403, detail="不允許存取此路徑")
    if not os.path.isfile(path):
        raise HTTPException(status_code=404, detail="檔案不存在")
    filename = os.path.basename(path)
    return FileResponse(path, filename=filename, media_type="application/octet-stream")


