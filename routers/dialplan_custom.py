"""
Dialplan 自定義管理（類型三：範本 + 既有 XML 編輯器）
================================================================
與類型一 / 類型二的分工：
  - 類型一（dialplan_routes.py）：00_route_*.xml，表單化外撥路由
  - 類型二（dialplan_system_extensions.py）：default.xml / public.xml，唯讀
  - 類型三（本檔）：其餘所有自定義 dialplan XML 檔案
      · 範本模式：選範本 → 填表單 → 依 schema 產生 XML（本檔負責）
      · 手動模式：既有的 raw textarea 編輯器，沿用 server.py 現有的
        GET/POST/DELETE /api/dialplan/file 與 POST /api/dialplan/create，
        本檔不重複實作，只在列表 API 裡把這些檔案一併列出。

新增範本只需要在 TEMPLATES 裡加一筆（fields + generator），
不需要更動任何路由或前端框架程式碼（前端依 fields schema 動態產生表單）。
"""

import os
import re
import json
import glob
from typing import Optional, Literal

from fastapi import APIRouter, HTTPException, Body, Depends
from pydantic import BaseModel, field_validator
from lxml import etree

from core.dialplan_common import make_backup, reload_and_verify, rollback_new_file, validate_xml
from core.auth import require_permission
from core.permissions import Module

router = APIRouter()

DIALPLAN_ROOT = "/etc/freeswitch/dialplan"
META_RE = re.compile(r"<!--\s*DASHBOARD_CUSTOM_META:\s*(\{.*?\})\s*-->", re.DOTALL)

# 與 routers/extensions.py 的 EXT_DIR 相同路徑，此處獨立宣告一份常數只是為了
# 避免跨 router import（本檔只需要唯讀掃描，不需要 extensions.py 的其他邏輯）
EXT_DIR = "/etc/freeswitch/directory/default"

# 由其他頁面管理的檔案前綴／檔名，類型三的列表要排除，避免重複管理入口
MANAGED_PREFIXES = ("00_route_", "00_group_", "00_ivr_")
MANAGED_FILENAMES = ("default.xml", "public.xml")


# ══════════════════════════════════════════════════════════════════════════
# 範本 Schema 定義
# ══════════════════════════════════════════════════════════════════════════

class TemplateField(BaseModel):
    key: str
    label: str
    type: Literal["text", "number", "select", "time", "dynamic_multiselect"]
    required: bool = True
    options: Optional[list[str]] = None
    placeholder: Optional[str] = None
    help: Optional[str] = None
    # dynamic_multiselect 專用：前端依此值決定要向哪個 API 抓即時選項清單，
    # 目前只有 "extensions" 一種來源，保留擴充空間（未來如 gateway/sound 清單）
    source: Optional[str] = None
    # 新增時自動帶入的實際值（不是灰字 placeholder），避免每次都要手動填常見值
    # 造成儲存時卡在必填驗證。與 placeholder 不同：這個值會真的寫進表單欄位。
    default: Optional[str] = None


def _xml_escape(s: str) -> str:
    return (str(s).replace("&", "&amp;").replace("<", "&lt;")
                   .replace(">", "&gt;").replace('"', "&quot;"))


_WDAY_MAP = {"mon-fri": "2-6", "mon-sat": "2-7", "all": "1-7"}
_TIME_RE = re.compile(r"^([01]\d|2[0-3]):([0-5]\d)$")


def _require(values: dict, key: str, label: str) -> str:
    v = str(values.get(key, "")).strip()
    if not v:
        raise ValueError(f"「{label}」為必填欄位")
    return v


