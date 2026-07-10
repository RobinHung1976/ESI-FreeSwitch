"""
routers/ivr.py — IVR 互動語音應答管理：/api/ivr*（含 lua 腳本部署與/api/ivr/sounds/* 相容端點，實際邏輯委派給 routers/sounds.py）
"""
import os
import json
import shutil
import glob
from datetime import datetime
from typing import List
from fastapi import APIRouter, HTTPException, UploadFile, File, Depends
from pydantic import BaseModel

from core.esl_client import esl
from core.constants import IVR_SOUNDS_DIR, IVR_MENU_DIR
from routers.sounds import list_sound_library, upload_sound, delete_sound, stream_sound
from core.auth import require_permission
from core.permissions import Module

router = APIRouter()


# ════════════════════════════════════════════════════════════════════════════════
# IVR 管理（Interactive Voice Response）
# ════════════════════════════════════════════════════════════════════════════════
#
# 每個 IVR 選單存成兩個 XML 檔：
#   /etc/freeswitch/dialplan/default/00_ivr_<id>.xml  ← Dialplan 入口 extension
#   /etc/freeswitch/ivr-menus/<id>.xml                ← mod_ivr 選單定義
#
# IVR 設定以 <!-- DASHBOARD_IVR_META: {...} --> JSON 註解存放在 Dialplan 檔開頭，
# 不需獨立資料庫，與群組管理方式一致。
#
# 按鍵 action_type：
#   extension / group → transfer <number> XML default
#   ivr               → ivr <menu_name>（子選單，遞迴支援）
#   voicemail         → voicemail default ${domain_name} <ext>
#   playback          → playback <file> + hangup
#   hangup            → hangup
# ════════════════════════════════════════════════════════════════════════════════

IVR_DIALPLAN_DIR = "/etc/freeswitch/dialplan/default"
# IVR_MENU_DIR 已改由 core.constants 匯入（見檔案開頭 import）
IVR_LUA_SCRIPT   = "/usr/share/freeswitch/scripts/ivr_runner.lua"
IVR_META_RE      = r"<!--\s*DASHBOARD_IVR_META:\s*(\{.*?\})\s*-->"


class IVRKeyAction(BaseModel):
    action_type: str = 'hangup'   # extension|group|ivr|voicemail|playback|hangup
    target:      str = ''

# [NEW] 帶 enabled 開關的轉接動作（用於 auto_transfer / post_greeting_transfer）
class IVRTransferAction(BaseModel):
    enabled:     bool = False
    action_type: str  = 'extension'
    target:      str  = ''

class IVRSchedule(BaseModel):
    enabled:         bool       = False
    work_start:      str        = '09:00'
    work_end:        str        = '18:00'
    work_days:       List[int]  = [1,2,3,4,5]  # 0=Sun 1=Mon … 6=Sat
    work_target:     str        = ''   # 上班時段 IVR id 或分機
    offhour_target:  str        = ''   # 舊欄位，向下相容
    offhour_sound:   str        = ''   # 下班時段語音（接通後播放）
    holiday_dates:   List[str]  = []   # ["2026-01-01", ...]
    holiday_target:  str        = ''   # 舊欄位，向下相容
    # [NEW] 下班/假日直轉，支援所有 action_type（優先於舊式 *_target 字串）
    offhour_action:  IVRKeyAction = IVRKeyAction(action_type='hangup', target='')
    holiday_action:  IVRKeyAction = IVRKeyAction(action_type='',       target='')
