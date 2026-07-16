#!/usr/bin/env bash
# update19.sh — Dialplan Context 切換 UI
# 範圍：
#   1. routers/dialplan_routes.py：context 動態決定寫入資料夾、GET/POST /api/dialplan/contexts、
#      find_conflicts() 依 context 分組、update 時 context 變更會搬移檔案
#   2. static/js/dialplan.js：路由規則 Tab 加 context 篩選（全部 context 卡片總覽+下鑽+麵包屑）、
#      表單加 Context 選單、衝突警告分「同 context」/「跨 context」；
#      自定義 Dialplan Tab 的 context 選單改動態清單 + 建立新 context
set -e

cd "$(dirname "$0")"

# ════════════════════════════════════════════════════════════════════════════
# 0. 自動歸檔（固定寫法，統一放進 updateN/）
# ════════════════════════════════════════════════════════════════════════════
ARCHIVE_DIR="updateN"
SELF="$(basename "$0")"

mkdir -p "$ARCHIVE_DIR"
for f in update*.sh; do
  [ "$f" = "$SELF" ] && continue
  [ -f "$f" ] || continue
  git mv "$f" "${ARCHIVE_DIR}/$f" 2>/dev/null || mv "$f" "${ARCHIVE_DIR}/$f"
done
git add "${ARCHIVE_DIR}"
if ! git diff --cached --quiet; then
  git commit -m "chore: 歸檔已執行的 updateN.sh 腳本"
fi

# ════════════════════════════════════════════════════════════════════════════
# 1. 前置驗證
# ════════════════════════════════════════════════════════════════════════════
if [ ! -f routers/dialplan_routes.py ]; then
  echo "❌ 找不到 routers/dialplan_routes.py，請確認執行路徑" >&2
  exit 1
fi
if [ ! -f static/js/dialplan.js ]; then
  echo "❌ 找不到 static/js/dialplan.js，請確認執行路徑" >&2
  exit 1
fi

SKIP_BACKEND=0
if grep -q "2026-07-15：新增多 context 支援" routers/dialplan_routes.py 2>/dev/null; then
  echo "ℹ️  routers/dialplan_routes.py 已包含多 context 支援，略過後端覆寫"
  SKIP_BACKEND=1
elif ! grep -q 'ROUTE_DIR = "/etc/freeswitch/dialplan/default"' routers/dialplan_routes.py; then
  echo "❌ routers/dialplan_routes.py 內容與預期基準不符（找不到 ROUTE_DIR 寫死字串），請先確認版本是否正確" >&2
  exit 1
fi

# ════════════════════════════════════════════════════════════════════════════
# 2. 後端：routers/dialplan_routes.py（整份覆寫）
# ════════════════════════════════════════════════════════════════════════════
if [ "$SKIP_BACKEND" = "0" ]; then
cp routers/dialplan_routes.py routers/dialplan_routes.py.bak.$(date +%Y%m%d%H%M%S)

cat > routers/dialplan_routes.py << 'ROUTES_PY_EOF'
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
        "note": "自訂正規式採取樣比對，無法窮舉所有號碼，建議搭配下方路由測試工具手動驗證。" if pattern_type == "custom_regex" else None,
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
ROUTES_PY_EOF

python3 -m py_compile routers/dialplan_routes.py
echo "✓ routers/dialplan_routes.py 語法檢查通過"
git add routers/dialplan_routes.py
fi

# ════════════════════════════════════════════════════════════════════════════
# 3. 前端：static/js/dialplan.js（精確字串比對，逐處替換）
# ════════════════════════════════════════════════════════════════════════════
cp static/js/dialplan.js static/js/dialplan.js.bak.$(date +%Y%m%d%H%M%S)

python3 << 'DIALPLAN_JS_PY_EOF'
import sys

path = "static/js/dialplan.js"
with open(path, "r", encoding="utf-8") as f:
    content = f.read()

edits = []

# ── A. 路由規則 Tab：新增 context 相關 state 變數 ──────────────────────────────
edits.append((
    "A. 新增 context state 變數",
"""let _routeGatewayCache = null;   // /api/gateway/list 快取
let _routeEditingId    = null;   // 目前編輯中的路由 id（新增模式為 null）
let _routeConflictTimer = null;  // debounce timer""",
"""let _routeGatewayCache = null;   // /api/gateway/list 快取
let _routeEditingId    = null;   // 目前編輯中的路由 id（新增模式為 null）
let _routeConflictTimer = null;  // debounce timer
let _routeContextCache   = [];      // /api/dialplan/contexts 快取
let _routeAllRoutesCache = [];      // 最近一次 /api/dialplan/routes 回應，供前端篩選/分組用
let _routeCurrentFilter  = 'default'; // 目前選取的 context，或 '__all__'
let _routeCameFromOverview = false;   // 是否是從「全部 context」總覽點卡片下鑽進來的""",
))

# ── B. renderDialplanRoutes：抓取 contexts，計算預設篩選 ─────────────────────
edits.append((
    "B. renderDialplanRoutes 抓取 contexts",
"""  const [routeData, gwData] = await Promise.all([
    apiFetch('/api/dialplan/routes'),
    apiFetch('/api/gateway/list'),
  ]);

  const routes = (routeData && routeData.routes) ? routeData.routes : [];
  _routeGatewayCache = (gwData && gwData.gateways) ? gwData.gateways : [];""",
"""  const [routeData, gwData, ctxData] = await Promise.all([
    apiFetch('/api/dialplan/routes'),
    apiFetch('/api/gateway/list'),
    apiFetch('/api/dialplan/contexts'),
  ]);

  const routes = (routeData && routeData.routes) ? routeData.routes : [];
  _routeGatewayCache   = (gwData && gwData.gateways) ? gwData.gateways : [];
  _routeContextCache   = (ctxData && ctxData.contexts) ? ctxData.contexts : ['default'];
  _routeAllRoutesCache = routes;
  _routeCurrentFilter  = _routeDefaultFilterContext(routes);""",
))

