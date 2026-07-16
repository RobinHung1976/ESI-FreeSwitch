"""
Dialplan 路由規則管理（類型一：外撥路由規則）
================================================
獨立於既有 /api/dialplan/* (原始 XML 編輯) 之外，提供表單化的外撥路由規則管理。

檔案格式：
  /etc/freeswitch/dialplan/<context>/00_route_<id>.xml
  比照 00_group_*.xml 的做法，設定資料以 JSON 註解內嵌在 XML 檔頭：
    <!-- DASHBOARD_ROUTE_META: {...} -->

設計重點：
  - pattern_type 限制在 prefix / exact / any / custom_regex 四種，
    確保可以用 build_regex() 還原出對應的 destination_number expression。
  - 路由衝突檢查與路由測試共用同一顆 build_regex() / match 邏輯，
    避免「衝突檢查說會衝突，但測試卻顯示不衝突」這種兩套邏輯各自飄走的情況。
  - 停用 (enabled=false) 的規則仍會寫入檔案，但 destination_number 的 condition
    會包進恆不成立的條件，等同停用且不需要每次啟用/停用都增刪檔案。
  - 2026-07-15：新增多 context 支援。規則實際寫入的資料夾由 context 欄位決定
    （/etc/freeswitch/dialplan/<context>/），列表/衝突檢查/legacy 掃描皆改為
    跨所有 context 資料夾進行。衝突檢查只在「同一 context」內視為真正衝突，
    跨 context 的號碼樣式重疊僅回傳為參考資訊（other_context_matches），不阻擋儲存。
"""

import os
import re
import json
import glob
import shutil
from datetime import datetime
from typing import List, Optional, Literal

from fastapi import APIRouter, HTTPException, Body, Depends
from pydantic import BaseModel, field_validator

# ESL 注入、reloadxml 驗證＋rollback、備份檔命名，都搬到 dialplan_common.py，
# 供類型二/三共用。init_esl 保留同名重新匯出，server.py 既有的
# `dialplan_routes.init_esl(esl)` 呼叫不用跟著改。
from core.dialplan_common import (
    init_esl, make_backup, reload_and_verify, rollback_new_file, force_reload,
)
from core.auth import require_permission
from core.permissions import Module

router = APIRouter()

DIALPLAN_ROOT = "/etc/freeswitch/dialplan"
ROUTE_DIR = f"{DIALPLAN_ROOT}/default"   # 保留給預設 context 參考用，實際路徑改由 _route_dir() 動態決定
ROUTE_META_RE = r"<!--\s*DASHBOARD_ROUTE_META:\s*(\{.*?\})\s*-->"
ROUTE_FILE_PREFIX = "00_route_"
DEFAULT_CONTEXT = "default"
CONTEXT_NAME_RE = r"^[A-Za-z0-9_\-]+$"

PATTERN_TYPES = ("prefix", "exact", "any", "custom_regex")


# ════════════════════════════════════════════════════════════════════════════
# Context 資料夾（多 context 支援）
# ════════════════════════════════════════════════════════════════════════════

def _route_dir(context: str) -> str:
    """依 context 決定路由規則檔案要寫入哪個 dialplan 子資料夾。"""
    ctx = (context or DEFAULT_CONTEXT).strip()
    if not re.match(CONTEXT_NAME_RE, ctx):
        raise ValueError(f"context 名稱格式錯誤：{ctx}")
    return os.path.join(DIALPLAN_ROOT, ctx)


def list_contexts() -> List[str]:
    """掃描 /etc/freeswitch/dialplan/ 底下實際存在的子資料夾，當作可選 context 清單。
    路由規則／自定義 Dialplan 兩個前端 Tab 共用這份清單。"""
    try:
        names = sorted(
            d for d in os.listdir(DIALPLAN_ROOT)
            if os.path.isdir(os.path.join(DIALPLAN_ROOT, d))
        )
    except FileNotFoundError:
        names = []
    if DEFAULT_CONTEXT not in names:
        names.insert(0, DEFAULT_CONTEXT)
    return names


def create_context_dir(context: str) -> str:
    """建立新的 context 資料夾（純 mkdir，不做任何 SIP Profile／轉接綁定）。
    只給「自定義 Dialplan」頁面呼叫；路由規則頁面只能選既有 context，不能建立新的。"""
    ctx = (context or "").strip()
    if not ctx or not re.match(CONTEXT_NAME_RE, ctx):
        raise ValueError("context 名稱僅能包含英數字、底線、連字號")
    path = os.path.join(DIALPLAN_ROOT, ctx)
    if os.path.isdir(path):
        raise ValueError(f"context「{ctx}」已存在")
    os.makedirs(path, exist_ok=False)
    return path


# 掃描自定義（未被 Dashboard 任何模組管理）dialplan 檔案時要排除的目錄/檔名
def _legacy_scan_dirs() -> List[str]:
    """回傳要掃描的舊有 dialplan 目錄：所有實際存在的 context 資料夾。"""
    return [os.path.join(DIALPLAN_ROOT, ctx) for ctx in list_contexts()]