class IVRData(BaseModel):
    id:                   str
    name:                 str         = ''
    number:               str         = ''
    greeting:             str         = ''
    menu_sound:           str         = ''
    invalid_sound:        str         = ''
    exit_sound:           str         = ''
    timeout:              int         = 10
    retries:              int         = 3
    inter_digit_timeout:  int         = 2000
    digit_len:            int         = 1
    direct_ext_dialing:   bool        = False
    direct_ext_digits:    int         = 4
    direct_ext_prefix:    str         = ''
    # ── 無效鍵 / 超時重試控制 ─────────────────────────────────────────────────
    # invalid_retries / timeout_retries：觸發幾次後才執行 keys["i"]/keys["t"] 動作
    #   第 1 ~ (N-1) 次：重播 IVR（播 menu_sound）
    #   第 N 次：播 final_sound（若有設定），再執行動作
    invalid_retries:      int         = 1   # 預設第1次就執行動作（同舊行為）
    invalid_final_sound:  str         = ''  # 最後一次無效時的特殊語音
    timeout_retries:      int         = 1   # 預設第1次就執行動作（同舊行為）
    timeout_final_sound:  str         = ''  # 最後一次超時時的特殊語音
    # [NEW] 直接轉接：進入 IVR 後立即轉接（跳過語音與按鍵）
    auto_transfer:           IVRTransferAction = IVRTransferAction()
    # [NEW] 播後轉接：播完 greeting 後自動轉接（不等按鍵）
    post_greeting_transfer:  IVRTransferAction = IVRTransferAction()
    keys:                 dict        = {}   # {"1": {action_type,target}, "t":…}
    schedule:             IVRSchedule = IVRSchedule()
    context:              str         = 'default'
    parent_id:            str         = ''

# ── writer helpers ────────────────────────────────────────────────────────────

def _ivr_meta_dict(data: IVRData) -> dict:
    def _action(obj):
        if isinstance(obj, (IVRKeyAction, IVRTransferAction)):
            d = {'action_type': obj.action_type, 'target': obj.target}
            if isinstance(obj, IVRTransferAction):
                d['enabled'] = obj.enabled
            return d
        return obj  # already a dict (legacy)

    return {
        'id': data.id, 'name': data.name, 'number': data.number,
        'greeting': data.greeting, 'menu_sound': data.menu_sound,
        'invalid_sound': data.invalid_sound, 'exit_sound': data.exit_sound,
        'timeout': data.timeout, 'retries': data.retries,
        'inter_digit_timeout': data.inter_digit_timeout,
        'digit_len': data.digit_len,
        'direct_ext_dialing': data.direct_ext_dialing,
        'direct_ext_digits':  data.direct_ext_digits,
        'direct_ext_prefix':  data.direct_ext_prefix,
        'invalid_retries': data.invalid_retries,
        'invalid_final_sound': data.invalid_final_sound,
        'timeout_retries': data.timeout_retries,
        'timeout_final_sound': data.timeout_final_sound,
        # [NEW]
        'auto_transfer':          _action(data.auto_transfer),
        'post_greeting_transfer': _action(data.post_greeting_transfer),
        'keys': {k: {'action_type': (v.action_type if isinstance(v, IVRKeyAction) else v.get('action_type','hangup')),
                     'target':      (v.target      if isinstance(v, IVRKeyAction) else v.get('target',''))}
                 for k, v in data.keys.items()},
        'schedule': {
            'enabled':        data.schedule.enabled,
            'work_start':     data.schedule.work_start,
            'work_end':       data.schedule.work_end,
            'work_days':      data.schedule.work_days,
            'work_target':    data.schedule.work_target,
            'offhour_target': data.schedule.offhour_target,
            'offhour_sound':  data.schedule.offhour_sound,
            'holiday_dates':  data.schedule.holiday_dates,
            'holiday_target': data.schedule.holiday_target,
            # [NEW]
            'offhour_action': _action(data.schedule.offhour_action),
            'holiday_action': _action(data.schedule.holiday_action),
        },
        'context': data.context, 'parent_id': data.parent_id,
    }


def write_ivr_json(data: IVRData, filepath: str):
    """寫入 IVR JSON 設定檔（供 ivr_runner.lua 讀取）"""
    import json as _j
    os.makedirs(os.path.dirname(filepath), exist_ok=True)
    with open(filepath, 'w', encoding='utf-8') as f:
        _j.dump(_ivr_meta_dict(data), f, ensure_ascii=False, indent=2)


def write_ivr_dialplan_xml(data: IVRData, filepath: str):
    """寫入 Dialplan 入口 XML（呼叫 lua ivr_runner.lua <id>）
    時段路由完全交給 Lua 處理，Dialplan 只做 answer + lua 呼叫。
    """
    import json as _j
    os.makedirs(os.path.dirname(filepath), exist_ok=True)
    meta_json = _j.dumps(_ivr_meta_dict(data), ensure_ascii=False)
    content = (
        f'<!-- DASHBOARD_IVR_META: {meta_json} -->\n'
        f'<include>\n'
        f'  <extension name="ivr_{data.id}">\n'
        f'    <condition field="destination_number" expression="^{data.number}$">\n'
        f'      <action application="answer"/>\n'
        f'      <action application="sleep" data="500"/>\n'
        f'      <action application="lua" data="ivr_runner.lua {data.id}"/>\n'
        f'    </condition>\n'
        f'  </extension>\n'
        f'</include>\n'
    )
    with open(filepath, 'w', encoding='utf-8') as f:
        f.write(content)