# ── C. 列表面板：篩選下拉 + table-wrap 換成可替換的 region ────────────────────
edits.append((
    "C. 列表面板改用 route-table-region",
"""      <div class="panel-header">
        <span class="panel-title">外撥路由規則</span>
        <span class="panel-badge">${routes.length} 條規則</span>
        <div class="panel-actions">
          <button class="btn" onclick="switchPage('dialplan_routes')">↺ 刷新</button>
          <button class="btn primary" onclick="openRouteEditor(null)">+ 新增路由規則</button>
        </div>
      </div>
      <div class="table-wrap">
        <table>
          <thead>
            <tr>
              <th>優先序</th><th>名稱</th><th>號碼樣式</th><th>目標 Gateway</th>
              <th>來電顯示</th><th>狀態</th><th>操作</th>
            </tr>
          </thead>
          <tbody>${_routeRowsHtml(routes)}</tbody>
        </table>
      </div>
      <div style="padding:10px 16px;font-size:11px;color:var(--muted)">
        ℹ️ 規則依優先序（數字越小越優先）由上而下比對，第一個符合的規則即生效。
        若多條規則的號碼範圍重疊，新增/編輯時會即時提示衝突。
      </div>""",
"""      <div class="panel-header">
        <span class="panel-title">外撥路由規則</span>
        <span class="panel-badge">${routes.length} 條規則</span>
        <div class="panel-actions">
          ${_routeFilterSelectHtml()}
          <button class="btn" onclick="switchPage('dialplan_routes')">↺ 刷新</button>
          <button class="btn primary" onclick="openRouteEditor(null)">+ 新增路由規則</button>
        </div>
      </div>
      <div id="route-table-region"></div>
      <div style="padding:10px 16px;font-size:11px;color:var(--muted)">
        ℹ️ 規則依優先序（數字越小越優先）由上而下比對，第一個符合的規則即生效。
        若多條規則的號碼範圍重疊，新增/編輯時會即時提示衝突（僅同一 context 內的規則視為衝突，跨 context 僅供參考）。
      </div>""",
))

# ── D. renderDialplanRoutes 結尾：先填 table-region 再處理表單預設值 ──────────
edits.append((
    "D. renderDialplanRoutes 結尾呼叫 _renderRouteListRegion()",
"""    </div>
  </div>`;

  onRoutePatternTypeChange();
}""",
"""    </div>
  </div>`;

  _renderRouteListRegion();
  onRoutePatternTypeChange();
}""",
))

