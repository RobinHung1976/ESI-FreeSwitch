"""
core/runtime.py — 背景執行期邏輯：ESL 事件回調、log/CDR 每日排程、WebSocket。

這些函式在原本的 server.py 是「跟哪個 API 端點都沒有直接對應關係」的
背景基礎設施，被 lifespan、多個 router 共同呼叫，所以獨立放在這裡，
而不是塞進任何一個 routers/*.py。
"""
import os
import json
import glob
import shutil
import asyncio
import websockets
from datetime import datetime, timedelta

from core.esl_client import esl
from core.ws_manager import manager
from core.backup_manager import backup_dashboard_config, backup_freeswitch_packages, cleanup_old_backups
from core import state
from core import cdr_db
from core import reg_log_db
from core.auth import TokenError
from urllib.parse import urlparse, parse_qs


def ext_from_channel_name(ch_name: str) -> str:
    """
    從 Channel-Name 取出分機號碼，僅接受 sofia/internal/ 或 sofia/default/ 前綴。
    外線 channel（sofia/external/, sofia/gateway/ 等）回傳空字串，避免誤判。
    """
    if not ch_name:
        return ""
    try:
        # 先解碼 URL encoding（%40 → @）
        ch_name = ch_name.replace("%40", "@")
        # 格式：sofia/<profile>/<number>@<host>
        parts = ch_name.split("/")
        if len(parts) < 3:
            return ""
        profile = parts[1].lower()
        if profile not in ("internal", "default"):
            return ""
        num = parts[2].split("@")[0].strip()
        # 排除非數字分機（避免外線號碼或 UUID 誤判）
        if not num.isdigit():
            return ""
        return num
    except Exception:
        return ""



import time as _time

