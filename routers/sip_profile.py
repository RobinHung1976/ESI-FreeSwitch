"""
routers/sip_profile.py — SIP Profile（internal / external / 自訂 NAT profile）安全參數編輯

設計原則同 vars.py：白名單參數才可寫入，其餘一律唯讀 + 403，需 SSH 手動修改。
新增 profile（NAT 用途）走獨立精靈端點，結構性欄位（context / ACL / 埠號綁定方式）
一律套用固定安全模板，不開放自由填寫，避免重演 ext-sip-ip/ext-rtp-ip 誤用導致斷線的問題。
"""
import os
import re
import glob
import shutil
import ipaddress
from datetime import datetime

from fastapi import APIRouter, HTTPException, Body, Depends
from pydantic import BaseModel, Field
from lxml import etree
from core.auth import require_permission
from core.permissions import Module

from core.esl_client import esl

router = APIRouter()

PROFILE_DIR = "/etc/freeswitch/sip_profiles"
CORE_PROFILES = {"internal", "external"}   # 系統核心 profile，禁止刪除


# ── 白名單：可安全編輯、reloadxml + profile restart 即生效、影響範圍可控 ──────
SIP_PARAM_WHITELIST = {
    "sip-trace": {
        "label": "SIP 封包追蹤", "type": "bool",
    },
    "sip-capture": {
        "label": "SIP 抓包 (HEP/homer)", "type": "bool",
    },
    "debug": {
        "label": "除錯等級 (0-9)", "type": "select",
        "options": [str(i) for i in range(10)],
    },
    "log-auth-failures": {
        "label": "記錄認證失敗", "type": "bool",
    },
    "dtmf-duration": {
        "label": "DTMF 持續時間 (ms)", "type": "numeric",
    },
    "nonce-ttl": {
        "label": "認證 Nonce TTL (秒)", "type": "numeric",
    },
    "rtp-timeout-sec": {
        "label": "RTP 閒置逾時 (秒)", "type": "numeric",
        "warn": "數值過小可能導致通話中被誤判逾時而斷線",
    },
    "rtp-hold-timeout-sec": {
        "label": "RTP 保留逾時 (秒)", "type": "numeric",
    },
    "inbound-codec-negotiation": {
        "label": "Codec 協商模式", "type": "select",
        "options": ["generous", "greedy"],
    },
}

# ── 黑名單：唯讀顯示，禁止透過網頁寫入（含造成過斷線 bug 的 ext-sip-ip/ext-rtp-ip）──
SIP_PARAM_BLACKLIST = {
    "context", "sip-port", "rtp-ip", "sip-ip", "ext-rtp-ip", "ext-sip-ip",
    "local-network-acl", "apply-nat-acl", "apply-inbound-acl", "apply-register-acl",
    "tls", "tls-only", "tls-bind-params", "tls-sip-port", "tls-passphrase",
    "tls-verify-date", "tls-verify-policy", "tls-verify-depth", "tls-verify-in-subjects",
    "tls-version", "tls-ciphers",
    "auth-calls", "auth-all-packets", "auth-subscriptions", "inbound-reg-force-matching-username",
    "record-template", "record-path",
    "inbound-codec-prefs", "outbound-codec-prefs",
    "ws-binding", "wss-binding",
    "force-register-domain", "force-subscription-domain", "force-register-db-domain",
    "challenge-realm", "inbound-late-negotiation",
    "watchdog-enabled", "watchdog-step-timeout", "watchdog-event-timeout",
    "forward-unsolicited-mwi-notify", "rtp-timer-name",
}


# ── 共用工具 ──────────────────────────────────────────────────────────────────

def _valid_profile_name(name: str) -> bool:
    return bool(re.fullmatch(r"[a-zA-Z0-9_-]{2,64}", name))


def _profile_path(name: str) -> str:
    if not _valid_profile_name(name):
        raise HTTPException(status_code=400, detail="Profile 名稱格式錯誤")
    path = f"{PROFILE_DIR}/{name}.xml"
    if not os.path.exists(path):
        raise HTTPException(status_code=404, detail=f"Profile {name} 不存在")
    return path


def _list_all_profile_names() -> list:
    return sorted(
        os.path.splitext(os.path.basename(p))[0]
        for p in glob.glob(f"{PROFILE_DIR}/*.xml")
    )


def _used_sip_ports() -> dict:
    """掃描所有 profile 目前使用的 sip-port（僅收純數字字面值，$${var} 形式無法在此展開比對）"""
    used = {}
    for name in _list_all_profile_names():
        try:
            tree = etree.parse(f"{PROFILE_DIR}/{name}.xml")
            for p in tree.findall(".//param[@name='sip-port']"):
                val = p.get("value", "")
                if val.isdigit():
                    used[val] = name
        except Exception:
            continue
    return used