# ── E. 新增 context 篩選/總覽卡片/下鑽/麵包屑 輔助函式 ─────────────────────────
edits.append((
    "E. 新增 context 篩選與總覽卡片輔助函式",
"""function _escAttr(s) {
  return _escHtml(s).replace(/'/g, '&#39;');
}""",
"""function _escAttr(s) {
  return _escHtml(s).replace(/'/g, '&#39;');
}

// ── Context 篩選／全部總覽卡片／下鑽／麵包屑 ─────────────────────────────────
function _routeContextCounts(routes) {
  const counts = {};
  routes.forEach(r => {
    const c = r.context || 'default';
    counts[c] = (counts[c] || 0) + 1;
  });
  return counts;
}

function _routeDefaultFilterContext(routes) {
  const counts = _routeContextCounts(routes);
  const contexts = Object.keys(counts);
  if (contexts.length <= 1) return contexts[0] || 'default';
  // 有多個 context 時，預設顯示規則數最多的那個，維持接近單一 context 時的既有體驗
  return contexts.sort((a, b) => counts[b] - counts[a])[0];
}

function _routeContextOptionsHtml(selected) {
  const list = _routeContextCache.length ? _routeContextCache : ['default'];
  return list.map(c =>
    `<option value="${_escAttr(c)}" ${c === selected ? 'selected' : ''}>${_escHtml(c)}</option>`
  ).join('');
}

function _routeFilterSelectHtml() {
  const counts = _routeContextCounts(_routeAllRoutesCache);
  const known  = _routeContextCache.length ? _routeContextCache : Object.keys(counts);
  const opts = known.map(c =>
    `<option value="${_escAttr(c)}" ${c === _routeCurrentFilter ? 'selected' : ''}>${_escHtml(c)}（${counts[c] || 0}）</option>`
  ).join('');
  return `
    <select class="settings-select" id="route-context-filter" style="max-width:200px" onchange="onRouteContextFilterChange()">
      ${opts}
      <option value="__all__" ${_routeCurrentFilter === '__all__' ? 'selected' : ''}>🗂 全部 context</option>
    </select>`;
}

function onRouteContextFilterChange() {
  const sel = document.getElementById('route-context-filter');
  if (!sel) return;
  _routeCurrentFilter = sel.value;
  _routeCameFromOverview = false;
  _renderRouteListRegion();
}

function _renderRouteListRegion() {
  const region = document.getElementById('route-table-region');
  if (!region) return;
  region.innerHTML = _routeCurrentFilter === '__all__'
    ? _routeOverviewCardsHtml()
    : _routeFlatTableHtml(_routeCurrentFilter);
}

function _routeOverviewCardsHtml() {
  const counts = _routeContextCounts(_routeAllRoutesCache);
  const contexts = Object.keys(counts).sort();
  if (contexts.length === 0) {
    return `<div style="padding:30px;text-align:center;color:var(--muted)">尚無路由規則</div>`;
  }
  const cards = contexts.map(ctx => {
    const rs = _routeAllRoutesCache.filter(r => (r.context || 'default') === ctx);
    const enabledCount = rs.filter(r => r.enabled !== false).length;
    return `
    <div style="border:1px solid var(--border);border-radius:8px;padding:16px;cursor:pointer;
                background:var(--panel2);transition:border-color .15s"
      onmouseover="this.style.borderColor='var(--accent)'"
      onmouseout="this.style.borderColor='var(--border)'"
      onclick="_routeDrillIntoContext('${_escAttr(ctx)}')">
      <div style="font-weight:600;font-size:14px;color:var(--text);margin-bottom:4px">📁 ${_escHtml(ctx)}</div>
      <div style="font-size:12px;color:var(--muted)">${rs.length} 條規則・${enabledCount} 啟用</div>
    </div>`;
  }).join('');
  return `<div style="padding:16px;display:grid;grid-template-columns:repeat(auto-fill,minmax(200px,1fr));gap:12px">${cards}</div>`;
}

function _routeDrillIntoContext(ctx) {
  _routeCurrentFilter = ctx;
  _routeCameFromOverview = true;
  const sel = document.getElementById('route-context-filter');
  if (sel) sel.value = ctx;
  _renderRouteListRegion();
}

function _routeBackToOverview() {
  _routeCurrentFilter = '__all__';
  _routeCameFromOverview = false;
  const sel = document.getElementById('route-context-filter');
  if (sel) sel.value = '__all__';
  _renderRouteListRegion();
}

function _routeFlatTableHtml(ctx) {
  const filtered = _routeAllRoutesCache.filter(r => (r.context || 'default') === ctx);
  const breadcrumb = _routeCameFromOverview ? `
    <div style="padding:8px 16px;font-size:12px;color:var(--muted);display:flex;align-items:center;gap:8px;
                border-bottom:1px solid var(--border)">
      🛣 路由規則 <span style="color:var(--muted)">›</span> <strong style="color:#fff">${_escHtml(ctx)}</strong>
      <button class="btn" style="padding:2px 8px;font-size:11px;margin-left:auto" onclick="_routeBackToOverview()">← 返回總覽</button>
    </div>` : '';
  return `
    ${breadcrumb}
    <div class="table-wrap">
      <table>
        <thead>
          <tr>
            <th>優先序</th><th>名稱</th><th>Context</th><th>號碼樣式</th><th>目標 Gateway</th>
            <th>來電顯示</th><th>狀態</th><th>操作</th>
          </tr>
        </thead>
        <tbody>${_routeRowsHtml(filtered)}</tbody>
      </table>
    </div>`;
}""",
))