# FreeSwitch 官方內建範例檔（不掃描，避免把整包 default.xml/public.xml 範例規則誤判成自定義路由）
LEGACY_SKIP_FILENAMES = {"default.xml", "public.xml"}
# 其他 Dashboard 模組已管理的檔名前綴，避免重複認領
LEGACY_SKIP_PREFIXES = ("00_group_", "00_ivr_", ROUTE_FILE_PREFIX)
# 已知非路由用途的 META 標記（出現代表此檔案由其他模組管理，略過）
LEGACY_OTHER_META_TAGS = ("DASHBOARD_GROUP_META", "DASHBOARD_IVR_META")


# ════════════════════════════════════════════════════════════════════════════
# 資料模型
# ════════════════════════════════════════════════════════════════════════════

class RouteRule(BaseModel):
    id: str = ""                                  # 編輯時帶入；新增留空，後端產生
    name: str
    pattern_type: Literal["prefix", "exact", "any", "custom_regex"]
    pattern_value: str = ""                        # prefix: "6,7"；exact: 完整號碼；custom_regex: 原始 regex
    gateway_name: str
    caller_id_override: str = ""
    toll_allow: str = ""
    enabled: bool = True
    priority: int = 100
    context: str = "default"

    @field_validator("name")
    @classmethod
    def _name_not_blank(cls, v):
        v = v.strip()
        if not v:
            raise ValueError("規則名稱不可為空")
        return v

    @field_validator("gateway_name")
    @classmethod
    def _gateway_not_blank(cls, v):
        v = v.strip()
        if not v:
            raise ValueError("請選擇目標 Gateway")
        return v

    @field_validator("priority")
    @classmethod
    def _priority_range(cls, v):
        if not (1 <= v <= 999):
            raise ValueError("優先順序須介於 1-999")
        return v

    @field_validator("pattern_value")
    @classmethod
    def _pattern_value_required(cls, v, info):
        pt = info.data.get("pattern_type")
        if pt in ("prefix", "exact", "custom_regex") and not v.strip():
            raise ValueError(f"pattern_type={pt} 時 pattern_value 不可為空")
        return v

    @field_validator("context")
    @classmethod
    def _context_format(cls, v):
        v = (v or DEFAULT_CONTEXT).strip()
        if not re.match(CONTEXT_NAME_RE, v):
            raise ValueError("context 名稱僅能包含英數字、底線、連字號")
        return v


# ════════════════════════════════════════════════════════════════════════════
# Regex 建構（衝突檢查 / 路由測試共用核心）
# ════════════════════════════════════════════════════════════════════════════

def build_regex(pattern_type: str, pattern_value: str) -> str:
    """依 pattern_type 組出對應的 destination_number expression。"""
    if pattern_type == "any":
        return r"^(.*)$"

    if pattern_type == "exact":
        num = pattern_value.strip()
        if not num.isdigit():
            raise ValueError("完全符合的號碼只能是數字")
        return f"^{re.escape(num)}$"

    if pattern_type == "prefix":
        prefixes = [p.strip() for p in pattern_value.split(",") if p.strip()]
        if not prefixes:
            raise ValueError("請至少輸入一個開頭數字")
        for p in prefixes:
            if not p.isdigit():
                raise ValueError(f"開頭樣式須為數字：{p}")
        if all(len(p) == 1 for p in prefixes):
            charset = "".join(prefixes)
            return f"^[{charset}](\\d*)$"
        # 長度不一致的前綴，改用 alternation
        escaped = [re.escape(p) for p in prefixes]
        return f"^({'|'.join(escaped)})(\\d*)$"

    if pattern_type == "custom_regex":
        try:
            re.compile(pattern_value)
        except re.error as e:
            raise ValueError(f"正規式語法錯誤：{e}")
        return pattern_value

    raise ValueError(f"未知的 pattern_type: {pattern_type}")


def generate_sample_numbers(pattern_type: str, pattern_value: str) -> List[str]:
    """為一條規則產生用來測試重疊的代表性號碼樣本（不含 custom_regex，無法窮舉）。"""
    if pattern_type == "any":
        return ["00000000", "99999999", "12345678"]

    if pattern_type == "exact":
        return [pattern_value.strip()]

    if pattern_type == "prefix":
        prefixes = [p.strip() for p in pattern_value.split(",") if p.strip()]
        samples = []
        for p in prefixes:
            samples += [p + "0000", p + "9999", p + "1"]
        return samples

    # custom_regex 無法窮舉樣本，回傳空陣列；衝突檢查時改用對方的樣本反向測試這顆 regex
    return []


def _compile_safe(pattern: str):
    try:
        return re.compile(pattern)
    except re.error:
        return None


