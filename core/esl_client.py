import json
import socket
import asyncio
import threading
from core.ws_manager import manager

FS_HOST = "127.0.0.1"
FS_PORT = 8055
FS_PASSWORD = "FSPyAdmin"

def update_esl_config(host: str, port: int, password: str):
    """動態更新 ESL 連線設定（供 /api/config/reload 呼叫）"""
    global FS_HOST, FS_PORT, FS_PASSWORD
    FS_HOST     = host
    FS_PORT     = port
    FS_PASSWORD = password

WATCHED_EVENTS = {
    "CHANNEL_CREATE",
    "CHANNEL_DESTROY",
    "CHANNEL_ANSWER",
    "CHANNEL_HOLD",
    "CHANNEL_UNHOLD",
    "CHANNEL_PARK",
    "CHANNEL_UNPARK",
    "HEARTBEAT",
    # FreeSwitch sofia register/unregister are CUSTOM events with subclass
    "CUSTOM",
}


# ── 底層讀取：逐行讀，遇到空行才結束 header ───────────────────────────────────

class ESLSocket:
    """
    封裝 ESL TCP 連線，提供逐行讀取能力。
    ESL 封包格式：
        Header-Line-1: value\n
        Header-Line-2: value\n
        \n                      ← 空行代表 header 結束
        <body，長度由 Content-Length 決定>
    """

    def __init__(self):
        self._sock: socket.socket | None = None
        self._buf = b""

    def connect(self, host: str, port: int):
        self._sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self._sock.settimeout(15)
        self._sock.connect((host, port))

    def _recv_more(self):
        chunk = self._sock.recv(4096)
        if not chunk:
            raise ConnectionError("ESL socket 已斷線")
        self._buf += chunk

    def read_line(self) -> str:
        """讀取一行（含換行符號，去除後回傳）"""
        while b"\n" not in self._buf:
            self._recv_more()
        idx = self._buf.index(b"\n")
        line = self._buf[:idx]
        self._buf = self._buf[idx + 1:]
        return line.decode("utf-8", errors="replace").rstrip("\r")

    def read_headers(self) -> dict:
        """逐行讀取 header，遇到空行停止"""
        headers = {}
        while True:
            line = self.read_line()
            if line == "":          # 空行 = header 結束
                break
            if ": " in line:
                k, v = line.split(": ", 1)
                headers[k.strip()] = v.strip()
        return headers

    def read_body(self, length: int) -> str:
        """依照 Content-Length 精確讀取 body"""
        while len(self._buf) < length:
            self._recv_more()
        body = self._buf[:length]
        self._buf = self._buf[length:]
        return body.decode("utf-8", errors="replace")

    def read_packet(self) -> tuple[dict, str]:
        """Read a full ESL packet. If Content-Type is text/event-plain,
        the body itself contains the event headers - parse them."""
        headers = self.read_headers()
        length = int(headers.get("Content-Length", 0))
        body = self.read_body(length) if length > 0 else ""
        # text/event-plain: body IS the event headers, re-parse
        if headers.get("Content-Type") == "text/event-plain" and body:
            event_headers = {}
            for line in body.splitlines():
                if ": " in line:
                    k, v = line.split(": ", 1)
                    event_headers[k.strip()] = v.strip()
            return event_headers, ""
        return headers, body

    def send(self, text: str):
        self._sock.sendall(text.encode("utf-8"))


def _make_authed_socket(host, port, password) -> ESLSocket:
    """建立並完成認證的 ESL 連線"""
    s = ESLSocket()
    s.connect(host, port)

    # 讀取 auth/request
    headers, _ = s.read_packet()
    assert headers.get("Content-Type") == "auth/request", f"預期 auth/request，收到：{headers}"

    # 送出密碼
    s.send(f"auth {password}\n\n")

    # 讀取 command/reply
    headers, body = s.read_packet()
    reply = headers.get("Reply-Text", body)
    if "+OK accepted" not in reply:
        raise RuntimeError(f"ESL 認證失敗：{reply}")

    return s


# ── 主類別 ────────────────────────────────────────────────────────────────────

