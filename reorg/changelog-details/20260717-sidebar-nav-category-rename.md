# 側邊欄分類重整：管理→話務功能、系統→系統維運、號碼目錄歸位

日期:2026-07-17
對應腳本:`update38.sh`（已在 production server `debian-freeswitch` 執行成功）

## 一、起因

側邊欄「管理」「系統」兩個分類長期以分類依據不一致（「管理」混雜話務資源與查詢記錄，「系統」內卻放了本質上屬於話務資源的「號碼目錄」），造成使用者實際使用時分不清某個功能該去哪個分類找，加上兩個標題字面（「管理」）本身不具區辨性。

## 二、分類原則重新定義

| 分類 | 判斷依據 |
|---|---|
| 監控 | 即時/統計監看，不涉及設定 |
| **話務功能**（原「管理」） | 跟「電話系統功能」有關的一切：資源設定 + 查詢記錄。判斷法：拿掉這套 Dashboard 換另一套系統，這個功能還存不存在？分機/號碼/IVR/Gateway/Dialplan/錄音/CDR 都是 FreeSwitch 本身就有的電話功能 |
| **系統維運**（原「系統」） | 跟「Dashboard 平台本身」有關的一切：使用者權限、ACL、日誌、備份、設定，都是這套 Dashboard 才有的維運功能 |

## 三、實際異動

1. **分類標題改名**：`<span class="nav-section-label">管理</span>` → `話務功能`；`系統` → `系統維運`（`data-group="manage"`/`data-group="system"` 內部識別值不變，僅顯示文字調整，不影響 `toggleNavGroup()`/accordion 狀態存取）
2. **「號碼目錄」nav-item 搬移**：從「系統維運」分類移到「話務功能」分類（音檔庫項目之後）。`data-page="numbers"` 屬性、後端路由、`init.js` 的 `pages{}`、`permissions.py` 的 `Module.numbers` 權限模組皆未變動，純粹是 DOM 位置搬移

搬移後「話務功能」分類項目（由上而下）：分機管理、分機群組、IVR 管理、通話記錄 CDR、錄音管理、Gateway / SIP Trunk、SIP Profile 進階設定、Dialplan 路由設定、音檔庫、**號碼目錄**

「系統維運」分類項目：ESL 終端機、系統日誌、使用者管理、SIPTrunk ACL 信任清單、設定、備份管理

## 四、實作方式

`update38.sh` 採 python3 精確字串比對（非完整覆寫），逐一比對唯一命中後才寫入：
- 移除「系統維運」群組內的號碼目錄區塊（前置比對出現次數必須剛好 1 次）
- 插入到「話務功能」群組音檔庫區塊之後
- 兩個分類標籤各自比對後才替換

同時修正上次（`update36.sh`）記錄的自動歸檔已知問題：歸檔步驟由 `git add -A` 改為明確 `git add update*.sh "$ARCHIVE_DIR"/`，本次歸檔 commit 確認乾淨（`2 files changed`，僅腳本本身相關檔案，未夾帶其他正在編輯中的檔案）。

## 五、驗證方式

- 瀏覽器強制重新整理，確認側邊欄第二/第三分類標題顯示「話務功能」「系統維運」
- 「號碼目錄」出現在「話務功能」分類底下（音檔庫之後），不再出現在「系統維運」
- 「號碼目錄」點擊功能正常，accordion 收合、active 色條、字級對比度（見 `20260717-sidebar-visual-refinement.md`）皆維持不變

**測試結果**：已在 production server 實際執行，功能 commit `1 file changed, 5 insertions(+), 5 deletions(-)`，符合預期（2 行標籤文字 + 3 行 nav-item 搬動）。

## 六、影響檔案總覽

| 檔案 | 異動 |
|---|---|
| `static/index.html` | 兩個 `nav-section-label` 文字改名；`numbers` nav-item 從系統群組搬到話務功能群組 |
| `update38.sh` | 新增，執行後已歸檔進 `updateN/` |
