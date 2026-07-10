"""
core/auth_db.py — 使用者/權限群組 SQLite 儲存層。

架構比照 core/cdr_db.py 的 _conn() pattern。
權限矩陣定義單一來源在 core/permissions.py，本檔只負責持久化與 CRUD。

密碼雜湊使用 stdlib hashlib.pbkdf2_hmac（避免新增 bcrypt/passlib 依賴），
600,000 次迭代符合 OWASP 2023+ 建議下限。
"""
import os
import hmac
import sqlite3
import secrets
import hashlib
from datetime import datetime
from contextlib import contextmanager

from core.permissions import (
    Module, Perm, ALL_MODULES, BUILTIN_GROUPS, BUILTIN_USERS, BUILTIN_GROUP_NAMES,
)

DB_DIR  = "/opt/fs-dashboard/data"
DB_PATH = os.path.join(DB_DIR, "auth.db")

PBKDF2_ITERATIONS = 600_000
PBKDF2_ALGO = "sha256"

# 範例帳號的固定初始密碼（首次登入強制改密碼，見 users.must_change_password）
_SEED_PASSWORD = "ChangeMe!2026"


class AuthError(Exception):
    """帳密錯誤 / 帳號停用等登入失敗情境，訊息刻意模糊避免帳號枚舉"""


# ── 連線 ──────────────────────────────────────────────────────────────────────

@contextmanager
def _conn():
    os.makedirs(DB_DIR, exist_ok=True)
    conn = sqlite3.connect(DB_PATH, timeout=10)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA busy_timeout=5000")
    conn.execute("PRAGMA foreign_keys=ON")
    try:
        yield conn
        conn.commit()
    finally:
        conn.close()


def _ensure_meta_table(conn):
    conn.execute("""
        CREATE TABLE IF NOT EXISTS auth_meta (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        )
    """)


def count_users() -> int:
    """auth.db 是否已有任何使用者 — 供過渡期「未啟用權限系統則放行」判斷"""
    with _conn() as conn:
        try:
            row = conn.execute("SELECT COUNT(*) AS c FROM users").fetchone()
            return row["c"] if row else 0
        except sqlite3.OperationalError:
            return 0  # table 尚未建立（init_db 尚未執行）


def get_or_create_jwt_secret() -> str:
    """首次啟動生成 256-bit secret 並存入 DB，之後重啟沿用（否則舊 token 全部失效）。"""
    with _conn() as conn:
        _ensure_meta_table(conn)
        row = conn.execute("SELECT value FROM auth_meta WHERE key='jwt_secret'").fetchone()
        if row:
            return row["value"]
        secret = secrets.token_hex(32)
        conn.execute("INSERT INTO auth_meta (key, value) VALUES ('jwt_secret', ?)", (secret,))
        return secret


def init_db():
    """建立 table/index，服務啟動時呼叫一次（idempotent）。"""
    with _conn() as conn:
        _ensure_meta_table(conn)
        conn.execute("""
            CREATE TABLE IF NOT EXISTS perm_groups (
                id          INTEGER PRIMARY KEY AUTOINCREMENT,
                name        TEXT UNIQUE NOT NULL,
                description TEXT NOT NULL DEFAULT '',
                scope       TEXT NOT NULL DEFAULT 'all' CHECK (scope IN ('all','own')),
                is_builtin  INTEGER NOT NULL DEFAULT 0,
                created_at  TEXT NOT NULL
            )
        """)
        conn.execute("""
            CREATE TABLE IF NOT EXISTS perm_group_permissions (
                group_id   INTEGER NOT NULL REFERENCES perm_groups(id) ON DELETE CASCADE,
                module     TEXT NOT NULL,
                can_read   INTEGER NOT NULL DEFAULT 0,
                can_create INTEGER NOT NULL DEFAULT 0,
                can_update INTEGER NOT NULL DEFAULT 0,
                can_delete INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY (group_id, module)
            )
        """)
        conn.execute("""
            CREATE TABLE IF NOT EXISTS users (
                id                   INTEGER PRIMARY KEY AUTOINCREMENT,
                username             TEXT UNIQUE NOT NULL,
                password_hash        TEXT NOT NULL,
                password_salt        TEXT NOT NULL,
                group_id             INTEGER NOT NULL REFERENCES perm_groups(id),
                owned_ext            TEXT,
                disabled             INTEGER NOT NULL DEFAULT 0,
                must_change_password INTEGER NOT NULL DEFAULT 0,
                created_at           TEXT NOT NULL,
                updated_at           TEXT NOT NULL
            )
        """)
        conn.execute("CREATE INDEX IF NOT EXISTS idx_users_group ON users(group_id)")