def _write_ivr_stub(data: IVRData, filepath: str):
    """子選單（無入口號碼）：僅寫 META 佔位 Dialplan 檔"""
    import json as _j
    os.makedirs(os.path.dirname(filepath), exist_ok=True)
    meta_json = _j.dumps(_ivr_meta_dict(data), ensure_ascii=False)
    with open(filepath, 'w', encoding='utf-8') as f:
        f.write(f'<!-- DASHBOARD_IVR_META: {meta_json} -->\n<include/>\n')


def _read_ivr_meta(filepath: str):
    import json as _j, re as _re
    try:
        with open(filepath, 'r', encoding='utf-8') as f:
            content = f.read()
        m = _re.search(IVR_META_RE, content, _re.DOTALL)
        if not m:
            return None
        meta = _j.loads(m.group(1))
        meta['path'] = filepath
        return meta
    except Exception:
        return None


def _normalize_keys(data: IVRData):
    data.keys = {k: (IVRKeyAction(**v) if isinstance(v, dict) else v)
                 for k, v in data.keys.items()}

# ── REST endpoints ────────────────────────────────────────────────────────────

@router.get("/api/ivr/list", dependencies=[Depends(require_permission(Module.IVR, "read"))])
def list_ivr():
    result = []
    for fp in sorted(glob.glob(f"{IVR_DIALPLAN_DIR}/00_ivr_*.xml")):
        meta = _read_ivr_meta(fp)
        if meta:
            result.append(meta)
    return {'ivrs': result, 'total': len(result)}


@router.get("/api/ivr/{ivr_id}", dependencies=[Depends(require_permission(Module.IVR, "read"))])
def get_ivr(ivr_id: str):
    fp = f"{IVR_DIALPLAN_DIR}/00_ivr_{ivr_id}.xml"
    meta = _read_ivr_meta(fp)
    if not meta:
        raise HTTPException(status_code=404, detail=f"IVR {ivr_id} 不存在")
    return meta


@router.post("/api/ivr", dependencies=[Depends(require_permission(Module.IVR, "create"))])
def create_ivr(data: IVRData):
    ivr_id = data.id.strip()
    if not ivr_id or not ivr_id.replace('-','').replace('_','').isalnum():
        raise HTTPException(status_code=400, detail="IVR ID 只能含英數字、連字號、底線")
    dp_path   = f"{IVR_DIALPLAN_DIR}/00_ivr_{ivr_id}.xml"
    json_path = f"{IVR_MENU_DIR}/{ivr_id}.json"
    if os.path.exists(dp_path):
        raise HTTPException(status_code=409, detail=f"IVR {ivr_id} 已存在")
    _normalize_keys(data)
    if data.number:
        write_ivr_dialplan_xml(data, dp_path)
    else:
        _write_ivr_stub(data, dp_path)
    write_ivr_json(data, json_path)
    esl.api('reloadxml')
    return {'ok': True, 'id': ivr_id}


@router.put("/api/ivr/{ivr_id}", dependencies=[Depends(require_permission(Module.IVR, "update"))])
def update_ivr(ivr_id: str, data: IVRData):
    dp_path   = f"{IVR_DIALPLAN_DIR}/00_ivr_{ivr_id}.xml"
    json_path = f"{IVR_MENU_DIR}/{ivr_id}.json"
    # 相容舊版（.xml 選單檔）
    old_xml_path = f"{IVR_MENU_DIR}/{ivr_id}.xml"
    if not os.path.exists(dp_path):
        raise HTTPException(status_code=404, detail=f"IVR {ivr_id} 不存在")
    ts = datetime.now().strftime("%Y%m%d_%H%M%S")
    shutil.copy2(dp_path, dp_path + f'.bak.{ts}')
    if os.path.exists(json_path):
        shutil.copy2(json_path, json_path + f'.bak.{ts}')
    # 舊版 XML 選單檔自動備份（不再使用）
    if os.path.exists(old_xml_path):
        shutil.copy2(old_xml_path, old_xml_path + f'.bak.{ts}')
    _normalize_keys(data)
    if data.number:
        write_ivr_dialplan_xml(data, dp_path)
    else:
        _write_ivr_stub(data, dp_path)
    write_ivr_json(data, json_path)
    esl.api('reloadxml')
    return {'ok': True, 'id': ivr_id}


