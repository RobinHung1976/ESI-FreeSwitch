# FreeSwitch Dashboard — Dialplan 管理功能總覽

**日期**：2026-07-01
**說明**：本文件為 Dialplan 管理功能的整體架構總覽與進度追蹤。各類型詳細技術規格請見對應文件：
- 類型一（路由規則）→ `dialplan-routing-rule-20260701.md`
- 類型二（系統內建 Extension）→ `dialplan-system-extensions-feature-20260701.md`
- 類型三（自定義）→ `dialplan-custom-feature-20260701.md`

---

## 一、整體架構：Dialplan 三種類型的分工

FreeSwitch 的 dialplan 並非單一結構，依「使用目的」和「管理方式」分成三種類型，對應三種完全不同的 UI 策略：

```
Dialplan 管理頁面
├── Tab：路由規則（Outbound Routing）  ← 類型一，表單式，已完成 ✅
├── Tab：系統內建（System Extensions） ← 類型二，唯讀+說明，規劃中 🔲
└── Tab：自定義（Custom）              ← 類型三，模板+XML 編輯器，規劃中 🔲
```

與其他頁面的分工：

| 檔案 / 類型 | 管理頁面 | 狀態 |
|---|---|---|
| `00_group_*.xml` | 群組管理頁面 | 已有 |
| `00_ivr_*.xml` | IVR 管理頁面 | 已有 |
| `00_route_*.xml` | Dialplan → 路由規則 Tab | ✅ 本次完成 |
| `default.xml`、`public.xml` | Dialplan → 系統內建 Tab（唯讀） | 🔲 規劃中 |
| 其他手寫 .xml | Dialplan → 自定義 Tab | 🔲 規劃中 |

---

## 五、尚未實作的通用功能

| 功能 | 優先度 | 說明 |
|---|---|---|
| Context 切換 UI | 中 | 目前前端固定 `default`；後端 `RouteRule` 已有 `context` 欄位，加選單即可 |
| 編輯時二次確認 | 低 | 按儲存前彈出 modal：「即將覆寫現有設定，確認？」 |
| 備份歷史列表 | 低 | 列出所有 `.bak.*` 備份檔，提供一鍵還原按鈕 |

---

## 六、實作進度總覽

| 功能 | 類型 | 狀態 |
|---|---|---|
| 外撥路由規則表單 CRUD | 類型一 | ✅ |
| 舊有手寫檔案自動偵測 | 類型一 | ✅ |
| 舊有檔案反解析（含 IP→gateway 還原） | 類型一 | ✅ |
| 舊有檔案一鍵升級 | 類型一 | ✅ |
| 號碼樣式即時衝突檢查（含 legacy） | 類型一 | ✅ |
| 路由測試工具（全域 + 表單內即時版） | 類型一 | ✅ |
| 自動備份（所有寫入操作） | 類型一 | ✅ |
| reloadxml 驗證 + 自動 rollback | 類型一 | ✅ |
| Dashboard 管理檔案保護 | 類型一 | ✅ |
| 進階 XML 預覽（表單內即時生成） | 類型一 | ✅ |
| 系統內建 Extension 唯讀列表+說明 | 類型二 | 🔲 |
| 模板選擇 → 填空式 XML 編輯器 | 類型三 | 🔲 |
| XML 語法驗證（類型三儲存前） | 類型三 | 🔲（機制已有，待接入） |
| 刪除二次確認 | 通用 | 🔲 |
| Context 切換 UI | 通用 | 🔲 |
| 備份歷史列表與一鍵還原 | 通用 | 🔲 |

---


## 七、相關檔案

| 檔案 | 說明 |
|---|---|
| `dialplan_routes.py` | 後端主模組：路由規則 CRUD、legacy 偵測/升級、衝突檢查、rollback |
| `dialplan-routes-ui.js` | 前端 UI 模組（已整合至 `index.html`） |
| `test_dialplan_routes.py` | 測試腳本，共 19 組，含 rollback 模擬測試 |
| `server.py` | 主應用，3 行整合：`import dialplan_routes` / `init_esl` / `include_router` |
| `dialplan-management-overview-20260701.md` | 本文件（整體架構總覽） |
| `dialplan-routing-rule-20260701.md` | 類型一詳細技術規格 |
| `dialplan-system-extensions-feature-20260701.md` | 類型二詳細技術規格 |
| `dialplan-custom-feature-20260701.md` | 類型三詳細技術規格 |
