# 導覽列權限隱藏全面驗證

日期:2026-07-16
對應待辦:`PROJECT-OVERVIEW.md` 已知待處理事項第 7 點（`applyAuthUI()` 自 2026-07-13 上線後僅測過「使用者管理」單一項目）

## 一、驗證方式

分兩階段：

1. **靜態比對**：核對 `core/permissions.py`（`Module` 常數、`ALL_MODULES`、5 組 `BUILTIN_GROUPS` 權限矩陣）、`static/index.html`（17 個 `.nav-item[data-page]`）、`static/js/init.js`（`NAV_PAGE_TO_MODULE`、`pages{}`、`applyAuthUI()`）三份原始碼是否一致
2. **實機測試**：以 5 個內建帳號（`admin`/`viewer`/`admin_tech_support`/`tech_support`/`user1001`）逐一登入，對照權限矩陣換算出的預期可見範圍，人工勾選側邊欄實際顯示結果

## 二、結果

### 靜態比對：✅ 無命名/拼字錯誤

17 個 nav-item 的 `data-page` 與 `permissions.py` 的 `Module` 常數逐一核對，全部正確對應；`dialplan_routes` 經 `NAV_PAGE_TO_MODULE` 正確轉換為 `dialplan` 模組；`applyAuthUI()` 比對邏輯本身無誤。

### 實機測試：✅ 5 個帳號行為皆符合預期矩陣

- System Admin / System Viewer / Technical Support Admin：17 項 nav-item 全部可見
- Technical Support：System 分類（numbers/esl/logs/users/settings/backup）正確全部隱藏，Dashboard/Operational 正常可見
- User(`user1001`)：僅 overview/report/cdr/recordings 可見，其餘 13 項正確隱藏，且 cdr/recordings 資料範圍正確限縮於 `owned_ext=1001`

## 三、副產物:靜態比對過程中發現的 2 個既有功能缺口(非本次隱藏邏輯的 bug)

1. **`calls` 模組沒有對應的 nav-item**:`init.js` 的 `pages{}` 有 `renderCalls`,但 `index.html` 側邊欄找不到 `data-page="calls"`,此頁面目前無 UI 入口可達
2. **`acl` 模組完全沒有前端頁面**:無 `acl.js`、`pages{}` 無此 key、側邊欄無對應項目。後端 `routers/acl.py`(190 行)已存在,`permissions.py` 的 5 組群組矩陣也都已納入 `acl` 權限設定,但前端從未做出對應畫面,任何群組(含 System Admin)皆無法從 UI 操作 ACL

這兩點與「隱藏邏輯是否正確」無關(矩陣換算與 nav-item 隱藏本身是乾淨的),純粹是前端頁面缺失,已另列待辦(見 `PROJECT-OVERVIEW.md` 第五節新增項目)。

## 四、結論

`PROJECT-OVERVIEW.md` 已知待處理事項第 7 點正式結案,待辦清單第六節對應項目勾選完成。
