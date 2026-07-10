"""
routers/sounds.py — 音檔庫（自訂上傳音檔 + 系統內建音檔）：/api/sounds*
"""
import os
import json
import glob
import re as _re
from fastapi import APIRouter, HTTPException, Query, UploadFile, File, Depends
from fastapi.responses import FileResponse

from core.constants import IVR_SOUNDS_DIR, IVR_MENU_DIR
from core.auth import require_permission
from core.permissions import Module

router = APIRouter()


# ════════════════════════════════════════════════════════════════════════════════
# 音檔庫（Sound Library）— 統一管理自訂上傳音檔 + 系統內建音檔
# ════════════════════════════════════════════════════════════════════════════════
#
# 自訂音檔：/var/lib/freeswitch/sounds/custom/（可上傳/刪除/試聽）
# 系統內建：/usr/share/freeswitch/sounds/ 下各分類資料夾（唯讀，可試聽）
#
# 沿用 IVR_SOUNDS_DIR 作為自訂音檔目錄，讓 IVR／分機／語音信箱等功能共用同一份檔案，
# 避免重複實作上傳邏輯、也避免各處檔案各放各的造成混亂。

SOUND_EXTS = ('.wav', '.mp3', '.ogg', '.gsm')

# 系統內建語音／音樂根目錄（路徑 → 顯示名稱）。
# 實際機器上確認過的目錄為：en, es, fr, music, pt, ru（無 zh，依現場 ls 結果調整）。
# 這些根目錄底下還會分語者/取樣率/功能子目錄（例如 en/us/callie/ivr/8000），
# 故改用遞迴掃描而非假設固定子路徑，較不易因版本差異而抓不到檔案。
BUILTIN_SOUND_ROOTS = [
    ('/usr/share/freeswitch/sounds/en',    '英文提示音'),
    ('/usr/share/freeswitch/sounds/es',    '西班牙文提示音'),
    ('/usr/share/freeswitch/sounds/fr',    '法文提示音'),
    ('/usr/share/freeswitch/sounds/pt',    '葡萄牙文提示音'),
    ('/usr/share/freeswitch/sounds/ru',    '俄文提示音'),
    ('/usr/share/freeswitch/sounds/music', '保留音樂（MOH）'),
]
BUILTIN_LIST_LIMIT = 200   # 每個分類最多列出幾筆，避免內建音檔過多拖慢頁面
BUILTIN_SCAN_DEPTH = 6     # 遞迴掃描深度上限，對應如 en/us/callie/ivr/8000/ 這類深度


def _safe_sound_filename(filename: str) -> bool:
    """檔名只允許英數字、底線、連字號、空白、點，且副檔名須在白名單內"""
    return bool(_re.match(r'^[\w\-. ]+\.(wav|mp3|ogg|gsm)$', filename, _re.IGNORECASE))


def _scan_builtin_sounds(base: str, label: str, limit: int) -> list:
    """遞迴掃描內建音檔根目錄，回傳最多 limit 筆音檔（依檔名排序）"""
    found = []
    base_depth = base.rstrip('/').count('/')
    for root, dirs, files in os.walk(base):
        if root.rstrip('/').count('/') - base_depth > BUILTIN_SCAN_DEPTH:
            dirs[:] = []
            continue
        for fname in sorted(files):
            if fname.lower().endswith(SOUND_EXTS):
                fp = os.path.join(root, fname)
                found.append({
                    'filename': fname, 'path': fp, 'category': label,
                    'size': os.path.getsize(fp), 'source': 'builtin',
                })
                if len(found) >= limit:
                    return found
    return found


@router.get("/api/sounds/list", dependencies=[Depends(require_permission(Module.SOUNDS, "read"))])
def list_sound_library(category: str = Query(default="all")):
    """
    列出音檔庫所有音檔。
    category: "all"（預設）| "custom" | 或 BUILTIN_SOUND_ROOTS 中的路徑
    """
    sounds = []

    if category in ("all", "custom") and os.path.isdir(IVR_SOUNDS_DIR):
        for fname in sorted(os.listdir(IVR_SOUNDS_DIR)):
            if fname.lower().endswith(SOUND_EXTS):
                fp = os.path.join(IVR_SOUNDS_DIR, fname)
                sounds.append({
                    'filename': fname, 'path': fp, 'category': '自訂音檔',
                    'size': os.path.getsize(fp), 'source': 'custom',
                })

    roots_by_path = dict(BUILTIN_SOUND_ROOTS)
    if category in ("all",) or category in roots_by_path:
        roots = BUILTIN_SOUND_ROOTS if category == "all" else [(category, roots_by_path[category])]
        for base, label in roots:
            if not os.path.isdir(base):
                continue
            sounds.extend(_scan_builtin_sounds(base, label, BUILTIN_LIST_LIMIT))

    return {'sounds': sounds, 'total': len(sounds),
             'categories': [{'path': p, 'label': l} for p, l in BUILTIN_SOUND_ROOTS]}