def find_conflicts(pattern_type: str, pattern_value: str,
                    existing_routes: List[dict], context: str = None,
                    self_id: str = "") -> dict:
    """回傳 {'same_context': [...], 'other_context': [...]}。

    context=None 時視為不分組（全部歸入 same_context，等同舊行為，供未傳 context
    的呼叫端相容）；傳入 context 時，只有 context 相同的重疊才算真正衝突，
    不同 context 的重疊只回傳為參考資訊，不阻擋儲存。
    """
    new_regex_str = build_regex(pattern_type, pattern_value)
    new_re = _compile_safe(new_regex_str)
    if new_re is None:
        raise ValueError("正規式編譯失敗，請檢查語法")

    new_samples = generate_sample_numbers(pattern_type, pattern_value)
    same_context, other_context = [], []

    for route in existing_routes:
        if self_id and route.get("id") == self_id:
            continue
        try:
            exist_regex_str = build_regex(route["pattern_type"], route["pattern_value"])
        except ValueError:
            continue
        exist_re = _compile_safe(exist_regex_str)
        if exist_re is None:
            continue
        exist_samples = generate_sample_numbers(route["pattern_type"], route["pattern_value"])

        hit = any(exist_re.match(s) for s in new_samples) or \
              any(new_re.match(s) for s in exist_samples)
        # 特例：雙方都是 custom_regex 時，兩邊樣本都是空陣列，上面的取樣比對永遠測不出重疊
        # （custom_regex 無法窮舉樣本）。至少攔截「規則字串完全相同」這種最常見的重複情形；
        # 語意相同但字串不同的 regex（例如 ^6\d{3}$ 與 ^(6\d{3})$）仍無法偵測，
        # 屬取樣比對法的已知限制，需搭配路由測試工具人工確認。
        if not hit and pattern_type == "custom_regex" and route.get("pattern_type") == "custom_regex":
            if pattern_value.strip() == (route.get("pattern_value") or "").strip():
                hit = True
        if not hit:
            continue

        entry = {
            "id": route.get("id"),
            "name": route.get("name"),
            "pattern_type": route.get("pattern_type"),
            "pattern_value": route.get("pattern_value"),
            "priority": route.get("priority"),
            "enabled": route.get("enabled", True),
            "context": route.get("context", DEFAULT_CONTEXT),
        }
        if context is None or route.get("context", DEFAULT_CONTEXT) == context:
            same_context.append(entry)
        else:
            other_context.append(entry)

    return {"same_context": same_context, "other_context": other_context}


# ════════════════════════════════════════════════════════════════════════════
# XML 讀寫
# ════════════════════════════════════════════════════════════════════════════

def _route_meta(data: RouteRule) -> dict:
    return {
        "id": data.id, "name": data.name,
        "pattern_type": data.pattern_type, "pattern_value": data.pattern_value,
        "gateway_name": data.gateway_name,
        "caller_id_override": data.caller_id_override,
        "toll_allow": data.toll_allow,
        "enabled": data.enabled, "priority": data.priority,
        "context": data.context,
    }


def _slugify(name: str) -> str:
    """從規則名稱產生安全的檔名片段（僅留英數字，其餘以底線替代）。"""
    slug = re.sub(r"[^\w]+", "_", name.strip(), flags=re.UNICODE).strip("_")
    return slug or "rule"


def write_route_xml(data: RouteRule, filepath: str):
    try:
        regex_expr = build_regex(data.pattern_type, data.pattern_value)
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))

    actions = []
    if data.toll_allow:
        actions.append(f'      <action application="set" data="toll_allow={data.toll_allow}"/>')
    if data.caller_id_override:
        actions.append(f'      <action application="set" data="effective_caller_id_number={data.caller_id_override}"/>')
    else:
        actions.append('      <action application="set" data="effective_caller_id_number=${outbound_caller_id_number}"/>')
    actions.append('      <action application="set" data="effective_caller_id_name=${effective_caller_id_name}"/>')

    # 取得 match group：prefix 用 $1（去掉開頭數字後的剩餘部分），exact/any 用整個 $0(=destination_number)
    if data.pattern_type == "prefix":
        bridge_target = f"sofia/gateway/{data.gateway_name}/$1"
    elif data.pattern_type == "custom_regex":
        # custom_regex 假設使用者自行使用 $1 等 capture group；若無則退回完整號碼
        bridge_target = f"sofia/gateway/{data.gateway_name}/$1" if "(" in data.pattern_value else f"sofia/gateway/{data.gateway_name}/${{destination_number}}"
    else:
        bridge_target = f"sofia/gateway/{data.gateway_name}/${{destination_number}}"

    actions.append(f'      <action application="bridge" data="{bridge_target}"/>')
    actions_xml = "\n".join(actions)

    # 停用規則：condition 包一個恆不成立的額外比對，保留檔案但不會被觸發
    condition_expr = regex_expr if data.enabled else f"(?!){regex_expr}"

    meta_json = json.dumps(_route_meta(data), ensure_ascii=False)
    content = f"""<!-- DASHBOARD_ROUTE_META: {meta_json} -->
<include>
  <extension name="route_{_slugify(data.name)}">
    <condition field="destination_number" expression="{condition_expr}">
{actions_xml}
    </condition>
  </extension>
</include>
"""
    with open(filepath, "w", encoding="utf-8") as f:
        f.write(content)


