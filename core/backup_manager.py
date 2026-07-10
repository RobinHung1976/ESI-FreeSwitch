"""
backup_manager.py — FreeSwitch Dashboard 備份/還原核心模組

備份分兩類：
  A) fs-dashboard config backup  → 設定檔 + Dashboard 程式碼 + restore_dashboard.sh
  B) freeswitch packages backup  → 所有 FS .deb 套件 + restore_freeswitch.sh

放置於 /opt/fs-dashboard/backup_manager.py
"""

import os
import glob
import json
import shutil
import tarfile
import tempfile
import subprocess
from datetime import datetime, timedelta
from pathlib import Path

# ── 常數 ─────────────────────────────────────────────────────────────────────

SETTINGS_FILE     = "/opt/fs-dashboard/settings.json"
DASHBOARD_DIR     = "/opt/fs-dashboard"
FS_CONFIG_DIR     = "/etc/freeswitch"
FS_SOUNDS_CUSTOM  = "/var/lib/freeswitch/sounds/custom"
FS_SCRIPTS_DIR    = "/usr/share/freeswitch/scripts"
VENV_DIR          = "/opt/myapp/venv"

DEFAULT_BACKUP_PATH         = "/opt/fs-dashboard/backups"
DEFAULT_BACKUP_RETAIN_DAYS  = 30

# ── 設定讀取 ─────────────────────────────────────────────────────────────────

def _load_settings() -> dict:
    defaults = {
        "backup_path":         DEFAULT_BACKUP_PATH,
        "backup_retain_days":  DEFAULT_BACKUP_RETAIN_DAYS,
        "backup_auto_enabled": False,
    }
    try:
        if os.path.isfile(SETTINGS_FILE):
            with open(SETTINGS_FILE, "r", encoding="utf-8") as f:
                data = json.load(f)
            return {**defaults, **data}
    except Exception:
        pass
    return defaults


def get_backup_dir() -> str:
    return _load_settings().get("backup_path", DEFAULT_BACKUP_PATH)


def get_retain_days() -> int:
    return int(_load_settings().get("backup_retain_days", DEFAULT_BACKUP_RETAIN_DAYS))


# ── 還原腳本模板 ──────────────────────────────────────────────────────────────