@router.delete("/api/ivr/{ivr_id}", dependencies=[Depends(require_permission(Module.IVR, "delete"))])
def delete_ivr(ivr_id: str):
    dp_path   = f"{IVR_DIALPLAN_DIR}/00_ivr_{ivr_id}.xml"
    json_path = f"{IVR_MENU_DIR}/{ivr_id}.json"
    old_xml   = f"{IVR_MENU_DIR}/{ivr_id}.xml"
    if not os.path.exists(dp_path):
        raise HTTPException(status_code=404, detail=f"IVR {ivr_id} 不存在")
    ts = datetime.now().strftime("%Y%m%d_%H%M%S")
    shutil.copy2(dp_path, dp_path + f'.bak.{ts}')
    os.remove(dp_path)
    for p in [json_path, old_xml]:
        if os.path.exists(p):
            shutil.copy2(p, p + f'.bak.{ts}')
            os.remove(p)
    esl.api('reloadxml')
    return {'ok': True}


@router.get("/api/ivr/lua/status", dependencies=[Depends(require_permission(Module.IVR, "read"))])
def ivr_lua_status():
    """確認 ivr_runner.lua 是否已部署"""
    exists  = os.path.isfile(IVR_LUA_SCRIPT)
    size    = os.path.getsize(IVR_LUA_SCRIPT) if exists else 0
    return {'deployed': exists, 'path': IVR_LUA_SCRIPT, 'size': size}


