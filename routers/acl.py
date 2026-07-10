"""
routers/acl.py — acl.conf.xml 自訂信任清單管理：/api/acl/trusted-sbc*

只管理「trusted_sbc」這一個自訂 list，不開放編輯 acl.conf.xml 既有系統清單
（domains、localnet.auto 等維持原樣，避免破壞既有機制）。

用途：內部 SBC/SIP trunk 可能分佈在不同網段（例如 192.168.100.220、172.16.20.2），
sip profile 的 local-network-acl 若仍用 localnet.auto（僅自動信任與主機同網段的來源），
跨網段的 SBC 不會被正確判斷為內部裝置。改用本清單明確列舉信任來源，
新增/移除 SBC 只需增減 IP，不必碰 profile 參數本身。
"""
import os
import shutil
import ipaddress
import subprocess   # ← 新增
from datetime import datetime

from fastapi import APIRouter, HTTPException, Body, Depends
from lxml import etree
from core.auth import require_permission
from core.permissions import Module
from core.esl_client import esl

router = APIRouter()

ACL_XML_PATH = "/etc/freeswitch/autoload_configs/acl.conf.xml"
TRUSTED_LIST_NAME = "trusted_sbc"


def _load_tree():
    if not os.path.exists(ACL_XML_PATH):
        raise HTTPException(status_code=500, detail=f"找不到 {ACL_XML_PATH}")
    try:
        return etree.parse(ACL_XML_PATH)
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"acl.conf.xml 解析失敗：{e}")


def _get_or_create_list(root):
    lists_node = root.find(".//network-lists")
    if lists_node is None:
        raise HTTPException(status_code=500, detail="acl.conf.xml 結構異常：找不到 network-lists 節點")
    target = lists_node.find(f"./list[@name='{TRUSTED_LIST_NAME}']")
    if target is None:
        target = etree.SubElement(lists_node, "list")
        target.set("name", TRUSTED_LIST_NAME)
        target.set("default", "deny")
    return target


def _normalize_cidr(value: str) -> str:
    """接受單一 IP 或 CIDR，統一轉成 CIDR 格式（單一 IP 補 /32）"""
    v = value.strip()
    try:
        net = ipaddress.ip_network(v, strict=False) if "/" in v else ipaddress.ip_network(f"{v}/32", strict=False)
    except ValueError:
        raise HTTPException(status_code=400, detail=f"無效的 IP/CIDR：{value}")
    return str(net)

def _test_acl_live(cidr: str) -> bool:
    try:
        net = ipaddress.ip_network(cidr, strict=False)
        test_ip = str(net.network_address) if net.num_addresses == 1 else str(next(net.hosts(), net.network_address))
        result = esl.api(f"acl {test_ip} {TRUSTED_LIST_NAME}")
        print(f"[DEBUG _test_acl_live] cidr={cidr} test_ip={test_ip} result={result!r}")
        return result.strip().lower() == "true"
    except Exception as e:                                          # ← 補回 as e
        print(f"[DEBUG _test_acl_live] EXCEPTION: {e}")
        return False

def _write_and_reload(tree):
    backup = ACL_XML_PATH + ".bak." + datetime.now().strftime("%Y%m%d_%H%M%S")
    shutil.copy2(ACL_XML_PATH, backup)
    try:
        tree.write(ACL_XML_PATH, xml_declaration=True, encoding="UTF-8", pretty_print=True)  # ← 加這個參數
    except Exception as e:
        shutil.copy2(backup, ACL_XML_PATH)
        raise HTTPException(status_code=500, detail=f"寫入失敗，已還原：{e}")
    esl.api("reloadxml")
    return backup


@router.get("/api/acl/trusted-sbc", dependencies=[Depends(require_permission(Module.ACL, "read"))])
def list_trusted_sbc():
    """列出目前信任的內部 SBC IP/CIDR，並附上是否已在 FreeSWITCH 記憶體中生效"""
    tree = _load_tree()
    target = tree.find(f".//list[@name='{TRUSTED_LIST_NAME}']")
    entries = []
    if target is not None:
        for node in target.findall("node"):
            cidr = node.get("cidr", "")
            entries.append({
                "cidr": cidr,
                "note": node.get("description", ""),
                "active": _test_acl_live(cidr),
            })
    return {"list_name": TRUSTED_LIST_NAME, "entries": entries}