# ── 密碼雜湊 ────────────────────────────────────────────────────────────────

def _hash_password(plain: str, salt: bytes | None = None) -> tuple[str, str]:
    salt = salt or secrets.token_bytes(16)
    digest = hashlib.pbkdf2_hmac(PBKDF2_ALGO, plain.encode("utf-8"), salt, PBKDF2_ITERATIONS)
    return digest.hex(), salt.hex()


def _verify_password(plain: str, stored_hash: str, stored_salt: str) -> bool:
    digest, _ = _hash_password(plain, bytes.fromhex(stored_salt))
    return hmac.compare_digest(digest, stored_hash)


# ── Perm <-> DB row 轉換 ──────────────────────────────────────────────────────

def _perm_from_row(row: sqlite3.Row) -> Perm:
    return Perm(
        read=bool(row["can_read"]), create=bool(row["can_create"]),
        update=bool(row["can_update"]), delete=bool(row["can_delete"]),
    )


def _perm_row_values(group_id: int, module: str, perm: Perm) -> tuple:
    return (group_id, module, int(perm.read), int(perm.create), int(perm.update), int(perm.delete))


# ── Seed：內建群組 + 範例帳號 ──────────────────────────────────────────────────

def seed_builtin_groups_and_users():
    """
    啟動時呼叫一次，idempotent：
    - 群組/使用者已存在 → 完全不覆蓋（保留管理員後續調整的權限、已改的密碼）
    - 只補齊「缺少」的群組、模組權限列、範例帳號
    """
    with _conn() as conn:
        for g in BUILTIN_GROUPS:
            row = conn.execute("SELECT id FROM perm_groups WHERE name=?", (g.name,)).fetchone()
            if row:
                gid = row["id"]
            else:
                cur = conn.execute(
                    "INSERT INTO perm_groups (name, description, scope, is_builtin, created_at) "
                    "VALUES (?,?,?,1,?)",
                    (g.name, g.description, g.scope, datetime.now().isoformat()),
                )
                gid = cur.lastrowid

            for module in ALL_MODULES:
                perm = g.perms.get(module, Perm())
                conn.execute(
                    "INSERT OR IGNORE INTO perm_group_permissions "
                    "(group_id, module, can_read, can_create, can_update, can_delete) "
                    "VALUES (?,?,?,?,?,?)",
                    _perm_row_values(gid, module, perm),
                )

        for u in BUILTIN_USERS:
            if conn.execute("SELECT 1 FROM users WHERE username=?", (u.username,)).fetchone():
                continue  # 已存在（可能已改密碼），不覆蓋
            gid = conn.execute(
                "SELECT id FROM perm_groups WHERE name=?", (u.group_name,)
            ).fetchone()["id"]
            pw_hash, pw_salt = _hash_password(_SEED_PASSWORD)
            now = datetime.now().isoformat()
            conn.execute(
                "INSERT INTO users "
                "(username, password_hash, password_salt, group_id, owned_ext, "
                " must_change_password, created_at, updated_at) "
                "VALUES (?,?,?,?,?,1,?,?)",
                (u.username, pw_hash, pw_salt, gid, u.owned_ext, now, now),
            )


# ── 群組查詢 ────────────────────────────────────────────────────────────────

def get_group_permissions(group_id: int) -> dict[str, Perm]:
    with _conn() as conn:
        rows = conn.execute(
            "SELECT * FROM perm_group_permissions WHERE group_id=?", (group_id,)
        ).fetchall()
    return {r["module"]: _perm_from_row(r) for r in rows}