def _restore_freeswitch_sh() -> str:
    """產生 restore_freeswitch.sh 腳本內容（新機 Step 1）"""
    return r"""#!/bin/bash
# ============================================================
# restore_freeswitch.sh
# 在全新 Debian 機器上安裝 FreeSwitch（版本與原機一致）
# 使用方式：
#   tar xzf freeswitch-packages-YYYY-MM-DD.tar.gz
#   bash restore_freeswitch.sh
# ============================================================
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEBS_DIR="$SCRIPT_DIR/debs"

echo "======================================================"
echo " FreeSwitch 套件還原腳本"
echo " 執行時間：$(date '+%Y-%m-%d %H:%M:%S')"
echo "======================================================"

# --- 1. 前置需求 ---
echo "[Step 1] 安裝前置依賴..."
apt-get update -qq
apt-get install -y --no-install-recommends \
    libssl3 libcurl4 libsqlite3-0 libedit2 libldns3 \
    liblua5.2-0 libopus0 libsndfile1 libspandsp3 \
    libpq5 libodbc2 libtiff6 libmemcached11 \
    python3 python3-venv python3-pip curl wget 2>/dev/null || true

# --- 2. 本機 .deb 安裝 ---
if [ -d "$DEBS_DIR" ] && [ "$(ls -A "$DEBS_DIR"/*.deb 2>/dev/null)" ]; then
    echo "[Step 2] 從備份套件安裝 FreeSwitch..."
    DEB_COUNT=$(ls "$DEBS_DIR"/*.deb | wc -l)
    echo "  找到 $DEB_COUNT 個 .deb 套件"

    # 先安裝 freeswitch-meta-bare（最小核心），再安裝其餘套件
    # dpkg 依賴順序：用 apt install 讀本機目錄方式處理依賴
    apt-get install -y "$DEBS_DIR"/*.deb 2>/dev/null || \
    dpkg -i "$DEBS_DIR"/*.deb || \
    apt-get install -f -y  # 修復未滿足的依賴

    echo "[Step 2] ✓ FreeSwitch 套件安裝完成"
else
    echo "[Step 2] ✗ 找不到 debs/ 目錄或無 .deb 檔案"
    echo "  請確認備份包已完整解壓縮"
    exit 1
fi

# --- 3. 確認安裝結果 ---
echo "[Step 3] 確認安裝..."
if command -v freeswitch >/dev/null 2>&1; then
    FS_VER=$(freeswitch -version 2>/dev/null | head -1 || echo "（無法取得版本）")
    echo "  ✓ FreeSwitch 已安裝：$FS_VER"
else
    echo "  ✗ freeswitch 指令不存在，安裝可能失敗"
    exit 1
fi

# --- 4. 啟動 FreeSwitch ---
echo "[Step 4] 啟動 FreeSwitch 服務..."
systemctl enable freeswitch 2>/dev/null || true
systemctl start freeswitch || true
sleep 3
systemctl status freeswitch --no-pager -l | head -20

echo ""
echo "======================================================"
echo " ✓ Step 1 完成：FreeSwitch 已安裝並啟動"
echo ""
echo " 下一步：執行 Dashboard 設定還原"
echo "   tar xzf fs-dashboard-config-YYYY-MM-DD.tar.gz"
echo "   bash restore_dashboard.sh"
echo "======================================================"
"""