def _gen_time_route(v: dict) -> str:
    """時段路由：上班時間轉某分機/群組，其餘時間轉語音信箱或其他號碼"""
    name = _require(v, "name", "規則名稱")
    number = _require(v, "number", "進線號碼")
    start_time = _require(v, "start_time", "上班開始")
    end_time = _require(v, "end_time", "上班結束")
    in_target = _require(v, "in_hours_target", "上班時間轉接目標")
    out_target = _require(v, "out_of_hours_target", "非上班時間轉接目標")
    days = str(v.get("days") or "mon-fri")

    if not re.match(r"^\d{2,6}$", number):
        raise ValueError("進線號碼只能是數字（2-6 碼）")
    if not _TIME_RE.match(start_time) or not _TIME_RE.match(end_time):
        raise ValueError("時間格式須為 HH:MM，例：09:00")
    if days not in _WDAY_MAP:
        raise ValueError("適用日參數不合法")
    if not re.match(r"^[\w\-]+$", in_target) or not re.match(r"^[\w\-]+$", out_target):
        raise ValueError("轉接目標只能是分機／IVR 號碼或 extension 名稱（英數字、底線、連字號）")

    ext_name = _xml_escape(name)
    start_hour = start_time.split(":")[0].lstrip("0") or "0"
    end_hour = end_time.split(":")[0].lstrip("0") or "0"

    return f"""<include>
  <extension name="{ext_name}">
    <condition field="destination_number" expression="^{_xml_escape(number)}$">
      <condition wday="{_WDAY_MAP[days]}" hour="{start_hour}-{end_hour}" break="on-false">
        <action application="transfer" data="{_xml_escape(in_target)} XML default"/>
      </condition>
      <action application="transfer" data="{_xml_escape(out_target)} XML default"/>
    </condition>
  </extension>
</include>
"""


def _gen_blacklist(v: dict) -> str:
    """黑名單：來電號碼命中即直接掛斷，不進入其他 dialplan"""
    name = _require(v, "name", "規則名稱")
    numbers_raw = _require(v, "numbers", "封鎖號碼")
    numbers = [n.strip() for n in numbers_raw.split(",") if n.strip()]
    if not numbers:
        raise ValueError("至少需要一組封鎖號碼")
    for n in numbers:
        if not re.match(r"^[\d+*]+$", n):
            raise ValueError(f"號碼「{n}」格式不合法，只能包含數字、+ 或 *")

    ext_name = _xml_escape(name)
    pattern = "|".join(re.escape(n) for n in numbers)
    return f"""<include>
  <extension name="{ext_name}">
    <condition field="caller_id_number" expression="^({pattern})$">
      <action application="log" data="WARNING Blocked blacklisted caller ${{caller_id_number}}"/>
      <action application="hangup" data="CALL_REJECTED"/>
    </condition>
  </extension>
</include>
"""


def _gen_internal_extension(v: dict) -> str:
    """
    內線互撥：讓勾選的分機可以在這個 context 內互相直撥。
    刻意不比照 default.xml 的 Local_Extension 寫死開放整段號碼區間
    （^(1[0-9]{3})$），而是只開放使用者明確勾選的分機清單，避免在自訂
    context（如 TC-ACSBC）意外開放不該讓這個來源撥打的分機。
    """
    name = _require(v, "name", "規則名稱")
    ext_raw = _require(v, "extensions", "允許撥打的分機")
    extensions = [e.strip() for e in ext_raw.split(",") if e.strip()]
    if not extensions:
        raise ValueError("至少需要勾選一支分機")
    for e in extensions:
        if not re.match(r"^\d{2,8}$", e):
            raise ValueError(f"分機號碼「{e}」格式不合法，只能是數字")

    timeout_raw = _require(v, "call_timeout", "通話逾時秒數")
    try:
        timeout = int(timeout_raw)
    except ValueError:
        raise ValueError("通話逾時秒數須為整數")
    if not (5 <= timeout <= 300):
        raise ValueError("通話逾時秒數須介於 5-300 之間")

    on_no_answer = str(v.get("on_no_answer") or "hangup")
    if on_no_answer not in ("hangup", "voicemail"):
        raise ValueError("「找不到人時」參數不合法")

    ext_name = _xml_escape(name)
    pattern = "|".join(re.escape(e) for e in extensions)

    voicemail_action = ""
    if on_no_answer == "voicemail":
        voicemail_action = """
      <action application="answer"/>
      <action application="sleep" data="1000"/>
      <action application="bridge" data="loopback/app=voicemail:default ${domain_name} ${dialed_extension}"/>"""

    return f"""<include>
  <extension name="{ext_name}">
    <condition field="destination_number" expression="^({pattern})$">
      <action application="export" data="dialed_extension=$1"/>
      <action application="set" data="call_timeout={timeout}"/>
      <action application="set" data="hangup_after_bridge=true"/>
      <action application="set" data="continue_on_fail=true"/>
      <action application="bridge" data="user/${{dialed_extension}}@${{domain_name}}"/>{voicemail_action}
    </condition>
  </extension>
</include>
"""


