"""
Dialplan 共用機制
================
供類型一（外撥路由 dialplan_routes.py）、類型二（系統內建唯讀）、
類型三（自定義 XML 編輯器）三個 dialplan 模組共用。

只放「與檔案類型無關」的機制：ESL 連線注入、reloadxml 驗證＋自動 rollback、
統一的備份檔命名。

刻意不放的東西：
  build_regex() / find_conflicts() 這類「外撥路由規則」特有的號碼樣式比對邏輯，
  不搬進來。類型三的模板（時段路由、黑名單）語意跟「destination_number → bridge
  gateway」完全不同，硬共用會讓之後想改比對邏輯時綁手綁腳。
"""

import os
import shutil
from lxml import etree 
from datetime import datetime

from fastapi import HTTPException

# 延遲匯入避免循環依賴：esl 物件由 server.py 於啟動時注入一次，
# 三個 dialplan 模組（routes / system_extensions / custom）共用同一顆連線。
_esl = None


def init_esl(esl_instance) -> None:
    global _esl
    _esl = esl_instance


def make_backup(filepath: str, suffix: str = "bak") -> str:
    """建立時間戳備份檔並回傳備份路徑。

    filepath 不存在時（理論上不該發生，呼叫端應先檢查）會直接讓
    shutil.copy2 拋出 FileNotFoundError，不吞掉例外——備份失敗不該被靜默略過。

    suffix: 預設 'bak'；legacy 升級等需要區分用途的情境可傳 'bak.upgraded'。
    """
    backup_path = f"{filepath}.{suffix}.{datetime.now().strftime('%Y%m%d_%H%M%S')}"
    shutil.copy2(filepath, backup_path)
    return backup_path
    
def validate_xml(content: str) -> None:
    """共用 XML 語法驗證，raw editor 與範本產生器都呼叫這支，不要各自 try/except。"""
    try:
        etree.fromstring(content.encode("utf-8"))
    except Exception as xe:
        raise HTTPException(status_code=400, detail=f"XML 語法錯誤：{xe}")   
        

def reload_and_verify(target_filepath: str, backup_path: str) -> str:
    """執行 reloadxml 並驗證結果，失敗時自動 rollback。

    - 成功（+OK）：回傳 ESL 結果字串，呼叫端不需要額外處理。
    - 失敗（-ERR 或 ESL 例外）：
        1. 若有 backup_path 且檔案存在，還原回 target_filepath
        2. 還原後再 reloadxml 一次，讓 FreeSwitch 回到正常狀態
        3. 拋出 HTTPException(500)，由呼叫端的路由函式往外傳給前端

    target_filepath: 剛剛寫入/移除的那個 XML 檔路徑（rollback 的還原目標）。
    backup_path:     儲存前的 .bak 備份路徑；空字串代表沒有舊版本可還原
                      （典型情境是「新增」，此時失敗後應由呼叫端自行刪除
                      剛建立的新檔，這裡只負責 reload 驗證本身）。
    """
    if _esl is None:
        # 沒有 ESL 連線（例如測試環境）——靜默跳過，不做 rollback
        return "+OK [no ESL, skipped]"

    try:
        result = _esl.api("reloadxml")
    except Exception as e:
        result = f"-ERR ESL exception: {e}"

    if result.startswith("-ERR") or "error" in result.lower():
        rollback_ok = False
        try:
            if backup_path and os.path.exists(backup_path):
                shutil.copy2(backup_path, target_filepath)
                rollback_ok = True
        except Exception:
            pass

        # 還原後再 reload 一次，讓 FreeSwitch 載回舊版設定
        try:
            _esl.api("reloadxml")
        except Exception:
            pass

        if rollback_ok:
            raise HTTPException(
                status_code=500,
                detail=(
                    f"FreeSwitch reloadxml 失敗：{result}。\n"
                    "已自動還原備份檔並重新載入，系統維持原本設定，請確認您的 dialplan 設定後再試一次。"
                ),
            )
        else:
            raise HTTPException(
                status_code=500,
                detail=(
                    f"FreeSwitch reloadxml 失敗：{result}。\n"
                    "⚠️ 備份還原也失敗，請立即手動至伺服器確認 dialplan 狀態！\n"
                    f"備份檔位置：{backup_path or '(無備份)'}"
                ),
            )

    return result


def force_reload() -> None:
    """靜默呼叫一次 reloadxml，吞掉所有例外。

    用於「呼叫端已經自行完成檔案層級的 rollback（例如升級流程要同時處理
    legacy 檔案還原＋新檔案刪除，邏輯比 reload_and_verify 內建的單檔案還原
    複雜），只需要 FreeSwitch 重新載入一次」的情境。不回傳結果、不拋例外，
    因為呼叫端此時通常已經在自己的錯誤處理路徑上，不該再被這裡的失敗打斷。
    """
    if _esl is None:
        return
    try:
        _esl.api("reloadxml")
    except Exception:
        pass


def rollback_new_file(filepath: str) -> None:
    """「新增」情境專用的 rollback：沒有備份可還原，直接刪除剛建立的半成品檔案
    並重新 reloadxml。給 create_route / 類型三的新增端點在
    reload_and_verify() 拋出 HTTPException 之後的 except 區塊呼叫。

    內部吞掉所有例外——這是失敗後的清理動作，本身再失敗也不該蓋掉原本
    要往外拋的 500 錯誤。
    """
    try:
        if os.path.exists(filepath):
            os.remove(filepath)
    except Exception:
        pass
    force_reload()