def update_ext_status(event_name: str, headers: dict):
    """
    由 ESL 事件執行緒呼叫，更新 ext_status 並透過 WebSocket 推播給前端。
    此函數執行在背景執行緒，透過 run_coroutine_threadsafe 發送非同步推播。
    """
    ch_name  = headers.get("Channel-Name", "")
    uuid     = headers.get("Unique-ID", "")
    caller   = headers.get("Caller-Caller-ID-Number", "")
    dest     = headers.get("Caller-Destination-Number", "")
    direction= headers.get("Call-Direction", "")     # inbound / outbound
    ans_state= headers.get("Answer-State", "")       # ringing / answered / hangup
    ext_num  = ext_from_channel_name(ch_name)

    now_ts = int(_time.time() * 1000)

    # ── REGISTER / UNREGISTER ─────────────────────────────────────────────────
    if event_name == "REGISTER":
        reg_user = (headers.get("from-user", "")
                    or headers.get("username", "")
                    or headers.get("reg_user", "")).split("@")[0].strip()
        network_ip = headers.get("network-ip", "") or headers.get("from-host", "")
        network_proto = headers.get("network-proto", "udp")
        print(f"[REGISTER] user={reg_user!r} ip={network_ip!r}")
        if reg_user:
            write_reg_log(reg_user, "REGISTER", network_ip, network_proto, now_ts)
            prev = state.ext_status.get(reg_user, {})
            if prev.get("status") in (None, "offline", ""):
                state.ext_status[reg_user] = {
                    "status": "idle", "peer": "", "direction": "", "since": now_ts
                }
                broadcast_ext_status(reg_user)
        return

    if event_name == "UNREGISTER":
        reg_user = (headers.get("username", "")
                    or headers.get("from-user", "")
                    or headers.get("reg_user", "")).split("@")[0].strip()
        network_ip = headers.get("network-ip", "") or headers.get("from-host", "")
        network_proto = headers.get("network-proto", "udp")
        print(f"[UNREGISTER] user={reg_user!r} ip={network_ip!r}")
        if reg_user:
            write_reg_log(reg_user, "UNREGISTER", network_ip, network_proto, now_ts)
            state.ext_status[reg_user] = {
                "status": "offline", "peer": "", "direction": "", "since": now_ts
            }
            broadcast_ext_status(reg_user)
        return
    # ── CHANNEL 事件：只處理能解析出分機號碼的 channel ──────────────────────
    if not ext_num:
        return

    if event_name == "CHANNEL_CREATE":
        if not ext_num:
            return
        state.uuid_to_ext[uuid] = ext_num
        
        # outbound：分機主動撥出，peer 是被叫號碼
        # inbound：外線打進來，peer 是來電號碼（caller）
        # 若 caller == ext_num 自己，顯示 dest 避免「自己打自己」的顯示
        if direction == "outbound":
            peer = dest
        else:
            peer = caller if caller and caller != ext_num else dest

        cur = state.ext_status.get(ext_num, {})
    # 如果已經是 talking/holding，不要退回 ringing（可能是 B leg 晚到）
        if cur.get("status") not in ("talking", "holding"):
            state.ext_status[ext_num] = {
            "status": "ringing", "peer": peer, "direction": direction, "since": now_ts
            }
            broadcast_ext_status(ext_num)

    elif event_name == "CHANNEL_ANSWER":
        state.uuid_to_ext[uuid] = ext_num
        peer = dest if direction == "outbound" else caller
        state.ext_status[ext_num] = {
            "status": "talking", "peer": peer, "direction": direction, "since": now_ts
        }
        broadcast_ext_status(ext_num)

    elif event_name == "CHANNEL_HOLD":
        cur = state.ext_status.get(ext_num, {})
        state.ext_status[ext_num] = {
            "status": "holding",
            "peer": cur.get("peer", ""),
            "direction": cur.get("direction", direction),
            "since": now_ts,
        }
        broadcast_ext_status(ext_num)

    elif event_name == "CHANNEL_UNHOLD":
        cur = state.ext_status.get(ext_num, {})
        state.ext_status[ext_num] = {
            "status": "talking",
            "peer": cur.get("peer", ""),
            "direction": cur.get("direction", direction),
            "since": now_ts,
        }
        broadcast_ext_status(ext_num)

    elif event_name == "CHANNEL_PARK":
        cur = state.ext_status.get(ext_num, {})
        state.ext_status[ext_num] = {
            "status": "parked",
            "peer": cur.get("peer", ""),
            "direction": cur.get("direction", direction),
            "since": now_ts,
        }
        broadcast_ext_status(ext_num)

    elif event_name == "CHANNEL_UNPARK":
        cur = state.ext_status.get(ext_num, {})
        state.ext_status[ext_num] = {
            "status": "talking",
            "peer": cur.get("peer", ""),
            "direction": cur.get("direction", direction),
            "since": now_ts,
        }
        broadcast_ext_status(ext_num)

    elif event_name == "CHANNEL_DESTROY":
        # 清除 UUID 對照
        state.uuid_to_ext.pop(uuid, None)
        # 只在沒有其他 active channel 的情況下才設回 idle
        # （同一分機可能有多個 leg，例如轉接中）
        still_active = any(e == ext_num for e in state.uuid_to_ext.values())
        if not still_active:
        # 確認是否仍在線上（offline 分機 DESTROY 不應設回 idle）
            cur = state.ext_status.get(ext_num, {})
            if cur.get("status") != "offline":
                state.ext_status[ext_num] = {
                "status": "idle", "peer": "", "direction": "", "since": now_ts
                }
                broadcast_ext_status(ext_num)


def broadcast_ext_status(ext_num: str):
    """把單一分機的最新狀態透過 WebSocket 推播給所有瀏覽器"""
    if not esl._loop:
        return
    payload = {
        "type": "EXT_STATUS_UPDATE",
        "ext":  ext_num,
        **state.ext_status.get(ext_num, {}),
    }
    asyncio.run_coroutine_threadsafe(
        manager.broadcast(payload, ext=ext_num), esl._loop
    )


# 2026-07-16：分機定期自動刷新 SIP 註冊（keepalive）不視為新登入，
# 只有「首次註冊 / 先前已登出後重新登入 / IP 或協定變動」才真正寫入 reg_log。
# 服務重啟後歸零屬預期行為（跟 state.ext_status 等其他記憶體狀態一致）。
_last_reg_state: dict = {}


