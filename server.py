"""
server.py — FreeSwitch Dashboard 進入點

只保留：FastAPI app 建立、middleware、靜態檔案掛載、router 掛載、lifespan。
所有實際的 API 邏輯都已搬到 routers/*.py（依領域拆分），
背景執行期邏輯（ESL 事件、log/CDR 排程、WebSocket）在 core/runtime.py。
"""
import asyncio
from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from fastapi.staticfiles import StaticFiles
from fastapi.responses import FileResponse

from core.esl_client import esl
from core import state, auth_db
from core.runtime import (
    load_server_settings,
    start_ws_server,
    update_ext_status,
    log_rotate_scheduler,
    reg_sync_scheduler,
)

from routers import (
    calls, logs, settings as settings_router, cdr, dialplan_files, vars as vars_router,
    extensions, files, gateway, recordings, groups, ivr, sounds, numbers, backup,
    dialplan_routes, dialplan_system_extensions, dialplan_custom,
    sip_profile, acl,
    auth as auth_router, users as users_router, perm_groups,   
)


# ── 啟動 / 關閉 ───────────────────────────────────────────────────────────────

@asynccontextmanager
async def lifespan(app: FastAPI):
    # 取得 main event loop 傳給 ESL（讓執行緒可以安全推播）
    loop = asyncio.get_running_loop()
    esl.set_event_loop(loop)

    # 注入分機狀態回調
    esl.set_status_callback(update_ext_status)
    
    # 權限系統：只建 schema，不自動 seed。seed 改由 POST /api/auth/bootstrap 手動觸發，
    # 過渡期讓 auth.db 保持「無使用者」即可全面放行，避免整合測試被鎖外，
    # 也避免重啟時無聲覆蓋管理員已調整的權限。
    auth_db.init_db()
    # 啟動前先載入持久化的 ESL 連線設定（若有）
    _saved = load_server_settings()
    # 初始化排程記憶體設定（從 settings.json 讀一次）
    state.scheduler_settings.update({
        "backup_auto_enabled": _saved.get("backup_auto_enabled", False),
        "backup_auto_time":    _saved.get("backup_auto_time", "00:01"),
    })
    if _saved.get("esl_host") or _saved.get("esl_port") or _saved.get("esl_password"):
        import core.esl_client as _esl_mod
        if _saved.get("esl_host"):
            _esl_mod.FS_HOST     = _saved["esl_host"]
        if _saved.get("esl_port"):
            _esl_mod.FS_PORT     = int(_saved["esl_port"])
        if _saved.get("esl_password"):
            _esl_mod.FS_PASSWORD = _saved["esl_password"]
        print(f"[config] 載入 ESL 設定：{_esl_mod.FS_HOST}:{_esl_mod.FS_PORT}")

    # 連接 FreeSwitch ESL
    esl.connect()

    # 啟動 ESL 事件監聽（背景執行緒）
    esl.start_event_loop()

    # 啟動 WebSocket server（在同一個 event loop）
    ws_server = await start_ws_server()

    # 啟動後主動查詢一次已登錄分機，初始化 ext_status
    # （避免 server 重啟後要等 REGISTER 事件才能更新狀態）
    try:
        import time as _t
        reg_data = esl.get_registrations()
        reg_rows = reg_data.get("rows", []) if isinstance(reg_data, dict) else []
        for r in reg_rows:
            raw_user = r.get("reg_user", "") or r.get("user", "")
            reg_user = raw_user.split("@")[0].strip()
            if reg_user and reg_user not in state.ext_status:
                state.ext_status[reg_user] = {
                    "status": "idle", "peer": "", "direction": "", "since": int(_t.time() * 1000)
                }
        print(f"[ext_status] 初始化完成，已登錄分機：{list(state.ext_status.keys())}")
    except Exception as e:
        print(f"[ext_status] 初始化查詢失敗：{e}")

    # 啟動 Log 每日自動輪轉排程
    asyncio.create_task(log_rotate_scheduler())

    # 啟動登錄清單同步排程（每 30 秒，補救 UNREGISTER 事件遺漏的情況）
    asyncio.create_task(reg_sync_scheduler())

    yield  # 應用程式運行中

    # 關閉時清理
    ws_server.close()
    await ws_server.wait_closed()


# ── FastAPI ───────────────────────────────────────────────────────────────────

app = FastAPI(title="FreeSwitch Dashboard API", lifespan=lifespan)

# CORS origin 收斂：從 settings.json 讀白名單，未設定時 fallback 回已知前端來源
_ALLOWED_ORIGINS = load_server_settings().get("cors_allowed_origins") or ["http://192.168.100.209:3000"]

app.add_middleware(
    CORSMiddleware,
    allow_origins=_ALLOWED_ORIGINS,
    allow_methods=["*"],
    allow_headers=["*"],
)

# 前端靜態資源（index.html / css / js）都在 static/ 子資料夾
app.mount("/static", StaticFiles(directory="static"), name="static")

# ── Router 掛載 ───────────────────────────────────────────────────────────────
# Dialplan 路由規則（類型一：外撥路由規則）需要注入 ESL 實例
dialplan_routes.init_esl(esl)

app.include_router(auth_router.router)
app.include_router(users_router.router)
app.include_router(perm_groups.router)
app.include_router(calls.router)
app.include_router(calls.router)
app.include_router(logs.router)
app.include_router(settings_router.router)
app.include_router(cdr.router)
app.include_router(dialplan_files.router)
app.include_router(vars_router.router)
app.include_router(extensions.router)
app.include_router(files.router)
app.include_router(gateway.router)
app.include_router(recordings.router)
app.include_router(groups.router)
app.include_router(ivr.router)
app.include_router(sounds.router)
app.include_router(numbers.router)
app.include_router(backup.router)
app.include_router(dialplan_routes.router)
app.include_router(dialplan_system_extensions.router)
app.include_router(dialplan_custom.router)
app.include_router(sip_profile.router)   # ← 新增
app.include_router(acl.router)           # ← 新增


@app.get("/")
def root():
    return FileResponse("static/index.html")

@app.get("/login.html")
def login_page():
    return FileResponse("static/login.html")

@app.get("/change-password.html")
def change_password_page():
    return FileResponse("static/change-password.html")

@app.get("/index.html")
def index_page():
    return FileResponse("static/index.html")
