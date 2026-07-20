"""
routers/files.py — 通用檔案下載端點：/api/download（供「設定 > 檔案路徑」頁面下載 vars.xml / dialplan XML / CDR / log 等使用）
"""
import os
from fastapi import APIRouter, HTTPException, Depends
from fastapi.responses import FileResponse

from core.auth import get_current_user_media
from core.permissions import Module, Perm

router = APIRouter()


# 路徑前綴 → 對應模組權限（依序比對，符合哪個前綴就要求該模組的 read 權限）
_DIR_MODULE_MAP = [
    ("/var/lib/freeswitch/recordings/", Module.RECORDINGS),
    ("/usr/share/freeswitch/sounds/", Module.SOUNDS),
    ("/var/log/freeswitch/", Module.LOGS),
    ("/etc/freeswitch/", Module.SETTINGS),
]


def _resolve_dir(d: str) -> str:
    return os.path.realpath(d).rstrip(os.sep)


def _required_module(real_path: str):
    for prefix, module in _DIR_MODULE_MAP:
        allowed_real = _resolve_dir(prefix)
        if real_path == allowed_real or real_path.startswith(allowed_real + os.sep):
            return module
    return None


@router.get("/api/download")
def download_file(path: str, user: dict = Depends(get_current_user_media)):
    """下載指定檔案，路徑先正規化再比對白名單，並依前綴要求對應模組的讀取權限

    2026-07-20 修復：原本此端點完全沒有認證檢查，任何人不用登入即可用 ?path=
    下載白名單目錄底下任意檔案；且路徑比對只用字面字串 startswith()，未用
    os.path.realpath() 正規化，有路徑穿越風險（例如 path 帶 ../ 繞過前綴檢查）。
    見 changelog-details/20260720-download-endpoint-auth-fix.md
    """
    real_path = os.path.realpath(path)

    module = _required_module(real_path)
    if module is None:
        raise HTTPException(status_code=403, detail="不允許存取此路徑")

    perm: Perm = user["permissions"].get(module, Perm())
    if not perm.allows("read"):
        raise HTTPException(status_code=403, detail=f"權限不足：{module} 需要 read 權限")

    if not os.path.isfile(real_path):
        raise HTTPException(status_code=404, detail="檔案不存在")

    filename = os.path.basename(real_path)
    return FileResponse(real_path, filename=filename, media_type="application/octet-stream")