def _read_route_meta(filepath: str) -> Optional[dict]:
    with open(filepath, "r", encoding="utf-8") as f:
        content = f.read()
    m = re.search(ROUTE_META_RE, content, re.DOTALL)
    if not m:
        return None
    meta = json.loads(m.group(1))
    meta["path"] = filepath
    meta["filename"] = os.path.basename(filepath)
    meta["legacy"] = False
    return meta


# ════════════════════════════════════════════════════════════════════════════
# 舊有手寫 dialplan 檔案的反解析（例如 DP_AC220.xml 這類沒有 META 標記的檔案）
# ════════════════════════════════════════════════════════════════════════════

GATEWAY_SCAN_DIR = "/etc/freeswitch/sip_profiles/external"


def _gateway_lookup() -> dict:
    """回傳 {name: gw_dict} 與 {proxy: gw_dict} 兩種對照表，供反解析 bridge target 用。
    proxy 對照表是為了處理舊檔案直接寫死 IP（如 sofia/gateway/192.168.100.220/$1）
    而非寫 gateway 名稱的情況。"""
    by_name, by_proxy = {}, {}
    try:
        for filepath in glob.glob(f"{GATEWAY_SCAN_DIR}/*.xml"):
            try:
                from lxml import etree
                tree = etree.parse(filepath)
                gw = tree.find(".//gateway")
                if gw is None:
                    continue
                name = gw.get("name", "")
                params = {p.get("name"): p.get("value") for p in tree.findall(".//param")}
                proxy = params.get("proxy", "")
                entry = {"name": name, "proxy": proxy}
                if name:
                    by_name[name] = entry
                if proxy:
                    by_proxy[proxy] = entry
            except Exception:
                continue
    except Exception:
        pass
    return {"by_name": by_name, "by_proxy": by_proxy}


def _classify_pattern(expression: str) -> tuple:
    """嘗試把一段 regex expression 歸類成 pattern_type/pattern_value。
    無法可靠歸類時一律退回 custom_regex，保留原始字串（不會弄丟資訊）。"""
    expr = expression.strip()

    if expr in (r"^(.*)$", r"^(.*)", ".*", r"^\d*$"):
        return "any", ""

    # 形如 ^[67](\d*)$ 或 ^[6,7](\d*)$（部分舊寫法字元類別內含逗號，視為 OR 而非字面逗號）
    m = re.match(r"^\^\[([0-9,]+)\]\(\\d\*\)\$$", expr)
    if m:
        digits = [c for c in m.group(1) if c.isdigit()]
        if digits:
            return "prefix", ",".join(digits)

    # 形如 ^(6|7)(\d*)$
    m = re.match(r"^\^\(([0-9|]+)\)\(\\d\*\)\$$", expr)
    if m:
        digits = [p for p in m.group(1).split("|") if p.isdigit()]
        if digits:
            return "prefix", ",".join(digits)

    # 完全符合純數字：^1234$
    m = re.match(r"^\^(\d+)\$$", expr)
    if m:
        return "exact", m.group(1)

    return "custom_regex", expr


def _extract_gateway_target(bridge_data: str, gw_lookup: dict) -> Optional[str]:
    """從 bridge action 的 data 屬性還原出 gateway 名稱。
    支援 sofia/gateway/<name>/... 與 sofia/gateway/<ip>/... 兩種寫法。"""
    m = re.search(r"sofia/gateway/([^/\s]+)/", bridge_data)
    if not m:
        return None
    target = m.group(1)
    if target in gw_lookup["by_name"]:
        return target
    if target in gw_lookup["by_proxy"]:
        return gw_lookup["by_proxy"][target]["name"]
    # 找不到對應的 gateway 設定，仍回傳原始值（IP 或名稱），讓使用者自行確認/修正
    return target