TEMPLATES = {
    "time_route": {
        "label": "時段路由（上班／非上班時間分流）",
        "description": "指定號碼在上班時段轉到某分機/群組，其餘時間轉到語音信箱或其他號碼。",
        "fields": [
            TemplateField(key="name", label="規則名稱", type="text",
                          placeholder="例：客服時段分流"),
            TemplateField(key="number", label="進線號碼", type="text",
                          placeholder="例：9500", help="使用者撥打或外線來電命中的號碼"),
            TemplateField(key="days", label="適用日", type="select",
                          options=["mon-fri", "mon-sat", "all"]),
            TemplateField(key="start_time", label="上班開始", type="time", placeholder="09:00"),
            TemplateField(key="end_time", label="上班結束", type="time", placeholder="18:00"),
            TemplateField(key="in_hours_target", label="上班時間轉接目標", type="text",
                          placeholder="例：1001 或群組/IVR 號碼"),
            TemplateField(key="out_of_hours_target", label="非上班時間轉接目標", type="text",
                          placeholder="例：9888（語音信箱入口）"),
        ],
        "generator": _gen_time_route,
    },
    "blacklist": {
        "label": "黑名單（封鎖來電）",
        "description": "來電號碼符合清單時直接掛斷，不會進入分機、群組或 IVR。",
        "fields": [
            TemplateField(key="name", label="規則名稱", type="text",
                          placeholder="例：騷擾電話封鎖"),
            TemplateField(key="numbers", label="封鎖號碼（逗號分隔）", type="text",
                          placeholder="0912345678,0287654321"),
        ],
        "generator": _gen_blacklist,
    },
    "internal_extension": {
        "label": "內線互撥（限定分機清單）",
        "description": "讓勾選的分機可以在這個 context 內互相直撥，找不到人時可選擇掛斷或轉語音信箱。",
        "fields": [
            TemplateField(key="name", label="規則名稱", type="text",
                          placeholder="例：TC-ACSBC 內線互撥"),
            TemplateField(key="extensions", label="允許撥打的分機", type="dynamic_multiselect",
                          source="extensions",
                          help="只有勾選的分機才能在這個 context 被撥打，未勾選的分機即使存在也撥不通"),
            TemplateField(key="call_timeout", label="通話逾時秒數", type="number",
                          default="30", placeholder="30", help="對方響鈴多久沒接算失敗（5-300 秒）"),
            TemplateField(key="on_no_answer", label="找不到人時", type="select",
                          options=["hangup", "voicemail"]),
        ],
        "generator": _gen_internal_extension,
    },
}


def _generate_xml(template_id: str, values: dict) -> str:
    tpl = TEMPLATES.get(template_id)
    if not tpl:
        raise HTTPException(status_code=404, detail=f"範本不存在：{template_id}")
    try:
        body = tpl["generator"](values)
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))
    meta = json.dumps({"template_id": template_id, "values": values}, ensure_ascii=False)
    return f"<!-- DASHBOARD_CUSTOM_META: {meta} -->\n{body}"


# ══════════════════════════════════════════════════════════════════════════
# Pydantic 請求模型
# ══════════════════════════════════════════════════════════════════════════

class TemplatePreviewRequest(BaseModel):
    template_id: str
    values: dict


class TemplateCreateRequest(BaseModel):
    template_id: str
    filename: str
    context: str = "default"
    values: dict

    @field_validator("filename")
    @classmethod
    def valid_filename(cls, v):
        if not re.match(r"^[\w\-]+\.xml$", v):
            raise ValueError("檔名只能含英數字、底線、連字號，副檔名須為 .xml")
        return v

    @field_validator("context")
    @classmethod
    def valid_context_format(cls, v):
        # 2026-08-11 修復：舊版寫死 Literal["default","public"]，導致範本模式
        # 完全無法寫入 default/public 以外的自訂 context（例如 TC-ACSBC），
        # 跟前端「Context 選單支援任意既有 context」的實際行為互相矛盾。
        # 這裡先只驗證格式，「是否真的存在」的檢查放在 handler 裡（見
        # create_from_template()），因為那邊才有 filesystem 存取時機。
        ctx = (v or "").strip()
        if not ctx or not re.match(r"^[\w\-]+$", ctx):
            raise ValueError("context 名稱格式不合法")
        return ctx