def write_reg_log(ext: str, event: str, ip: str, proto: str, ts_ms: int):
    """Write registration event to persistent SQLite log（core/reg_log_db.py）。
    2026-07-15：取代原本的記憶體 list（服務重啟即歸零）。
    2026-07-16：新增去重，過濾掉分機定期自動刷新註冊造成的重複記錄。
    """
    import datetime as _dt
    time_str = _dt.datetime.fromtimestamp(ts_ms / 1000).strftime('%Y-%m-%d %H:%M:%S')
    proto_up = proto.upper() if proto else "UDP"

    # ── 去重：同分機、同 IP/協定的連續 REGISTER 視為單純 keepalive 刷新 ──
    prev = _last_reg_state.get(ext)
    if (event == "REGISTER" and prev and prev.get("event") == "REGISTER"
            and prev.get("ip") == ip and prev.get("proto") == proto_up):
        return
    _last_reg_state[ext] = {"event": event, "ip": ip, "proto": proto_up}

    try:
        reg_log_db.insert_log(ext, event, ip, proto_up, ts_ms, time_str)
    except Exception as e:
        print(f"[REG_LOG] SQLite 寫入失敗：{e}")
    print(f"[REG_LOG] {event} ext={ext} ip={ip} at {time_str}")

    # Inject into live log SSE stream as a synthetic log line
    level = "NOTICE"
    if event == "UNREGISTER":
        msg = f"[Registration] {ext} UN-Registered from {ip} ({proto})"
    else:
        msg = f"[Registration] {ext} Registered from {ip} ({proto})"
    synthetic_line = f"{time_str} [{level}] sofia_reg.c:0 {msg}"
    if state.log_inject_queues and esl._loop:
        async def _inject(line=synthetic_line):
            dead = set()
            for q in list(state.log_inject_queues):
                try:
                    q.put_nowait(line)
                except Exception:
                    dead.add(q)
            state.log_inject_queues.difference_update(dead)
        asyncio.run_coroutine_threadsafe(_inject(), esl._loop)


async def reg_sync_scheduler():
    """
    每 30 秒主動查詢 show registrations，同步分機的 idle/offline 狀態。
    這是 UNREGISTER 事件的保險機制：
      - 分機正常登出 → FreeSwitch 發 UNREGISTER 事件（即時）
      - 分機強制斷線 → 沒有 UNREGISTER 事件，靠這個排程補救
    """
    import time as _t
    while True:
        await asyncio.sleep(30)
        try:
            reg_data = esl.get_registrations()
            reg_rows = reg_data.get("rows", []) if isinstance(reg_data, dict) else []
            # 目前已登錄的分機 set
            registered_now = set()
            for r in reg_rows:
                raw = r.get("reg_user", "") or r.get("user", "")
                u = raw.split("@")[0].strip()
                if u:
                    registered_now.add(u)

            now_ts = int(_t.time() * 1000)
            changed = []

            for ext, st in state.ext_status.items():
                if ext in registered_now:
                    # 分機有登錄：若目前是 offline 改為 idle
                    if st.get("status") == "offline":
                        state.ext_status[ext] = {"status": "idle", "peer": "", "direction": "", "since": now_ts}
                        changed.append(ext)
                else:
                    # 分機沒有登錄：若目前不是 offline/talking/holding 就改為 offline
                    # （talking/holding 可能是 ESL 尚未發 DESTROY，保守處理）
                    if st.get("status") in ("idle", "ringing", "parked"):
                        state.ext_status[ext] = {"status": "offline", "peer": "", "direction": "", "since": now_ts}
                        changed.append(ext)

            if changed:
                print(f"[reg-sync] 狀態修正：{changed}")
                for ext in changed:
                    broadcast_ext_status(ext)

        except Exception as e:
            print(f"[reg-sync] 查詢失敗：{e}")


# ── Log 路徑設定 ──────────────────────────────────────────────────────────────

FS_LOG_DIR  = "/var/log/freeswitch"
FS_LOG_FILE = f"{FS_LOG_DIR}/freeswitch.log"


# ── 設定檔（保留天數等後端設定）──────────────────────────────────────────────

SETTINGS_FILE = "/opt/fs-dashboard/settings.json"

def load_server_settings() -> dict:
    defaults = {
        "log_retain_days": 30,
        "cdr_retain_days": 30,
        "cdr_summary_retain_days": 730,   # 每日彙總（SQLite）長期保留天數，與 raw 明細分開計算
        "reg_log_retain_days": 90,        # 登錄記錄（reg_log，SQLite）保留天數，2026-07-15 起持久化
    }
    try:
        if os.path.isfile(SETTINGS_FILE):
            with open(SETTINGS_FILE, "r", encoding="utf-8") as f:
                data = json.load(f)
                return {**defaults, **data}
    except Exception:
        pass
    return defaults