# ── F. _routeRowsHtml：加入 Context 欄位 ──────────────────────────────────────
edits.append((
    "F. _routeRowsHtml 加入 Context 欄位",
"""function _routeRowsHtml(routes) {
  if (routes.length === 0) {
    return `<tr><td colspan="7" style="text-align:center;color:var(--muted);padding:20px">尚無路由規則</td></tr>`;
  }
  return routes.map(r => {
    const ptMeta = PATTERN_TYPE_META[r.pattern_type] || { label: r.pattern_type };
    const patternDisplay = r.pattern_type === 'any'
      ? '任意號碼'
      : `${ptMeta.label}：${r.pattern_value}`;

    if (r.legacy) {
      return `<tr style="background:rgba(230,81,0,0.06)">
        <td style="color:var(--accent-bright);font-weight:600">${r.priority}</td>
        <td style="color:#fff;font-weight:600">
          ${_escHtml(r.name)}
          <span style="display:block;font-size:10px;color:var(--yellow);font-weight:400">
            ⚠️ 未納入管理（來源：${_escHtml(r.filename)}）
          </span>
        </td>
        <td style="font-size:12px;color:var(--label)">${_escHtml(patternDisplay)}</td>
        <td style="font-size:12px">${_escHtml(r.gateway_name)}</td>
        <td style="font-size:11px;color:var(--muted)">${_escHtml(r.caller_id_override) || '—'}</td>
        <td><span class="call-status status-hold"><span class="dot"></span>舊有檔案</span></td>
        <td style="display:flex;gap:4px;flex-wrap:wrap">
          <button class="btn primary" style="padding:3px 8px;font-size:11px" onclick="openRouteUpgradeEditor('${r.id}')">
            ⬆ 升級並納入管理
          </button>
        </td>
      </tr>`;
    }

    const statusBadge = r.enabled
      ? `<span class="call-status status-active"><span class="dot"></span>啟用</span>`
      : `<span class="call-status status-hold"><span class="dot"></span>停用</span>`;
    return `<tr>
      <td style="color:var(--accent-bright);font-weight:600">${r.priority}</td>
      <td style="color:#fff;font-weight:600">${_escHtml(r.name)}</td>
      <td style="font-size:12px;color:var(--label)">${_escHtml(patternDisplay)}</td>
      <td style="font-size:12px">${_escHtml(r.gateway_name)}</td>
      <td style="font-size:11px;color:var(--muted)">${_escHtml(r.caller_id_override) || '—'}</td>
      <td>${statusBadge}</td>
      <td style="display:flex;gap:4px;flex-wrap:wrap">
        <button class="btn" style="padding:3px 8px;font-size:11px" onclick="openRouteEditor('${r.id}')">✏ 編輯</button>
        <button class="btn" style="padding:3px 8px;font-size:11px" onclick="toggleRouteEnabled('${r.id}', ${!r.enabled})">
          ${r.enabled ? '⏸ 停用' : '▶ 啟用'}
        </button>
        <button class="btn danger" style="padding:3px 8px;font-size:11px" onclick="deleteRoute('${r.id}', '${_escAttr(r.name)}')">✕ 刪除</button>
      </td>
    </tr>`;
  }).join('');
}""",
"""function _routeRowsHtml(routes) {
  if (routes.length === 0) {
    return `<tr><td colspan="8" style="text-align:center;color:var(--muted);padding:20px">尚無路由規則</td></tr>`;
  }
  return routes.map(r => {
    const ptMeta = PATTERN_TYPE_META[r.pattern_type] || { label: r.pattern_type };
    const patternDisplay = r.pattern_type === 'any'
      ? '任意號碼'
      : `${ptMeta.label}：${r.pattern_value}`;
    const ctxLabel = r.context || 'default';

    if (r.legacy) {
      return `<tr style="background:rgba(230,81,0,0.06)">
        <td style="color:var(--accent-bright);font-weight:600">${r.priority}</td>
        <td style="color:#fff;font-weight:600">
          ${_escHtml(r.name)}
          <span style="display:block;font-size:10px;color:var(--yellow);font-weight:400">
            ⚠️ 未納入管理（來源：${_escHtml(r.filename)}）
          </span>
        </td>
        <td style="font-size:11px;color:var(--label)">${_escHtml(ctxLabel)}</td>
        <td style="font-size:12px;color:var(--label)">${_escHtml(patternDisplay)}</td>
        <td style="font-size:12px">${_escHtml(r.gateway_name)}</td>
        <td style="font-size:11px;color:var(--muted)">${_escHtml(r.caller_id_override) || '—'}</td>
        <td><span class="call-status status-hold"><span class="dot"></span>舊有檔案</span></td>
        <td style="display:flex;gap:4px;flex-wrap:wrap">
          <button class="btn primary" style="padding:3px 8px;font-size:11px" onclick="openRouteUpgradeEditor('${r.id}')">
            ⬆ 升級並納入管理
          </button>
        </td>
      </tr>`;
    }

    const statusBadge = r.enabled
      ? `<span class="call-status status-active"><span class="dot"></span>啟用</span>`
      : `<span class="call-status status-hold"><span class="dot"></span>停用</span>`;
    return `<tr>
      <td style="color:var(--accent-bright);font-weight:600">${r.priority}</td>
      <td style="color:#fff;font-weight:600">${_escHtml(r.name)}</td>
      <td style="font-size:11px;color:var(--label)">${_escHtml(ctxLabel)}</td>
      <td style="font-size:12px;color:var(--label)">${_escHtml(patternDisplay)}</td>
      <td style="font-size:12px">${_escHtml(r.gateway_name)}</td>
      <td style="font-size:11px;color:var(--muted)">${_escHtml(r.caller_id_override) || '—'}</td>
      <td>${statusBadge}</td>
      <td style="display:flex;gap:4px;flex-wrap:wrap">
        <button class="btn" style="padding:3px 8px;font-size:11px" onclick="openRouteEditor('${r.id}')">✏ 編輯</button>
        <button class="btn" style="padding:3px 8px;font-size:11px" onclick="toggleRouteEnabled('${r.id}', ${!r.enabled})">
          ${r.enabled ? '⏸ 停用' : '▶ 啟用'}
        </button>
        <button class="btn danger" style="padding:3px 8px;font-size:11px" onclick="deleteRoute('${r.id}', '${_escAttr(r.name)}')">✕ 刪除</button>
      </td>
    </tr>`;
  }).join('');
}""",
))

# ── G. openRouteEditor：編輯模式帶入 context ───────────────────────────────────
edits.append((
    "G. openRouteEditor 編輯模式帶入 context",
"""    document.getElementById('route-name').value          = data.name || '';
    document.getElementById('route-pattern-type').value  = data.pattern_type || 'prefix';
    document.getElementById('route-pattern-value').value = data.pattern_value || '';
    document.getElementById('route-gateway-name').value  = data.gateway_name || '';
    document.getElementById('route-caller-id').value     = data.caller_id_override || '';
    document.getElementById('route-toll-allow').value    = data.toll_allow || '';
    document.getElementById('route-priority').value      = data.priority || 100;
    document.getElementById('route-enabled').value       = String(data.enabled !== false);""",
"""    document.getElementById('route-name').value          = data.name || '';
    document.getElementById('route-pattern-type').value  = data.pattern_type || 'prefix';
    document.getElementById('route-pattern-value').value = data.pattern_value || '';
    document.getElementById('route-gateway-name').value  = data.gateway_name || '';
    document.getElementById('route-caller-id').value     = data.caller_id_override || '';
    document.getElementById('route-toll-allow').value    = data.toll_allow || '';
    document.getElementById('route-priority').value      = data.priority || 100;
    document.getElementById('route-enabled').value       = String(data.enabled !== false);
    document.getElementById('route-context').innerHTML   = _routeContextOptionsHtml(data.context || 'default');""",
))

