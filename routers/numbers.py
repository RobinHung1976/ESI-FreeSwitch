"""
routers/numbers.py — 整合分機／群組／IVR／自定義 dialplan／保留號碼的號碼地圖：/api/numbers
"""
import os
import glob
from fastapi import APIRouter, Depends
from lxml import etree

from core.constants import FS_RESERVED
from routers.extensions import EXT_DIR
from routers.groups import GROUP_DIR, _read_group_meta
from routers.ivr import IVR_DIALPLAN_DIR, _read_ivr_meta
from core.auth import require_permission
from core.permissions import Module

router = APIRouter()


# ════════════════════════════════════════════════════════════════════════════════
# 號碼目錄（Number Map）
# ════════════════════════════════════════════════════════════════════════════════
#
# GET /api/numbers
#   整合所有號碼來源：
#   1. Dashboard 管理的分機 / 群組 / IVR（從現有 XML 讀取）
#   2. 全 Dialplan 掃描（找出非 Dashboard 管理的自定義 extension）
#   3. FreeSwitch 內建保留號碼（硬編碼）
# ════════════════════════════════════════════════════════════════════════════════

# FreeSwitch 內建保留號碼（vanilla config）


DIALPLAN_DIRS = [
    "/etc/freeswitch/dialplan/default",
    "/etc/freeswitch/dialplan/public",
    "/etc/freeswitch/dialplan",
]

def _scan_dialplan_numbers(known_files: set) -> list:
    """掃描全 Dialplan 目錄，找出非 Dashboard 管理的自定義 extension"""
    import re as _re
    results = []
    seen_files = set()

    for dp_dir in DIALPLAN_DIRS:
        if not os.path.isdir(dp_dir):
            continue
        for fname in sorted(os.listdir(dp_dir)):
            if not fname.endswith('.xml'):
                continue
            fpath = os.path.join(dp_dir, fname)
            if fpath in seen_files or fpath in known_files:
                continue
            seen_files.add(fpath)
            try:
                with open(fpath, 'r', encoding='utf-8', errors='ignore') as f:
                    content = f.read()

                # 跳過 Dashboard 管理的檔案（有特定 META 標記）
                if any(tag in content for tag in [
                    'DASHBOARD_GROUP_META',
                    'DASHBOARD_IVR_META',
                ]):
                    continue

                # 抓取 extension name 和 destination_number expression
                ext_blocks = _re.findall(
                    r'<extension\s+name=["\']([^"\']+)["\'][^>]*>.*?'
                    r'destination_number["\'][^"\']*["\'][^"\']*expression=["\']([^"\']+)["\']',
                    content, _re.DOTALL
                )
                if not ext_blocks:
                    # 嘗試另一種屬性順序
                    ext_blocks = _re.findall(
                        r'<extension\s+name=["\']([^"\']+)["\'].*?'
                        r'expression=["\']([^"\']+)["\']',
                        content, _re.DOTALL
                    )

                context = 'default'
                if '/public' in fpath:
                    context = 'public'

                for ext_name, expr in ext_blocks:
                    # 嘗試從 regex 提取簡單號碼
                    clean = expr.strip('^$').replace('\\d', 'N')
                    results.append({
                        "number":   clean,
                        "type":     "custom",
                        "name":     ext_name,
                        "owner":    f"自定義 Dialplan",
                        "context":  context,
                        "file":     fname,
                        "detail":   f"來自 {fpath}",
                    })
            except Exception:
                pass

    return results


@router.get("/api/numbers", dependencies=[Depends(require_permission(Module.NUMBERS, "read"))])
def list_numbers():
    """整合所有號碼來源，回傳完整號碼地圖"""
    numbers = []
    known_files = set()

    # ── 1. 分機 ────────────────────────────────────────────────────────────────
    try:
        for fpath in sorted(glob.glob(f"{EXT_DIR}/*.xml")):
            known_files.add(fpath)
            try:
                tree = etree.parse(fpath)
                user = tree.find('.//user')
                if user is None:
                    continue
                uid  = user.get('id', '')
                params = {p.get('name'): p.get('value')
                          for p in tree.findall('.//param')}
                variables = {v.get('name'): v.get('value')
                             for v in tree.findall('.//variable')}
                numbers.append({
                    "number":  uid,
                    "type":    "extension",
                    "name":    params.get('effective_caller_id_name') or
                               variables.get('effective_caller_id_name') or uid,
                    "owner":   "分機管理",
                    "context": "default",
                    "file":    os.path.basename(fpath),
                    "detail":  f"分機 {uid}",
                })
            except Exception:
                pass
    except Exception:
        pass

    # ── 2. 群組 ────────────────────────────────────────────────────────────────
    try:
        for pattern in [f"{GROUP_DIR}/00_group_*.xml", f"{GROUP_DIR}/group_*.xml"]:
            for fpath in sorted(glob.glob(pattern)):
                if fpath in known_files:
                    continue
                known_files.add(fpath)
                meta = _read_group_meta(fpath)
                if not meta:
                    continue
                members_str = '、'.join(meta.get('members', []))
                numbers.append({
                    "number":  meta['id'],
                    "type":    "group",
                    "name":    meta.get('name') or f"群組 {meta['id']}",
                    "owner":   "分機群組",
                    "context": meta.get('context', 'default'),
                    "file":    os.path.basename(fpath),
                    "detail":  f"成員：{members_str or '（無）'}｜策略：{meta.get('strategy','simultaneous')}",
                })
    except Exception:
        pass

    # ── 3. IVR ─────────────────────────────────────────────────────────────────
    try:
        for fpath in sorted(glob.glob(f"{IVR_DIALPLAN_DIR}/00_ivr_*.xml")):
            known_files.add(fpath)
            meta = _read_ivr_meta(fpath)
            if not meta:
                continue
            if not meta.get('number'):
                continue  # 子選單無入口號碼，不列入
            key_count = len(meta.get('keys', {}))
            sched_str = '已啟用時段路由' if (meta.get('schedule') or {}).get('enabled') else ''
            numbers.append({
                "number":  meta['number'],
                "type":    "ivr",
                "name":    meta.get('name') or meta['id'],
                "owner":   "IVR 管理",
                "context": meta.get('context', 'default'),
                "file":    os.path.basename(fpath),
                "detail":  f"IVR ID：{meta['id']}｜{key_count} 個按鍵" + (f"｜{sched_str}" if sched_str else ''),
            })
    except Exception:
        pass

    # ── 4. 自定義 Dialplan 掃描 ────────────────────────────────────────────────
    try:
        custom = _scan_dialplan_numbers(known_files)
        numbers.extend(custom)
    except Exception:
        pass

    # ── 5. FreeSwitch 內建保留號碼 ─────────────────────────────────────────────
    numbers.extend(FS_RESERVED)

    # ── 排序：數字在前（按號碼升冪），非數字在後 ───────────────────────────────
    def sort_key(n):
        num = n['number']
        try:
            return (0, int(num), num)
        except Exception:
            return (1, 0, num)

    numbers.sort(key=sort_key)

    # 統計
    type_counts = {}
    for n in numbers:
        t = n['type']
        type_counts[t] = type_counts.get(t, 0) + 1

    return {
        'numbers':     numbers,
        'total':       len(numbers),
        'type_counts': type_counts,
    }