def _restore_dashboard_sh() -> str:
    """產生 restore_dashboard.sh 腳本內容（新機 Step 2）"""
    return r"""#!/bin/bash
# ============================================================
# restore_dashboard.sh
# 還原 fs-dashboard 設定與程式（在 restore_freeswitch.sh 之後執行）
# 使用方式：
#   tar xzf fs-dashboard-config-YYYY-MM-DD.tar.gz
#   bash restore_dashboard.sh
# ============================================================
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "======================================================"
echo " fs-dashboard 設定還原腳本"
echo " 執行時間：$(date '+%Y-%m-%d %H:%M:%S')"
echo "======================================================"

# --- 前置確認 ---
if ! command -v freeswitch >/dev/null 2>&1; then
    echo "✗ FreeSwitch 未安裝，請先執行 restore_freeswitch.sh"
    exit 1
fi

# --- 1. Python 虛擬環境 ---
echo "[Step 1] 建立 Python 虛擬環境..."
mkdir -p /opt/myapp
python3 -m venv /opt/myapp/venv
/opt/myapp/venv/bin/pip install --upgrade pip -q

if [ -f "$SCRIPT_DIR/pip-requirements.txt" ]; then
    /opt/myapp/venv/bin/pip install -r "$SCRIPT_DIR/pip-requirements.txt" -q
    echo "  ✓ pip 套件已安裝"
else
    /opt/myapp/venv/bin/pip install fastapi uvicorn websockets lxml python-multipart -q
    echo "  ✓ 使用預設套件清單安裝"
fi

# --- 2. Dashboard 程式 ---
echo "[Step 2] 還原 Dashboard 程式..."
mkdir -p /opt/fs-dashboard/backups
if [ -d "$SCRIPT_DIR/dashboard" ]; then
    cp -r "$SCRIPT_DIR/dashboard/." /opt/fs-dashboard/
    echo "  ✓ Dashboard 檔案已複製至 /opt/fs-dashboard/"
else
    echo "  ✗ 找不到 dashboard/ 目錄"
    exit 1
fi

# --- 3. FreeSwitch 設定檔 ---
echo "[Step 3] 還原 FreeSwitch 設定..."
if [ -d "$SCRIPT_DIR/freeswitch-config" ]; then
    # 備份目前設定（以防萬一）
    if [ -d /etc/freeswitch ]; then
        BACKUP_TS=$(date +%Y%m%d_%H%M%S)
        mv /etc/freeswitch "/etc/freeswitch.pre-restore.$BACKUP_TS"
        echo "  原設定已備份至 /etc/freeswitch.pre-restore.$BACKUP_TS"
    fi
    cp -r "$SCRIPT_DIR/freeswitch-config" /etc/freeswitch
    chown -R freeswitch:freeswitch /etc/freeswitch 2>/dev/null || true
    echo "  ✓ FreeSwitch 設定已還原至 /etc/freeswitch/"
else
    echo "  ✗ 找不到 freeswitch-config/ 目錄"
    exit 1
fi

# --- 4. 自訂語音檔 ---
echo "[Step 4] 還原自訂語音檔..."
if [ -d "$SCRIPT_DIR/sounds-custom" ]; then
    mkdir -p /var/lib/freeswitch/sounds/custom
    cp -r "$SCRIPT_DIR/sounds-custom/." /var/lib/freeswitch/sounds/custom/
    chown -R freeswitch:freeswitch /var/lib/freeswitch/sounds/custom 2>/dev/null || true
    echo "  ✓ 語音檔已還原"
else
    echo "  (略過：無自訂語音檔備份)"
fi

# --- 5. Lua 腳本 ---
echo "[Step 5] 還原 Lua 腳本..."
if [ -d "$SCRIPT_DIR/scripts" ]; then
    mkdir -p /usr/share/freeswitch/scripts
    cp -r "$SCRIPT_DIR/scripts/." /usr/share/freeswitch/scripts/
    echo "  ✓ Lua 腳本已還原"
else
    echo "  (略過：無 Lua 腳本備份)"
fi

# --- 6. systemd service ---
echo "[Step 6] 安裝 systemd service..."
if [ -f "$SCRIPT_DIR/systemd/fs-dashboard.service" ]; then
    cp "$SCRIPT_DIR/systemd/fs-dashboard.service" /etc/systemd/system/
    systemctl daemon-reload
    systemctl enable fs-dashboard
    echo "  ✓ fs-dashboard.service 已安裝並啟用"
else
    echo "  (略過：無 service 檔備份)"
fi

# --- 7. 重啟服務 ---
echo "[Step 7] 重啟服務..."
systemctl restart freeswitch || true
sleep 2
systemctl restart fs-dashboard || true
sleep 2

# --- 8. 驗證 ---
echo ""
echo "[驗證] 服務狀態："
systemctl status freeswitch --no-pager -l | head -5
systemctl status fs-dashboard --no-pager -l | head -5

echo ""
echo "======================================================"
echo " ✓ 還原完成！"
echo ""
echo " 驗證清單："
echo "  1. 開啟瀏覽器 http://<新機IP>:3000"
echo "  2. 確認分機列表正常"
echo "  3. fs_cli -H 127.0.0.1 -P 8055 -p FSPyAdmin -x 'status'"
echo "  4. curl http://localhost:3000/api/settings"
echo "======================================================"
"""


# ── 備份核心函式 ──────────────────────────────────────────────────────────────