def _parse_legacy_route_file(filepath: str, gw_lookup: dict) -> Optional[dict]:
    """嘗試把一個未被任何 Dashboard 模組管理的 dialplan 檔案解析成路由規則 dict。
    只處理「單一 extension、含 destination_number condition、含 bridge action 到 sofia/gateway」
    這種典型外撥路由結構；解析不出來就回傳 None（代表不在這次的處理範圍內，
    會留給類型三的自定義 dialplan 編輯器處理）。
    """
    try:
        from lxml import etree
        with open(filepath, "r", encoding="utf-8") as f:
            content = f.read()
        tree = etree.fromstring(content.encode("utf-8"))
    except Exception:
        return None

    extensions = tree.findall(".//extension")
    if len(extensions) != 1:
        return None  # 多個 extension 的檔案結構較複雜，不嘗試自動辨識，交由自定義 dialplan 編輯器處理
    ext = extensions[0]
    ext_name = ext.get("name", os.path.splitext(os.path.basename(filepath))[0])

    conditions = ext.findall("condition")
    dest_condition = None
    toll_allow_value = ""
    for cond in conditions:
        field = (cond.get("field") or "").strip()
        if field == "destination_number":
            dest_condition = cond
        elif "toll_allow" in field:
            toll_allow_value = cond.get("expression", "")

    if dest_condition is None:
        return None  # 沒有針對 destination_number 的條件，不是外撥路由規則的典型結構

    expression = dest_condition.get("expression", "")
    actions = dest_condition.findall("action")
    bridge_action = next((a for a in actions if a.get("application") == "bridge"), None)
    if bridge_action is None:
        return None  # 沒有 bridge 動作，可能是別種用途的 extension（轉接分機、IVR 等），不歸類為路由規則

    bridge_data = bridge_action.get("data", "")
    gateway_name = _extract_gateway_target(bridge_data, gw_lookup)
    if not gateway_name:
        return None

    caller_id_override = ""
    for a in actions:
        if a.get("application") == "set" and (a.get("data") or "").startswith("effective_caller_id_number="):
            val = a.get("data").split("=", 1)[1]
            if val and "${outbound_caller_id_number}" not in val and "$" not in val:
                caller_id_override = val

    pattern_type, pattern_value = _classify_pattern(expression)

    return {
        "id": None,                       # 尚未升級，沒有正式 id
        "name": ext_name,
        "pattern_type": pattern_type,
        "pattern_value": pattern_value,
        "gateway_name": gateway_name,
        "caller_id_override": caller_id_override,
        "toll_allow": toll_allow_value,
        "enabled": True,
        "priority": 100,                  # 舊檔案無優先序資訊，給預設值；升級時可調整
        "context": os.path.basename(os.path.dirname(filepath)) or DEFAULT_CONTEXT,
        "path": filepath,
        "filename": os.path.basename(filepath),
        "legacy": True,                   # 標記為「尚未升級」，前端據此顯示升級提示/限制編輯方式
        "legacy_raw_expression": expression,
        "legacy_raw_bridge": bridge_data,
    }


def _scan_legacy_routes() -> List[dict]:
    """掃描未被任何 Dashboard 模組管理的 dialplan 檔案，嘗試辨識出外撥路由規則。"""
    gw_lookup = _gateway_lookup()
    result = []
    seen = set()
    for d in _legacy_scan_dirs():
        if not os.path.isdir(d):
            continue
        for filepath in sorted(glob.glob(f"{d}/*.xml")):
            fname = os.path.basename(filepath)
            if filepath in seen:
                continue
            seen.add(filepath)
            if fname in LEGACY_SKIP_FILENAMES:
                continue
            if fname.startswith(LEGACY_SKIP_PREFIXES):
                continue
            try:
                with open(filepath, "r", encoding="utf-8") as f:
                    content = f.read()
            except Exception:
                continue
            if any(tag in content for tag in LEGACY_OTHER_META_TAGS) or "DASHBOARD_ROUTE_META" in content:
                continue  # 已被其他模組管理或已升級過，略過
            parsed = _parse_legacy_route_file(filepath, gw_lookup)
            if parsed:
                # 用檔案路徑當穩定 id（尚未升級前不能用一般 route id，避免跟正式規則混淆）
                parsed["id"] = "legacy:" + fname
                result.append(parsed)
    return result


def _load_all_routes(include_legacy: bool = True) -> List[dict]:
    """讀取所有路由規則，依 priority 由小到大排序（數字越小越優先）。
    跨所有 context 資料夾掃描；include_legacy=True 時會一併納入尚未升級的舊有手寫
    dialplan 檔案（如 DP_AC220.xml）。"""
    result = []
    for ctx in list_contexts():
        pattern = os.path.join(DIALPLAN_ROOT, ctx, f"{ROUTE_FILE_PREFIX}*.xml")
        for filepath in sorted(glob.glob(pattern)):
            try:
                meta = _read_route_meta(filepath)
                if meta:
                    result.append(meta)
            except Exception:
                pass

    if include_legacy:
        try:
            result.extend(_scan_legacy_routes())
        except Exception:
            pass  # 舊檔案解析失敗不應影響正規規則的列表，安靜略過

    result.sort(key=lambda r: (r.get("priority", 100), r.get("id") or ""))
    return result


def _route_filepath(route_id: str, context: str = None) -> str:
    """依 route_id 產生檔案路徑。
    - 提供 context：直接組出目標路徑（新增規則／搬移到新 context 時使用）
    - 不提供 context：跨所有 context 資料夾掃描既有檔案（更新/刪除/查詢/toggle 用），
      找不到就回傳預設 context 下的路徑，讓呼叫端用 os.path.exists 判斷後回 404。
    """
    if context is not None:
        return os.path.join(_route_dir(context), f"{ROUTE_FILE_PREFIX}{route_id}.xml")
    for ctx in list_contexts():
        candidate = os.path.join(DIALPLAN_ROOT, ctx, f"{ROUTE_FILE_PREFIX}{route_id}.xml")
        if os.path.exists(candidate):
            return candidate
    return os.path.join(_route_dir(DEFAULT_CONTEXT), f"{ROUTE_FILE_PREFIX}{route_id}.xml")


def _gen_route_id() -> str:
    """產生一個簡短且不衝突的 route id（時間戳基底，避免額外資料庫）。
    跨所有 context 資料夾檢查是否已存在同名檔案。"""
    ts = datetime.now().strftime("%y%m%d%H%M%S")
    candidate = f"r{ts}"
    n = 0
    while os.path.exists(_route_filepath(candidate)):
        n += 1
        candidate = f"r{ts}{n}"
    return candidate


