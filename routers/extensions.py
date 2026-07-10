"""
routers/extensions.py — 分機 CRUD：/api/extensions*
"""

from fastapi import Depends
from core.auth import require_permission
from core.permissions import Module

import os
import glob
import shutil
from datetime import datetime
from fastapi import APIRouter, HTTPException, Query
from pydantic import BaseModel
from lxml import etree

from core.esl_client import esl

router = APIRouter()


EXT_DIR = "/etc/freeswitch/directory/default"

@router.get("/api/extensions/list", dependencies=[Depends(require_permission(Module.EXTENSIONS, "read"))])
def list_extensions():
    """列出所有分機"""
    result = []
    for filepath in sorted(glob.glob(f"{EXT_DIR}/*.xml")):
        try:
            tree = etree.parse(filepath)
            user = tree.find('.//user')
            if user is None: continue
            ext_id = user.get('id','').strip()
            if not ext_id:          # 跳過 id 為空的異常 XML
                continue
            # 若要只允許純數字分機（推薦），加這行：
            if not ext_id.isdigit():
                continue
            params = {p.get('name'): p.get('value') 
                     for p in tree.findall('.//params/param')}
            variables = {v.get('name'): v.get('value') 
                        for v in tree.findall('.//variables/variable')}
            result.append({
                'id':         ext_id,
                'password':   params.get('password',''),
                'vm_password':params.get('vm-password',''),
                'caller_id_name': variables.get('effective_caller_id_name',''),
                'caller_id_number': variables.get('effective_caller_id_number',''),
                'callgroup':  variables.get('callgroup',''),
                'toll_allow': variables.get('toll_allow',''),
                'accountcode':variables.get('accountcode',''),
                'context':    variables.get('user_context','default'),
                'recording_enabled': variables.get('recording_enabled','false') == 'true',
                'voicemail_enabled': variables.get('voicemail_enabled','true') == 'true',
                'path':       filepath,
                'filename':   os.path.basename(filepath),
            })
        except Exception as e:
            pass
    return {'extensions': result, 'total': len(result)}

class ExtensionData(BaseModel):
    id: str
    password: str = '$${default_password}'
    vm_password: str = ''
    caller_id_name: str = ''
    caller_id_number: str = ''
    callgroup: str = 'default'
    toll_allow: str = 'domestic,international,local'
    context: str = 'default'
    recording_enabled: bool = False
    voicemail_enabled: bool = True

def write_extension_xml(data: ExtensionData, filepath: str):
    vm_pw = data.vm_password or data.id
    recording_val = "true" if data.recording_enabled else "false"
    vm_enabled_val = "true" if data.voicemail_enabled else "false"
    content = f"""<include>
  <user id="{data.id}">
    <params>
      <param name="password" value="{data.password}"/>
      <param name="vm-password" value="{vm_pw}"/>
    </params>
    <variables>
      <variable name="toll_allow" value="{data.toll_allow}"/>
      <variable name="accountcode" value="{data.id}"/>
      <variable name="user_context" value="{data.context}"/>
      <variable name="effective_caller_id_name" value="{data.caller_id_name}"/>
      <variable name="effective_caller_id_number" value="{data.id}"/>
      <variable name="outbound_caller_id_name" value="${{outbound_caller_name}}"/>
      <variable name="outbound_caller_id_number" value="${{outbound_caller_id}}"/>
      <variable name="callgroup" value="{data.callgroup}"/>
      <variable name="recording_enabled" value="{recording_val}"/>
      <variable name="voicemail_enabled" value="{vm_enabled_val}"/>
    </variables>
  </user>
</include>"""
    with open(filepath, 'w', encoding='utf-8') as f:
        f.write(content)

@router.post("/api/extensions", dependencies=[Depends(require_permission(Module.EXTENSIONS, "create"))])
def create_extension(data: ExtensionData):
    """新增分機"""
    filepath = f"{EXT_DIR}/{data.id}.xml"
    if os.path.exists(filepath):
        raise HTTPException(status_code=409, detail=f"分機 {data.id} 已存在")
    write_extension_xml(data, filepath)
    esl.api('reloadxml')
    return {'ok': True, 'id': data.id}

@router.put("/api/extensions/{ext_id}", dependencies=[Depends(require_permission(Module.EXTENSIONS, "update"))])
def update_extension(ext_id: str, data: ExtensionData):
    """更新分機"""
    filepath = f"{EXT_DIR}/{ext_id}.xml"
    if not os.path.exists(filepath):
        raise HTTPException(status_code=404, detail=f"分機 {ext_id} 不存在")
    backup = filepath + ".bak." + datetime.now().strftime("%Y%m%d_%H%M%S")
    shutil.copy2(filepath, backup)
    write_extension_xml(data, filepath)
    esl.api('reloadxml')
    return {'ok': True, 'id': ext_id}

@router.delete("/api/extensions/{ext_id}", dependencies=[Depends(require_permission(Module.EXTENSIONS, "delete"))])
def delete_extension(ext_id: str, filename: str = Query(None)):
    """刪除分機，filename 參數處理 id≠檔名 的異常 XML"""
    if filename:
        safe = os.path.basename(filename)
        if not safe.endswith('.xml') or '/' in safe or '..' in safe:
            raise HTTPException(status_code=400, detail="非法 filename")
        filepath = f"{EXT_DIR}/{safe}"
    else:
        filepath = f"{EXT_DIR}/{ext_id}.xml"
    if not os.path.exists(filepath):
        raise HTTPException(status_code=404, detail=f"分機 {ext_id} 不存在")
    backup = filepath + ".bak." + datetime.now().strftime("%Y%m%d_%H%M%S")
    shutil.copy2(filepath, backup)
    os.remove(filepath)
    esl.api('reloadxml')
    return {'ok': True}



