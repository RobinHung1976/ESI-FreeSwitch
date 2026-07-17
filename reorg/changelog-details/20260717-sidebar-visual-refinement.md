# 側邊欄視覺優化 + updateN.sh 文件交付流程修正

日期:2026-07-17
對應腳本:`update35.sh`、`update36.sh`（皆已在 production server `debian-freeswitch` 執行成功並 push）

## 一、起因

側邊欄「監控/管理/系統」三個分類標題與底下 nav-item 項目文字，字級（皆 16px）與顏色（同色系深淺相近）都太接近，畫面看起來擁擠、層級不分明。

## 二、CSS 調整內容（分兩輪迭代）

### v1（`update35.sh`）

- `.nav-section-label` 新增字級 11px、大寫、字距拉開
- `.nav-group + .nav-group` 新增分類間分隔線
- `.nav-icon` 改為固定寬度 20px + `inline-flex` 置中，統一 emoji 與符號 icon 的對齊

### v2（`update36.sh`，依實機截圖回饋調整）

第一輪回饋：大標題縮太小（11px 不易讀），項目文字仍偏大，兩者顏色對比不夠強烈。調整為：

| 項目 | 調整前 | 調整後 |
|---|---|---|
| `.nav-section-label` 字級 | 11px | 13px |
| `.nav-section-label` 顏色 | 沿用 `.nav-section` 的 `#0277bd` | `#012a44`（加深，強化對比） |
| `.nav-item` 字級 | 16px | 13px |
| `.nav-item` 顏色 | `#1e3d5c` | `#4a6a8a`（變淺，與標題形成深/淺對比） |

hover/active 狀態的鮮豔藍色（`#0277bd`）維持不動，僅調整預設靜止狀態的顏色與字級。

兩輪皆採用「疊加新規則覆蓋舊值」的寫法（同選擇器後定義的規則覆蓋前面的屬性），未改動既有 `.nav-item`/`.nav-section-label` 原始規則本身，也未動 `index.html` 結構。

## 三、`ops-github-workflow.md` 文件流程修正

### 1. 交付方式：由「貼上存檔」改為「直接產生檔案」

原文件記載「下載檔案的方式有時不可行，退回貼上存檔」，此限制已不成立，改為 Claude 直接產生 `updateN.sh` 實體檔案交付，貼上存檔僅作備援。

### 2. 新增「純文件（.md）異動如何推上 GitHub」章節

釐清純文件變更（`PROJECT-OVERVIEW.md`/`CHANGELOG.md`/`feature-*.md`/`ops-*.md` 等）不需要透過 `updateN.sh`，直接手動 `git add`/`commit`/`push` 三連即可，commit 訊息統一用 `docs:` 前綴。

### 3. 記錄一起已知但未修正的 bug

**現象**：執行 `update36.sh` 時，使用者手動編輯中的 `reorg/ops/ops-github-workflow.md`（30 行異動）被自動歸檔步驟的 `git add -A` 一併掃進 `chore: 歸檔已執行的 updateN.sh 腳本`（commit `1e2e2ad`），導致這次文件異動被誤貼上 `chore` 標籤而非預期的 `docs:`。

**根本原因**：自動歸檔固定寫法用 `git add -A` 全掃當下所有未 commit 的變更，只要「手動編輯文件」跟「執行 updateN.sh」的時間點重疊，就會被一起掃進歸檔 commit。

**處置**：由於該 commit 已經 `push`（`a983384..310fac9`），拆分修正需要 `git reset --soft` + force push，風險評估後判斷不值得，選擇保留現況、僅記錄問題與修正方向，待下次撰寫新 `updateN.sh` 時一併帶入：

```bash
# 修正方向：只 add 明確路徑，不用 -A 全掃
git add update*.sh "$ARCHIVE_DIR"/
```

已記錄進 `reorg/ops/ops-github-workflow.md` 的「自動歸檔固定寫法」章節。

## 四、驗證方式

- 瀏覽器強制重新整理 `/`，確認側邊欄大標題（13px、深色）與項目文字（13px、淺色）呈現明顯層級對比，accordion 收合與 active 左側色條功能不受影響
- `git log --oneline -5` 確認 commit 序列：`chore`(歸檔) → `style`(v1) → `chore`(歸檔，誤夾帶文件) → `style`(v2) → `docs`(問題記錄)
- `git push` 全數成功，遠端與本地一致

## 五、影響檔案總覽

| 檔案 | 異動 |
|---|---|
| `static/css/style.css` | 新增側邊欄視覺覆蓋規則（v1 + v2），未改動既有規則 |
| `reorg/ops/ops-github-workflow.md` | 交付方式章節改寫、新增 md 推送流程章節、記錄自動歸檔已知問題 |
| `update35.sh`/`update36.sh` | 新增，執行後已歸檔進 `updateN/` |