class TemplateUpdateRequest(BaseModel):
    path: str
    template_id: str
    values: dict


# ══════════════════════════════════════════════════════════════════════════
# 路徑安全檢查
# ══════════════════════════════════════════════════════════════════════════

def _assert_allowed_path(path: str) -> None:
    if not path.startswith(DIALPLAN_ROOT + "/"):
        raise HTTPException(status_code=403, detail="不允許存取此路徑")


def _assert_not_managed(fpath: str) -> None:
    fname = os.path.basename(fpath)
    if fname.startswith(MANAGED_PREFIXES) or fname in MANAGED_FILENAMES:
        raise HTTPException(
            status_code=403,
            detail="此檔案由其他管理頁面維護（路由規則／群組／IVR／系統內建），請至對應頁面操作",
        )


# ══════════════════════════════════════════════════════════════════════════
# API 端點
# ══════════════════════════════════════════════════════════════════════════

@router.get("/api/dialplan/custom/templates", dependencies=[Depends(require_permission(Module.DIALPLAN, "read"))])
def list_templates():
    return {
        "templates": [
            {
                "id": tid,
                "label": t["label"],
                "description": t.get("description", ""),
                "fields": [f.model_dump() for f in t["fields"]],
            }
            for tid, t in TEMPLATES.items()
        ]
    }


@router.get("/api/dialplan/custom/extension-options", dependencies=[Depends(require_permission(Module.DIALPLAN, "read"))])
def list_extension_options():
    """
    輕量分機清單，只給範本表單「勾選分機」用途：只回傳 id + 顯示名稱。

    刻意不重用 /api/extensions/list（Module.EXTENSIONS）：那支 API 會明碼回傳
    SIP 密碼／語音信箱密碼，單純為了畫面上勾選分機號碼卻把密碼一併下載到
    前端不合理；且權限矩陣是 19 模組各自獨立設計，操作 Dialplan 頁面的人
    不一定有（也不應該需要）Extensions 模組的讀取權限。這支端點掛在
    Module.DIALPLAN 底下，跟頁面本身同一個權限模組，不需要跨模組權限。
    """
    result = []
    for filepath in sorted(glob.glob(f"{EXT_DIR}/*.xml")):
        try:
            tree = etree.parse(filepath)
            user = tree.find('.//user')
            if user is None:
                continue
            ext_id = user.get('id', '').strip()
            if not ext_id or not ext_id.isdigit():
                continue
            variables = {v.get('name'): v.get('value') for v in tree.findall('.//variables/variable')}
            result.append({
                "id": ext_id,
                "caller_id_name": variables.get('effective_caller_id_name', '') or ext_id,
            })
        except Exception:
            continue
    return {"extensions": result}


@router.get("/api/dialplan/custom/files", dependencies=[Depends(require_permission(Module.DIALPLAN, "read"))])
def list_custom_files():
    """列出所有非其他頁面管理的自定義 dialplan 檔案。

    2026-08-11 修復：舊版寫死只掃 ("default", "public") 兩個 context，
    導致寫進其他自訂 context（如 TC-ACSBC）的檔案完全不會出現在這個列表——
    改成掃描 list_contexts() 回傳的所有真實存在 context。
    """
    from routers.dialplan_routes import list_contexts as _list_dialplan_contexts
    result = []
    for context in _list_dialplan_contexts():
        pattern = os.path.join(DIALPLAN_ROOT, context, "*.xml")
        for fpath in sorted(glob.glob(pattern)):
            fname = os.path.basename(fpath)
            if fname.startswith(MANAGED_PREFIXES) or fname in MANAGED_FILENAMES:
                continue
            try:
                with open(fpath, "r", encoding="utf-8") as f:
                    content = f.read()
            except Exception as e:
                result.append({
                    "filename": fname, "path": fpath, "context": context,
                    "error": str(e), "is_template": False,
                    "extensions": [], "destinations": [],
                })
                continue

            m = META_RE.search(content)
            is_template, template_id, template_label = False, None, None
            if m:
                try:
                    meta = json.loads(m.group(1))
                    template_id = meta.get("template_id")
                    if template_id in TEMPLATES:
                        is_template = True
                        template_label = TEMPLATES[template_id]["label"]
                except (json.JSONDecodeError, KeyError):
                    pass

            extensions = re.findall(r'<extension\s+name="([^"]+)"', content)
            destinations = re.findall(
                r'<condition\s+field="destination_number"\s+expression="([^"]*)"', content
            )

            result.append({
                "filename": fname,
                "path": fpath,
                "context": context,
                "size": os.path.getsize(fpath),
                "is_template": is_template,
                "template_id": template_id,
                "template_label": template_label,
                "extensions": extensions,
                "destinations": destinations,
            })
    return {"files": result, "total": len(result)}