# ── H. openRouteEditor：新增模式帶入預設 context（沿用目前篩選） ────────────────
edits.append((
    "H. openRouteEditor 新增模式帶入預設 context",
"""    document.getElementById('route-name').value          = '';
    document.getElementById('route-pattern-type').value  = 'prefix';
    document.getElementById('route-pattern-value').value = '';
    document.getElementById('route-gateway-name').value  = '';
    document.getElementById('route-caller-id').value     = '';
    document.getElementById('route-toll-allow').value    = '';
    document.getElementById('route-priority').value      = 100;
    document.getElementById('route-enabled').value       = 'true';""",
"""    document.getElementById('route-name').value          = '';
    document.getElementById('route-pattern-type').value  = 'prefix';
    document.getElementById('route-pattern-value').value = '';
    document.getElementById('route-gateway-name').value  = '';
    document.getElementById('route-caller-id').value     = '';
    document.getElementById('route-toll-allow').value    = '';
    document.getElementById('route-priority').value      = 100;
    document.getElementById('route-enabled').value       = 'true';
    document.getElementById('route-context').innerHTML   =
      _routeContextOptionsHtml(_routeCurrentFilter && _routeCurrentFilter !== '__all__' ? _routeCurrentFilter : 'default');""",
))

# ── I. openRouteUpgradeEditor：帶入 legacy 檔案偵測到的 context ────────────────
edits.append((
    "I. openRouteUpgradeEditor 帶入 context",
"""  document.getElementById('route-name').value          = data.name || '';
  document.getElementById('route-pattern-type').value  = data.pattern_type || 'custom_regex';
  document.getElementById('route-pattern-value').value = data.pattern_value || data.legacy_raw_expression || '';
  document.getElementById('route-gateway-name').value  = data.gateway_name || '';
  document.getElementById('route-caller-id').value     = data.caller_id_override || '';
  document.getElementById('route-toll-allow').value    = data.toll_allow || '';
  document.getElementById('route-priority').value      = data.priority || 100;
  document.getElementById('route-enabled').value       = 'true';""",
"""  document.getElementById('route-name').value          = data.name || '';
  document.getElementById('route-pattern-type').value  = data.pattern_type || 'custom_regex';
  document.getElementById('route-pattern-value').value = data.pattern_value || data.legacy_raw_expression || '';
  document.getElementById('route-gateway-name').value  = data.gateway_name || '';
  document.getElementById('route-caller-id').value     = data.caller_id_override || '';
  document.getElementById('route-toll-allow').value    = data.toll_allow || '';
  document.getElementById('route-priority').value      = data.priority || 100;
  document.getElementById('route-enabled').value       = 'true';
  document.getElementById('route-context').innerHTML   = _routeContextOptionsHtml(data.context || 'default');""",
))

# ── J. 表單 HTML：新增 Context 選單 ─────────────────────────────────────────
edits.append((
    "J. 表單新增 Context 選單",
"""        <div class="settings-row">
          <span class="settings-label">目標 Gateway *</span>
          <select class="settings-select" id="route-gateway-name">
            <option value="">請選擇 Gateway</option>
            ${_routeGatewayCache.map(g =>
              `<option value="${g.name}">${g.name}${g.proxy ? ' (' + g.proxy + ')' : ''}</option>`).join('')}
          </select>
        </div>
        ${_routeGatewayCache.length === 0 ? `
        <div style="margin-left:164px;font-size:11px;color:var(--red)">
          ⚠️ 尚未設定任何 Gateway，請先到「Gateway / SIP Trunk」頁面新增後再回來設定路由。
        </div>` : ''}""",
"""        <div class="settings-row">
          <span class="settings-label">目標 Gateway *</span>
          <select class="settings-select" id="route-gateway-name">
            <option value="">請選擇 Gateway</option>
            ${_routeGatewayCache.map(g =>
              `<option value="${g.name}">${g.name}${g.proxy ? ' (' + g.proxy + ')' : ''}</option>`).join('')}
          </select>
        </div>
        ${_routeGatewayCache.length === 0 ? `
        <div style="margin-left:164px;font-size:11px;color:var(--red)">
          ⚠️ 尚未設定任何 Gateway，請先到「Gateway / SIP Trunk」頁面新增後再回來設定路由。
        </div>` : ''}

        <div class="settings-row">
          <span class="settings-label">Context *</span>
          <select class="settings-select" id="route-context" style="max-width:200px" onchange="onRoutePatternInput()"></select>
          <span style="font-size:11px;color:var(--muted)">決定寫入哪個 dialplan context 資料夾；新增 context 請到「自定義 Dialplan」頁面</span>
        </div>""",
))

# ── K. saveRoute：payload 帶入 context ────────────────────────────────────
edits.append((
    "K. saveRoute payload 加入 context",
"""  const payload = {
    name, pattern_type: patternType, pattern_value: patternValue,
    gateway_name: gatewayName, caller_id_override: callerId,
    toll_allow: tollAllow, priority, enabled,
  };""",
"""  const context = document.getElementById('route-context')?.value || 'default';
  const payload = {
    name, pattern_type: patternType, pattern_value: patternValue,
    gateway_name: gatewayName, caller_id_override: callerId,
    toll_allow: tollAllow, priority, enabled, context,
  };""",
))

