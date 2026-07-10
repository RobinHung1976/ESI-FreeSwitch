"""
Dialplan 系統內建 Extension（類型二：唯讀檢視）
================================================
解析 default.xml / public.xml 裡 FreeSwitch 原廠內建的 extension，
搭配靜態說明對照表回傳白話說明。不提供任何寫入 API——這些 extension
本身不該被改，使用者需要的只是「知道這個號碼被佔用了、它在做什麼」。

與類型一的分工：
  類型一（dialplan_routes.py）管 00_route_*.xml（外撥路由規則）。
  類型二（本檔案）只讀 default.xml / public.xml，兩者互不重疊、不共用檔案掃描邏輯。
"""

import os
from typing import Optional

from fastapi import APIRouter, Depends
from lxml import etree

from core.auth import require_permission
from core.permissions import Module

router = APIRouter()

SYSTEM_XML_FILES = {
    "default": "/etc/freeswitch/dialplan/default.xml",
    "public": "/etc/freeswitch/dialplan/public.xml",
}

# 白話說明對照表：key 用 extension 的 name 屬性，不是號碼——
# default.xml 裡大量 extension 對應的是「號碼範圍」或「正規式功能碼」
# （例如 Local_Extension 對應 1000–1999，park 對應 park+N 這種樣式），
# 用單一號碼當 key 涵蓋不了。
#
# 找不到對照的 extension 仍會被列出（description=None），前端顯示「尚無說明」
# 並提示可展開查看原始 XML，而不是嘗試動態解析生成說明文字——
# 動態生成的說明不可靠，寧可讓使用者自己看原始碼判斷。
DEFAULT_EXT_DESCRIPTIONS: dict[str, str] = {
    # ── 測試音訊 / 除錯 ──────────────────────────────────────────────
    "echo": "回音測試：撥打後聽到自己的聲音",
    "delay_echo": "延遲回音測試（5 秒後聽到自己的聲音）",
    "milliwatt": "音量基準測試音（1004Hz 測試音）",
    "tone_stream": "播放自訂音效測試",
    "hold_music": "等待音樂測試（需搭配 SRTP 加密才會播放）",
    "show_info": "顯示目前通話詳細資訊（除錯用）",
    "video_record": "視訊錄製測試",
    "video_playback": "視訊播放測試",
    "laugh break": "播放趣味語音片段（示範用）",
    "wait": "測試用：播放等待音樂後掛斷",
    "ClueCon": "FreeSwitch ClueCon 研討會示範 IVR（會外連網際網路）",
    # ── 傳真 ────────────────────────────────────────────────────────
    "fax_receive": "傳真接收測試",
    "fax_transmit": "傳真發送測試",
    # ── 回鈴音示範 ───────────────────────────────────────────────────
    "ringback_180": "回鈴音示範（180 Ringing，早期媒體）",
    "ringback_183_uk_ring": "回鈴音示範（183，英式鈴聲）",
    "ringback_183_music_ring": "回鈴音示範（183，音樂鈴聲）",
    "ringback_post_answer_uk_ring": "接聽後鈴聲示範（英式鈴聲）",
    "ringback_post_answer_music": "接聽後鈴聲示範（音樂鈴聲）",
    # ── 通話控制功能碼 ───────────────────────────────────────────────
    "eavesdrop": "監聽通話（依 spymap 或全域，需搭配權限使用）",
    "call_return": "回撥上一通來電（*69 / 869）",
    "del-group": "將自己從振鈴群組移除",
    "add-group": "將自己加入振鈴群組",
    "call-group-simo": "同時振鈴群組所有成員",
    "call-group-order": "依順序振鈴群組成員",
    "extension-intercom": "對講機模式直接接通分機（自動應答，不響鈴）",
    "operator": "接線總機（轉接到分機 1000）",
    "vmain": "語音信箱主選單（4000 / *98）",
    "rtp_multicast_page": "多點廣播對講（Page Group）",
    "park": "通話停駐（Call Park），依撥打方式對應 5900 或 park+號碼",
    "unpark": "取回停駐通話，依撥打方式對應 5901、parking、pickup",
    "valet_park": "代客停車式停駐（Valet Park，6000 為入口，6001–6099 為車位）",
    # ── 分機 / 群組撥打 ──────────────────────────────────────────────
    "Local_Extension": "一般分機（1000–1999），含轉接/錄音/來電轉接等按鍵功能",
    "Local_Extension_Skinny": "Skinny 協定分機（1100–1119）",
    "group_dial_sales": "撥打業務群組（2000）",
    "group_dial_support": "撥打客服群組（2001）",
    "group_dial_billing": "撥打帳務群組（2002）",
    "public_extensions": "外線來電轉接內部分機（1000–1019）",
    # ── 會議室 ──────────────────────────────────────────────────────
    "ivr_demo": "FreeSwitch 內建示範 IVR（5000）",
    "dynamic_conference": "動態建立會議室並外連測試"
        "（⚠ 會外連 conference.freeswitch.org，曾導致 NORMAL_TEMPORARY_FAILURE）",
    "nb_conferences": "窄頻語音會議室（3000–3099）",
    "wb_conferences": "寬頻語音會議室（3100–3199）",
    "uwb_conferences": "超寬頻語音會議室（3200–3299）",
    "cdquality_conferences": "CD 音質會議室（3300–3399，或視訊版）",
    "cdquality_stereo_conferences": "立體聲視訊會議畫面切換",
    "conference-canvases": "視訊會議子畫布切換",
    "conf mod": "會議室主持人模式（6070-moderator）",
    "cdquality_conferences_720": "720p 視訊會議室（3600–3699）",
    "cdquality_conferences_480": "480p 視訊會議室（3700–3799）",
    "cdquality_conferences_320": "320p 視訊會議室（3800–3899）",
    "freeswitch_public_conf_via_sip": "FreeSwitch 官方公開會議室（外連 conference.freeswitch.org）",
    "public_conference_extensions": "外線來電轉接內部會議室（35xx 系列）",
    "mad_boss_intercom": "老闆對講機自動撥出功能（官方示範用）",
    "mad_boss_intercom2": "老闆對講機自動撥出功能（官方示範用，版本二）",
    "mad_boss": "老闆會議自動撥出功能（官方示範用）",
    # ── 攔截 / 重播 ──────────────────────────────────────────────────
    "global-intercept": "全域攔截：接聽最近一通被轉接/漏接的來電（886）",
    "group-intercept": "攔截同群組正在響鈴的來電（*8）",
    "intercept-ext": "攔截指定分機正在響鈴的來電（**分機號碼）",
    "redial": "重播上一次撥出的號碼（redial / 870）",
    # ── 保底 catch-all（比對到 .* ，容易誤判成故障，特別註記）───────────
    "enum": "ENUM 撥號查詢：僅在啟用 mod_enum 時生效，攔截所有未命中前面規則的號碼",
    "acknowledge_call": "保底 catch-all：其他規則都沒命中時，播放等待音樂並應答，"
        "避免真正無人處理時呼叫端逾時掛斷",
}