# ════════════════════════════════════════════════════════════════════════════
# API 端點
# ════════════════════════════════════════════════════════════════════════════

@router.get("/api/dialplan/contexts", dependencies=[Depends(require_permission(Module.DIALPLAN, "read"))])
def get_contexts():
    """回傳目前 /etc/freeswitch/dialplan/ 底下實際存在的 context 清單，
    供路由規則／自定義 Dialplan 兩個前端 Tab 共用。"""
    return {"contexts": list_contexts()}


@router.post("/api/dialplan/contexts", dependencies=[Depends(require_permission(Module.DIALPLAN, "create"))])
def create_context(context: str = Body(..., embed=True)):
    """建立新的 context 資料夾（純 mkdir）。只給「自定義 Dialplan」頁面呼叫，
    路由規則頁面只能從既有清單選擇，不提供建立入口。"""
    try:
        path = create_context_dir(context)
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))
    return {
        "ok": True,
        "context": context.strip(),
        "path": path,
        "warning": "已建立資料夾，但尚未與任何來源綁定。請自行到 SIP Profile 或其他 dialplan 設定"
                   "中，讓某個來源實際指向這個 context 名稱，通話才會真正進入此 context。",
    }


@router.get("/api/dialplan/routes", dependencies=[Depends(require_permission(Module.DIALPLAN, "read"))])
def list_routes():
    """列出所有外撥路由規則（依優先順序排序，跨所有 context）。"""
    routes = _load_all_routes()
    return {"routes": routes, "total": len(routes)}


@router.get("/api/dialplan/routes/{route_id}", dependencies=[Depends(require_permission(Module.DIALPLAN, "read"))])
def get_route(route_id: str):
    if route_id.startswith("legacy:"):
        for legacy in _scan_legacy_routes():
            if legacy["id"] == route_id:
                return legacy
        raise HTTPException(status_code=404, detail=f"舊有 dialplan 檔案 {route_id} 不存在或已被升級/移除")

    filepath = _route_filepath(route_id)
    if not os.path.exists(filepath):
        raise HTTPException(status_code=404, detail=f"路由規則 {route_id} 不存在")
    meta = _read_route_meta(filepath)
    if not meta:
        raise HTTPException(status_code=500, detail="無法解析此規則的設定內容")
    return meta


@router.post("/api/dialplan/routes/check-conflict", dependencies=[Depends(require_permission(Module.DIALPLAN, "read"))])
def check_conflict(
    pattern_type: str = Body(...),
    pattern_value: str = Body(default=""),
    context: str = Body(default=DEFAULT_CONTEXT),
    self_id: str = Body(default=""),
):
    """檢查新／編輯中的 pattern 是否與既有路由規則重疊。
    只有同一 context 內的重疊才會回傳在 conflicts（會阻擋儲存）；
    跨 context 的重疊回傳在 other_context_matches，僅供參考，不阻擋。"""
    try:
        build_regex(pattern_type, pattern_value)
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))

    existing = _load_all_routes()
    try:
        result = find_conflicts(pattern_type, pattern_value, existing, context=context, self_id=self_id)
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))

    return {
        "has_conflict": len(result["same_context"]) > 0,
        "conflicts": result["same_context"],
        "other_context_matches": result["other_context"],
        "note": "自訂正規式採取樣比對，僅能偵測規則字串完全相同的重複；若是語意相同但寫法不同的正規式"
                "（例如 ^6\\d{3}$ 與 ^(6\\d{3})$）無法自動偵測，請務必搭配下方路由測試工具手動驗證。"
                if pattern_type == "custom_regex" else None,
    }


@router.post("/api/dialplan/routes/test-number", dependencies=[Depends(require_permission(Module.DIALPLAN, "read"))])
def test_route_number(number: str = Body(..., embed=True)):
    """模擬撥打此號碼，依優先順序找出第一個命中的路由規則，並回傳完整比對過程。"""
    num = number.strip()
    if not num:
        raise HTTPException(status_code=400, detail="請輸入測試號碼")

    routes = _load_all_routes()
    matched = None
    checked = []

    for route in routes:
        pattern_type = route.get("pattern_type")
        pattern_value = route.get("pattern_value", "")
        enabled = route.get("enabled", True)
        try:
            regex_str = build_regex(pattern_type, pattern_value)
        except ValueError:
            checked.append({
                "id": route.get("id"), "name": route.get("name"),
                "pattern": pattern_value, "matched": False,
                "enabled": enabled, "priority": route.get("priority"),
                "error": "規則正規式錯誤",
            })
            continue

        is_match = False
        if enabled:
            r = _compile_safe(regex_str)
            is_match = bool(r and r.match(num))

        checked.append({
            "id": route.get("id"), "name": route.get("name"),
            "pattern": regex_str, "matched": is_match,
            "enabled": enabled, "priority": route.get("priority"),
            "gateway_name": route.get("gateway_name"),
        })

        if is_match and matched is None:
            matched = {
                "id": route.get("id"), "name": route.get("name"),
                "gateway_name": route.get("gateway_name"),
                "priority": route.get("priority"),
                "caller_id_override": route.get("caller_id_override") or None,
            }

    return {
        "number": num,
        "matched_route": matched,
        "all_checked": checked,
    }