@router.post("/api/acl/trusted-sbc", dependencies=[Depends(require_permission(Module.ACL, "create"))])
def add_trusted_sbc(cidr: str = Body(...), note: str = Body("")):
    """新增一筆信任 SBC IP/CIDR"""
    normalized = _normalize_cidr(cidr)
    tree = _load_tree()
    root = tree.getroot()
    target = _get_or_create_list(root)

    if target.find(f"./node[@cidr='{normalized}']") is not None:
        raise HTTPException(status_code=409, detail=f"{normalized} 已存在於信任清單中")

    node = etree.SubElement(target, "node")
    node.set("type", "allow")
    node.set("cidr", normalized)
    if note:
        node.set("description", note)

    backup = _write_and_reload(tree)
    return {"ok": True, "backup": backup, "added": normalized}

@router.put("/api/acl/trusted-sbc/{old_cidr:path}", dependencies=[Depends(require_permission(Module.ACL, "update"))])
def update_trusted_sbc(old_cidr: str, cidr: str = Body(...), note: str = Body("")):
    """編輯既有信任項目：可同時修改 IP/CIDR 與備註（IP 變更時視為 rename）"""
    old_normalized = _normalize_cidr(old_cidr)
    new_normalized = _normalize_cidr(cidr)

    tree = _load_tree()
    root = tree.getroot()
    target = root.find(f".//list[@name='{TRUSTED_LIST_NAME}']")
    node = target.find(f"./node[@cidr='{old_normalized}']") if target is not None else None
    if node is None:
        raise HTTPException(status_code=404, detail=f"信任清單中找不到 {old_normalized}")

    if new_normalized != old_normalized and target.find(f"./node[@cidr='{new_normalized}']") is not None:
        raise HTTPException(status_code=409, detail=f"{new_normalized} 已存在於信任清單中")

    node.set("cidr", new_normalized)
    if note:
        node.set("description", note)
    elif node.get("description") is not None:
        del node.attrib["description"]

    backup = _write_and_reload(tree)
    return {"ok": True, "backup": backup, "updated": new_normalized}

# routers/acl.py — remove_trusted_sbc()，回傳加一個 flag 供前端顯示 toast
@router.delete("/api/acl/trusted-sbc/{cidr:path}", dependencies=[Depends(require_permission(Module.ACL, "delete"))])
def remove_trusted_sbc(cidr: str):
    normalized = _normalize_cidr(cidr)
    tree = _load_tree()
    root = tree.getroot()
    target = root.find(f".//list[@name='{TRUSTED_LIST_NAME}']")
    node = target.find(f"./node[@cidr='{normalized}']") if target is not None else None
    if node is None:
        raise HTTPException(status_code=404, detail=f"信任清單中找不到 {normalized}")

    target.remove(node)
    backup = _write_and_reload(tree)
    # 移除後仍查詢一次記憶體狀態，回傳給前端做「尚未真正撤銷」的提示
    still_active = _test_acl_live(normalized)
    return {"ok": True, "backup": backup, "removed": normalized, "still_active_until_restart": still_active}

# routers/acl.py
@router.post("/api/acl/apply-restart", dependencies=[Depends(require_permission(Module.ACL, "update"))])
def apply_restart(confirm: bool = Body(False, embed=True)):
    calls_raw = esl.api("show calls count")
    active_calls = 0
    try:
        active_calls = int(calls_raw.strip().split()[0])
    except (ValueError, IndexError):
        pass

    if active_calls > 0 and not confirm:
        raise HTTPException(
            status_code=409,
            detail=f"目前有 {active_calls} 通進行中的通話，重啟會全部中斷。確定要繼續請再次送出確認。"
        )

    try:
        # 完全脫離父行程（fs-dashboard 自身若因依賴關係被連帶重啟也不影響此呼叫）
        subprocess.Popen(
            ["systemctl", "restart", "freeswitch"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
    except FileNotFoundError:
        raise HTTPException(status_code=500, detail="找不到 systemctl 指令，請確認執行環境")
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"重啟失敗：{e}，請 SSH 手動執行 systemctl restart freeswitch")

    return {"ok": True, "active_calls_dropped": active_calls, "note": "重啟指令已送出（背景執行），約 10-30 秒後完成"}
