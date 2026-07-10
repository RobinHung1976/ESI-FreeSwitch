"""
core/state.py — 跨 router 共用的執行期共享狀態（in-memory）。

刻意獨立成一個沒有任何專案內部 import 的模組：
所有 router 和 core/runtime.py 都可以放心 import 這裡的東西，
不會有循環 import 的風險。
"""
import asyncio

# 分機即時狀態表：ext_status[ext_num] = {status, peer, direction, since}
ext_status: dict = {}

# channel UUID -> 分機號碼 對照表（用於 DESTROY 時快速找回分機）
uuid_to_ext: dict = {}

# Registration history log（最新事件在陣列尾端）
reg_log: list = []
REG_LOG_MAX = 500

# SSE log injection：每個連線 /api/logs/stream 的客戶端一個 Queue
log_inject_queues: set = set()

# 排程設定的 single source of truth（記憶體版本，settings.json 為持久化版本）
scheduler_settings: dict = {
    "backup_auto_enabled": False,
    "backup_auto_time": "00:01",
}
scheduler_wakeup = asyncio.Event()   # 儲存設定時 set()，喚醒 scheduler 重新計算