@router.post("/api/dialplan/routes", dependencies=[Depends(require_permission(Module.DIALPLAN, "create"))])
def create_route(data: RouteRule):
    """新增外撥路由規則（含正規式驗證 + 與既有規則衝突檢查；依 context 寫入對應資料夾）。"""
    try:
        build_regex(data.pattern_type, data.pattern_value)
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))

    if data.context not in list_contexts():
        raise HTTPException(status_code=400, detail=f"context「{data.context}」不存在，請先到「自定義 Dialplan」頁面建立")

    existing = _load_all_routes()
    try:
        result = find_conflicts(data.pattern_type, data.pattern_value, existing, context=data.context)
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))
    conflicts = result["same_context"]
    if conflicts:
        names = "、".join(f"「{c['name']}」" for c in conflicts)
        raise HTTPException(
            status_code=409,
            detail=f"此號碼樣式與同一 context（{data.context}）既有路由規則重疊：{names}。請調整號碼樣式或使用路由測試工具確認，"
                   f"若仍要新增，請先停用或調整衝突規則。",
        )

    data.id = _gen_route_id()
    try:
        filepath = _route_filepath(data.id, data.context)
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))
    os.makedirs(os.path.dirname(filepath), exist_ok=True)
    write_route_xml(data, filepath)
    # 新增沒有前一版備份可還原，rollback 就是刪除剛才寫入的新檔（rollback_new_file 處理）
    try:
        reload_and_verify(filepath, backup_path="")
    except HTTPException:
        rollback_new_file(filepath)
        raise
    return {"ok": True, "id": data.id}


@router.put("/api/dialplan/routes/{route_id}", dependencies=[Depends(require_permission(Module.DIALPLAN, "update"))])
def update_route(route_id: str, data: RouteRule):
    """更新外撥路由規則（自動排除自身做衝突檢查；覆寫前備份）。
    若 context 有變更，會把檔案從舊 context 資料夾搬到新的資料夾。"""
    if route_id.startswith("legacy:"):
        raise HTTPException(
            status_code=400,
            detail="此規則尚未升級成 Dashboard 格式，請使用「升級並儲存」功能（POST .../legacy/upgrade）。",
        )
    old_filepath = _route_filepath(route_id)
    if not os.path.exists(old_filepath):
        raise HTTPException(status_code=404, detail=f"路由規則 {route_id} 不存在")

    try:
        build_regex(data.pattern_type, data.pattern_value)
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))

    if data.context not in list_contexts():
        raise HTTPException(status_code=400, detail=f"context「{data.context}」不存在，請先到「自定義 Dialplan」頁面建立")

    existing = _load_all_routes()
    try:
        result = find_conflicts(data.pattern_type, data.pattern_value, existing, context=data.context, self_id=route_id)
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))
    conflicts = result["same_context"]
    if conflicts:
        names = "、".join(f"「{c['name']}」" for c in conflicts)
        raise HTTPException(
            status_code=409,
            detail=f"此號碼樣式與同一 context（{data.context}）既有路由規則重疊：{names}。請調整號碼樣式或先停用衝突規則。",
        )

    data.id = route_id
    try:
        new_filepath = _route_filepath(route_id, data.context)
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))

    if new_filepath == old_filepath:
        # context 未變更：原地覆寫，行為與升級多 context 支援前完全一致
        backup = make_backup(old_filepath)
        write_route_xml(data, old_filepath)
        reload_and_verify(old_filepath, backup)
        return {"ok": True, "id": route_id, "backup": backup}

    # context 有變更：檔案要搬到新的 context 資料夾。
    # 先在新位置寫入並驗證 reload 成功，再刪除舊檔案，避免中途失敗兩邊都壞掉。
    os.makedirs(os.path.dirname(new_filepath), exist_ok=True)
    write_route_xml(data, new_filepath)
    try:
        reload_and_verify(new_filepath, backup_path="")
    except HTTPException:
        rollback_new_file(new_filepath)
        raise

    old_backup = make_backup(old_filepath, suffix="bak.moved")
    os.remove(old_filepath)
    force_reload()
    return {"ok": True, "id": route_id, "backup": old_backup, "moved_to_context": data.context}


