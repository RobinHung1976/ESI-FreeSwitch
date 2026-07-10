"""
core/ws_manager.py — WebSocket 連線管理，含權限過濾。

scope="own" 的使用者只應該看到自己分機的即時狀態，
所以 broadcast() 依 ext 參數過濾收件對象，而非無腦全推播。
"""
import asyncio
import json
from typing import Optional
from websockets.legacy.server import WebSocketServerProtocol

from core.auth import decode_access_token, TokenError


class WebSocketManager:
    def __init__(self):
        # ws -> {"username": str, "scope": "all"|"own", "owned_ext": str|None}
        self.clients: dict[WebSocketServerProtocol, dict] = {}

    def authenticate(self, token: str) -> dict:
        """驗證 WS 連線帶入的 JWT，失敗拋 TokenError（呼叫端負責關閉連線）"""
        payload = decode_access_token(token)
        return {
            "username":  payload.get("sub", ""),
            "scope":     payload.get("scope", "own"),  # 缺省視為最嚴格 own，避免因欄位缺漏而放大權限
            "owned_ext": payload.get("owned_ext"),
        }

    def add(self, ws: WebSocketServerProtocol, user_info: dict):
        self.clients[ws] = user_info

    def remove(self, ws: WebSocketServerProtocol):
        self.clients.pop(ws, None)

    async def broadcast(self, data: dict, ext: Optional[str] = None):
        """
        ext=None：一般全域事件（如系統通知），全部連線都收到。
        ext="1001"：分機相關事件（通話狀態、登錄狀態等），scope="own" 只有 owned_ext 相符才收到。
        """
        if not self.clients:
            return
        message = json.dumps(data, ensure_ascii=False)

        targets = []
        for ws, info in self.clients.items():
            if ext is not None and info["scope"] == "own" and info["owned_ext"] != ext:
                continue
            targets.append(ws)

        if not targets:
            return
        await asyncio.gather(
            *[client.send(message) for client in targets],
            return_exceptions=True
        )


manager = WebSocketManager()