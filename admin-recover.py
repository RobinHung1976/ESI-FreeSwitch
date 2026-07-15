#!/usr/bin/env python3
"""
admin-recover.py — 緊急救援工具:忘記所有 System Admin 密碼時使用

⚠️ 這支腳本會完全繞過 HTTP API / JWT 驗證,直接呼叫後端 core/auth_db.py
   的內部函式操作 SQLite(/opt/fs-dashboard/data/auth.db)。

⚠️ 使用前提:你必須已經有伺服器本機或 SSH shell 存取權限。
   能執行這支腳本,本身就等同於已經是「有權操作這台伺服器」的人 ——
   這是刻意設計成「只有能碰到主機檔案系統的人才能救援」,
   而不是任何知道帳號的人都能透過網路重設,避免變成另一個攻擊面。

⚠️ 請務必先備份 auth.db 再執行:
   cp /opt/fs-dashboard/data/auth.db /opt/fs-dashboard/data/auth.db.bak.$(date +%Y%m%d_%H%M%S)

用法:
    cd /opt/fs-dashboard   # 專案根目錄,確保 core/ 在 PYTHONPATH 下
    python3 admin-recover.py
"""
import sys
import getpass

# 確保能 import 到專案的 core 模組;若你的專案路徑不同,修改這行
sys.path.insert(0, ".")

try:
    import core.auth_db as auth_db
except ImportError:
    print("❌ 找不到 core.auth_db,請確認是否在專案根目錄(/opt/fs-dashboard)下執行本腳本。")
    sys.exit(1)


def main():
    print("=== 緊急密碼救援工具 ===")
    print("⚠️  本工具直接操作資料庫,略過所有登入驗證,請確認你有權限這麼做。\n")

    confirm = input("是否已經備份過 auth.db? [y/N]: ").strip().lower()
    if confirm != "y":
        print("請先備份再執行:")
        print("  cp /opt/fs-dashboard/data/auth.db /opt/fs-dashboard/data/auth.db.bak.$(date +%Y%m%d_%H%M%S)")
        sys.exit(0)

    auth_db.init_db()  # 確保表格存在,不會覆蓋既有資料

    result = auth_db.list_users()
    rows = result.get("rows", result) if isinstance(result, dict) else result

    if not rows:
        print("⚠️  目前資料庫沒有任何使用者。若是全新環境,應該呼叫 bootstrap 而不是本腳本。")
        sys.exit(1)

    print("\n目前所有使用者(原始欄位,未做欄位假設):\n")
    for row in rows:
        print("-" * 40)
        for k, v in row.items():
            print(f"  {k}: {v}")
    print("-" * 40)

    target_id = input("\n請輸入要重設密碼的使用者 ID: ").strip()
    try:
        target_id_int = int(target_id)
    except ValueError:
        print("❌ ID 必須是數字")
        sys.exit(1)

    matched = [r for r in rows if str(r.get("id")) == str(target_id_int)]
    if not matched:
        print(f"❌ 找不到 ID={target_id_int} 的使用者")
        sys.exit(1)

    print(f"\n即將重設使用者: {matched[0]}")

    new_password = getpass.getpass("請輸入新密碼(至少 8 碼): ")
    new_password_confirm = getpass.getpass("請再次輸入確認: ")
    if new_password != new_password_confirm:
        print("❌ 兩次輸入的密碼不一致")
        sys.exit(1)
    if len(new_password) < 8:
        print("❌ 密碼長度需至少 8 碼")
        sys.exit(1)

    force_choice = input("重設後是否強制下次登入改密碼? [Y/n]: ").strip().lower()
    force_change = force_choice != "n"

    try:
        # 直接呼叫後端同一套函式,雜湊邏輯與 API 完全一致
        auth_db.reset_password(target_id_int, new_password, force_change=force_change)
    except Exception as e:
        print(f"❌ 重設失敗: {e}")
        sys.exit(1)

    print("\n✅ 密碼已重設成功。")
    print("建議接下來:")
    print("  1. 用新密碼登入,確認可以正常進入系統")
    print("  2. 檢查是否需要重啟服務(通常不需要,JWT/密碼查詢皆即時查 DB)")
    print("  3. 事後檢討為何會走到需要用本工具救援的地步(例如密碼保管流程)")


if __name__ == "__main__":
    main()
