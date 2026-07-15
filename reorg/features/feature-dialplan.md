# Dialplan 路由設定 — 總覽

> 對應頁面：管理 → Dialplan 路由設定（三合一頁面）
> 子頁：[`feature-dialplan-routing-rule.md`](feature-dialplan-routing-rule.md)（類型一）· [`feature-dialplan-system-extensions.md`](feature-dialplan-system-extensions.md)（類型二）· [`feature-dialplan-custom.md`](feature-dialplan-custom.md)（類型三）
> 演變歷史：[20260701 Dialplan 管理總覽](../changelog-details/20260701-dialplan-management-overview.md)

## 整體架構：三種類型分工

FreeSwitch 的 dialplan 依「使用目的」與「管理方式」分成三種類型，各自獨立 Tab：

```
Dialplan 路由設定頁面
├── Tab：路由規則（Outbound Routing）  ← 類型一，表單式
├── Tab：系統內建（System Extensions） ← 類型二，唯讀 + 說明
└── Tab：自定義（Custom）              ← 類型三，範本 + XML 編輯器
```

與其他頁面的分工邊界：

| 檔案 / 類型 | 管理頁面 |
|---|---|
| `00_group_*.xml` | 分機群組管理頁面 |
| `00_ivr_*.xml` | IVR 管理頁面 |
| `00_route_*.xml` | Dialplan → 路由規則 Tab |
| `default.xml`、`public.xml` | Dialplan → 系統內建 Tab（唯讀） |
| 其他手寫 `.xml` | Dialplan → 自定義 Tab |

## 共用基礎設施（`dialplan_common.py`）

三種類型共用同一套 reload/rollback/備份機制，避免類型間互相 import 私有函式：

| 函式 | 說明 |
|---|---|
| `init_esl(esl_instance)` | 注入 ESL 連線，三模組共用同一顆 |
| `make_backup(filepath, suffix="bak")` | 建立時間戳備份 |
| `reload_and_verify(target_filepath, backup_path)` | `reloadxml` 並驗證，失敗自動從備份還原 + 再次 reload + 丟 500 |
| `force_reload()` | 靜默 reloadxml，吞例外 |
| `rollback_new_file(filepath)` | 新增情境專用：無備份可還原時，直接刪除半成品新檔並重新 reload |
| `validate_xml(content)` | 共用 XML 語法驗證（`lxml.etree.fromstring`） |

`build_regex()`/`find_conflicts()` 這類「路由規則」特有的號碼樣式比對邏輯，刻意留在 `dialplan_routes.py`，不搬進共用模組——類型三的範本語意不同，硬共用會綁死擴充彈性。

## 尚未實作的通用功能

| 功能 | 優先度 | 說明 |
|---|---|---|
| Context 切換 UI | 中 | 後端 `RouteRule` 已有 `context` 欄位，前端加選單即可 |
| 編輯二次確認 | 低 | 儲存前彈窗確認 |
| 備份歷史列表與一鍵還原 | 低 | 列出所有 `.bak.*`，提供還原按鈕 |

## 實作進度總覽

| 功能 | 類型 | 狀態 |
|---|---|---|
| 外撥路由規則表單 CRUD、legacy 偵測/反解析/升級、衝突檢查、路由測試工具 | 類型一 | ✅ |
| 系統內建 Extension 唯讀列表 + 說明 | 類型二 | ✅ |
| 範本選擇 → 填空式 XML 編輯器（時段路由、黑名單範本） | 類型三 | ✅ |
| XML 語法驗證（共用） | 通用 | ✅ |
| Context 切換 UI | 通用 | 🔲 |
| 備份歷史列表與一鍵還原 | 通用 | 🔲 |
| 既有 raw editor（`server.py`/`dialplan_files.py`）遷移至 `dialplan_custom.py` 並改用 `reload_and_verify` | 類型三 | 🔲（可選，目前獨立實作，reload 失敗不會自動 rollback） |