@router.get("/api/dialplan/custom/file", dependencies=[Depends(require_permission(Module.DIALPLAN, "read"))])
def parse_custom_file(path: str):
    """讀檔並嘗試反解 META，讓範本建立的檔案可以回到表單編輯，
    非範本檔案則回傳 editable_as_template=False，前端據此改用手動 raw 編輯器。
    """
    _assert_allowed_path(path)
    _assert_not_managed(path)
    if not os.path.exists(path):
        raise HTTPException(status_code=404, detail="檔案不存在")

    with open(path, "r", encoding="utf-8") as f:
        content = f.read()

    m = META_RE.search(content)
    if not m:
        return {"editable_as_template": False, "content": content}
    try:
        meta = json.loads(m.group(1))
        template_id = meta.get("template_id")
        if template_id not in TEMPLATES:
            return {"editable_as_template": False, "content": content}
        return {
            "editable_as_template": True,
            "template_id": template_id,
            "values": meta.get("values", {}),
            "content": content,
        }
    except (json.JSONDecodeError, KeyError):
        return {"editable_as_template": False, "content": content}


@router.post("/api/dialplan/custom/preview", dependencies=[Depends(require_permission(Module.DIALPLAN, "read"))])
def preview_template(req: TemplatePreviewRequest):
    """不寫檔，只回傳產生的 XML 供前端「進階 XML 預覽」使用"""
    xml = _generate_xml(req.template_id, req.values)
    return {"xml": xml}


@router.post("/api/dialplan/custom/create", dependencies=[Depends(require_permission(Module.DIALPLAN, "create"))])
def create_from_template(req: TemplateCreateRequest):
    from routers.dialplan_routes import list_contexts as _list_dialplan_contexts
    if req.context not in _list_dialplan_contexts():
        raise HTTPException(
            status_code=400,
            detail=f"context「{req.context}」不存在或尚未被 FreeSwitch 正式辨識，"
                   f"請先到「自定義 Dialplan」頁面的 Context 選單建立",
        )

    dp_dir = os.path.join(DIALPLAN_ROOT, req.context)
    fpath = os.path.join(dp_dir, req.filename)

    if os.path.exists(fpath):
        raise HTTPException(status_code=409, detail=f"檔案已存在：{fpath}")
    _assert_not_managed(fpath)

    content = _generate_xml(req.template_id, req.values)
    validate_xml(content)

    os.makedirs(dp_dir, exist_ok=True)
    try:
        with open(fpath, "w", encoding="utf-8") as f:
            f.write(content)
    except OSError as e:
        raise HTTPException(status_code=500, detail=f"寫入檔案失敗：{e}")

    try:
        reload_and_verify(fpath, backup_path="")
    except HTTPException:
        rollback_new_file(fpath)
        raise

    return {"ok": True, "path": fpath}


@router.put("/api/dialplan/custom/file", dependencies=[Depends(require_permission(Module.DIALPLAN, "update"))])
def update_from_template(req: TemplateUpdateRequest):
    """更新一個原本就是由範本建立的檔案（重新產生 XML 並覆寫）"""
    _assert_allowed_path(req.path)
    _assert_not_managed(req.path)
    if not os.path.exists(req.path):
        raise HTTPException(status_code=404, detail="檔案不存在")

    content = _generate_xml(req.template_id, req.values)
    validate_xml(content)

    backup_path = make_backup(req.path)
    try:
        with open(req.path, "w", encoding="utf-8") as f:
            f.write(content)
    except OSError as e:
        raise HTTPException(status_code=500, detail=f"寫入檔案失敗：{e}")

    reload_and_verify(req.path, backup_path)
    return {"ok": True, "path": req.path, "backup": backup_path}
