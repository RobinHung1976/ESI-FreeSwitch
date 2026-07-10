"""routers/auth.py — 登入 / 個人資訊 / 改密碼 / 過渡期 bootstrap"""
from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field

from core.auth import create_access_token, get_current_user, ACCESS_TOKEN_EXPIRE_MINUTES
from core.auth_db import (
    verify_login, change_own_password, AuthError,
    count_users, seed_builtin_groups_and_users, list_users, _SEED_PASSWORD,
)
from core.permissions import ALL_MODULES

router = APIRouter(prefix="/api/auth", tags=["auth"])


class LoginRequest(BaseModel):
    username: str = Field(min_length=1)
    password: str = Field(min_length=1)


class ChangePasswordRequest(BaseModel):
    old_password: str = Field(min_length=1)
    new_password: str = Field(min_length=8)


@router.post("/bootstrap")
def bootstrap():
    if count_users() > 0:
        raise HTTPException(400, "權限系統已初始化，無法重複執行 bootstrap")
    seed_builtin_groups_and_users()
    return {
        "ok": True,
        "message": f"已建立範例帳號，初始密碼統一為「{_SEED_PASSWORD}」，請立即登入並改密碼",
        "users": [u["username"] for u in list_users()],
    }


@router.post("/login")
def login(body: LoginRequest):
    try:
        info = verify_login(body.username, body.password)
    except AuthError as e:
        raise HTTPException(401, str(e))

    token = create_access_token({
        "sub": info["username"], "user_id": info["user_id"], "group_id": info["group_id"],
        "group_name": info["group_name"], "scope": info["scope"], "owned_ext": info["owned_ext"],
        "permissions": info["permissions"],
    })
    return {
        "access_token": token, "token_type": "bearer",
        "expires_in": ACCESS_TOKEN_EXPIRE_MINUTES * 60,
        "username": info["username"], "group_name": info["group_name"],
        "must_change_password": info["must_change_password"],
    }


@router.get("/me")
def me(user: dict = Depends(get_current_user)):
    return {
        "username": user["sub"], "group_name": user["group_name"],
        "scope": user["scope"], "owned_ext": user["owned_ext"],
        "permissions": {mod: user["permissions"][mod].to_dict() for mod in ALL_MODULES},
    }


@router.post("/change-password")
def change_password(body: ChangePasswordRequest, user: dict = Depends(get_current_user)):
    try:
        change_own_password(user["user_id"], body.old_password, body.new_password)
    except AuthError as e:
        raise HTTPException(400, str(e))
    return {"ok": True, "message": "密碼已更新，請重新登入"}