@router.post("/api/ivr/lua/deploy", dependencies=[Depends(require_permission(Module.IVR, "update"))])
def deploy_ivr_lua():
    """部署 ivr_runner.lua 到 FreeSwitch scripts 目錄"""
    lua_content = r'''-- ivr_runner.lua  —  ESI Dashboard 通用 IVR 執行引擎
-- 呼叫：<action application="lua" data="ivr_runner.lua MENU_ID"/>

local json_dir = "/etc/freeswitch/ivr-menus/"

-- ── JSON 解析：支援 cjson / lua-json / 純 Lua fallback ───────────────────────
local _json_decode
do
    -- 嘗試 1: cjson（最常見）
    local ok, lib = pcall(require, "cjson")
    if ok then _json_decode = lib.decode; goto done end
    -- 嘗試 2: cjson.safe
    ok, lib = pcall(require, "cjson.safe")
    if ok then _json_decode = lib.decode; goto done end
    -- 嘗試 3: dkjson
    ok, lib = pcall(require, "dkjson")
    if ok then _json_decode = function(s) return lib.decode(s) end; goto done end
    -- 嘗試 4: json
    ok, lib = pcall(require, "json")
    if ok then _json_decode = lib.decode; goto done end

    -- Fallback: 純 Lua 簡易解析器（處理 IVR JSON 格式已足夠）
    freeswitch.consoleLog("WARNING", "[ivr] 無可用 JSON 函式庫，使用內建解析器\n")

    local function skip_ws(s, i)
        while i <= #s and s:sub(i,i):match("%s") do i = i + 1 end
        return i
    end

    local parse_value  -- forward declaration

    local function parse_string(s, i)
        -- i points to opening "
        local result = {}
        i = i + 1
        while i <= #s do
            local c = s:sub(i,i)
            if c == '"' then return table.concat(result), i + 1 end
            if c == '\\' then
                i = i + 1
                local e = s:sub(i,i)
                if     e == '"'  then result[#result+1] = '"'
                elseif e == '\\' then result[#result+1] = '\\'
                elseif e == '/'  then result[#result+1] = '/'
                elseif e == 'n'  then result[#result+1] = '\n'
                elseif e == 'r'  then result[#result+1] = '\r'
                elseif e == 't'  then result[#result+1] = '\t'
                elseif e == 'b'  then result[#result+1] = '\b'
                elseif e == 'f'  then result[#result+1] = '\f'
                else result[#result+1] = e end
            else
                result[#result+1] = c
            end
            i = i + 1
        end
        return nil, i
    end

    local function parse_number(s, i)
        local j = i
        if s:sub(j,j) == '-' then j = j + 1 end
        while j <= #s and s:sub(j,j):match("[0-9%.eE%+%-]") do j = j + 1 end
        return tonumber(s:sub(i, j-1)), j
    end

    local function parse_array(s, i)
        local arr = {}
        i = skip_ws(s, i + 1)  -- skip '['
        if s:sub(i,i) == ']' then return arr, i + 1 end
        while true do
            local v; v, i = parse_value(s, i)
            arr[#arr+1] = v
            i = skip_ws(s, i)
            local c = s:sub(i,i)
            if c == ']' then return arr, i + 1 end
            if c ~= ',' then break end
            i = skip_ws(s, i + 1)
        end
        return arr, i
    end

    local function parse_object(s, i)
        local obj = {}
        i = skip_ws(s, i + 1)  -- skip '{'
        if s:sub(i,i) == '}' then return obj, i + 1 end
        while true do
            i = skip_ws(s, i)
            if s:sub(i,i) ~= '"' then break end
            local k; k, i = parse_string(s, i)
            i = skip_ws(s, i)
            if s:sub(i,i) ~= ':' then break end
            i = skip_ws(s, i + 1)
            local v; v, i = parse_value(s, i)
            obj[k] = v
            i = skip_ws(s, i)
            local c = s:sub(i,i)
            if c == '}' then return obj, i + 1 end
            if c ~= ',' then break end
            i = skip_ws(s, i + 1)
        end
        return obj, i
    end

    parse_value = function(s, i)
        i = skip_ws(s, i)
        local c = s:sub(i,i)
        if c == '"' then return parse_string(s, i)
        elseif c == '{' then return parse_object(s, i)
        elseif c == '[' then return parse_array(s, i)
        elseif c == 't' then return true,  i + 4
        elseif c == 'f' then return false, i + 5
        elseif c == 'n' then return nil,   i + 4
        else return parse_number(s, i) end
    end

    _json_decode = function(s)
        local ok2, result = pcall(function()
            local v, _ = parse_value(s, 1)
            return v
        end)
        if ok2 then return result end
        return nil
    end

    ::done::
end

-- ── 載入設定 ────────────────────────────────────────────────────────────────
local function load_cfg(menu_id)
    local path = json_dir .. menu_id .. ".json"
    local f = io.open(path, "r")
    if not f then
        freeswitch.consoleLog("ERR", "[ivr] 找不到設定：" .. path .. "\n")
        return nil
    end
    local s = f:read("*all"); f:close()
    local data = _json_decode(s)
    if not data then
        freeswitch.consoleLog("ERR", "[ivr] JSON 解析失敗：" .. menu_id .. "\n")
        return nil
    end
    freeswitch.consoleLog("INFO", "[ivr] 設定載入成功：" .. menu_id .. "\n")
    return data
end

-- ── 時段路由 ────────────────────────────────────────────────────────────────
local function check_schedule(sched)
    if not sched or not sched.enabled then return nil end

    local year  = tonumber(os.date("%Y"))
    local month = tonumber(os.date("%m"))
    local mday  = tonumber(os.date("%d"))
    local hour  = tonumber(os.date("%H"))
    local min   = tonumber(os.date("%M"))
    local wday  = tonumber(os.date("%w"))
    local hhmm  = hour * 100 + min
    local today = string.format("%04d-%02d-%02d", year, month, mday)

    freeswitch.consoleLog("INFO", "[ivr] 時段判斷 today=" .. today .. " wday=" .. wday .. " hhmm=" .. hhmm .. "\n")

    local offhour_snd = sched.offhour_sound or ""

    if sched.holiday_dates then
        for _, hd in ipairs(sched.holiday_dates) do
            if hd == today then
                local ht = (sched.holiday_target ~= "") and sched.holiday_target or sched.offhour_target
                ht = (ht ~= "") and ht or "hangup"
                freeswitch.consoleLog("INFO", "[ivr] 假日 → " .. ht .. "\n")
                return { target = ht, sound = offhour_snd }
            end
        end
    end

    local is_workday = false
    if sched.work_days then
        for _, d in ipairs(sched.work_days) do
            if tonumber(d) == wday then is_workday = true; break end
        end
    end

    local function hhmm_of(str)
        if not str then return 900 end
        local h, m = str:match("(%d+):(%d+)")
        return h and (tonumber(h) * 100 + tonumber(m)) or 900
    end
    local ws = hhmm_of(sched.work_start or "09:00")
    local we = hhmm_of(sched.work_end   or "18:00")

    if is_workday and hhmm >= ws and hhmm < we then
        local wt = sched.work_target or ""
        freeswitch.consoleLog("INFO", "[ivr] 上班時段 → " .. (wt ~= "" and wt or "本選單") .. "\n")
        return { target = (wt ~= "" and wt or nil), sound = "" }
    else
        local ot = sched.offhour_target or ""
        ot = (ot ~= "") and ot or "hangup"
        freeswitch.consoleLog("INFO", "[ivr] 下班/非工作日 → " .. ot .. "\n")
        return { target = ot, sound = offhour_snd }
    end
end

-- ── 按鍵動作執行 ────────────────────────────────────────────────────────────
local function execute_action(session, action)
    local at  = action.action_type or "hangup"
    local tgt = action.target or ""
    freeswitch.consoleLog("INFO", "[ivr] 動作：" .. at .. " → " .. tgt .. "\n")
    if at == "extension" or at == "group" then
        session:execute("transfer", tgt .. " XML default")
    elseif at == "ivr" then
        run_ivr(session, tgt)
    elseif at == "voicemail" then
        local dom = session:getVariable("domain_name") or "localhost"
        session:execute("voicemail", "default " .. dom .. " " .. tgt)
    elseif at == "playback" then
        if tgt ~= "" then session:execute("playback", tgt) end
        session:execute("hangup", "")
    else
        session:execute("hangup", "")
    end
end

-- ── 主 IVR 執行（遞迴支援）─────────────────────────────────────────────────
function run_ivr(session, menu_id, depth)
    depth = depth or 0
    if depth > 10 then
        freeswitch.consoleLog("ERR", "[ivr] 遞迴深度超過 10，掛斷\n")
        session:execute("hangup", ""); return
    end

    freeswitch.consoleLog("INFO", "[ivr] 載入選單：" .. menu_id .. "\n")
    local cfg = load_cfg(menu_id)
    if not cfg then session:execute("hangup", ""); return end

    -- 時段路由
    if cfg.schedule and cfg.schedule.enabled then
        local sched_result = check_schedule(cfg.schedule)
        if sched_result then
            local target = sched_result.target
            local sound  = sched_result.sound or ""
            if target == "hangup" then
                -- 下班：先播語音再掛斷
                if sound ~= "" then session:execute("playback", sound) end
                session:execute("hangup", ""); return
            elseif target and target ~= menu_id then
                -- 轉至其他 IVR/分機
                if sound ~= "" then session:execute("playback", sound) end
                run_ivr(session, target, depth + 1); return
            end
            -- target == nil 表示進入本選單，不做額外動作
        end
    end

    local timeout   = (cfg.timeout or 10) * 1000
    local dlen      = cfg.digit_len or 1
    local greeting  = cfg.greeting or ""
    local msound    = cfg.menu_sound or ""
    local isound    = cfg.invalid_sound or ""
    local esound    = cfg.exit_sound or ""
    local keys      = cfg.keys or {}

    local invalid_max   = math.max(1, cfg.invalid_retries or 1)
    local invalid_snd   = cfg.invalid_final_sound or ""
    local timeout_max   = math.max(1, cfg.timeout_retries or 1)
    local timeout_snd   = cfg.timeout_final_sound or ""
    local invalid_count = 0
    local timeout_count = 0
    local safety_limit  = 50
    local loop_count    = 0
    local greeted       = false

    while session:ready() do
        loop_count = loop_count + 1
        if loop_count > safety_limit then
            freeswitch.consoleLog("ERR", "[ivr] 超過安全迴圈上限，掛斷\n")
            session:execute("hangup", ""); return
        end

        local snd
        if not greeted and greeting ~= "" then
            snd = greeting
        elseif msound ~= "" then
            snd = msound
        end
        greeted = true

        local digit = ""
        if snd and snd ~= "" then
            digit = session:playAndGetDigits(dlen, dlen, 1, timeout, "#", snd, isound, "\\d+", "")
        else
            digit = session:getDigits(dlen, "#", timeout)
        end
        freeswitch.consoleLog("INFO", "[ivr] 按鍵：'" .. (digit or "") .. "'\n")

        if digit and digit ~= "" then
            local action = keys[digit]
            if action then
                execute_action(session, action); return
            else
                invalid_count = invalid_count + 1
                freeswitch.consoleLog("INFO", "[ivr] 無效鍵 " .. invalid_count .. "/" .. invalid_max .. "\n")
                if invalid_count >= invalid_max then
                    -- 最後一次：只播 final_sound，跳過 invalid_sound
                    if invalid_snd ~= "" then
                        session:execute("playback", invalid_snd)
                    end
                    local ia = keys["i"]
                    if ia then execute_action(session, ia) else session:execute("hangup", "") end
                    return
                end
                -- 未達上限：播每次提示音後重播選單
                if isound ~= "" then session:execute("playback", isound) end
                freeswitch.consoleLog("INFO", "[ivr] 無效鍵重播選單\n")
            end
        else
            timeout_count = timeout_count + 1
            freeswitch.consoleLog("INFO", "[ivr] 超時 " .. timeout_count .. "/" .. timeout_max .. "\n")
            if timeout_count >= timeout_max then
                -- 最後一次：只播 final_sound，跳過 exit_sound
                if timeout_snd ~= "" then
                    session:execute("playback", timeout_snd)
                end
                local ta = keys["t"]
                if ta then execute_action(session, ta) else session:execute("hangup", "") end
                return
            end
            -- 未達上限：播每次提示音後重播選單
            if esound ~= "" then session:execute("playback", esound) end
            freeswitch.consoleLog("INFO", "[ivr] 超時重播選單\n")
        end
    end

    if esound ~= "" then session:execute("playback", esound) end
    session:execute("hangup", "")
end

-- ── 入口 ──────────────────────────────────────────────────────────────────
local menu_id = argv[1]
if not menu_id or menu_id == "" then
    freeswitch.consoleLog("ERR", "[ivr] 未指定 MENU_ID\n")
    session:execute("hangup", "")
else
    run_ivr(session, menu_id, 0)
end
'''
    try:
        os.makedirs(os.path.dirname(IVR_LUA_SCRIPT), exist_ok=True)
        # 備份舊版（如有）
        if os.path.exists(IVR_LUA_SCRIPT):
            ts = datetime.now().strftime("%Y%m%d_%H%M%S")
            shutil.copy2(IVR_LUA_SCRIPT, IVR_LUA_SCRIPT + f'.bak.{ts}')
        with open(IVR_LUA_SCRIPT, 'w', encoding='utf-8') as f:
            f.write(lua_content)
        return {'ok': True, 'path': IVR_LUA_SCRIPT, 'size': len(lua_content)}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

@router.get("/api/ivr/sounds/list", dependencies=[Depends(require_permission(Module.IVR, "read"))])
def list_ivr_sounds():
    """[相容保留] IVR 編輯器仍呼叫此端點；邏輯已委派給共用的 list_sound_library()"""
    return list_sound_library()


@router.post("/api/ivr/sounds/upload", dependencies=[Depends(require_permission(Module.IVR, "create"))])
async def upload_ivr_sound(file: UploadFile = File(...)):
    """[相容保留] IVR 編輯器仍呼叫此端點；邏輯已委派給共用的 upload_sound()"""
    return await upload_sound(file)


@router.delete("/api/ivr/sounds/{filename}", dependencies=[Depends(require_permission(Module.IVR, "delete"))])
def delete_ivr_sound(filename: str):
    """[相容保留] IVR 編輯器仍呼叫此端點；邏輯已委派給共用的 delete_sound()"""
    return delete_sound(filename)


@router.get("/api/ivr/sounds/stream", dependencies=[Depends(require_permission(Module.IVR, "read"))])
async def stream_ivr_sound(path: str):
    """[相容保留] IVR 編輯器仍呼叫此端點；邏輯已委派給共用的 stream_sound()"""
    return await stream_sound(path)