def backup_dashboard_config() -> dict:
    """
    備份 A：fs-dashboard 設定 + 程式碼
    打包內容：
      dashboard/          → /opt/fs-dashboard/
      freeswitch-config/  → /etc/freeswitch/
      sounds-custom/      → /var/lib/freeswitch/sounds/custom/
      scripts/            → /usr/share/freeswitch/scripts/
      systemd/            → fs-dashboard.service
      pip-requirements.txt
      restore_dashboard.sh
    """
    backup_dir = get_backup_dir()
    os.makedirs(backup_dir, exist_ok=True)

    ts       = datetime.now().strftime("%Y-%m-%d_%H-%M-%S")
    filename = f"fs-dashboard-config-{ts}.tar.gz"
    out_path = os.path.join(backup_dir, filename)

    with tempfile.TemporaryDirectory() as tmp:
        pkg_root = os.path.join(tmp, "fs-dashboard-config")
        os.makedirs(pkg_root)

        errors = []

        # 1. Dashboard 程式碼
        dash_dst = os.path.join(pkg_root, "dashboard")
        if os.path.isdir(DASHBOARD_DIR):
            shutil.copytree(DASHBOARD_DIR, dash_dst,
                            ignore=shutil.ignore_patterns("backups", "__pycache__", "*.pyc"))
        else:
            errors.append(f"找不到 {DASHBOARD_DIR}")

        # 2. FreeSwitch 設定
        fs_dst = os.path.join(pkg_root, "freeswitch-config")
        if os.path.isdir(FS_CONFIG_DIR):
            shutil.copytree(FS_CONFIG_DIR, fs_dst)
        else:
            errors.append(f"找不到 {FS_CONFIG_DIR}")

        # 3. 自訂語音
        if os.path.isdir(FS_SOUNDS_CUSTOM):
            shutil.copytree(FS_SOUNDS_CUSTOM,
                            os.path.join(pkg_root, "sounds-custom"))

        # 4. Lua 腳本
        if os.path.isdir(FS_SCRIPTS_DIR):
            shutil.copytree(FS_SCRIPTS_DIR,
                            os.path.join(pkg_root, "scripts"))

        # 5. systemd service
        svc_src = "/etc/systemd/system/fs-dashboard.service"
        svc_dst = os.path.join(pkg_root, "systemd")
        os.makedirs(svc_dst, exist_ok=True)
        if os.path.isfile(svc_src):
            shutil.copy2(svc_src, svc_dst)

        # 6. pip requirements
        req_path = os.path.join(pkg_root, "pip-requirements.txt")
        try:
            result = subprocess.run(
                [f"{VENV_DIR}/bin/pip", "freeze"],
                capture_output=True, text=True, timeout=30
            )
            with open(req_path, "w") as f:
                f.write(result.stdout)
        except Exception as e:
            errors.append(f"pip freeze 失敗：{e}")
            with open(req_path, "w") as f:
                f.write("fastapi\nuvicorn\nwebsockets\nlxml\npython-multipart\n")

        # 7. 還原腳本
        with open(os.path.join(pkg_root, "restore_dashboard.sh"), "w") as f:
            f.write(_restore_dashboard_sh())
        os.chmod(os.path.join(pkg_root, "restore_dashboard.sh"), 0o755)

        # 8. 備份資訊 manifest
        manifest = {
            "type":       "fs-dashboard-config",
            "created_at": datetime.now().isoformat(),
            "hostname":   _get_hostname(),
            "errors":     errors,
        }
        with open(os.path.join(pkg_root, "manifest.json"), "w") as f:
            json.dump(manifest, f, ensure_ascii=False, indent=2)

        # 打包
        with tarfile.open(out_path, "w:gz") as tar:
            tar.add(pkg_root, arcname="fs-dashboard-config")

    size = os.path.getsize(out_path)
    print(f"[backup] config 備份完成：{out_path} ({size} bytes)")
    return {
        "ok":       True,
        "type":     "config",
        "filename": filename,
        "path":     out_path,
        "size":     size,
        "errors":   errors,
    }


