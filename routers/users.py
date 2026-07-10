"""routers/users.py — 使用者管理（需 Module.USERS 權限）"""
from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field

from core.auth import require_permission
from core.permissions import Module
import core.auth_db as auth_db

router = APIRouter(prefix="/api/users", tags=["users"])


class CreateUserRequest(BaseModel):
    username: str = Field(min_length=1, max_length=64)
    password: str = Field(min_length=8)
    group_id: int
    owned_ext: str | None = None


class UpdateUserRequest(BaseModel):
    group_id: int | None = None
    owned_ext: str | None = None
    disabled: bool | None = None


class ResetPasswordRequest(BaseModel):
    new_password: str = Field(min_length=8)


@router.get("", dependencies=[Depends(require_permission(Module.USERS, "read"))])
def list_users():
    return {"rows": auth_db.list_users()}


@router.post("", dependencies=[Depends(require_permission(Module.USERS, "create"))])
def create_user(body: CreateUserRequest):
    try:
        uid = auth_db.create_user(body.username, body.password, body.group_id, body.owned_ext)
    except ValueError as e:
        raise HTTPException(400, str(e))
    return {"id": uid}


@router.put("/{user_id}", dependencies=[Depends(require_permission(Module.USERS, "update"))])
def update_user(user_id: int, body: UpdateUserRequest):
    try:
        auth_db.update_user(
            user_id, group_id=body.group_id, owned_ext=body.owned_ext, disabled=body.disabled,
        )
    except ValueError as e:
        raise HTTPException(400, str(e))
    return {"ok": True}


@router.post("/{user_id}/reset-password", dependencies=[Depends(require_permission(Module.USERS, "update"))])
def reset_password(user_id: int, body: ResetPasswordRequest):
    try:
        auth_db.reset_password(user_id, body.new_password, force_change=True)
    except ValueError as e:
        raise HTTPException(400, str(e))
    return {"ok": True}


@router.delete("/{user_id}", dependencies=[Depends(require_permission(Module.USERS, "delete"))])
def delete_user(user_id: int):
    try:
        auth_db.delete_user(user_id)
    except ValueError as e:
        raise HTTPException(400, str(e))
    return {"ok": True}