def list_groups() -> list[dict]:
    with _conn() as conn:
        groups = conn.execute("SELECT * FROM perm_groups ORDER BY id").fetchall()
        result = []
        for g in groups:
            perms = get_group_permissions(g["id"])
            result.append({
                "id": g["id"], "name": g["name"], "description": g["description"],
                "scope": g["scope"], "is_builtin": bool(g["is_builtin"]),
                "permissions": {mod: perms.get(mod, Perm()).to_dict() for mod in ALL_MODULES},
            })
        return result


def create_group(name: str, description: str, scope: str, perms: dict[str, Perm]) -> int:
    if scope not in ("all", "own"):
        raise ValueError("scope 必須是 'all' 或 'own'")
    with _conn() as conn:
        if conn.execute("SELECT 1 FROM perm_groups WHERE name=?", (name,)).fetchone():
            raise ValueError(f"群組名稱「{name}」已存在")
        cur = conn.execute(
            "INSERT INTO perm_groups (name, description, scope, is_builtin, created_at) "
            "VALUES (?,?,?,0,?)",
            (name, description, scope, datetime.now().isoformat()),
        )
        gid = cur.lastrowid
        for module in ALL_MODULES:
            perm = perms.get(module, Perm())
            conn.execute(
                "INSERT INTO perm_group_permissions "
                "(group_id, module, can_read, can_create, can_update, can_delete) "
                "VALUES (?,?,?,?,?,?)",
                _perm_row_values(gid, module, perm),
            )
        return gid


def update_group_permissions(group_id: int, perms: dict[str, Perm]):
    """更新群組權限矩陣。is_builtin 群組允許改權限內容，但名稱/scope 不可變（呼叫端需另擋）。"""
    with _conn() as conn:
        if not conn.execute("SELECT 1 FROM perm_groups WHERE id=?", (group_id,)).fetchone():
            raise ValueError("群組不存在")
        for module, perm in perms.items():
            if module not in ALL_MODULES:
                continue
            conn.execute("""
                INSERT INTO perm_group_permissions (group_id, module, can_read, can_create, can_update, can_delete)
                VALUES (?,?,?,?,?,?)
                ON CONFLICT(group_id, module) DO UPDATE SET
                    can_read=excluded.can_read, can_create=excluded.can_create,
                    can_update=excluded.can_update, can_delete=excluded.can_delete
            """, _perm_row_values(group_id, module, perm))


def delete_group(group_id: int):
    with _conn() as conn:
        row = conn.execute("SELECT name, is_builtin FROM perm_groups WHERE id=?", (group_id,)).fetchone()
        if not row:
            raise ValueError("群組不存在")
        if row["is_builtin"]:
            raise ValueError(f"「{row['name']}」為系統內建群組，不可刪除")
        if conn.execute("SELECT 1 FROM users WHERE group_id=?", (group_id,)).fetchone():
            raise ValueError("尚有使用者屬於此群組，請先移轉或刪除相關使用者")
        conn.execute("DELETE FROM perm_groups WHERE id=?", (group_id,))


# ── 使用者查詢 / CRUD ──────────────────────────────────────────────────────────

def _user_public_dict(row: sqlite3.Row) -> dict:
    return {
        "id": row["id"], "username": row["username"], "group_id": row["group_id"],
        "owned_ext": row["owned_ext"], "disabled": bool(row["disabled"]),
        "must_change_password": bool(row["must_change_password"]),
        "created_at": row["created_at"], "updated_at": row["updated_at"],
    }


def list_users() -> list[dict]:
    with _conn() as conn:
        rows = conn.execute("""
            SELECT u.*, g.name AS group_name, g.scope AS group_scope
            FROM users u JOIN perm_groups g ON g.id = u.group_id
            ORDER BY u.id
        """).fetchall()
    result = []
    for r in rows:
        d = _user_public_dict(r)
        d["group_name"] = r["group_name"]
        d["group_scope"] = r["group_scope"]
        result.append(d)
    return result


def get_user_by_username(username: str) -> sqlite3.Row | None:
    with _conn() as conn:
        return conn.execute("SELECT * FROM users WHERE username=?", (username,)).fetchone()


