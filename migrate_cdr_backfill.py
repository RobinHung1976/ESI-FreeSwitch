"""
migrate_cdr_backfill.py — 一次性搬遷腳本：把現有 Master.csv + 已歸檔的 cdr-YYYY-MM-DD.csv
匯入新的 SQLite（core/cdr_db.py），並為每個歸檔日期建立 cdr_daily_summary。

部署 SQLite 版本後，在 /opt/fs-dashboard 執行一次：
    cd /opt/fs-dashboard
    python3 migrate_cdr_backfill.py

冪等：可重複執行，不會產生重複資料（uuid 去重），summary 會覆蓋重算。
"""
import os
import sys
import glob

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from core import cdr_db
from core.runtime import CDR_DIR, CDR_MASTER


def main():
    cdr_db.init_db()
    print(f"[migrate] DB 初始化完成：{cdr_db.DB_PATH}")

    # 1) 今天尚未歸檔的 Master.csv
    n = cdr_db.import_csv_file(CDR_MASTER)
    print(f"[migrate] Master.csv（今日）匯入 {n} 筆新資料")

    # 2) 已歸檔的歷史 CDR CSV
    pattern = os.path.join(CDR_DIR, "cdr-????-??-??.csv")
    archive_files = sorted(glob.glob(pattern))
    if not archive_files:
        print("[migrate] 沒有找到歷史歸檔 CDR 檔案")
    total_imported = 0
    for path in archive_files:
        basename = os.path.basename(path)
        date_str = basename.replace("cdr-", "").replace(".csv", "")
        n = cdr_db.import_csv_file(path)
        total_imported += n
        summary = cdr_db.build_daily_summary(date_str)
        print(f"[migrate] {basename}: 匯入 {n} 筆，彙總 total={summary['total']} "
              f"answered={summary['answered']} no_answer={summary['no_answer']} busy={summary['busy']}")

    print(f"[migrate] 完成。歷史檔案共匯入 {total_imported} 筆，"
          f"已建立 {len(archive_files)} 天的每日彙總（cdr_daily_summary，長期保留）。")
    print("[migrate] 提醒：raw 明細仍受 cdr_retain_days 保留期限制，"
          "下次排程 cleanup 執行時會依設定清除範圍外的 raw 明細（彙總不受影響）。")


if __name__ == "__main__":
    main()