@router.post("/api/sounds/upload", dependencies=[Depends(require_permission(Module.SOUNDS, "create"))])
async def upload_sound(file: UploadFile = File(...)):
    """上傳自訂音檔到音檔庫（建議 8kHz 16bit Mono WAV，相容 FreeSwitch 播放品質）"""
    if not file.filename.lower().endswith(SOUND_EXTS):
        raise HTTPException(status_code=400, detail="只接受 WAV/MP3/OGG/GSM 格式")
    if not _safe_sound_filename(file.filename):
        raise HTTPException(status_code=400, detail="檔名僅允許英數字、底線、連字號、空白與副檔名")

    os.makedirs(IVR_SOUNDS_DIR, exist_ok=True)
    dest = os.path.join(IVR_SOUNDS_DIR, file.filename)
    if os.path.exists(dest):
        raise HTTPException(status_code=409, detail=f"檔名 {file.filename} 已存在，請先刪除或改名後再上傳")

    content = await file.read()
    MAX_SOUND_BYTES = 20 * 1024 * 1024  # 20MB 上限，避免誤傳大檔塞滿磁碟
    if len(content) > MAX_SOUND_BYTES:
        raise HTTPException(status_code=400, detail="檔案過大（上限 20MB）")

    with open(dest, 'wb') as f:
        f.write(content)
    return {'ok': True, 'filename': file.filename, 'path': dest, 'size': len(content)}


@router.get("/api/sounds/usage", dependencies=[Depends(require_permission(Module.SOUNDS, "read"))])
def sound_usage(filename: str = Query(...)):
    """
    查詢某個自訂音檔目前被哪些 IVR 選單引用，避免刪除仍在使用中的音檔。
    僅掃描 IVR JSON 設定（分機/語音信箱若未來也使用音檔庫，可在此擴充掃描範圍）。
    """
    if not _safe_sound_filename(filename):
        raise HTTPException(status_code=400, detail="檔名格式不正確")

    full_path = os.path.join(IVR_SOUNDS_DIR, filename)
    used_by = []
    try:
        for fpath in glob.glob(f"{IVR_MENU_DIR}/*.json"):
            try:
                with open(fpath, 'r', encoding='utf-8') as f:
                    ivr_data = json.load(f)
                blob = json.dumps(ivr_data, ensure_ascii=False)
                if filename in blob or full_path in blob:
                    used_by.append({
                        'type': 'ivr',
                        'id': ivr_data.get('id', os.path.basename(fpath)),
                        'name': ivr_data.get('name', ''),
                    })
            except Exception:
                continue
    except Exception:
        pass

    return {'filename': filename, 'used_by': used_by, 'in_use': len(used_by) > 0}


@router.delete("/api/sounds/{filename}", dependencies=[Depends(require_permission(Module.SOUNDS, "delete"))])
def delete_sound(filename: str, force: bool = Query(default=False)):
    """
    刪除自訂音檔。預設會先檢查是否被 IVR 引用中，若有引用且 force=false 則拒絕刪除，
    避免刪掉正在使用的音檔導致播放失敗。
    """
    if not _safe_sound_filename(filename):
        raise HTTPException(status_code=400, detail="檔名格式不正確")

    path = os.path.join(IVR_SOUNDS_DIR, filename)
    if not os.path.isfile(path):
        raise HTTPException(status_code=404, detail="檔案不存在")

    if not force:
        usage = sound_usage(filename)
        if usage['in_use']:
            names = '、'.join(u.get('name') or u.get('id', '') for u in usage['used_by'])
            raise HTTPException(
                status_code=409,
                detail=f"此音檔仍被使用中（{names}），請先於該處更換音檔，或加上 force=true 強制刪除"
            )

    os.remove(path)
    return {'ok': True}


@router.get("/api/sounds/stream", dependencies=[Depends(require_permission(Module.SOUNDS, "read"))])
async def stream_sound(path: str):
    """串流播放音檔（試聽用）。僅允許音檔庫範圍內的路徑，防止任意檔案讀取"""
    allowed = [IVR_SOUNDS_DIR, '/usr/share/freeswitch/sounds/']
    if not any(path.startswith(d) for d in allowed):
        raise HTTPException(status_code=403, detail="不允許存取此路徑")
    if not os.path.isfile(path):
        raise HTTPException(status_code=404, detail="檔案不存在")
    ext = path.rsplit('.', 1)[-1].lower()
    media_map = {'wav': 'audio/wav', 'mp3': 'audio/mpeg', 'ogg': 'audio/ogg', 'gsm': 'audio/gsm'}
    return FileResponse(path, media_type=media_map.get(ext, 'audio/octet-stream'),
                        headers={"Accept-Ranges": "bytes", "Cache-Control": "no-cache"})