def create_user(username: str, password: str, group_id: int, owned_ext: str | None = None) -> int:
    if not username or not username.strip():
        raise ValueError("帳號不可為空")
    if len(password) < 8:
        raise ValueError("密碼長度至少 8 碼")
    with _conn() as conn:
        if conn.execute("SELECT 1 FROM users WHERE username=?", (username,)).fetchone():
            raise ValueError(f"帳號「{username}」已存在")
        group = conn.execute("SELECT scope FROM perm_groups WHERE id=?", (group_id,)).fetchone()
        if not group:
            raise ValueError("指定的權限群組不存在")
        if group["scope"] == "own" and not owned_ext:
            raise ValueError("此群組要求指定 owned_ext（僅限自己分機）")
        pw_hash, pw_salt = _hash_password(password)
        now = datetime.now().isoformat()
        cur = conn.execute(
            "INSERT INTO users "
            "(username, password_hash, password_salt, group_id, owned_ext, "
            " must_change_password, created_at, updated_at) "
            "VALUES (?,?,?,?,?,0,?,?)",
            (username, pw_hash, pw_salt, group_id, owned_ext, now, now),
        )
        return cur.lastrowid


def update_user(user_id: int, *, group_id: int | None = None, owned_ext: str | None = None,
                 disabled: bool | None = None) -> None:
    with _conn() as conn:
        row = conn.execute("SELECT * FROM users WHERE id=?", (user_id,)).fetchone()
        if not row:
            raise ValueError("使用者不存在")
        new_group_id = group_id if group_id is not None else row["group_id"]
        new_owned_ext = owned_ext if owned_ext is not None else row["owned_ext"]
        new_disabled = int(disabled) if disabled is not None else row["disabled"]
        conn.execute(
            "UPDATE users SET group_id=?, owned_ext=?, disabled=?, updated_at=? WHERE id=?",
            (new_group_id, new_owned_ext, new_disabled, datetime.now().isoformat(), user_id),
        )


def reset_password(user_id: int, new_password: str, force_change: bool = True) -> None:
    if len(new_password) < 8:
        raise ValueError("密碼長度至少 8 碼")
    pw_hash, pw_salt = _hash_password(new_password)
    with _conn() as conn:
        if not conn.execute("SELECT 1 FROM users WHERE id=?", (user_id,)).fetchone():
            raise ValueError("使用者不存在")
        conn.execute(
            "UPDATE users SET password_hash=?, password_salt=?, must_change_password=?, updated_at=? WHERE id=?",
            (pw_hash, pw_salt, int(force_change), datetime.now().isoformat(), user_id),
        )


def change_own_password(user_id: int, old_password: str, new_password: str) -> None:
    with _conn() as conn:
        row = conn.execute("SELECT * FROM users WHERE id=?", (user_id,)).fetchone()
        if not row or not _verify_password(old_password, row["password_hash"], row["password_salt"]):
            raise AuthError("原密碼不正確")
    reset_password(user_id, new_password, force_change=False)


def delete_user(user_id: int) -> None:
    with _conn() as conn:
        row = conn.execute("SELECT username FROM users WHERE id=?", (user_id,)).fetchone()
        if not row:
            raise ValueError("使用者不存在")
        conn.execute("DELETE FROM users WHERE id=?", (user_id,))


# ── 登入驗證 ────────────────────────────────────────────────────────────────

def verify_login(username: str, password: str) -> dict:
    """
    成功回傳登入所需完整資訊（含權限矩陣，供上層組 JWT payload）。
    失敗一律拋 AuthError，訊息不透露「帳號不存在」或「密碼錯誤」的差異，避免帳號枚舉。
    """
    row = get_user_by_username(username)
    if not row or not _verify_password(password, row["password_hash"], row["password_salt"]):
        raise AuthError("帳號或密碼錯誤")
    if row["disabled"]:
        raise AuthError("此帳號已被停用")

    with _conn() as conn:
        group = conn.execute("SELECT * FROM perm_groups WHERE id=?", (row["group_id"],)).fetchone()
    perms = get_group_permissions(row["group_id"])

    return {
        "user_id": row["id"],
        "username": row["username"],
        "group_id": group["id"],
        "group_name": group["name"],
        "scope": group["scope"],
        "owned_ext": row["owned_ext"],
        "must_change_password": bool(row["must_change_password"]),
        "permissions": {mod: perms.get(mod, Perm()).to_dict() for mod in ALL_MODULES},
    }
