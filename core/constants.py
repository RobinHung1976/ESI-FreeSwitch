"""
core/constants.py — 多個 router 共用的路徑常數。

原本這些常數各自定義在 groups / ivr / numbers / sounds 對應的段落裡，
因為彼此互相引用（例如 groups.py 的 create_group() 要檢查 FS_RESERVED，
sounds.py 要用 IVR_SOUNDS_DIR），搬進獨立檔案可以避免 router 之間互相
import 造成循環依賴。
"""

# ── FreeSwitch 內建保留號碼（groups.py 新增檢查 / numbers.py 顯示用）──────────
FS_RESERVED = [
    {"number": "0000", "type": "reserved", "name": "FreeSWITCH echo/delay test", "owner": "FreeSwitch 內建"},
    {"number": "0001", "type": "reserved", "name": "Music on Hold test",          "owner": "FreeSwitch 內建"},
    {"number": "0002", "type": "reserved", "name": "FreeSWITCH info",             "owner": "FreeSwitch 內建"},
    {"number": "2000", "type": "reserved", "name": "Conference (moderator)",       "owner": "FreeSwitch 內建"},
    {"number": "2001", "type": "reserved", "name": "Conference (member)",          "owner": "FreeSwitch 內建"},
    {"number": "2002", "type": "reserved", "name": "Conference (DTMF control)",    "owner": "FreeSwitch 內建"},
    {"number": "3000", "type": "reserved", "name": "Call Center Queue",            "owner": "FreeSwitch 內建"},
    {"number": "3001", "type": "reserved", "name": "Call Center Agent login",      "owner": "FreeSwitch 內建"},
    {"number": "3002", "type": "reserved", "name": "Call Center Agent logout",     "owner": "FreeSwitch 內建"},
    {"number": "3010", "type": "reserved", "name": "Call Center Tier add",         "owner": "FreeSwitch 內建"},
    {"number": "3011", "type": "reserved", "name": "Call Center Tier del",         "owner": "FreeSwitch 內建"},
    {"number": "3012", "type": "reserved", "name": "Call Center Tier list",        "owner": "FreeSwitch 內建"},
    {"number": "3013", "type": "reserved", "name": "Call Center Caller list",      "owner": "FreeSwitch 內建"},
    {"number": "4000", "type": "reserved", "name": "Valet Parking",               "owner": "FreeSwitch 內建"},
    {"number": "5000", "type": "reserved", "name": "Directory (dial by name)",     "owner": "FreeSwitch 內建"},
    {"number": "5001", "type": "reserved", "name": "Conference Bridge (外部 conference.freeswitch.org)", "owner": "FreeSwitch 內建"},
    {"number": "5002", "type": "reserved", "name": "Conference Bridge (外部 conference.freeswitch.org)", "owner": "FreeSwitch 內建"},
    {"number": "6000", "type": "reserved", "name": "Park & Retrieve",             "owner": "FreeSwitch 內建"},
    {"number": "9195", "type": "reserved", "name": "Tone stream test",            "owner": "FreeSwitch 內建"},
    {"number": "9196", "type": "reserved", "name": "Echo test",                   "owner": "FreeSwitch 內建"},
    {"number": "9197", "type": "reserved", "name": "Milliwatt tone",              "owner": "FreeSwitch 內建"},
    {"number": "9198", "type": "reserved", "name": "Tetris ringtone",             "owner": "FreeSwitch 內建"},
    {"number": "9199", "type": "reserved", "name": "Hold music",                  "owner": "FreeSwitch 內建"},
    {"number": "9888", "type": "reserved", "name": "Voicemail check",             "owner": "FreeSwitch 內建"},
]


# ── 音檔庫路徑（ivr.py 的 /api/ivr/sounds/* 相容端點 / sounds.py 本體共用）────
IVR_SOUNDS_DIR = "/var/lib/freeswitch/sounds/custom"
IVR_MENU_DIR   = "/etc/freeswitch/ivr-menus"