# ── L. _checkRouteConflict：context 分組顯示 ───────────────────────────────
edits.append((
    "L. _checkRouteConflict 支援 context 分組",
"""async function _checkRouteConflict() {
  const div = document.getElementById('route-conflict-warning');
  const patternType  = document.getElementById('route-pattern-type').value;
  const patternValue = document.getElementById('route-pattern-value').value.trim();

  if (patternType !== 'any' && !patternValue) {
    div.innerHTML = '';
    return;
  }

  try {
    const res = await fetch(`${API_BASE}/api/dialplan/routes/check-conflict`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        pattern_type: patternType,
        pattern_value: patternValue,
        self_id: _routeUpgradingLegacyId || _routeEditingId || '',
      }),
    });
    const data = await res.json();

    if (!res.ok) {
      div.innerHTML = `<div style="font-size:12px;color:var(--red)">⚠️ ${_escHtml(data.detail || '正規式錯誤')}</div>`;
      return;
    }

    if (!data.has_conflict) {
      div.innerHTML = `<span style="font-size:11px;color:var(--green)">✓ 號碼樣式未與既有規則重疊</span>`;
      return;
    }

    const list = data.conflicts.map(c =>
      `<li>「${_escHtml(c.name)}」（優先序 ${c.priority}，${c.enabled ? '啟用中' : '已停用'}）— ${_escHtml(c.pattern_value || '任意')}</li>`
    ).join('');

    div.innerHTML = `
      <div style="padding:8px 10px;background:#ffebee;border:1px solid #ef9a9a;border-radius:4px">
        <div style="font-size:12px;color:#c62828;font-weight:600">⚠️ 此號碼樣式與下列規則重疊：</div>
        <ul style="margin:4px 0 4px 18px;font-size:12px;color:#c62828">${list}</ul>
        ${data.note ? `<div style="font-size:11px;color:#c62828;margin-top:2px">${_escHtml(data.note)}</div>` : ''}
        <div style="font-size:11px;color:#c62828;margin-top:4px">
          可用下方「快速測試」欄位輸入實際號碼，確認目前會被哪一條規則攔截。
        </div>
      </div>`;
  } catch (e) {
    div.innerHTML = `<div style="font-size:12px;color:var(--red)">⚠️ 衝突檢查失敗：${e.message}</div>`;
  }
}""",
"""async function _checkRouteConflict() {
  const div = document.getElementById('route-conflict-warning');
  const patternType  = document.getElementById('route-pattern-type').value;
  const patternValue = document.getElementById('route-pattern-value').value.trim();
  const context      = document.getElementById('route-context')?.value || 'default';

  if (patternType !== 'any' && !patternValue) {
    div.innerHTML = '';
    return;
  }

  try {
    const res = await fetch(`${API_BASE}/api/dialplan/routes/check-conflict`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        pattern_type: patternType,
        pattern_value: patternValue,
        context,
        self_id: _routeUpgradingLegacyId || _routeEditingId || '',
      }),
    });
    const data = await res.json();

    if (!res.ok) {
      div.innerHTML = `<div style="font-size:12px;color:var(--red)">⚠️ ${_escHtml(data.detail || '正規式錯誤')}</div>`;
      return;
    }

    let html = '';

    if (!data.has_conflict) {
      html += `<span style="font-size:11px;color:var(--green)">✓ 號碼樣式未與同一 context 的既有規則重疊</span>`;
    } else {
      const list = data.conflicts.map(c =>
        `<li>「${_escHtml(c.name)}」（優先序 ${c.priority}，${c.enabled ? '啟用中' : '已停用'}）— ${_escHtml(c.pattern_value || '任意')}</li>`
      ).join('');
      html += `
      <div style="padding:8px 10px;background:#ffebee;border:1px solid #ef9a9a;border-radius:4px">
        <div style="font-size:12px;color:#c62828;font-weight:600">⚠️ 此號碼樣式與下列同 context 規則重疊：</div>
        <ul style="margin:4px 0 4px 18px;font-size:12px;color:#c62828">${list}</ul>
        ${data.note ? `<div style="font-size:11px;color:#c62828;margin-top:2px">${_escHtml(data.note)}</div>` : ''}
        <div style="font-size:11px;color:#c62828;margin-top:4px">
          可用下方「快速測試」欄位輸入實際號碼，確認目前會被哪一條規則攔截。
        </div>
      </div>`;
    }

    if (data.other_context_matches && data.other_context_matches.length) {
      const otherList = data.other_context_matches.map(c =>
        `<li>「${_escHtml(c.name)}」（context: ${_escHtml(c.context)}，優先序 ${c.priority}）</li>`
      ).join('');
      html += `
      <div style="padding:8px 10px;background:#e3f2fd;border:1px solid #90caf9;border-radius:4px;margin-top:6px">
        <div style="font-size:11px;color:#1565c0">ℹ️ 以下規則號碼樣式相同，但屬於其他 context，不影響本次判斷：</div>
        <ul style="margin:4px 0 0 18px;font-size:11px;color:#1565c0">${otherList}</ul>
      </div>`;
    }

    div.innerHTML = html;
  } catch (e) {
    div.innerHTML = `<div style="font-size:12px;color:var(--red)">⚠️ 衝突檢查失敗：${e.message}</div>`;
  }
}""",
))

