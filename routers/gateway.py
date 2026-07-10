"""
routers/gateway.py — Gateway / SIP Trunk CRUD：/api/gateway*
"""
import os
import glob
import shutil
from datetime import datetime
from fastapi import APIRouter, HTTPException, Depends
from pydantic import BaseModel
from lxml import etree

from core.esl_client import esl
from core.auth import require_permission
from core.permissions import Module

router = APIRouter()

GATEWAY_DIR = "/etc/freeswitch/sip_profiles/external"


@router.get("/api/gateway/list", dependencies=[Depends(require_permission(Module.GATEWAY, "read"))])
def list_gateways():
    """列出所有 Gateway XML 檔案"""
    result = []
    try:
        for filepath in sorted(glob.glob(f"{GATEWAY_DIR}/*.xml")):
            try:
                tree = etree.parse(filepath)
                gw = tree.find('.//gateway')
                if gw is None: continue
                params = {p.get('name'): p.get('value')
                         for p in tree.findall('.//param')}
                result.append({
                    'name':     gw.get('name',''),
                    'username': params.get('username',''),
                    'password': params.get('password',''),
                    'proxy':    params.get('proxy',''),
                    'register': params.get('register','false'),
                    'caller_id_in_from': params.get('caller-id-in-from','false'),
                    'extension': params.get('extension',''),
                    'path':     filepath,
                    'filename': os.path.basename(filepath),
                })
            except Exception:
                pass
        return {'gateways': result, 'total': len(result)}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


class GatewayData(BaseModel):
    name:     str
    username: str = ''
    password: str = ''
    proxy:    str = ''
    register: str = 'false'
    extension: str = ''
    caller_id_in_from: str = 'false'


def write_gateway_xml(data: GatewayData, filepath: str):
    content = f"""<include>
  <gateway name="{data.name}">
    <param name="username" value="{data.username}"/>
    <param name="password" value="{data.password}"/>
    <param name="proxy" value="{data.proxy}"/>
    <param name="register" value="{data.register}"/>
    <param name="extension" value="{data.extension or data.username}"/>
    <param name="caller-id-in-from" value="{data.caller_id_in_from}"/>
  </gateway>
</include>"""
    with open(filepath, 'w', encoding='utf-8') as f:
        f.write(content)


@router.post("/api/gateway", dependencies=[Depends(require_permission(Module.GATEWAY, "create"))])
def create_gateway(data: GatewayData):
    filepath = f"{GATEWAY_DIR}/{data.name}.xml"
    if os.path.exists(filepath):
        raise HTTPException(status_code=409, detail=f"Gateway {data.name} 已存在")
    write_gateway_xml(data, filepath)
    esl.api('reloadxml')
    esl.api('sofia profile external rescan')
    return {'ok': True}


@router.put("/api/gateway/{name}", dependencies=[Depends(require_permission(Module.GATEWAY, "update"))])
def update_gateway(name: str, data: GatewayData):
    filepath = f"{GATEWAY_DIR}/{name}.xml"
    if not os.path.exists(filepath):
        raise HTTPException(status_code=404, detail=f"Gateway {name} 不存在")
    backup = filepath + ".bak." + datetime.now().strftime("%Y%m%d_%H%M%S")
    shutil.copy2(filepath, backup)
    write_gateway_xml(data, filepath)
    esl.api('reloadxml')
    esl.api('sofia profile external rescan')
    return {'ok': True}


@router.delete("/api/gateway/{name}", dependencies=[Depends(require_permission(Module.GATEWAY, "delete"))])
def delete_gateway(name: str):
    filepath = f"{GATEWAY_DIR}/{name}.xml"
    if not os.path.exists(filepath):
        raise HTTPException(status_code=404, detail=f"Gateway {name} 不存在")
    backup = filepath + ".bak." + datetime.now().strftime("%Y%m%d_%H%M%S")
    shutil.copy2(filepath, backup)
    os.remove(filepath)
    esl.api('reloadxml')
    esl.api('sofia profile external rescan')
    return {'ok': True}