def save_server_settings(data: dict):
    os.makedirs(os.path.dirname(SETTINGS_FILE), exist_ok=True)
    current = load_server_settings()
    current.update(data)
    with open(SETTINGS_FILE, "w", encoding="utf-8") as f:
        json.dump(current, f, ensure_ascii=False, indent=2)


def _send_freeswitch_hup() -> dict:
    """
    送出 SIGHUP 給 FreeSwitch 主 process，觸發 mod_logfile 依
    logfile.conf.xml 的 rotate-on-hup=true 設定重新開啟 log 檔案。

    背景（2026-08-11 稽核發現，見 changelog-details/20260811-log-rotate-hup-fix.md）：
    FreeSwitch 收到 SIGHUP 前，既有 file descriptor 的寫入 offset 停留在
    HUP 之前的位置，外部單純 truncate 檔案內容完全不會讓 FreeSwitch 知道、
    也不會重置這個 offset。沒有這一步，_rotate_log_now() 的 truncate
    形同虛設，新內容實質上寫不進使用者看得到的檔案——這是本專案上線以來
    持續存在、直到 2026-08-11 才被發現的資料遺失型 bug。

    官方文件：https://developer.signalwire.com/freeswitch/FreeSWITCH-Explained/Modules/mod_logfile_1048990
    （標準做法即 `kill -HUP <freeswitch pid>`）。

    mod_logfile 收到 HUP 後，會自行把「當下的 freeswitch.log」再 rename
    成 freeswitch.log.<FreeSwitch 內部時間戳記> 並開一個全新的空檔——
    由於呼叫本函式前 freeswitch.log 已經被我們 truncate 成 0 bytes，
    這個副產物檔案必然是 0 bytes 空檔，屬無害殘留，一併清掉避免「日誌
    管理」頁面看到來路不明的空檔案。
    """
    import signal
    import subprocess
    import time as _t

    try:
        pgrep_result = subprocess.run(
            ["pgrep", "-f", "bin/freeswitch"],
            capture_output=True, text=True, timeout=5
        )
        pids = [p for p in pgrep_result.stdout.strip().splitlines() if p]
        if not pids:
            return {"ok": False, "error": "找不到 FreeSwitch process，log 檔案未通知重新開啟"}
        fs_pid = int(pids[0])
        os.kill(fs_pid, signal.SIGHUP)
    except Exception as e:
        return {"ok": False, "error": f"送出 SIGHUP 失敗：{e}"}

    # 短暫等待 mod_logfile／mod_cdr_csv 處理 HUP 並完成各自的 rename，
    # 再清掉它們產生的空殘留檔（log 與 CDR 兩種副產物都要清）
    _t.sleep(0.5)
    cleaned = []
    for base_path in (FS_LOG_FILE, CDR_MASTER):
        try:
            for f in glob.glob(f"{base_path}.*"):
                try:
                    if os.path.isfile(f) and os.path.getsize(f) == 0:
                        os.remove(f)
                        cleaned.append(os.path.basename(f))
                except Exception:
                    pass
        except Exception:
            pass

    return {"ok": True, "pid": fs_pid, "cleaned_empty_artifacts": cleaned}


def _rotate_log_now() -> dict:
    """
    將 freeswitch.log 依昨天日期（或目前內容最早日期）另存為
    freeswitch-YYYY-MM-DD.log，然後清空原始 log。

    注意：本函式**不會**送出 SIGHUP。2026-08-11 修復後，HUP 一律由
    `_rotate_log_and_cdr_now()` 在 log 與 CDR 兩邊都完成 truncate 後
    統一送出一次——因為 SIGHUP 是 FreeSwitch process 層級訊號，
    mod_logfile／mod_cdr_csv 會同時反應，若只有其中一邊完成 truncate
    就送出訊號，另一邊尚未安全歸檔的內容會被 FreeSwitch 自己的
    rotate-on-hup 邏輯搬進 Dashboard 不認識的孤兒檔案，等同製造新的
    資料遺失。單獨呼叫本函式（不接著送 HUP）會導致 FreeSwitch 既有 fd
    的寫入 offset 不重置、新內容實質上寫不進去，見
    changelog-details/20260811-log-rotate-hup-fix.md。
    回傳操作結果 dict。
    """
    import re
    yesterday = (datetime.now() - timedelta(days=1)).strftime("%Y-%m-%d")
    dest_name = f"freeswitch-{yesterday}.log"
    dest_path = os.path.join(FS_LOG_DIR, dest_name)

    if not os.path.isfile(FS_LOG_FILE):
        return {"ok": False, "error": "freeswitch.log 不存在"}

    # 避免重複 rotate（同一天已經 rotate 過）
    if os.path.exists(dest_path):
        return {"ok": False, "error": f"{dest_name} 已存在，略過"}

    try:
        # 複製（而非移動）到日期檔，保留原檔供 FreeSwitch 繼續寫入
        shutil.copy2(FS_LOG_FILE, dest_path)
        # 清空原始 log（truncate，不刪檔，保留檔名/inode）
        with open(FS_LOG_FILE, "w") as f:
            f.truncate(0)
        size = os.path.getsize(dest_path)
        print(f"[log-rotate] {dest_path} ({size} bytes)")
        return {"ok": True, "file": dest_name, "path": dest_path, "size": size}
    except Exception as e:
        return {"ok": False, "error": str(e)}


