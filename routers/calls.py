"""
routers/calls.py — 通話監控與 ESL 直接指令：/api/calls /api/channels /api/registrations /api/ext/status /api/reg/log /api/esl /api/calls/*
"""
from fastapi import APIRouter, HTTPException, Query, Depends
from pydantic import BaseModel

from core.esl_client import esl
from core import state
from core.auth import require_permission, get_current_user, apply_scope
from core.permissions import Module

router = APIRouter()


def _filter_rows_by_ext(rows: list, ext: str) -> list:
    """scope='own' 用：保留任一欄位值包含指定分機號的紀錄（欄位命名未知時的通用過濾）"""
    return [r for r in rows if any(ext in str(v) for v in r.values())]


@router.get("/api/calls", dependencies=[Depends(require_permission(Module.CALLS, "read"))])
def get_calls(user: dict = Depends(get_current_user)):
    data = esl.get_calls()
    if user["scope"] == "own":
        ext = apply_scope(user, None, Module.CALLS)
        if isinstance(data, dict) and isinstance(data.get("rows"), list):
            data["rows"] = _filter_rows_by_ext(data["rows"], ext)
    return data


@router.get("/api/channels", dependencies=[Depends(require_permission(Module.CALLS, "read"))])
def get_channels():
    return esl.get_channels()


@router.get("/api/registrations", dependencies=[Depends(require_permission(Module.CALLS, "read"))])
def get_registrations():
    """
    取得已登錄分機清單。
    FreeSwitch 不同版本回傳的 reg_user 欄位可能含有 realm（1001@host），
    在此統一 normalize 為純粹的使用者名稱。
    """
    data = esl.get_registrations()
    rows = data.get("rows", []) if isinstance(data, dict) else []
    for r in rows:
        raw = r.get("reg_user", "") or r.get("user", "")
        r["reg_user"] = raw.split("@")[0].strip()
        if "network_proto" in r:
            r["network_proto"] = r["network_proto"].lower()
    return data


@router.get("/api/ext/status", dependencies=[Depends(require_permission(Module.CALLS, "read"))])
def get_ext_status():
    """回傳目前所有分機的即時狀態（頁面初始載入用）"""
    return {"status": state.ext_status}


@router.get("/api/reg/log", dependencies=[Depends(require_permission(Module.CALLS, "read"))])
def get_reg_log(limit: int = Query(default=200, ge=1, le=500)):
    """Return registration history log (newest first)"""
    return {"logs": list(reversed(state.reg_log[-limit:])), "total": len(state.reg_log)}


class ESLCommand(BaseModel):
    command: str


@router.post("/api/esl", dependencies=[Depends(require_permission(Module.CALLS, "create"))])
def run_esl(body: ESLCommand):
    try:
        result = esl.api(body.command)
        return {"result": result}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


class UUIDRequest(BaseModel):
    uuid: str


@router.post("/api/calls/hangup", dependencies=[Depends(require_permission(Module.CALLS, "update"))])
def hangup(body: UUIDRequest):
    result = esl.hangup_call(body.uuid)
    return {"result": result}


@router.post("/api/calls/hold", dependencies=[Depends(require_permission(Module.CALLS, "update"))])
def hold(body: UUIDRequest):
    result = esl.hold_call(body.uuid)
    return {"result": result}


class TransferRequest(BaseModel):
    uuid: str
    destination: str


@router.post("/api/calls/transfer", dependencies=[Depends(require_permission(Module.CALLS, "update"))])
def transfer(body: TransferRequest):
    result = esl.transfer_call(body.uuid, body.destination)
    return {"result": result}