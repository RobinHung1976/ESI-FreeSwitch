"""routers/perm_groups.py — 權限群組管理（新增/調整自訂群組）"""
from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field

from core.auth import require_permission
from core.permissions import Module, Perm, ALL_MODULES
import core.auth_db as auth_db

router = APIRouter(prefix="/api/perm-groups", tags=["perm-groups"])


class PermFlags(BaseModel):
    read: bool = False
    create: bool = False
    update: bool = False
    delete: bool = False


class CreateGroupRequest(BaseModel):
    name: str = Field(min_length=1, max_length=64)
    description: str = ""
    scope: str = Field(pattern="^(all|own)$")
    permissions: dict[str, PermFlags]


class UpdateGroupPermissionsRequest(BaseModel):
    permissions: dict[str, PermFlags]


def _to_perm_dict(raw: dict[str, PermFlags]) -> dict[str, Perm]:
    return {
        mod: Perm(**raw[mod].model_dump())
        for mod in ALL_MODULES if mod in raw
    }


@router.get("", dependencies=[Depends(require_permission(Module.USERS, "read"))])
def list_groups():
    return {"rows": auth_db.list_groups()}


@router.post("", dependencies=[Depends(require_permission(Module.USERS, "create"))])
def create_group(body: CreateGroupRequest):
    try:
        gid = auth_db.create_group(
            body.name, body.description, body.scope, _to_perm_dict(body.permissions),
        )
    except ValueError as e:
        raise HTTPException(400, str(e))
    return {"id": gid}


@router.put("/{group_id}/permissions", dependencies=[Depends(require_permission(Module.USERS, "update"))])
def update_group_permissions(group_id: int, body: UpdateGroupPermissionsRequest):
    """僅更新權限矩陣；name/scope 固定不可改（含內建與自訂群組，避免改壞 scope 造成資料外洩判斷錯亂）"""
    try:
        auth_db.update_group_permissions(group_id, _to_perm_dict(body.permissions))
    except ValueError as e:
        raise HTTPException(400, str(e))
    return {"ok": True}


@router.delete("/{group_id}", dependencies=[Depends(require_permission(Module.USERS, "delete"))])
def delete_group(group_id: int):
    try:
        auth_db.delete_group(group_id)
    except ValueError as e:
        raise HTTPException(400, str(e))
    return {"ok": True}