def backup_freeswitch_packages() -> dict:
    """
    備份 B：FreeSwitch .deb 套件（版本完全一致）
    打包內容：
      debs/*.deb          → 所有已安裝的 freeswitch-* 套件
      packages.txt        → dpkg --get-selections 完整清單
      restore_freeswitch.sh
    注意：.deb 下載需要 apt-get install --download-only，約 50-200MB
    """
    backup_dir = get_backup_dir()
    os.makedirs(backup_dir, exist_ok=True)

    ts       = datetime.now().strftime("%Y-%m-%d_%H-%M-%S")
    filename = f"freeswitch-packages-{ts}.tar.gz"
    out_path = os.path.join(backup_dir, filename)

    with tempfile.TemporaryDirectory() as tmp:
        pkg_root = os.path.join(tmp, "freeswitch-packages")
        debs_dir = os.path.join(pkg_root, "debs")
        os.makedirs(debs_dir)

        errors = []

        # 1. 取得已安裝的 freeswitch-* 套件清單
        installed_pkgs = _get_installed_fs_packages()
        if not installed_pkgs:
            return {"ok": False, "error": "找不到已安裝的 freeswitch 套件"}

        print(f"[backup] 找到 {len(installed_pkgs)} 個 freeswitch 套件，開始收集 .deb...")

        # 2. 收集 .deb — 三層 fallback 策略
        deb_count = 0
        deb_count, errors = _collect_debs(installed_pkgs, debs_dir, errors, tmp)

        # 3. dpkg 完整套件清單
        try:
            result = subprocess.run(
                ["dpkg", "--get-selections"],
                capture_output=True, text=True, timeout=30
            )
            with open(os.path.join(pkg_root, "packages.txt"), "w") as f:
                f.write(result.stdout)
        except Exception as e:
            errors.append(f"dpkg --get-selections 失敗：{e}")

        # 4. FreeSwitch 版本資訊
        version_info = _get_fs_version()
        with open(os.path.join(pkg_root, "freeswitch-version.txt"), "w") as f:
            f.write(version_info)

        # 5. 還原腳本
        with open(os.path.join(pkg_root, "restore_freeswitch.sh"), "w") as f:
            f.write(_restore_freeswitch_sh())
        os.chmod(os.path.join(pkg_root, "restore_freeswitch.sh"), 0o755)

        # 6. manifest
        manifest = {
            "type":           "freeswitch-packages",
            "created_at":     datetime.now().isoformat(),
            "hostname":       _get_hostname(),
            "fs_version":     version_info.strip(),
            "packages_count": len(installed_pkgs),
            "debs_count":     deb_count,
            "packages":       installed_pkgs,
            "errors":         errors,
        }
        with open(os.path.join(pkg_root, "manifest.json"), "w") as f:
            json.dump(manifest, f, ensure_ascii=False, indent=2)

        # 打包
        with tarfile.open(out_path, "w:gz") as tar:
            tar.add(pkg_root, arcname="freeswitch-packages")

    size = os.path.getsize(out_path)
    print(f"[backup] packages 備份完成：{out_path} ({size} bytes)")
    return {
        "ok":         True,
        "type":       "packages",
        "filename":   filename,
        "path":       out_path,
        "size":       size,
        "deb_count":  deb_count,
        "pkg_count":  len(installed_pkgs),
        "errors":     errors,
    }


# ── 還原（設定，情境A：Server 還活著）────────────────────────────────────────

