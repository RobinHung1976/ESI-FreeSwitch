"""
core/permissions.py — 權限系統的單一資料來源（Single Source of Truth）。

只定義常數與資料結構，不碰 DB、不碰 FastAPI。
auth_db.py 的 seed 邏輯直接 import BUILTIN_GROUPS / BUILTIN_USERS 寫入 SQLite；
core/auth.py 的 require_permission() 依 Module 常數查權限，不重複定義矩陣。
"""
from dataclasses import dataclass, asdict
from typing import Literal

Action = Literal["read", "create", "update", "delete"]
Scope = Literal["all", "own"]


# ── 模組常數 ────────────────────────────────────────────────────────────────

class Module:
    OVERVIEW    = "overview"
    REPORT      = "report"
    EXTENSIONS  = "extensions"
    GROUPS      = "groups"       # 通話群組(callgroup)頁面，非權限群組
    IVR         = "ivr"
    NUMBERS     = "numbers"
    CALLS       = "calls"
    CDR         = "cdr"
    RECORDINGS  = "recordings"
    SOUNDS      = "sounds"
    GATEWAY     = "gateway"
    DIALPLAN    = "dialplan"
    ESL         = "esl"
    LOGS        = "logs"
    SETTINGS    = "settings"
    BACKUP      = "backup"
    USERS       = "users"        # 使用者/權限群組管理本身
    SIP_PROFILE = "sip_profile"
    ACL         = "acl"


ALL_MODULES: tuple[str, ...] = (
    Module.OVERVIEW, Module.REPORT, Module.EXTENSIONS, Module.GROUPS, Module.IVR,
    Module.NUMBERS, Module.CALLS, Module.CDR, Module.RECORDINGS, Module.SOUNDS,
    Module.GATEWAY, Module.DIALPLAN, Module.ESL, Module.LOGS, Module.SETTINGS,
    Module.BACKUP, Module.USERS, Module.SIP_PROFILE, Module.ACL,
)

# scope="own" 時，僅這些模組會依 owned_ext 過濾查詢結果
SCOPABLE_MODULES: frozenset[str] = frozenset({Module.CDR, Module.RECORDINGS, Module.CALLS})

# 模組分類（供矩陣建構與未來 UI 分組顯示使用）
DASHBOARD_MODULES: tuple[str, ...] = (Module.OVERVIEW, Module.REPORT)
OPERATIONAL_MODULES: tuple[str, ...] = (
    Module.EXTENSIONS, Module.GROUPS, Module.IVR, Module.NUMBERS,
    Module.CALLS, Module.CDR, Module.RECORDINGS, Module.SOUNDS, Module.SIP_PROFILE,
)
SYSTEM_MODULES: tuple[str, ...] = (
    Module.GATEWAY, Module.DIALPLAN, Module.ESL, Module.LOGS, Module.ACL,
    Module.SETTINGS, Module.BACKUP, Module.USERS,
)

assert set(DASHBOARD_MODULES) | set(OPERATIONAL_MODULES) | set(SYSTEM_MODULES) == set(ALL_MODULES)


# ── 權限旗標 ────────────────────────────────────────────────────────────────

@dataclass(frozen=True, slots=True)
class Perm:
    read:   bool = False
    create: bool = False
    update: bool = False
    delete: bool = False

    def allows(self, action: Action) -> bool:
        return getattr(self, action)

    def to_dict(self) -> dict:
        return asdict(self)


NONE  = Perm()
READ  = Perm(read=True)
RCU   = Perm(read=True, create=True, update=True)
RCUD  = Perm(read=True, create=True, update=True, delete=True)


def _matrix(dashboard: Perm, operational: Perm, system: Perm) -> dict[str, Perm]:
    m: dict[str, Perm] = {}
    m.update({mod: dashboard   for mod in DASHBOARD_MODULES})
    m.update({mod: operational for mod in OPERATIONAL_MODULES})
    m.update({mod: system      for mod in SYSTEM_MODULES})
    return m


# ── 5 組內建群組 ─────────────────────────────────────────────────────────────

@dataclass(frozen=True, slots=True)
class GroupDef:
    name: str
    description: str
    scope: Scope
    perms: dict[str, Perm]


BUILTIN_GROUPS: tuple[GroupDef, ...] = (
    GroupDef(
        name="System Admin",
        description="全部功能完整存取，含使用者與權限群組管理",
        scope="all",
        perms=_matrix(dashboard=RCUD, operational=RCUD, system=RCUD),
    ),
    GroupDef(
        name="System Viewer",
        description="全部功能唯讀，不可新增/修改/刪除",
        scope="all",
        perms=_matrix(dashboard=READ, operational=READ, system=READ),
    ),
    GroupDef(
        name="Technical Support Admin",
        description="全模組讀寫，含系統設定/Gateway/Dialplan/備份/使用者管理，"
                     "但系統級模組不可刪除",
        scope="all",
        perms=_matrix(dashboard=RCUD, operational=RCUD, system=RCU),
    ),
    GroupDef(
        name="Technical Support",
        description="維運操作模組全權限，Dashboard 可新增/修改不可刪除，不可碰系統級模組",
        scope="all",
        perms=_matrix(dashboard=RCU, operational=RCUD, system=NONE),
    ),
    GroupDef(
        name="User",
        description="僅能唯讀自己分機相關資料（CDR/錄音/通話記錄）",
        scope="own",
        perms=_matrix(dashboard=READ, operational=NONE, system=NONE) | {mod: READ for mod in SCOPABLE_MODULES},
    ),
)

BUILTIN_GROUP_NAMES: frozenset[str] = frozenset(g.name for g in BUILTIN_GROUPS)


@dataclass(frozen=True, slots=True)
class UserSeed:
    username: str
    group_name: str
    owned_ext: str | None = None


BUILTIN_USERS: tuple[UserSeed, ...] = (
    UserSeed(username="admin",              group_name="System Admin"),
    UserSeed(username="viewer",             group_name="System Viewer"),
    UserSeed(username="admin_tech_support", group_name="Technical Support Admin"),
    UserSeed(username="tech_support",       group_name="Technical Support"),
    UserSeed(username="user1001",           group_name="User", owned_ext="1001"),
)


def get_group_def(name: str) -> GroupDef | None:
    return next((g for g in BUILTIN_GROUPS if g.name == name), None)


def check_permission(perms: dict[str, Perm], module: str, action: Action) -> bool:
    perm = perms.get(module)
    return bool(perm and perm.allows(action))
