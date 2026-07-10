"""
routers/vars.py — vars.xml 白名單全域變數讀寫：/api/vars
"""
import os
import shutil
from datetime import datetime
from fastapi import APIRouter, HTTPException, Body, Depends
from lxml import etree

from core.esl_client import esl
from core.auth import require_permission
from core.permissions import Module

router = APIRouter()


# ── 全域變數設定（vars.xml）────────────────────────────────────────────────
VARS_XML_PATH = "/etc/freeswitch/vars.xml"

# 白名單：只暴露可安全透過 reloadxml 套用、不會中斷服務的變數。
# 依實際 vars-20260630.xml 內容校正（2026-06-30）。
# 危險變數（網路/Port/TLS/Codec 等動到需重啟服務或破壞 STUN 自動偵測的）刻意不放入。
VARS_WHITELIST = {
    "default_password": {
        "label": "預設分機密碼", "type": "password",
        "warn": "影響所有未個別覆寫密碼的分機註冊，請確認後再儲存",
    },
    "domain": {
        "label": "預設網域 (SIP Domain)", "type": "text",
        "warn": "影響分機 SIP 註冊網域，變更後既有分機可能需要重新註冊",
    },
    "hold_music": {"label": "保留音樂路徑", "type": "text"},
    "outbound_caller_name": {"label": "外撥顯示名稱", "type": "text"},
    "outbound_caller_id":   {"label": "外撥顯示號碼", "type": "text"},
    # default_areacode / default_country 已移除：vanilla vars.xml 與本系統 Dialplan
    # 均無規則實際引用這兩個變數，留在白名單會誤導使用者以為改了會生效。
    "console_loglevel": {
        "label": "主控台日誌等級", "type": "select",
        "options": ["debug", "info", "notice", "warning", "err", "crit", "alert"],
    },
    "call_debug": {"label": "通話除錯模式", "type": "bool"},
    "presence_privacy": {
        "label": "隱藏目的號碼 (Presence Privacy)", "type": "bool",
        "warn": "true 時 NOTIFY 訊息不包含目的號碼，影響部分話機的來電顯示/燈號功能",
    },
}

# 明確禁止編輯的高風險變數（即使日後想擴充白名單也擋下，需改用 SSH）。
# external_rtp_ip / external_sip_ip 在 vars.xml 中用 cmd="stun-set"（非 "set"），
# 解析器本就不會讀到，這裡列出是防禦性保留：避免日後有人把 cmd 改回 "set" 而產生漏洞。
VARS_BLACKLIST = {
    "internal_sip_port", "internal_tls_port", "external_sip_port", "external_tls_port",
    "internal_ssl_enable", "external_ssl_enable", "internal_auth_calls", "external_auth_calls",
    "sip_tls_version", "sip_tls_ciphers", "rtp_sdes_suites",
    "rtp_video_max_bandwidth_in", "rtp_video_max_bandwidth_out",
    "bind_server_ip", "external_rtp_ip", "external_sip_ip", "local_ip_v4",
    "rtp_start_port", "rtp_end_port",
    "default_provider_password",  # 範例憑證，避免誤用網頁編輯敏感憑證欄位
}


def _parse_vars_xml(path: str = VARS_XML_PATH) -> dict:
    """解析 vars.xml 中 <X-PRE-PROCESS cmd="set" data="key=value"/>，只回傳白名單變數"""
    if not os.path.exists(path):
        raise HTTPException(status_code=404, detail=f"找不到 {path}")
    try:
        tree = etree.parse(path)
    except Exception as xe:
        raise HTTPException(status_code=500, detail=f"vars.xml 解析失敗：{xe}")

    result = {}
    for node in tree.getroot().findall(".//X-PRE-PROCESS"):
        if node.get("cmd") != "set":
            continue
        data = node.get("data", "")
        key, sep, value = data.partition("=")
        key = key.strip()
        if not sep or key not in VARS_WHITELIST:
            continue
        meta = VARS_WHITELIST[key]
        result[key] = {
            "label":   meta["label"],
            "type":    meta["type"],
            "value":   value,
            "warn":    meta.get("warn", ""),
            "options": meta.get("options", []),
        }
    return result


def _update_vars_xml(updates: dict, path: str = VARS_XML_PATH) -> str:
    """更新 vars.xml 中白名單變數的值，寫回前備份原檔，回傳備份路徑"""
    if not os.path.exists(path):
        raise HTTPException(status_code=404, detail=f"找不到 {path}")

    safe_updates = {}
    for k, v in updates.items():
        if k in VARS_BLACKLIST:
            raise HTTPException(status_code=403, detail=f"變數 {k} 為禁止編輯項目，請改用 SSH 手動修改")
        if k not in VARS_WHITELIST:
            raise HTTPException(status_code=400, detail=f"變數 {k} 不在允許編輯清單中")
        if not isinstance(v, str):
            raise HTTPException(status_code=400, detail=f"變數 {k} 的值必須是字串")

        meta = VARS_WHITELIST[k]
        if meta["type"] == "bool" and v not in ("true", "false"):
            raise HTTPException(status_code=400, detail=f"變數 {k} 只能是 true 或 false")
        if meta["type"] == "select" and v not in meta.get("options", []):
            raise HTTPException(status_code=400, detail=f"變數 {k} 必須是以下其中之一：{', '.join(meta['options'])}")
        if meta["type"] in ("text", "password") and v.strip() == "":
            raise HTTPException(status_code=400, detail=f"變數 {k} 不可為空白")

        safe_updates[k] = v

    if not safe_updates:
        raise HTTPException(status_code=400, detail="沒有任何有效的變數更新")

    try:
        tree = etree.parse(path)
    except Exception as xe:
        raise HTTPException(status_code=500, detail=f"vars.xml 解析失敗：{xe}")

    root = tree.getroot()
    found_keys = set()
    for node in root.findall(".//X-PRE-PROCESS"):
        if node.get("cmd") != "set":
            continue
        data = node.get("data", "")
        key, sep, _old_value = data.partition("=")
        key = key.strip()
        if sep and key in safe_updates:
            node.set("data", f"{key}={safe_updates[key]}")
            found_keys.add(key)

    missing = set(safe_updates) - found_keys
    if missing:
        raise HTTPException(status_code=404, detail=f"vars.xml 中找不到變數：{', '.join(sorted(missing))}")

    backup = path + ".bak." + datetime.now().strftime("%Y%m%d_%H%M%S")
    shutil.copy2(path, backup)
    try:
        tree.write(path, xml_declaration=True, encoding="UTF-8")
    except Exception as e:
        # 寫入失敗時還原備份，避免留下半套設定
        shutil.copy2(backup, path)
        raise HTTPException(status_code=500, detail=f"寫入失敗，已還原原檔：{e}")

    return backup


@router.get("/api/vars", dependencies=[Depends(require_permission(Module.SETTINGS, "read"))])
def api_get_vars():
    """讀取 vars.xml 白名單內的全域變數"""
    return _parse_vars_xml()


@router.post("/api/vars", dependencies=[Depends(require_permission(Module.SETTINGS, "update"))])
def api_update_vars(updates: dict = Body(...)):
    """更新 vars.xml 白名單變數，寫回前自動備份，成功後 reloadxml"""
    backup = _update_vars_xml(updates)
    esl.api('reloadxml')
    return {"ok": True, "backup": backup, "updated": list(updates.keys())}