def _cleanup_old_logs():
    """刪除超過保留天數的歷史日誌檔"""
    settings = load_server_settings()
    retain_days = int(settings.get("log_retain_days", 30))
    cutoff = datetime.now() - timedelta(days=retain_days)
    pattern = os.path.join(FS_LOG_DIR, "freeswitch-????-??-??.log")
    deleted = []
    for f in glob.glob(pattern):
        basename = os.path.basename(f)
        # 從檔名取日期 freeswitch-YYYY-MM-DD.log
        try:
            date_str = basename.replace("freeswitch-", "").replace(".log", "")
            file_date = datetime.strptime(date_str, "%Y-%m-%d")
            if file_date < cutoff:
                os.remove(f)
                deleted.append(basename)
                print(f"[log-cleanup] 已刪除 {basename}")
        except Exception as e:
            print(f"[log-cleanup] 跳過 {basename}：{e}")
    return deleted


CDR_DIR     = "/var/log/freeswitch/cdr-csv"
CDR_MASTER  = f"{CDR_DIR}/Master.csv"

def _rotate_cdr_now(use_today: bool = False) -> dict:
    """將 Master.csv 歸檔為 cdr-YYYY-MM-DD.csv，然後清空 Master.csv
    use_today=True 時用今天日期（手動觸發），False 時用昨天日期（排程觸發）
    """
    if use_today:
        date_str = datetime.now().strftime("%Y-%m-%d")
    else:
        date_str = (datetime.now() - timedelta(days=1)).strftime("%Y-%m-%d")
    dest_name = f"cdr-{date_str}.csv"
    dest_path = os.path.join(CDR_DIR, dest_name)

    # Master.csv 不存在時建立空白檔
    os.makedirs(CDR_DIR, exist_ok=True)
    if not os.path.isfile(CDR_MASTER):
        open(CDR_MASTER, "w").close()

    if os.path.exists(dest_path):
        return {"ok": False, "error": f"{dest_name} 今日已歸檔，無需重複執行"}

    try:
        # 歸檔前先把當天完整資料同步進 SQLite，並建立長期彙總（cdr_daily_summary）
        # 這一步是後續 raw 明細可以被安全 purge、但報表仍能查到該天統計的關鍵
        cdr_db.init_db()
        cdr_db.import_csv_file(CDR_MASTER)
        cdr_db.build_daily_summary(date_str)

        shutil.copy2(CDR_MASTER, dest_path)
        with open(CDR_MASTER, "w") as f:
            f.truncate(0)
        size = os.path.getsize(dest_path)
        print(f"[cdr-rotate] {dest_path} ({size} bytes)")
        return {"ok": True, "file": dest_name, "path": dest_path, "size": size}
    except Exception as e:
        return {"ok": False, "error": str(e)}


def _file_is_empty_or_missing(path: str) -> bool:
    """檔案不存在或大小為 0 bytes（代表沒有尚未安全歸檔的內容會被 HUP 誤搬走）"""
    try:
        return (not os.path.isfile(path)) or os.path.getsize(path) == 0
    except Exception:
        return False


