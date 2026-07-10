"""
routers/groups.py — 分機群組（Ring Group / Hunt Group）CRUD：/api/groups*
"""
import os
import glob
import shutil
from datetime import datetime
from typing import List
from fastapi import APIRouter, HTTPException, Depends
from pydantic import BaseModel

from core.esl_client import esl
from core.constants import FS_RESERVED
from core.auth import require_permission
from core.permissions import Module

router = APIRouter()

GROUP_DIR = "/etc/freeswitch/dialplan/default"
GROUP_META_RE = r"<!--\s*DASHBOARD_GROUP_META:\s*(\{.*?\})\s*-->"


class GroupData(BaseModel):
    id: str
    name: str = ''
    members: List[str] = []
    strategy: str = 'simultaneous'
    ring_timeout: int = 20
    fallback_type: str = 'voicemail'
    fallback_target: str = ''
    context: str = 'default'


def _group_meta(data: GroupData) -> dict:
    return {
        "id": data.id, "name": data.name, "members": data.members,
        "strategy": data.strategy, "ring_timeout": data.ring_timeout,
        "fallback_type": data.fallback_type, "fallback_target": data.fallback_target,
        "context": data.context,
    }


def write_group_xml(data: GroupData, filepath: str):
    import json
    separator = ',' if data.strategy == 'simultaneous' else '|'
    legs = separator.join(f"user/{m}@${{domain_name}}" for m in data.members)

    if data.fallback_type == 'voicemail' and data.fallback_target:
        fallback_xml = (
            f'      <action application="answer"/>\n'
            f'      <action application="sleep" data="500"/>\n'
            f'      <action application="voicemail" data="default ${{domain_name}} {data.fallback_target}"/>\n'
        )
    elif data.fallback_type == 'extension' and data.fallback_target:
        fallback_xml = f'      <action application="transfer" data="{data.fallback_target} XML {data.context}"/>\n'
    else:
        fallback_xml = '      <action application="hangup" data="NO_ANSWER"/>\n'

    meta_json = json.dumps(_group_meta(data), ensure_ascii=False)
    content = f"""<!-- DASHBOARD_GROUP_META: {meta_json} -->
<include>
  <extension name="ring_group_{data.id}">
    <condition field="destination_number" expression="^{data.id}$">
      <action application="set" data="ring_group_name={data.name}"/>
      <action application="set" data="continue_on_fail=true"/>
      <action application="set" data="call_timeout={data.ring_timeout}"/>
      <action application="bridge" data="{legs}"/>
{fallback_xml}    </condition>
  </extension>
</include>
"""
    with open(filepath, 'w', encoding='utf-8') as f:
        f.write(content)


def _read_group_meta(filepath: str):
    import json, re
    with open(filepath, 'r', encoding='utf-8') as f:
        content = f.read()
    m = re.search(GROUP_META_RE, content, re.DOTALL)
    if not m:
        return None
    meta = json.loads(m.group(1))
    meta['path'] = filepath
    return meta


@router.get("/api/groups/list", dependencies=[Depends(require_permission(Module.GROUPS, "read"))])
def list_groups():
    """列出所有分機群組（讀取 00_group_*.xml 及舊格式 group_*.xml 內嵌的 JSON 設定）"""
    result = []
    seen_paths = set()
    patterns = [
        f"{GROUP_DIR}/00_group_*.xml",
        f"{GROUP_DIR}/group_*.xml",
    ]
    for pattern in patterns:
        for filepath in sorted(glob.glob(pattern)):
            if filepath in seen_paths:
                continue
            seen_paths.add(filepath)
            try:
                meta = _read_group_meta(filepath)
                if meta:
                    result.append(meta)
            except Exception:
                pass
    return {'groups': result, 'total': len(result)}


@router.post("/api/groups", dependencies=[Depends(require_permission(Module.GROUPS, "create"))])
def create_group(data: GroupData):
    """新增分機群組"""
    gid = data.id.strip()
    if not gid.isdigit() or not (2 <= len(gid) <= 6):
        raise HTTPException(status_code=400, detail="群組撥號號碼須為 2-6 位數字")
    reserved_set = {r["number"] for r in FS_RESERVED}
    if gid in reserved_set:
        reserved_name = next((r["name"] for r in FS_RESERVED if r["number"] == gid), "FreeSwitch 內建")
        raise HTTPException(status_code=409, detail=f"號碼 {gid} 為 FreeSwitch 保留號碼（{reserved_name}），請改用其他號碼")
    if 1000 <= int(gid) <= 1999:
        raise HTTPException(status_code=400, detail="號碼 1000-1999 保留給分機，請改用其他號碼（建議 7001、7002…）")
    if not data.members:
        raise HTTPException(status_code=400, detail="請至少指定一位成員分機")
    filepath = f"{GROUP_DIR}/00_group_{gid}.xml"
    old_filepath = f"{GROUP_DIR}/group_{gid}.xml"
    if os.path.exists(filepath) or os.path.exists(old_filepath):
        raise HTTPException(status_code=409, detail=f"群組 {gid} 已存在")
    write_group_xml(data, filepath)
    esl.api('reloadxml')
    return {'ok': True, 'id': gid}


@router.put("/api/groups/{group_id}", dependencies=[Depends(require_permission(Module.GROUPS, "update"))])
def update_group(group_id: str, data: GroupData):
    """更新分機群組（自動升級舊格式 group_*.xml → 00_group_*.xml）"""
    if not data.members:
        raise HTTPException(status_code=400, detail="請至少指定一位成員分機")
    new_filepath = f"{GROUP_DIR}/00_group_{group_id}.xml"
    old_filepath  = f"{GROUP_DIR}/group_{group_id}.xml"
    if os.path.exists(new_filepath):
        filepath = new_filepath
    elif os.path.exists(old_filepath):
        filepath = old_filepath
        old_backup = old_filepath + ".bak." + datetime.now().strftime("%Y%m%d_%H%M%S")
        shutil.copy2(old_filepath, old_backup)
        os.remove(old_filepath)
        filepath = new_filepath
        print(f"[groups] 升級檔名：{old_filepath} → {new_filepath}")
    else:
        raise HTTPException(status_code=404, detail=f"群組 {group_id} 不存在")
    if os.path.exists(filepath):
        backup = filepath + ".bak." + datetime.now().strftime("%Y%m%d_%H%M%S")
        shutil.copy2(filepath, backup)
    write_group_xml(data, filepath)
    esl.api('reloadxml')
    return {'ok': True, 'id': group_id}


@router.delete("/api/groups/{group_id}", dependencies=[Depends(require_permission(Module.GROUPS, "delete"))])
def delete_group(group_id: str):
    """刪除分機群組（備份原檔，支援新舊格式檔名）"""
    new_filepath = f"{GROUP_DIR}/00_group_{group_id}.xml"
    old_filepath  = f"{GROUP_DIR}/group_{group_id}.xml"
    if os.path.exists(new_filepath):
        filepath = new_filepath
    elif os.path.exists(old_filepath):
        filepath = old_filepath
    else:
        raise HTTPException(status_code=404, detail=f"群組 {group_id} 不存在")
    backup = filepath + ".bak." + datetime.now().strftime("%Y%m%d_%H%M%S")
    shutil.copy2(filepath, backup)
    os.remove(filepath)
    esl.api('reloadxml')
    return {'ok': True}