# ── M. 自定義 Dialplan：新增 _dcContextsCache 變數 ────────────────────────────
edits.append((
    "M. 新增 _dcContextsCache 變數",
"""let _dcTemplates   = null;   // /api/dialplan/custom/templates 快取
let _dcFiles       = [];     // /api/dialplan/custom/files 快取
let _dcMode        = 'list'; // 'list' | 'pick' | 'form'""",
"""let _dcTemplates   = null;   // /api/dialplan/custom/templates 快取
let _dcFiles       = [];     // /api/dialplan/custom/files 快取
let _dcContextsCache = [];   // /api/dialplan/contexts 快取
let _dcMode        = 'list'; // 'list' | 'pick' | 'form'""",
))

# ── N. renderDialplanCustom：抓取 contexts ────────────────────────────────
edits.append((
    "N. renderDialplanCustom 抓取 contexts",
"""  const [tplData, fileData] = await Promise.all([
    apiFetch('/api/dialplan/custom/templates'),
    apiFetch('/api/dialplan/custom/files'),
  ]);

  _dcTemplates = (tplData && tplData.templates) ? tplData.templates : [];
  _dcFiles     = (fileData && fileData.files) ? fileData.files : [];
  _dcMode      = 'list';""",
"""  const [tplData, fileData, ctxData] = await Promise.all([
    apiFetch('/api/dialplan/custom/templates'),
    apiFetch('/api/dialplan/custom/files'),
    apiFetch('/api/dialplan/contexts'),
  ]);

  _dcTemplates     = (tplData && tplData.templates) ? tplData.templates : [];
  _dcFiles         = (fileData && fileData.files) ? fileData.files : [];
  _dcContextsCache = (ctxData && ctxData.contexts) ? ctxData.contexts : ['default', 'public'];
  _dcMode          = 'list';""",
))

# ── O. 新增建立 context 相關輔助函式 ──────────────────────────────────────
edits.append((
    "O. 新增建立新 context 輔助函式",
"""function _dcCollectValues() {
  const tpl = _dcCurrentTemplate();
  const values = {};
  (tpl?.fields || []).forEach(f => {
    const el = document.getElementById(`dc-field-${f.key}`);
    values[f.key] = el ? el.value.trim() : '';
  });
  return values;
}""",
"""function _dcCollectValues() {
  const tpl = _dcCurrentTemplate();
  const values = {};
  (tpl?.fields || []).forEach(f => {
    const el = document.getElementById(`dc-field-${f.key}`);
    values[f.key] = el ? el.value.trim() : '';
  });
  return values;
}

// ── Context 選單：動態清單 + 就地建立新 context ───────────────────────────────
function _dcContextOptionsHtml(selected) {
  const list = _dcContextsCache.length ? _dcContextsCache : ['default', 'public'];
  const opts = list.map(c =>
    `<option value="${_escAttr(c)}" ${c === selected ? 'selected' : ''}>${_escHtml(c)}</option>`).join('');
  return opts + `<option value="__new__">+ 建立新 context...</option>`;
}

function _dcHandleContextChange(selectEl) {
  if (selectEl.value !== '__new__') return;
  _dcPromptNewContext(selectEl);
}

function _dcPromptNewContext(selectEl) {
  const fallback = _dcContextsCache[0] || 'default';
  document.body.insertAdjacentHTML('beforeend', _dpModalHtml('📁 建立新 Context', `
    <div style="margin-bottom:10px">
      <label style="font-size:12px;color:var(--label);display:block;margin-bottom:4px">
        Context 名稱 <span style="font-size:11px;color:var(--muted)">（英數字、底線、連字號）</span>
      </label>
      <input id="dc-new-context-name" class="settings-input" style="width:100%;box-sizing:border-box" placeholder="例：branch2">
    </div>
    <div style="padding:8px 10px;background:#fff3e0;border:1px solid #ffcc80;border-radius:4px;font-size:11px;color:#e65100;margin-bottom:10px">
      ⚠️ 建立後只是新增一個空的 dialplan 資料夾，還需要另外到 SIP Profile 或其他 dialplan 設定中，
      讓某個來源實際指向這個 context 名稱，通話才會真正進入此 context。
    </div>
    <div id="dc-new-context-msg" style="font-size:12px;min-height:18px;margin-bottom:8px"></div>
    <div style="display:flex;gap:8px">
      <button class="btn" onclick="_dcCreateNewContext('${selectEl.id}', '${fallback}')"
        style="background:var(--accent);color:#fff;font-weight:600;padding:6px 20px">建立</button>
      <button class="btn" onclick="dpCloseModal(); document.getElementById('${selectEl.id}').value='${fallback}'">取消</button>
    </div>
  `));
}

async function _dcCreateNewContext(selectId, fallbackValue) {
  const nameInput = document.getElementById('dc-new-context-name');
  const msg       = document.getElementById('dc-new-context-msg');
  const name = (nameInput?.value || '').trim();
  if (!name) { if (msg) { msg.textContent = '❌ 請輸入 context 名稱'; msg.style.color = 'var(--red)'; } return; }
  if (!/^[\\w\\-]+$/.test(name)) {
    if (msg) { msg.textContent = '❌ 僅能包含英數字、底線、連字號'; msg.style.color = 'var(--red)'; }
    return;
  }
  if (msg) { msg.textContent = '建立中...'; msg.style.color = 'var(--yellow)'; }
  try {
    const res  = await fetch(`${API_BASE}/api/dialplan/contexts`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ context: name }),
    });
    const data = await res.json();
    if (res.ok && data.ok) {
      if (!_dcContextsCache.includes(name)) _dcContextsCache.push(name);
      dpCloseModal();
      const sel = document.getElementById(selectId);
      if (sel) { sel.innerHTML = _dcContextOptionsHtml(name); sel.value = name; }
    } else {
      if (msg) { msg.textContent = `❌ ${data.detail || '建立失敗'}`; msg.style.color = 'var(--red)'; }
    }
  } catch (e) {
    if (msg) { msg.textContent = `❌ ${e.message}`; msg.style.color = 'var(--red)'; }
  }
}""",
))