def _rotate_log_and_cdr_now(cdr_use_today: bool = False, primary: str = "log") -> dict:
    """
    Log 與 CDR 合併輪轉（2026-08-11 修復核心邏輯，見
    changelog-details/20260811-log-rotate-hup-fix.md）。

    背景：FreeSwitch 的 `rotate-on-hup` 是 process 層級設定，SIGHUP 送出後
    mod_logfile／mod_cdr_csv 會**同時**反應。過去 `_rotate_log_now()`／
    `_rotate_cdr_now()` 各自獨立呼叫、彼此不知道對方進度，若只針對其中一個
    檔案 truncate 完就送出 HUP，另一個尚未被我們安全複製走的檔案內容，會被
    FreeSwitch 自己的 rotate-on-hup 邏輯搬進 Dashboard 完全不認識的孤兒檔案
    （例如 freeswitch.log.<FreeSwitch 內部時間戳記>），等同製造新的資料遺失。

    因此改為：log 與 CDR 各自完成「複製＋truncate」後，才統一送出一次 HUP；
    且只有在兩邊都「這次真的有 truncate 到」或「檔案本來就是空的（沒東西可
    丟）」時才送出 HUP，避免「今日已歸檔」這類 no-op 情況下，另一邊還有
    未保存的新內容卻被 HUP 意外搬走。

    cdr_use_today: 比照原本 `_rotate_cdr_now()` 的參數語意，True＝歸檔今天
        （手動觸發應使用，因為按下當下 Master.csv 裡裝的是「今天」尚未
        歸檔的內容），False＝歸檔昨天（排程觸發，午夜後執行時 Master.csv
        裡裝的是「昨天」的內容）。
    primary: "log" 或 "cdr"，決定哪一邊的結果攤平到最外層，維持
        `/api/logs/rotate`／`/api/cdr/rotate` 個別呼叫時原本的回傳格式
        （`ok`/`file`/`path`/`size`）相容；另一邊的完整結果仍可從
        回傳值的 "log"/"cdr" key 底下查到。
    """
    log_result = _rotate_log_now()
    cdr_result = _rotate_cdr_now(use_today=cdr_use_today)

    log_safe = log_result.get("ok") or _file_is_empty_or_missing(FS_LOG_FILE)
    cdr_safe = cdr_result.get("ok") or _file_is_empty_or_missing(CDR_MASTER)
    any_truncated = log_result.get("ok") or cdr_result.get("ok")

    if any_truncated and log_safe and cdr_safe:
        hup_result = _send_freeswitch_hup()
        if not hup_result.get("ok"):
            print(f"[rotate] ⚠ SIGHUP 失敗：{hup_result.get('error')}，"
                  f"已 truncate 的檔案可能仍卡在 FreeSwitch 舊 offset")
    elif not any_truncated:
        hup_result = {"ok": False, "error": "略過：log 與 CDR 皆無實際 truncate 動作"}
    else:
        hup_result = {
            "ok": False,
            "error": "略過 HUP：另一邊尚有未安全歸檔的內容（例如今日已歸檔過但"
                     "檔案已有新資料累積），避免造成孤兒檔案資料遺失，本次僅"
                     "完成已成功的那一邊，未重置 FreeSwitch 寫入 offset",
        }

    combined_ok = bool(any_truncated)
    base = dict(log_result if primary == "log" else cdr_result)
    base.pop("error", None)
    base["ok"] = combined_ok
    if not combined_ok:
        base["error"] = f"log: {log_result.get('error')}; cdr: {cdr_result.get('error')}"
    base["log"] = log_result
    base["cdr"] = cdr_result
    base["hup"] = hup_result
    return base


def _cleanup_old_cdrs():
    """刪除超過保留天數的歷史 CDR：CSV 備援檔 + SQLite raw 明細；彙總資料另用長期保留天數清理"""
    settings = load_server_settings()
    retain_days = int(settings.get("cdr_retain_days", 30))
    cutoff = datetime.now() - timedelta(days=retain_days)
    pattern = os.path.join(CDR_DIR, "cdr-????-??-??.csv")
    deleted = []
    for f in glob.glob(pattern):
        basename = os.path.basename(f)
        try:
            date_str = basename.replace("cdr-", "").replace(".csv", "")
            file_date = datetime.strptime(date_str, "%Y-%m-%d")
            if file_date < cutoff:
                os.remove(f)
                deleted.append(basename)
                print(f"[cdr-cleanup] 已刪除 CSV 備援檔 {basename}")
        except Exception as e:
            print(f"[cdr-cleanup] 跳過 {basename}：{e}")

    # ── SQLite raw 明細：依 cdr_retain_days 清除（該日彙總已於 rotate 時建立，不受影響）──
    try:
        cutoff_str = cutoff.strftime("%Y-%m-%d")
        purged_raw = cdr_db.purge_raw_before(cutoff_str)
        if purged_raw:
            print(f"[cdr-cleanup] 已清除 SQLite raw 明細 {purged_raw} 筆（早於 {cutoff_str}）")
    except Exception as e:
        print(f"[cdr-cleanup] SQLite raw 清理失敗：{e}")

    # ── SQLite 每日彙總：依 cdr_summary_retain_days 清除（預設 730 天，通常不會觸發）──
    try:
        summary_retain_days = int(settings.get("cdr_summary_retain_days", 730))
        summary_cutoff = (datetime.now() - timedelta(days=summary_retain_days)).strftime("%Y-%m-%d")
        purged_summary = cdr_db.purge_summary_before(summary_cutoff)
        if purged_summary:
            print(f"[cdr-cleanup] 已清除彙總 {purged_summary} 天（早於 {summary_cutoff}）")
    except Exception as e:
        print(f"[cdr-cleanup] SQLite summary 清理失敗：{e}")

    return deleted