def restore_dashboard_config(tar_path: str) -> dict:
    """
    從上傳的 tar.gz 還原 Dashboard 設定（Server 仍在運行時的情境A）
    - 解壓到暫存目錄
    - 驗證 manifest type
    - 覆蓋設定檔（不覆蓋 server.py/esl_client.py 等程式碼，只還原設定與 FS config）
    - reloadxml
    """
    if not os.path.isfile(tar_path):
        return {"ok": False, "error": "備份檔不存在"}

    with tempfile.TemporaryDirectory() as tmp:
        try:
            with tarfile.open(tar_path, "r:gz") as tar:
                # 安全檢查：防止 path traversal
                for member in tar.getmembers():
                    if member.name.startswith("/") or ".." in member.name:
                        return {"ok": False, "error": f"備份包含不安全路徑：{member.name}"}
                tar.extractall(tmp)
        except Exception as e:
            return {"ok": False, "error": f"解壓縮失敗：{e}"}

        # 找到解壓目錄
        pkg_root = os.path.join(tmp, "fs-dashboard-config")
        if not os.path.isdir(pkg_root):
            return {"ok": False, "error": "備份格式不正確（找不到 fs-dashboard-config/）"}

        # 驗證 manifest
        manifest_path = os.path.join(pkg_root, "manifest.json")
        if os.path.isfile(manifest_path):
            with open(manifest_path) as f:
                manifest = json.load(f)
            if manifest.get("type") != "fs-dashboard-config":
                return {"ok": False, "error": "備份類型不符（這不是 config 備份包）"}

        errors   = []
        restored = []

        # 1. 還原 FreeSwitch 設定（僅設定檔，不動程式碼）
        fs_src = os.path.join(pkg_root, "freeswitch-config")
        if os.path.isdir(fs_src):
            # 備份目前設定
            ts      = datetime.now().strftime("%Y%m%d_%H%M%S")
            fs_bak  = f"/etc/freeswitch.restore-bak.{ts}"
            try:
                shutil.copytree("/etc/freeswitch", fs_bak)
                shutil.rmtree("/etc/freeswitch")
                shutil.copytree(fs_src, "/etc/freeswitch")
                restored.append("freeswitch config")
            except Exception as e:
                errors.append(f"FreeSwitch 設定還原失敗：{e}")

        # 2. 還原 settings.json（保留目前 esl 連線設定）
        settings_src = os.path.join(pkg_root, "dashboard", "settings.json")
        if os.path.isfile(settings_src):
            try:
                current_esl = {}
                if os.path.isfile(SETTINGS_FILE):
                    with open(SETTINGS_FILE) as f:
                        current = json.load(f)
                    # 保留目前 ESL 連線設定（不從備份覆蓋，避免連不上）
                    for key in ("esl_host", "esl_port", "esl_password"):
                        if key in current:
                            current_esl[key] = current[key]
                with open(settings_src) as f:
                    new_settings = json.load(f)
                new_settings.update(current_esl)
                with open(SETTINGS_FILE, "w") as f:
                    json.dump(new_settings, f, ensure_ascii=False, indent=2)
                restored.append("settings.json")
            except Exception as e:
                errors.append(f"settings.json 還原失敗：{e}")

        # 3. 還原自訂語音
        sounds_src = os.path.join(pkg_root, "sounds-custom")
        if os.path.isdir(sounds_src):
            try:
                os.makedirs(FS_SOUNDS_CUSTOM, exist_ok=True)
                for f in glob.glob(os.path.join(sounds_src, "*")):
                    shutil.copy2(f, FS_SOUNDS_CUSTOM)
                restored.append("sounds/custom")
            except Exception as e:
                errors.append(f"語音檔還原失敗：{e}")

        # 4. 還原 Lua 腳本
        scripts_src = os.path.join(pkg_root, "scripts")
        if os.path.isdir(scripts_src):
            try:
                for f in glob.glob(os.path.join(scripts_src, "*.lua")):
                    shutil.copy2(f, FS_SCRIPTS_DIR)
                restored.append("lua scripts")
            except Exception as e:
                errors.append(f"Lua 腳本還原失敗：{e}")

        # 5. reloadxml
        try:
            subprocess.run(
                ["fs_cli", "-H", "127.0.0.1", "-P", "8055", "-p", "FSPyAdmin",
                 "-x", "reloadxml"],
                capture_output=True, timeout=15
            )
            restored.append("reloadxml")
        except Exception as e:
            errors.append(f"reloadxml 失敗：{e}")

    return {
        "ok":       len(errors) == 0,
        "restored": restored,
        "errors":   errors,
        "manifest": manifest if "manifest" in dir() else {},
    }


# ── 備份清單與管理 ────────────────────────────────────────────────────────────

