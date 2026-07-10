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
            _write_reg_log(reg_user, "REGISTER", network_ip, network_proto, now_ts)
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
            _write_reg_log(reg_user, "UNREGISTER", network_ip, network_proto, now_ts)
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
        manager.broadcast(payload), esl._loop
    )


def write_reg_log(ext: str, event: str, ip: str, proto: str, ts_ms: int):
    """Write registration event to in-memory log (max REG_LOG_MAX entries)"""
    import datetime as _dt
    time_str = _dt.datetime.fromtimestamp(ts_ms / 1000).strftime('%Y-%m-%d %H:%M:%S')
    entry = {
        "ext":       ext,
        "event":     event,
        "ip":        ip,
        "proto":     proto.upper() if proto else "UDP",
        "ts":        ts_ms,
        "time_str":  time_str,
    }
    state.reg_log.append(entry)
    if len(state.reg_log) > REG_LOG_MAX:
        state.reg_log.pop(0)
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


def _rotate_log_now() -> dict:
    """
    將 freeswitch.log 依昨天日期（或目前內容最早日期）另存為
    freeswitch-YYYY-MM-DD.log，然後清空原始 log 供 FreeSwitch 繼續寫入。
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
        # 清空原始 log（truncate，不刪檔，讓 FreeSwitch 的 fd 繼續有效）
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
            print(f"[log-rotate] {_rotate_log_now()}")
            _cleanup_old_logs()
            print(f"[cdr-rotate] {_rotate_cdr_now()}")
            _cleanup_old_cdrs()
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
    manager.add(websocket)
    print(f"瀏覽器已連線：{websocket.remote_address}")
    try:
        await websocket.wait_closed()
    finally:
        manager.remove(websocket)
        print(f"瀏覽器已離線：{websocket.remote_address}")

async def start_ws_server():
    """在 main event loop 內啟動 WebSocket server"""
    server = await websockets.serve(ws_handler, "0.0.0.0", 8080)
    print("WebSocket 啟動於 ws://0.0.0.0:8080")
    return server