def _cleanup_old_reg_logs():
    """刪除超過保留天數的登錄記錄（SQLite，2026-07-15 起持久化）"""
    settings = load_server_settings()
    retain_days = int(settings.get("reg_log_retain_days", 90))
    cutoff_str = (datetime.now() - timedelta(days=retain_days)).strftime("%Y-%m-%d")
    try:
        purged = reg_log_db.purge_before(cutoff_str)
        if purged:
            print(f"[reg-log-cleanup] 已清除 {purged} 筆（早於 {cutoff_str}）")
        return purged
    except Exception as e:
        print(f"[reg-log-cleanup] 清理失敗：{e}")
        return 0


async def log_rotate_scheduler():
    """背景協程：sleep 到精確觸發時間，或被 settings 儲存事件提早喚醒重新計算。"""
    _rotated_date:   str = ""
    _backed_up_date: str = ""

    while True:
        now = datetime.now()
        cfg = state.scheduler_settings   # 讀記憶體，無 disk I/O

        # 計算下次 rotate 時間（固定 00:00:30）
        next_rotate = now.replace(hour=0, minute=0, second=30, microsecond=0)
        if next_rotate <= now:
            next_rotate += timedelta(days=1)

        # 計算下次備份時間（從記憶體設定讀取）
        try:
            auto_h, auto_m = [int(x) for x in (cfg.get("backup_auto_time") or "00:01").split(":")]
        except Exception:
            auto_h, auto_m = 0, 1
        next_backup = now.replace(hour=auto_h, minute=auto_m, second=0, microsecond=0)
        if next_backup <= now:
            next_backup += timedelta(days=1)

        wait_secs = (min(next_rotate, next_backup) - now).total_seconds()
        
        # ── DEBUG ──────────────────────────────────────────────────────────────
        print(f"[scheduler-debug] 現在時間：{now.strftime('%Y-%m-%d %H:%M:%S')}")
        print(f"[scheduler-debug] state.scheduler_settings = {cfg}")
        print(f"[scheduler-debug] 解析備份時間 → {auto_h:02d}:{auto_m:02d}")
        print(f"[scheduler-debug] next_rotate  = {next_rotate.strftime('%Y-%m-%d %H:%M:%S')}")
        print(f"[scheduler-debug] next_backup  = {next_backup.strftime('%Y-%m-%d %H:%M:%S')}")
        print(f"[scheduler-debug] wait_secs    = {wait_secs:.0f}s")
        print(f"[scheduler-debug] _rotated_date={_rotated_date!r}  _backed_up_date={_backed_up_date!r}")
        # ───────────────────────────────────────────────────────────────────────
        
        #print(f"[scheduler] 下次喚醒：{min(next_rotate, next_backup).strftime('%Y-%m-%d %H:%M:%S')}（{wait_secs:.0f}s）")

        # 等到時間到，或被 wakeup event 喚醒（settings 已變更）
        try:
            await asyncio.wait_for(state.scheduler_wakeup.wait(), timeout=wait_secs)
            state.scheduler_wakeup.clear()
            print("[scheduler] 設定已更新，重新計算排程時間")
            continue   # 重新計算，不執行備份/rotate
        except asyncio.TimeoutError:
            pass       # 正常時間到，繼續往下

        now = datetime.now()
        today = now.strftime("%Y-%m-%d")
        
        # ── DEBUG ──────────────────────────────────────────────────────────────
        print(f"[scheduler-debug] 時間到，開始檢查觸發條件，now={now.strftime('%H:%M:%S')}")
        rotate_target = now.replace(hour=0, minute=0, second=30, microsecond=0)
        backup_target = now.replace(hour=auto_h, minute=auto_m, second=0, microsecond=0)
        print(f"[scheduler-debug] rotate diff={abs((now-rotate_target).total_seconds()):.0f}s  rotated={_rotated_date!r}")
        print(f"[scheduler-debug] backup diff={abs((now-backup_target).total_seconds()):.0f}s  backed={_backed_up_date!r}  enabled={cfg.get('backup_auto_enabled')}")
        # ───────────────────────────────────────────────────────────────────────

        # ── Log/CDR rotate（00:00:30 附近，同天只執行一次）──────────────────
        rotate_target = now.replace(hour=0, minute=0, second=30, microsecond=0)
        if abs((now - rotate_target).total_seconds()) <= 90 and _rotated_date != today:
            _rotated_date = today
            print(f"[scheduler] 執行 Log/CDR rotate ({today})")
            # 2026-08-11 起改用合併函式：log 與 CDR 都完成 truncate 後才
            # 統一送出一次 SIGHUP，避免其中一邊尚未安全歸檔時被另一邊的
            # HUP 意外搬走內容（見 _rotate_log_and_cdr_now() docstring）
            print(f"[rotate] {_rotate_log_and_cdr_now(cdr_use_today=False, primary='log')}")
            _cleanup_old_logs()
            _cleanup_old_cdrs()
            _cleanup_old_reg_logs()
            cleanup_old_backups()

        # ── 自動備份（backup_auto_time，同天只執行一次）─────────────────────
        backup_target = now.replace(hour=auto_h, minute=auto_m, second=0, microsecond=0)
        if (abs((now - backup_target).total_seconds()) <= 90
                and cfg.get("backup_auto_enabled")
                and _backed_up_date != today):
            print(f"[backup-auto] 開始自動備份 ({cfg.get('backup_auto_time')})")
            try:
                loop = asyncio.get_event_loop()
                res_config   = await loop.run_in_executor(None, backup_dashboard_config)
                res_packages = await loop.run_in_executor(None, backup_freeswitch_packages)
                print(f"[backup-auto] config：{res_config}")
                print(f"[backup-auto] packages：{res_packages}")
                if res_config.get("ok") and res_packages.get("ok"):
                    _backed_up_date = today
                else:
                    print(f"[backup-auto] 部分失敗，下次重試")
            except Exception as e:
                print(f"[backup-auto] 例外錯誤：{e}")