class FreeSwitchESL:
    def __init__(self):
        self._api_sock: ESLSocket | None = None
        self._lock = threading.Lock()
        self._loop: asyncio.AbstractEventLoop | None = None
        self._status_callback = None   # 供 server.py 注入狀態處理函數

    def set_status_callback(self, cb):
        """server.py 注入：每個 Channel/Register 事件觸發後呼叫 cb(event_name, headers)"""
        self._status_callback = cb

    def connect(self):
        self._api_sock = _make_authed_socket(FS_HOST, FS_PORT, FS_PASSWORD)
        # 認證後移除 timeout，讓 API 呼叫可以等待回應
        self._api_sock._sock.settimeout(None)
        print(f"ESL 已連線至 {FS_HOST}:{FS_PORT}")

    def reconnect(self, host: str | None = None, port: int | None = None, password: str | None = None):
        """
        重新建立 API socket 連線。
        若帶入新的 host/port/password，先更新全域設定再重連。
        事件監聽 socket 為獨立執行緒，重連後會在下次斷線時自動重啟，
        因此這裡只重建 API socket（立即生效）。
        """
        import esl_client as _self_mod
        if host is not None:
            _self_mod.FS_HOST     = host
        if port is not None:
            _self_mod.FS_PORT     = port
        if password is not None:
            _self_mod.FS_PASSWORD = password

        with self._lock:
            try:
                if self._api_sock and self._api_sock._sock:
                    self._api_sock._sock.close()
            except Exception:
                pass
            self._api_sock = _make_authed_socket(
                _self_mod.FS_HOST, _self_mod.FS_PORT, _self_mod.FS_PASSWORD
            )
            self._api_sock._sock.settimeout(None)
        print(f"ESL 已重連至 {_self_mod.FS_HOST}:{_self_mod.FS_PORT}")

    def api(self, command: str) -> str:
        """執行 ESL API 指令，回傳 body 字串"""
        with self._lock:
            self._api_sock.send(f"api {command}\n\n")
            headers, body = self._api_sock.read_packet()
            return body.strip()

    # ── 常用 API ──────────────────────────────────────────────────────────────

    def get_calls(self) -> dict:
        raw = self.api("show calls as json")
        try:
            return json.loads(raw)
        except json.JSONDecodeError:
            return {"rows": [], "rowCount": 0}

    def get_channels(self) -> dict:
        raw = self.api("show channels as json")
        try:
            return json.loads(raw)
        except json.JSONDecodeError:
            return {"rows": [], "rowCount": 0}

    def get_registrations(self) -> dict:
        raw = self.api("show registrations as json")
        try:
            return json.loads(raw)
        except json.JSONDecodeError:
            return {"rows": [], "rowCount": 0}

    def hangup_call(self, uuid: str) -> str:
        return self.api(f"uuid_kill {uuid}")

    def hold_call(self, uuid: str) -> str:
        return self.api(f"uuid_hold {uuid}")

    def transfer_call(self, uuid: str, dest: str) -> str:
        return self.api(f"uuid_transfer {uuid} {dest} XML default")

    # ── 事件監聽（獨立 socket）────────────────────────────────────────────────

    def set_event_loop(self, loop: asyncio.AbstractEventLoop):
        self._loop = loop

    def start_event_loop(self):
        """開獨立連線訂閱事件，與 API socket 完全分開"""
        def listen():
            try:
                ev = _make_authed_socket(FS_HOST, FS_PORT, FS_PASSWORD)
                ev._sock.settimeout(None)

                # 訂閱所有事件
                ev.send("event plain all\n\n")
                ev.read_packet()   # 吃掉 +OK

                print("ESL 事件監聽已啟動")

                while True:
                    headers, body = ev.read_packet()
                    event_name = headers.get("Event-Name", "")

                    # FreeSwitch sofia register/unregister come as CUSTOM events
                    # Remap: CUSTOM + sofia::register -> REGISTER
                    if event_name == "CUSTOM":
                        subclass = headers.get("Event-Subclass", "")
                        # FreeSwitch URL-encodes the subclass: sofia%3A%3Aregister
                        if subclass in ("sofia::register", "sofia%3A%3Aregister"):
                            event_name = "REGISTER"
                        elif subclass in ("sofia::unregister", "sofia%3A%3Aunregister",
                                          "sofia::expire",    "sofia%3A%3Aexpire"):
                            event_name = "UNREGISTER"
                        else:
                            continue  # other CUSTOM events we don't need

                    if event_name not in WATCHED_EVENTS and event_name not in ("REGISTER", "UNREGISTER"):
                        continue
                    # DEBUG: 確認 Channel-Name 原始格式
                    if event_name.startswith("CHANNEL_"):
                        print(f"[ESL_RAW] {event_name} "
                              f"Channel-Name={headers.get('Channel-Name','?')} "
                              f"Direction={headers.get('Call-Direction','?')} "
                              f"Caller={headers.get('Caller-Caller-ID-Number','?')} "
                              f"Dest={headers.get('Caller-Destination-Number','?')}")

                    payload = {
                        "type":        event_name,
                        "uuid":        headers.get("Unique-ID", ""),
                        "Unique-ID":   headers.get("Unique-ID", ""),
                        "caller":      headers.get("Caller-Caller-ID-Number", ""),
                        "destination": headers.get("Caller-Destination-Number", ""),
                        "direction":   headers.get("Call-Direction", ""),
                        "timestamp":   headers.get("Event-Date-Local", ""),
                        # 未接來電偵測所需欄位
                        "Caller-Caller-ID-Number": headers.get("Caller-Caller-ID-Number", ""),
                        "Caller-Caller-ID-Name":   headers.get("Caller-Caller-ID-Name", ""),
                        "Call-Direction":           headers.get("Call-Direction", ""),
                        "Hangup-Cause":             headers.get("Hangup-Cause", ""),
                        # 分機狀態即時更新所需欄位
                        "Channel-Name":             headers.get("Channel-Name", ""),
                        "Answer-State":             headers.get("Answer-State", ""),
                        "Channel-State":            headers.get("Channel-State", ""),
                        "Hold-Accum":               headers.get("variable_hold_accum", ""),
                        # REGISTER / UNREGISTER 欄位
                        "from-user":                headers.get("from-user", ""),
                        "from-host":                headers.get("from-host", ""),
                        "network-ip":               headers.get("network-ip", ""),
                        # PRESENCE_IN 欄位
                        "Presence-Call-Direction":  headers.get("Presence-Call-Direction", ""),
                        "Channel-Presence-ID":      headers.get("Channel-Presence-ID", ""),
                    }

                    # 通知 server.py 更新分機狀態表（在事件執行緒中同步呼叫）
                    if self._status_callback:
                        try:
                            # debug：印出 REGISTER/UNREGISTER 的完整 headers
                            self._status_callback(event_name, headers)
                        except Exception as cb_err:
                            print(f"status_callback 錯誤：{cb_err}")

                    if self._loop:
                        asyncio.run_coroutine_threadsafe(
                            manager.broadcast(payload), self._loop
                        )

            except Exception as e:
                print(f"ESL 事件監聽錯誤：{e}")

        threading.Thread(target=listen, daemon=True).start()


esl = FreeSwitchESL()