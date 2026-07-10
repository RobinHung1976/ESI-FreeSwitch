"""
routers/dialplan_files.py — 原始 Dialplan XML 檔案通用讀寫 API（/api/dialplan*）。與 dialplan_routes.py / dialplan_system_extensions.py / dialplan_custom.py 三個結構化模組不同，這裡是給「檔案路徑」頁面 XML 編輯器與自定義範本模組共用的底層檔案存取端點，維持原路徑不動。
"""
import os
import glob
import shutil
from datetime import datetime
from fastapi import APIRouter, HTTPException, Body, Depends
from lxml import etree

from core.esl_client import esl
from core.auth import require_permission
from core.permissions import Module

router = APIRouter()


@router.get("/api/dialplan", dependencies=[Depends(require_permission(Module.DIALPLAN, "read"))])
def get_dialplan():
    """讀取 FreeSwitch dialplan XML 檔案清單與內容"""
    dialplan_dir = "/etc/freeswitch/dialplan"
    result = []
    try:
        xml_files = sorted(glob.glob(f"{dialplan_dir}/**/*.xml", recursive=True) +
                          glob.glob(f"{dialplan_dir}/*.xml"))
        for filepath in xml_files:
            filename = os.path.basename(filepath)
            relpath  = filepath.replace(dialplan_dir + "/", "")
            try:
                with open(filepath, "r", encoding="utf-8") as f:
                    content = f.read()
                # 從 XML 解析 context name
                import re
                contexts = re.findall(r'<context\s+name="([^"]+)"', content)
                extensions = re.findall(r'<extension\s+name="([^"]+)"', content)
                result.append({
                    "filename":   filename,
                    "path":       filepath,
                    "relpath":    relpath,
                    "size":       os.path.getsize(filepath),
                    "contexts":   contexts,
                    "extensions": extensions,
                    "content":    content,
                })
            except Exception as e:
                result.append({
                    "filename": filename,
                    "path":     filepath,
                    "error":    str(e),
                    "contexts": [], "extensions": [], "content": ""
                })
        return {"files": result, "total": len(result)}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

# Edit Dialplan XML file ------------------------------------------------
@router.get("/api/dialplan/file", dependencies=[Depends(require_permission(Module.DIALPLAN, "read"))])
def get_dialplan_file(path: str):
    """讀取指定 XML 檔案內容"""
    # 安全檢查：只允許讀取 freeswitch 設定目錄
    allowed_dirs = ["/etc/freeswitch/"]
    if not any(path.startswith(d) for d in allowed_dirs):
        raise HTTPException(status_code=403, detail="不允許存取此路徑")
    try:
        with open(path, "r", encoding="utf-8") as f:
            return {"path": path, "content": f.read()}
    except FileNotFoundError:
        raise HTTPException(status_code=404, detail="檔案不存在")

@router.post("/api/dialplan/file", dependencies=[Depends(require_permission(Module.DIALPLAN, "update"))])
def save_dialplan_file(path: str = Body(...), content: str = Body(...)):
    """儲存 XML 檔案並備份原檔，儲存後自動 reloadxml"""
    allowed_dirs = ["/etc/freeswitch/"]
    if not any(path.startswith(d) for d in allowed_dirs):
        raise HTTPException(status_code=403, detail="不允許存取此路徑")
    try:
        # XML 語法驗證
        try:
            etree.fromstring(content.encode('utf-8'))
        except Exception as xe:
            raise HTTPException(status_code=400, detail=f"XML 語法錯誤：{xe}")
        # 備份原檔（若存在）
        backup = None
        if os.path.exists(path):
            backup = path + ".bak." + datetime.now().strftime("%Y%m%d_%H%M%S")
            shutil.copy2(path, backup)
        # 寫入
        with open(path, "w", encoding="utf-8") as f:
            f.write(content)
        esl.api('reloadxml')
        return {"ok": True, "backup": backup}
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.post("/api/dialplan/create", dependencies=[Depends(require_permission(Module.DIALPLAN, "create"))])
def create_dialplan_file(
    filename: str = Body(...),
    context:  str = Body(default="default"),
    content:  str = Body(default=""),
):
    """新增自定義 Dialplan XML 檔案"""
    import re as _re
    # 檔名安全檢查
    if not _re.match(r'^[\w\-]+\.xml$', filename):
        raise HTTPException(status_code=400, detail="檔名只能含英數字、底線、連字號，副檔名須為 .xml")
    if context not in ('default', 'public'):
        raise HTTPException(status_code=400, detail="context 只能為 default 或 public")

    dp_dir  = f"/etc/freeswitch/dialplan/{context}"
    fpath   = os.path.join(dp_dir, filename)
    if os.path.exists(fpath):
        raise HTTPException(status_code=409, detail=f"檔案已存在：{fpath}")

    # 預設 XML 範本
    if not content:
        content = f"""<include>
  <extension name="{filename.replace('.xml','')}">
    <condition field="destination_number" expression="^XXXX$">
      <action application="answer"/>
      <action application="hangup"/>
    </condition>
  </extension>
</include>
"""
    try:
        etree.fromstring(content.encode('utf-8'))
    except Exception as xe:
        raise HTTPException(status_code=400, detail=f"XML 語法錯誤：{xe}")

    os.makedirs(dp_dir, exist_ok=True)
    with open(fpath, "w", encoding="utf-8") as f:
        f.write(content)
    esl.api('reloadxml')
    return {"ok": True, "path": fpath}


@router.delete("/api/dialplan/file", dependencies=[Depends(require_permission(Module.DIALPLAN, "delete"))])
def delete_dialplan_file(path: str = Body(..., embed=True)):
    """刪除自定義 Dialplan XML 檔案（備份後刪除）"""
    allowed_dirs = ["/etc/freeswitch/dialplan/"]
    if not any(path.startswith(d) for d in allowed_dirs):
        raise HTTPException(status_code=403, detail="不允許刪除此路徑")
    # 禁止刪除 Dashboard 管理的檔案
    fname = os.path.basename(path)
    if fname.startswith(('00_group_', '00_ivr_')):
        raise HTTPException(status_code=403, detail="請從群組/IVR 管理頁刪除此檔案")
    if not os.path.exists(path):
        raise HTTPException(status_code=404, detail="檔案不存在")
    ts     = datetime.now().strftime("%Y%m%d_%H%M%S")
    backup = path + f".bak.{ts}"
    shutil.copy2(path, backup)
    os.remove(path)
    esl.api('reloadxml')
    return {"ok": True, "backup": backup}