@router.post("/api/dialplan/routes/legacy/upgrade", dependencies=[Depends(require_permission(Module.DIALPLAN, "update"))])
def upgrade_legacy_route(legacy_id: str = Body(...), data: RouteRule = Body(...)):
    """將一個尚未升級的舊有手寫 dialplan 檔案（如 DP_AC220.xml）升級成 Dashboard 標準格式。

    流程：
      1. 驗證新 pattern 合法且不與「其他」既有規則衝突（排除自己這個 legacy 檔案）
      2. 備份原始舊檔案（保留在原處，副檔名加 .bak.upgraded.<timestamp>，不刪除，方便回溯比對）
      3. 寫入新的 00_route_<id>.xml（依 context 寫進對應資料夾，正式納入 Dashboard 管理格式 + META）
      4. 移除原始舊檔案（已備份），reloadxml
    """
    if not legacy_id.startswith("legacy:"):
        raise HTTPException(status_code=400, detail="legacy_id 格式錯誤，應為 legacy:<filename>")

    legacy_filename = legacy_id.split(":", 1)[1]
    legacy_filepath = None
    for d in _legacy_scan_dirs():
        candidate = os.path.join(d, legacy_filename)
        if os.path.exists(candidate):
            legacy_filepath = candidate
            break
    if legacy_filepath is None:
        raise HTTPException(status_code=404, detail=f"找不到舊有檔案 {legacy_filename}，可能已被升級或移除")

    try:
        build_regex(data.pattern_type, data.pattern_value)
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))

    if data.context not in list_contexts():
        raise HTTPException(status_code=400, detail=f"context「{data.context}」不存在，請先到「自定義 Dialplan」頁面建立")

    # 衝突檢查時排除自己這個 legacy 檔案（用 legacy_id 當 self_id）
    existing = _load_all_routes()
    try:
        result = find_conflicts(data.pattern_type, data.pattern_value, existing, context=data.context, self_id=legacy_id)
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))
    conflicts = result["same_context"]
    if conflicts:
        names = "、".join(f"「{c['name']}」" for c in conflicts)
        raise HTTPException(
            status_code=409,
            detail=f"此號碼樣式與同一 context（{data.context}）既有路由規則重疊：{names}。請調整號碼樣式或先停用衝突規則後再升級。",
        )

    # 備份原始舊檔案（保留不刪，標註為已升級，方便日後對照原始寫法）
    backup = make_backup(legacy_filepath, suffix="bak.upgraded")

    data.id = _gen_route_id()
    try:
        new_filepath = _route_filepath(data.id, data.context)
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))
    os.makedirs(os.path.dirname(new_filepath), exist_ok=True)
    write_route_xml(data, new_filepath)

    # 移除原始舊檔案（已備份，避免兩條規則同時存在造成 dialplan 重複比對）
    os.remove(legacy_filepath)

    try:
        reload_and_verify(new_filepath, backup)
    except HTTPException:
        # reload 失敗：還原舊檔案、刪除新檔案，保持升級前狀態
        try:
            shutil.copy2(backup, legacy_filepath)
            os.remove(new_filepath)
            force_reload()
        except Exception:
            pass
        raise

    return {
        "ok": True,
        "id": data.id,
        "upgraded_from": legacy_filename,
        "backup": backup,
        "warning": "升級後的規則格式與原始手寫 XML 可能有些微差異（例如條件比對順序、未對應到表單欄位的客製動作），"
                   "請務必重新測試一次撥號行為，確認與升級前一致。",
    }


@router.delete("/api/dialplan/routes/{route_id}", dependencies=[Depends(require_permission(Module.DIALPLAN, "delete"))])
def delete_route(route_id: str):
    """刪除外撥路由規則（備份後刪除）。"""
    if route_id.startswith("legacy:"):
        raise HTTPException(
            status_code=400,
            detail="尚未升級的舊有檔案請直接到伺服器上刪除原始檔案，或先升級後再用此功能刪除。",
        )
    filepath = _route_filepath(route_id)
    if not os.path.exists(filepath):
        raise HTTPException(status_code=404, detail=f"路由規則 {route_id} 不存在")
    backup = make_backup(filepath)
    os.remove(filepath)
    # 刪除後 verify：若 reload 失敗，rollback 就是把備份還原回 filepath
    reload_and_verify(filepath, backup)
    return {"ok": True}


@router.patch("/api/dialplan/routes/{route_id}/toggle", dependencies=[Depends(require_permission(Module.DIALPLAN, "update"))])
def toggle_route(route_id: str, enabled: bool = Body(..., embed=True)):
    """快速啟用/停用路由規則，不需重新送整份表單。"""
    if route_id.startswith("legacy:"):
        raise HTTPException(
            status_code=400,
            detail="尚未升級的舊有檔案無法直接啟用/停用，請先升級成 Dashboard 格式。",
        )
    filepath = _route_filepath(route_id)
    if not os.path.exists(filepath):
        raise HTTPException(status_code=404, detail=f"路由規則 {route_id} 不存在")
    meta = _read_route_meta(filepath)
    if not meta:
        raise HTTPException(status_code=500, detail="無法解析此規則的設定內容")

    data = RouteRule(
        id=route_id,
        name=meta["name"],
        pattern_type=meta["pattern_type"],
        pattern_value=meta.get("pattern_value", ""),
        gateway_name=meta["gateway_name"],
        caller_id_override=meta.get("caller_id_override", ""),
        toll_allow=meta.get("toll_allow", ""),
        enabled=enabled,
        priority=meta.get("priority", 100),
        context=meta.get("context", DEFAULT_CONTEXT),
    )
    backup = make_backup(filepath)
    write_route_xml(data, filepath)
    reload_and_verify(filepath, backup)
    return {"ok": True, "id": route_id, "enabled": enabled}