# ── 讀取 / 更新既有 profile 白名單參數 ────────────────────────────────────────

@router.get("/api/sip-profile", dependencies=[Depends(require_permission(Module.SIP_PROFILE, "read"))])
def list_sip_profiles():
    """列出所有 profile 檔名（含既有 internal/external 與日後新增的 NAT profile）"""
    return {"profiles": _list_all_profile_names()}


@router.get("/api/sip-profile/{name}", dependencies=[Depends(require_permission(Module.SIP_PROFILE, "read"))])
def get_sip_profile(name: str):
    path = _profile_path(name)
    tree = etree.parse(path)
    params = {p.get("name"): p.get("value", "") for p in tree.findall(".//param")}
    return {
        "name": name,
        "editable": {k: params.get(k, "") for k in SIP_PARAM_WHITELIST if k in params},
        "readonly": {k: v for k, v in params.items() if k in SIP_PARAM_BLACKLIST},
        "meta": SIP_PARAM_WHITELIST,
    }


@router.post("/api/sip-profile/{name}", dependencies=[Depends(require_permission(Module.SIP_PROFILE, "update"))])
def update_sip_profile(name: str, updates: dict = Body(...)):
    path = _profile_path(name)

    safe = {}
    for k, v in updates.items():
        if k in SIP_PARAM_BLACKLIST:
            raise HTTPException(status_code=403, detail=f"參數 {k} 為禁止編輯項目，請改用 SSH 手動修改")
        if k not in SIP_PARAM_WHITELIST:
            raise HTTPException(status_code=400, detail=f"參數 {k} 不在允許編輯清單中")
        if not isinstance(v, str):
            raise HTTPException(status_code=400, detail=f"參數 {k} 值必須是字串")

        meta = SIP_PARAM_WHITELIST[k]
        if meta["type"] == "bool" and v not in ("true", "false"):
            raise HTTPException(status_code=400, detail=f"參數 {k} 只能是 true 或 false")
        if meta["type"] == "select" and v not in meta.get("options", []):
            raise HTTPException(status_code=400, detail=f"參數 {k} 必須是以下其中之一：{', '.join(meta['options'])}")
        if meta["type"] == "numeric" and not re.fullmatch(r"\d{1,6}", v):
            raise HTTPException(status_code=400, detail=f"參數 {k} 必須是數字")

        safe[k] = v

    if not safe:
        raise HTTPException(status_code=400, detail="沒有任何有效的參數更新")

    tree = etree.parse(path)
    found = set()
    for p in tree.findall(".//param"):
        if p.get("name") in safe:
            p.set("value", safe[p.get("name")])
            found.add(p.get("name"))
    missing = set(safe) - found
    if missing:
        raise HTTPException(
            status_code=404,
            detail=f"profile 中找不到參數：{', '.join(sorted(missing))}（需先在 XML 中加入該 param 節點才能編輯）"
        )

    backup = path + ".bak." + datetime.now().strftime("%Y%m%d_%H%M%S")
    shutil.copy2(path, backup)
    try:
        tree.write(path, xml_declaration=True, encoding="UTF-8")
    except Exception as e:
        shutil.copy2(backup, path)
        raise HTTPException(status_code=500, detail=f"寫入失敗，已還原：{e}")

    esl.api("reloadxml")
    # 參數層級設定需 restart 才會套用；rescan 只重讀 gateways，兩者不可混用
    restart_result = esl.api(f"sofia profile {name} restart")
    return {"ok": True, "backup": backup, "updated": list(safe.keys()), "restart_result": restart_result}


# ── 新增 NAT Profile 精靈：固定安全模板，不開放結構性欄位 ─────────────────────

class NatProfileCreate(BaseModel):
    name: str = Field(..., description="Profile 名稱，例如 external_nat")
    sip_port: int = Field(..., ge=5000, le=65000)
    ext_ip_mode: str = Field("stun", pattern="^(auto|stun|static)$")
    stun_server: str = "stun:stun.freeswitch.org"
    static_ip: str = ""
    context: str = "public"


def _resolve_ext_ip_value(data: NatProfileCreate) -> str:
    if data.ext_ip_mode == "auto":
        return "auto"
    if data.ext_ip_mode == "stun":
        if not data.stun_server.startswith("stun:"):
            raise HTTPException(status_code=400, detail="STUN server 需以 stun: 開頭，例如 stun:stun.freeswitch.org")
        return data.stun_server
    # static：需明確固定公網 IP，改動後須手動維護
    try:
        ipaddress.IPv4Address(data.static_ip)
    except ValueError:
        raise HTTPException(status_code=400, detail=f"無效的固定 IP：{data.static_ip}")
    return data.static_ip