def list_backups() -> list:
    """列出所有備份檔（config + packages），按時間倒序"""
    backup_dir = get_backup_dir()
    if not os.path.isdir(backup_dir):
        return []

    result = []
    patterns = [
        ("config",   "fs-dashboard-config-*.tar.gz"),
        ("packages", "freeswitch-packages-*.tar.gz"),
    ]
    for btype, pattern in patterns:
        for fpath in glob.glob(os.path.join(backup_dir, pattern)):
            basename = os.path.basename(fpath)
            stat     = os.stat(fpath)
            result.append({
                "filename": basename,
                "type":     btype,
                "path":     fpath,
                "size":     stat.st_size,
                "size_mb":  round(stat.st_size / 1024 / 1024, 2),
                "mtime":    datetime.fromtimestamp(stat.st_mtime).strftime("%Y-%m-%d %H:%M:%S"),
            })

    result.sort(key=lambda x: x["mtime"], reverse=True)
    return result


def delete_backup(filename: str) -> dict:
    """刪除指定備份檔（檔名安全性驗證）"""
    import re
    if not re.match(
        r'^(fs-dashboard-config|freeswitch-packages)-\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}\.tar\.gz$',
        filename
    ):
        return {"ok": False, "error": "檔名格式不正確"}

    backup_dir = get_backup_dir()
    fpath      = os.path.join(backup_dir, filename)

    if not os.path.isfile(fpath):
        return {"ok": False, "error": "檔案不存在"}

    os.remove(fpath)
    return {"ok": True, "deleted": filename}


def cleanup_old_backups() -> list:
    """刪除超過保留天數的備份（排程呼叫）"""
    retain_days = get_retain_days()
    cutoff      = datetime.now() - timedelta(days=retain_days)
    backup_dir  = get_backup_dir()
    deleted     = []

    for pattern in ("fs-dashboard-config-*.tar.gz", "freeswitch-packages-*.tar.gz"):
        for fpath in glob.glob(os.path.join(backup_dir, pattern)):
            mtime = datetime.fromtimestamp(os.path.getmtime(fpath))
            if mtime < cutoff:
                os.remove(fpath)
                deleted.append(os.path.basename(fpath))
                print(f"[backup-cleanup] 已刪除 {os.path.basename(fpath)}")

    return deleted


# ── 輔助函式 ──────────────────────────────────────────────────────────────────

def _get_installed_fs_packages() -> list:
    """取得所有已安裝的 freeswitch-* 套件名稱清單"""
    try:
        result = subprocess.run(
            ["dpkg-query", "-W", "-f=${Package}\n", "freeswitch*"],
            capture_output=True, text=True, timeout=15
        )
        pkgs = [p.strip() for p in result.stdout.splitlines() if p.strip()]
        return pkgs
    except Exception:
        return []


def _get_fs_version() -> str:
    try:
        result = subprocess.run(
            ["freeswitch", "-version"],
            capture_output=True, text=True, timeout=10
        )
        return result.stdout.strip() or result.stderr.strip()
    except Exception:
        return "unknown"