# ── P. 範本表單的 dc-context 選單改為動態 ─────────────────────────────────
edits.append((
    "P. 範本表單 dc-context 改動態選單",
"""          <label style="font-size:12px;color:var(--label);display:block;margin-bottom:4px">Context</label>
          <select id="dc-context" class="settings-select" style="width:100%;box-sizing:border-box">
            <option value="default">default（分機撥出）</option>
            <option value="public">public（外線來電）</option>
          </select>""",
"""          <label style="font-size:12px;color:var(--label);display:block;margin-bottom:4px">Context</label>
          <select id="dc-context" class="settings-select" style="width:100%;box-sizing:border-box" onchange="_dcHandleContextChange(this)">
            ${_dcContextOptionsHtml('default')}
          </select>""",
))

# ── Q. 手動新增 modal 的 dc-manual-context 選單改為動態 ────────────────────
edits.append((
    "Q. 手動新增 dc-manual-context 改動態選單",
"""      <div>
        <label style="font-size:12px;color:var(--label);display:block;margin-bottom:4px">Context</label>
        <select id="dc-manual-context" class="settings-select" style="width:100%;box-sizing:border-box">
          <option value="default">default（分機撥出）</option>
          <option value="public">public（外線來電）</option>
        </select>
      </div>""",
"""      <div>
        <label style="font-size:12px;color:var(--label);display:block;margin-bottom:4px">Context</label>
        <select id="dc-manual-context" class="settings-select" style="width:100%;box-sizing:border-box" onchange="_dcHandleContextChange(this)">
          ${_dcContextOptionsHtml('default')}
        </select>
      </div>""",
))

# ── 套用：先全部檢查，任何一項對不上就中止，不寫入檔案 ──────────────────────
failures = []
already_applied = []
to_apply = []

for label, old, new in edits:
    if new in content:
        already_applied.append(label)
        continue
    count = content.count(old)
    if count == 1:
        to_apply.append((label, old, new))
    else:
        failures.append((label, count))

if failures:
    print("❌ 以下項目比對失敗，未寫入任何檔案：", file=sys.stderr)
    for label, count in failures:
        print(f"   - {label}：找到 {count} 次（預期剛好 1 次）", file=sys.stderr)
    sys.exit(1)

for label, old, new in to_apply:
    content = content.replace(old, new, 1)

with open(path, "w", encoding="utf-8") as f:
    f.write(content)

print(f"✓ 套用 {len(to_apply)} 項變更，{len(already_applied)} 項已存在略過")
for label in already_applied:
    print(f"   (已存在，略過) {label}")
for label, _, _ in to_apply:
    print(f"   (已套用) {label}")
DIALPLAN_JS_PY_EOF

if command -v node >/dev/null 2>&1; then
  node --check static/js/dialplan.js
  echo "✓ static/js/dialplan.js 語法檢查通過"
else
  echo "⚠️  找不到 node，略過 JS 語法檢查，建議手動確認"
fi

git add static/js/dialplan.js

# ════════════════════════════════════════════════════════════════════════════
# 4. Commit
# ════════════════════════════════════════════════════════════════════════════
if ! git diff --cached --quiet; then
  git commit -m "feat: Dialplan Context 切換 UI（路由規則 context 篩選/總覽下鑽 + 自定義 Dialplan 建立新 context）"
else
  echo "ℹ️  沒有變更需要 commit（可能已經套用過）"
fi

echo ""
echo "════════════════════════════════════════════════════"
git log --oneline -3
echo "════════════════════════════════════════════════════"
echo ""
echo "驗證重點清單："
echo "  1. systemctl restart fs-dashboard"
echo "  2. 瀏覽器強制重新整理（Ctrl+Shift+R）載入新版 dialplan.js"
echo "  3. Dialplan 路由設定 → 路由規則 Tab："
echo "     - 篩選下拉是否顯示既有 context（只有 default 時應該跟改版前一樣直接看到表格）"
echo "     - 新增路由規則，表單是否有 Context 選單"
echo "     - 故意設定一個跟既有規則重疊的號碼樣式，確認同 context 顯示紅色阻擋、跨 context 顯示藍色參考"
echo "     - 若有多個 context，切換篩選到「全部 context」，確認卡片總覽 + 點擊下鑽 + 麵包屑返回都正常"
echo "  4. Dialplan 路由設定 → 自定義 Dialplan Tab："
echo "     - 新增（範本或手動）時 Context 選單改成讀取 /api/dialplan/contexts"
echo "     - 選「+ 建立新 context...」，輸入名稱建立，確認 /etc/freeswitch/dialplan/<新名稱>/ 資料夾確實產生，且警語有顯示"
echo "  5. journalctl -u fs-dashboard -f 確認無 500 錯誤"
echo "  6. 編輯一條既有規則，改變它的 Context 後儲存，確認："
echo "     - 舊資料夾底下的檔案消失（備份為 .bak.moved.*）"
echo "     - 新資料夾底下出現同一條規則"
echo "     - reloadxml 後撥號行為正常"