NAT_PROFILE_TEMPLATE = """<profile name="{name}">
  <!-- 由 Dashboard NAT Profile 精靈產生，結構比照 external.xml，僅開放安全欄位 -->
  <gateways>
    <X-PRE-PROCESS cmd="include" data="{name}/*.xml"/>
  </gateways>
  <aliases></aliases>
  <domains>
    <domain name="all" alias="false" parse="true"/>
  </domains>
  <settings>
    <param name="debug" value="0"/>
    <param name="sip-trace" value="no"/>
    <param name="sip-capture" value="no"/>
    <param name="rfc2833-pt" value="101"/>
    <param name="sip-port" value="{sip_port}"/>
    <param name="dialplan" value="XML"/>
    <param name="context" value="{context}"/>
    <param name="dtmf-duration" value="2000"/>
    <param name="inbound-codec-prefs" value="$${{global_codec_prefs}}"/>
    <param name="outbound-codec-prefs" value="$${{outbound_codec_prefs}}"/>
    <param name="hold-music" value="$${{hold_music}}"/>
    <param name="rtp-timer-name" value="soft"/>
    <param name="local-network-acl" value="trusted_sbc"/>
    <param name="manage-presence" value="false"/>
    <param name="inbound-codec-negotiation" value="generous"/>
    <param name="nonce-ttl" value="60"/>
    <param name="auth-calls" value="false"/>
    <param name="inbound-late-negotiation" value="true"/>
    <param name="rtp-ip" value="$${{local_ip_v4}}"/>
    <param name="sip-ip" value="$${{local_ip_v4}}"/>
    <param name="ext-rtp-ip" value="{ext_ip}"/>
    <param name="ext-sip-ip" value="{ext_ip}"/>
    <param name="rtp-timeout-sec" value="300"/>
    <param name="rtp-hold-timeout-sec" value="1800"/>
    <param name="tls" value="false"/>
  </settings>
</profile>
"""


@router.post("/api/sip-profile/nat-wizard", dependencies=[Depends(require_permission(Module.SIP_PROFILE, "create"))])
def create_nat_profile(data: NatProfileCreate):
    if not _valid_profile_name(data.name):
        raise HTTPException(status_code=400, detail="Profile 名稱只能包含英數字、底線、連字號，長度 2-64")
    if data.name in CORE_PROFILES:
        raise HTTPException(status_code=400, detail=f"{data.name} 為系統保留名稱，請換一個名稱")

    path = f"{PROFILE_DIR}/{data.name}.xml"
    if os.path.exists(path):
        raise HTTPException(status_code=409, detail=f"Profile {data.name} 已存在")

    used_ports = _used_sip_ports()
    port_str = str(data.sip_port)
    if port_str in used_ports:
        raise HTTPException(
            status_code=409,
            detail=f"埠號 {data.sip_port} 已被 profile「{used_ports[port_str]}」使用，請換一個埠號"
        )

    ext_ip = _resolve_ext_ip_value(data)

    content = NAT_PROFILE_TEMPLATE.format(
        name=data.name, sip_port=data.sip_port, context=data.context, ext_ip=ext_ip,
    )

    # gateway 子目錄，比照 external/ 模式，供未來掛接該 profile 專屬 trunk（gateway.py 可沿用）
    os.makedirs(f"{PROFILE_DIR}/{data.name}", exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        f.write(content)

    esl.api("reloadxml")
    start_result = esl.api(f"sofia profile {data.name} start")

    return {
        "ok": True,
        "name": data.name,
        "ext_ip_mode": data.ext_ip_mode,
        "ext_ip_value": ext_ip,
        "start_result": start_result,
        "note": "新 profile 已建立，請至 Gateway 頁面確認狀態為 RUNNING；"
                "若未出現，請確認 sofia.conf.xml 是否有萬用字元 include sip_profiles/*.xml 後再試一次。",
    }


@router.delete("/api/sip-profile/{name}", dependencies=[Depends(require_permission(Module.SIP_PROFILE, "delete"))])
def delete_sip_profile(name: str):
    """僅允許刪除非核心 profile（internal/external 禁止刪除，避免誤刪主系統設定）"""
    if name in CORE_PROFILES:
        raise HTTPException(status_code=403, detail="internal / external 為系統核心 profile，禁止刪除")
    path = _profile_path(name)

    backup = path + ".bak." + datetime.now().strftime("%Y%m%d_%H%M%S")
    shutil.copy2(path, backup)
    os.remove(path)

    esl.api(f"sofia profile {name} stop")
    esl.api("reloadxml")
    return {"ok": True, "backup": backup}
