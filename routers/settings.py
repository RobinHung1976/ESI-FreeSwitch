"""
routers/settings.py — Dashboard 後端設定與 ESL 連線設定即時套用：/api/settings /api/config/reload
"""

from fastapi import Depends
from core.auth import require_permission
from core.permissions import Module

from fastapi import APIRouter, Body
from pydantic import BaseModel

from core.esl_client import esl
from core import state
from core.runtime import load_server_settings, save_server_settings

router = APIRouter()


# ── 後端設定 API ──────────────────────────────────────────────────────────────

@router.get("/api/settings", dependencies=[Depends(require_permission(Module.SETTINGS, "read"))])
def get_settings():
    return load_server_settings()

@router.post("/api/settings", dependencies=[Depends(require_permission(Module.SETTINGS, "update"))])
async def post_settings(body: dict = Body(...)):
    save_server_settings(body)
    # 同步更新記憶體排程設定，並喚醒 scheduler 重新計算觸發時間
    state.scheduler_settings.update({
        "backup_auto_enabled": body.get("backup_auto_enabled", False),
        "backup_auto_time":    body.get("backup_auto_time", "00:01"),
    })
    state.scheduler_wakeup.set()
    return {"ok": True}


# ── 連線設定即時套用 ──────────────────────────────────────────────────────────

class ESLConfigReload(BaseModel):
    host:     str = "127.0.0.1"
    port:     int = 8055
    password: str = "FSPyAdmin"

@router.post("/api/config/reload", dependencies=[Depends(require_permission(Module.SETTINGS, "update"))])
def config_reload(body: ESLConfigReload):
    """
    即時套用 ESL 連線設定並重連。
    前端「設定頁」儲存連線參數後呼叫此端點，後端立即重建 ESL API socket。
    同時將新設定持久化到 settings.json，下次重啟時自動使用。
    """
    try:
        # 持久化
        save_server_settings({
            "esl_host":     body.host,
            "esl_port":     body.port,
            "esl_password": body.password,
        })
        # 重連 API socket（帶入新參數）
        esl.reconnect(host=body.host, port=body.port, password=body.password)
        return {
            "ok":   True,
            "host": body.host,
            "port": body.port,
            "msg":  f"已重連至 {body.host}:{body.port}",
        }
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"ESL 重連失敗：{e}")