def _collect_debs(installed_pkgs: list, debs_dir: str, errors: list, tmp_root: str) -> tuple[int, list]:
    """
    收集 freeswitch .deb 套件，三層 fallback 策略：
      Layer 1: 直接從 /var/cache/apt/archives/ 複製（最快，無需網路）
      Layer 2: apt-get download（需要 apt repo 可用）
      Layer 3: dpkg-repack（從已安裝二進位重新打包，最慢但最可靠）

    回傳 (deb_count, errors)
    """
    APT_CACHE = "/var/cache/apt/archives"
    deb_count = 0

    # ── Layer 1：apt cache 複製 ───────────────────────────────────────────────
    # 依套件名稱在 cache 目錄比對（前綴比對，忽略版本號與架構後綴）
    cache_debs = glob.glob(os.path.join(APT_CACHE, "freeswitch*.deb"))
    cache_map: dict[str, str] = {}
    for deb_path in cache_debs:
        pkg_name = os.path.basename(deb_path).split("_")[0]  # e.g. freeswitch-mod-lua
        cache_map[pkg_name] = deb_path

    cache_hits   = []
    cache_misses = []
    for pkg in installed_pkgs:
        if pkg in cache_map:
            cache_hits.append(pkg)
        else:
            cache_misses.append(pkg)

    for pkg in cache_hits:
        try:
            shutil.copy2(cache_map[pkg], debs_dir)
            deb_count += 1
        except Exception as e:
            errors.append(f"apt-cache 複製失敗 {pkg}：{e}")
            cache_misses.append(pkg)

    print(f"[backup] Layer1 apt-cache：{deb_count} 個複製成功，{len(cache_misses)} 個未命中")

    # ── Layer 2：apt-get download（處理 cache miss 的套件）───────────────────
    if cache_misses:
        apt_tmp = os.path.join(tmp_root, "apt-download")
        os.makedirs(apt_tmp, exist_ok=True)
        try:
            result = subprocess.run(
                ["apt-get", "download"] + cache_misses,
                cwd=apt_tmp,
                capture_output=True, text=True, timeout=300,
            )
            if result.returncode != 0 and result.stderr:
                errors.append(f"apt-get download 警告：{result.stderr[:300]}")

            downloaded = []
            for deb_file in glob.glob(os.path.join(apt_tmp, "*.deb")):
                pkg_name = os.path.basename(deb_file).split("_")[0]
                shutil.copy2(deb_file, debs_dir)
                deb_count += 1
                downloaded.append(pkg_name)

            still_missing = [p for p in cache_misses if p not in downloaded]
            print(f"[backup] Layer2 apt-download：{len(downloaded)} 個下載成功，{len(still_missing)} 個仍缺")

        except subprocess.TimeoutExpired:
            still_missing = cache_misses
            errors.append("apt-get download 超時（300秒）")
        except Exception as e:
            still_missing = cache_misses
            errors.append(f"apt-get download 失敗：{e}")
    else:
        still_missing = []

    # ── Layer 3：dpkg-repack（最後手段，從安裝二進位重打包）─────────────────
    if still_missing:
        repack_available = subprocess.run(
            ["which", "dpkg-repack"], capture_output=True
        ).returncode == 0

        if not repack_available:
            try:
                subprocess.run(
                    ["apt-get", "install", "-y", "dpkg-repack"],
                    capture_output=True, timeout=60,
                )
                repack_available = True
            except Exception:
                pass

        if repack_available:
            repack_tmp = os.path.join(tmp_root, "repack")
            os.makedirs(repack_tmp, exist_ok=True)
            repacked = 0
            for pkg in still_missing:
                try:
                    result = subprocess.run(
                        ["dpkg-repack", pkg],
                        cwd=repack_tmp,
                        capture_output=True, text=True, timeout=60,
                    )
                    packed = glob.glob(os.path.join(repack_tmp, f"{pkg}_*.deb"))
                    if packed:
                        shutil.copy2(packed[0], debs_dir)
                        deb_count += 1
                        repacked += 1
                    elif result.returncode != 0:
                        errors.append(f"dpkg-repack {pkg} 失敗：{result.stderr[:200]}")
                except Exception as e:
                    errors.append(f"dpkg-repack {pkg} 例外：{e}")
            print(f"[backup] Layer3 dpkg-repack：{repacked}/{len(still_missing)} 個成功")
        else:
            errors.append(f"dpkg-repack 不可用，{len(still_missing)} 個套件無法打包")

    if deb_count == 0:
        errors.append("未成功收集任何 .deb 套件")

    return deb_count, errors


def _get_hostname() -> str:
    try:
        return subprocess.run(
            ["hostname"], capture_output=True, text=True
        ).stdout.strip()
    except Exception:
        return "unknown"
