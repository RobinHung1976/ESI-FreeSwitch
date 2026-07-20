"""
core/auth.py — JWT 簽發/驗證 + FastAPI 權限 dependency。

手寫 HS256（stdlib hmac/hashlib/base64），理由同 auth_db.py 的密碼雜湊：
專案 requirements.txt 精簡，避免為單一功能引入 PyJWT/python-jose。

權限改變不即時生效（設計決議）：perms 整包塞進 JWT payload，
require_permission() 只解 token 不查 DB，換取效能；代價是要重新登入才會反映異動。
"""
import hmac
import json
import time
import base64
import hashlib
from typing import Literal

from fastapi import Depends, HTTPException
from fastapi.security import HTTPBearer, HTTPAuthorizationCredentials

from core.auth_db import get_or_create_jwt_secret
from core.permissions import Perm, SCOPABLE_MODULES

Action = Literal["read", "create", "update", "delete"]

ACCESS_TOKEN_EXPIRE_MINUTES = 30
_JWT_ALG = "HS256"
_SECRET: str | None = None  # lazy-load，第一次使用時才查/建 DB

_security = HTTPBearer(auto_error=False)


def _secret() -> bytes:
    global _SECRET
    if _SECRET is None:
        _SECRET = get_or_create_jwt_secret()
    return _SECRET.encode("utf-8")


def _b64url_encode(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def _b64url_decode(s: str) -> bytes:
    padding = "=" * (-len(s) % 4)
    return base64.urlsafe_b64decode(s + padding)


class TokenError(Exception):
    """token 缺失/格式錯誤/簽章不符/過期，統一轉成 401"""


def create_access_token(claims: dict, expires_minutes: int = ACCESS_TOKEN_EXPIRE_MINUTES) -> str:
    now = int(time.time())
    header = {"alg": _JWT_ALG, "typ": "JWT"}
    payload = {**claims, "iat": now, "exp": now + expires_minutes * 60}

    signing_input = f"{_b64url_encode(json.dumps(header).encode())}." \
                     f"{_b64url_encode(json.dumps(payload).encode())}"
    signature = hmac.new(_secret(), signing_input.encode("ascii"), hashlib.sha256).digest()
    return f"{signing_input}.{_b64url_encode(signature)}"


def decode_access_token(token: str) -> dict:
    try:
        header_b64, payload_b64, sig_b64 = token.split(".")
    except ValueError:
        raise TokenError("token 格式錯誤")

    signing_input = f"{header_b64}.{payload_b64}".encode("ascii")
    expected_sig = hmac.new(_secret(), signing_input, hashlib.sha256).digest()
    if not hmac.compare_digest(expected_sig, _b64url_decode(sig_b64)):
        raise TokenError("token 簽章不符")

    payload = json.loads(_b64url_decode(payload_b64))
    if payload.get("exp", 0) < time.time():
        raise TokenError("token 已過期，請重新登入")
    return payload


# ── FastAPI Dependencies ──────────────────────────────────────────────────

def get_current_user(creds: HTTPAuthorizationCredentials | None = Depends(_security)) -> dict:
    if creds is None:
        raise HTTPException(401, "缺少登入憑證")
    try:
        payload = decode_access_token(creds.credentials)
    except TokenError as e:
        raise HTTPException(401, str(e))

    # perms 存 token 時是 {module: {read,create,update,delete}}，這裡還原成 Perm 物件方便呼叫 .allows()
    payload["permissions"] = {
        mod: Perm(**flags) for mod, flags in payload.get("permissions", {}).items()
    }
    return payload


def require_permission(module: str, action: Action):
    """掛在 router 或單一 endpoint 的 dependencies=[]，403 時中斷請求"""
    def _dep(user: dict = Depends(get_current_user)) -> dict:
        perm: Perm = user["permissions"].get(module, Perm())
        if not perm.allows(action):
            raise HTTPException(403, f"權限不足：{module} 需要 {action} 權限")
        return user
    return _dep


def get_current_user_sse(
    token: str | None = None,
    creds: HTTPAuthorizationCredentials | None = Depends(_security),
) -> dict:
    """
    SSE 專用認證：瀏覽器原生 EventSource 無法自訂 Authorization header，
    比照既有 WebSocket 認證作法（core/runtime.py ws_handler 的 ?token=），
    改為 header 或 query string token 兩者擇一皆可通過；一般 REST API
    仍只認 header（見 get_current_user），不受此函式影響。
    """
    raw_token = creds.credentials if creds is not None else token
    if not raw_token:
        raise HTTPException(401, "缺少登入憑證")
    try:
        payload = decode_access_token(raw_token)
    except TokenError as e:
        raise HTTPException(401, str(e))

    payload["permissions"] = {
        mod: Perm(**flags) for mod, flags in payload.get("permissions", {}).items()
    }
    return payload


def require_permission_sse(module: str, action: Action):
    """SSE 端點專用版本的 require_permission，認證走 get_current_user_sse"""
    def _dep(user: dict = Depends(get_current_user_sse)) -> dict:
        perm: Perm = user["permissions"].get(module, Perm())
        if not perm.allows(action):
            raise HTTPException(403, f"權限不足：{module} 需要 {action} 權限")
        return user
    return _dep


def apply_scope(user: dict, requested_ext: str | None, module: str) -> str | None:
    """
    scope='own' 的使用者，即使前端傳了別的分機號也強制鎖定成自己的 owned_ext；
    非 scopable 模組（scope='own' 卻誤呼叫到不支援過濾的模組）直接拒絕存取。
    """
    if user["scope"] != "own":
        return requested_ext
    if module not in SCOPABLE_MODULES:
        raise HTTPException(403, "此帳號僅能存取自己分機的資料，該模組不支援此範圍")
    return user["owned_ext"]