def _parse_system_extensions(filepath: str, context: str) -> list[dict]:
    """解析單一 dialplan 檔案，回傳所有「有 destination_number 條件」的 extension。

    沒有 destination_number 條件的 extension（例如 unloop、global 這類系統內部
    保護機制，不是使用者會撥打的號碼）直接略過，不列入結果。
    """
    if not os.path.isfile(filepath):
        return []
    try:
        tree = etree.parse(filepath)
    except Exception:
        return []

    result = []
    for idx, ext in enumerate(tree.findall(".//extension")):
        name = ext.get("name", f"ext_{idx}")

        dest_expr: Optional[str] = None
        for cond in ext.findall("condition"):
            field = (cond.get("field") or "").strip()
            if field == "destination_number":
                dest_expr = cond.get("expression", "")
                break
        if dest_expr is None:
            continue

        raw_xml = etree.tostring(ext, pretty_print=True, encoding="unicode")

        result.append({
            # 同名 extension 在同一檔案內可能出現多次（如 park/unpark 依廠牌各寫一份），
            # 用 "context:name:idx" 保證前端列表 key 唯一。
            "id": f"{context}:{name}:{idx}",
            "context": context,
            "name": name,
            "destination_number": dest_expr,
            "description": DEFAULT_EXT_DESCRIPTIONS.get(name),
            "raw_xml": raw_xml,
        })
    return result


@router.get("/api/dialplan/system-extensions", dependencies=[Depends(require_permission(Module.DIALPLAN, "read"))])
def list_system_extensions():
    """列出 default.xml / public.xml 的內建 extension（唯讀）。

    刻意只提供這一個 GET 端點，沒有任何寫入路由——
    這是防止誤改系統內建 extension 的第一道防線，比前端隱藏編輯按鈕更可靠。
    """
    by_context = {
        context: _parse_system_extensions(filepath, context)
        for context, filepath in SYSTEM_XML_FILES.items()
    }
    total = sum(len(v) for v in by_context.values())
    described = sum(
        1 for exts in by_context.values() for e in exts if e["description"]
    )
    return {
        "extensions": by_context,
        "total": total,
        "described": described,
    }