# ── WebSocket ─────────────────────────────────────────────────────────────────

async def ws_handler(websocket):
    # token 走 query string：ws://host:8080/?token=<JWT>
    # （瀏覽器原生 WebSocket API 無法自訂 Authorization header，這是業界標準做法）
    #
    # websockets >=14 的新版 asyncio 實作用 ServerConnection，沒有 .path 屬性，
    # 路徑要從 websocket.request.path 取得；舊版 legacy protocol 才有 .path。
    # 兩者都相容處理，避免套件升級後再次炸掉。
    req = getattr(websocket, "request", None)
    raw_path = req.path if req is not None else getattr(websocket, "path", "")
    query = parse_qs(urlparse(raw_path).query)
    token = query.get("token", [None])[0]

    if not token:
        await websocket.close(code=4401, reason="缺少登入憑證")
        return
    try:
        user_info = manager.authenticate(token)
    except TokenError as e:
        await websocket.close(code=4401, reason=str(e))
        return

    manager.add(websocket, user_info)
    print(f"瀏覽器已連線：{websocket.remote_address}")
    try:
        await websocket.wait_closed()
    finally:
        manager.remove(websocket)
        print(f"瀏覽器已離線：{websocket.remote_address}")

async def start_ws_server():
    """在 main event loop 內啟動 WebSocket server
    只 bind 127.0.0.1：對外一律透過 nginx 的 /ws/ 反向代理轉發進來，
    8080 本身不再對外或對內網其他主機開放，降低攻擊面。
    """
    server = await websockets.serve(ws_handler, "127.0.0.1", 8080)
    print("WebSocket 啟動於 ws://127.0.0.1:8080（僅限本機，經 nginx /ws/ 轉發對外）")
    return server

