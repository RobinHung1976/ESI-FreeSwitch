# `updateN.sh` 自動歸檔資料夾命名錯誤修正

日期:2026-07-15
對應腳本:`update9.sh`(已在 production server `debian-freeswitch` 執行成功)
背景:`ops-github-workflow.md` 記載的「自動歸檔固定寫法」用 `update${CURRENT}`(依當次腳本編號)當資料夾名稱,但本專案實際上一直是把所有執行過的 `updateM.sh` 統一歸檔進同一個固定資料夾 `updateN/`(`update2.sh`~`update7.sh` 皆在其中)。執行 `update8.sh` 時依文件字面寫法建立了一個新的 `update8/` 資料夾(裡面只有被重複搬進去的 `update7.sh`),造成歸檔位置分散、跟既有慣例不一致。

## 現象

`update8.sh` 執行完後,`ls` 看到:

```
updateN/     ← 既有的統一歸檔資料夾(update2.sh ~ update7.sh)
update8/     ← 這次誤建的新資料夾,裡面只有 update7.sh
update8.sh   ← 剛執行完、尚未被歸檔的當次腳本
```

## 根本原因

`ops-github-workflow.md` 的「自動歸檔固定寫法」範例程式碼:

```bash
CURRENT=<本次腳本編號>
mkdir -p "update${CURRENT}"
```

字面上就是「用當次腳本編號建立資料夾」,跟文件其他地方描述的「搬進 `updateN/` 資料夾」用詞雖然一樣,但範例程式碼實際執行結果是每次都建立一個新資料夾(`update8/`、`update9/`……),而不是固定的 `updateN/`。過去 `update2.sh`~`update7.sh` 能統一放在 `updateN/`,推測是先前撰寫腳本時沒有機械式照抄這段範例、而是手動固定了資料夾名稱,這次 `update8.sh` 照抄文件範例才第一次踩到這個落差。

## 修復

### 1. `update9.sh`:修正既有的 `update8/` 資料夾

- 把 `update8/update7.sh` 併回 `updateN/update7.sh`
- 移除空的 `update8/` 資料夾
- 沿用修正後的固定歸檔邏輯,把 `update8.sh` 本身也搬進 `updateN/`
- 含前置驗證(`update8/` 不存在時安全跳過,冪等)

### 2. `ops-github-workflow.md`:修正「自動歸檔固定寫法」範例

```bash
# 修改前
CURRENT=<本次腳本編號>
mkdir -p "update${CURRENT}"
for f in update*.sh; do
  [ "$f" = "update${CURRENT}.sh" ] && continue
  ...
done

# 修改後
ARCHIVE_DIR="updateN"
SELF="$(basename "$0")"

mkdir -p "$ARCHIVE_DIR"
for f in update*.sh; do
  [ "$f" = "$SELF" ] && continue
  [ -f "$f" ] || continue
  git mv "$f" "${ARCHIVE_DIR}/$f" 2>/dev/null || mv "$f" "${ARCHIVE_DIR}/$f"
done
```

改用固定資料夾名稱 `updateN`,並用 `$(basename "$0")` 動態取得目前執行中的腳本檔名(不用再手動設定 `CURRENT` 編號變數,順便減少一個容易忘記改的手動步驟)。

## 驗證方式

```bash
ls -la                  # 不應再看到 update8/ 或任何 updateM/ 資料夾
ls updateN/             # 應包含 update2.sh ~ update8.sh,每個檔名只出現一次
git status --porcelain  # 乾淨
git log --oneline -3    # 確認 commit 訊息正確
```

於沙箱 git repo 實測過完整流程(含冪等重跑測試),確認搬移邏輯正確、不會重複搬移或遺漏檔案。

## 後續影響

之後所有 `updateN.sh` 都會沿用修正後的固定寫法,統一歸檔進 `updateN/`,不會再發生類似的資料夾命名分散問題。

---

**測試結果**:`update9.sh` 已於 production server 實際執行,`updateN/` 資料夾結構恢復統一,無殘留的錯誤命名資料夾。
