# reorg/ 文件目錄補進 git 版控（2026-07-15）

## 現象

在收尾「Nginx reverse proxy + HTTPS」項目、要把 `PROJECT-OVERVIEW.md` checklist 打勾時，
第一次執行 `update13.sh` 直接失敗：

```
grep: PROJECT-OVERVIEW.md: No such file or directory
```

`find` 後發現 `PROJECT-OVERVIEW.md`、`CHANGELOG.md`、`changelog-details/` 實際位於
`/opt/fs-dashboard/reorg/` 底下，而不是 repo 根目錄。

## 根本原因

進一步用 `git ls-files reorg/` 檢查發現**完全沒有輸出**——`reorg/` 這整個資料夾
（`archive/`、`changelog-details/`、`features/`、`ops/`、`reference/`，以及
`PROJECT-OVERVIEW.md`、`CHANGELOG.md` 本身）從頭到尾都不在 git 版控範圍內。

用 `git status --porcelain=v1 --ignored -- reorg/` 交叉確認，所有項目都顯示 `??`
（untracked），沒有任何一項是被 `.gitignore` 刻意排除的 `!!`——代表這不是設計上
特意讓文件目錄游離在 repo 之外，單純是建立 `reorg/` 資料夾當時忘了 `git add`，
之後也沒有人發現。

## 修復

分兩階段處理：

1. **`update14.sh`**：先只針對「Nginx reverse proxy + HTTPS」相關的三個檔案
   （`reorg/PROJECT-OVERVIEW.md`、`reorg/CHANGELOG.md`、新建的
   `reorg/changelog-details/20260715-nginx-https-feature.md`）修正路徑並 `git add`，
   讓當下要收尾的項目可以先完整完成。

2. **`update15.sh`**：完成上一項後，另外全面稽核一次，用
   `find /opt/fs-dashboard/reorg -type f` 對照 `git ls-files reorg/`，
   確認 `reorg/` 底下其餘 **96 個檔案**（`archive/` 37 個歷史文件、
   `features/` 18 個功能文件、`ops/` 4 個維運文件、`reference/` 1 個參考索引、
   `changelog-details/` 剩餘 36 個）全數未被追蹤，一次性 `git add reorg/` 補齊。

### 執行過程的小插曲

`update15.sh` 執行到 `git diff --cached --name-status -- reorg/` 這行時，因為輸出
筆數多（96 筆），觸發了系統預設的 pager（`less`），把腳本卡在等待使用者按 `q`
離開分頁檢視的狀態，導致同一支腳本裡後面的 `git commit` 沒有被執行到——`git add`
已經確實把檔案加進索引，只是還沒 commit。透過 `git log --oneline` 確認 commit
沒有產生後，手動補執行一次 `git commit` 即完成，沒有任何檔案遺失。

**教訓**：往後 `updateN.sh` 裡如果有 `git diff`/`git log` 這類輸出筆數可能很多的
指令，應該加上 `--no-pager`（例如 `git --no-pager diff --cached --name-status`），
避免腳本在非互動情境下被 pager 卡住。

## 驗證方式

```bash
git status --porcelain -- reorg/     # 應無任何輸出（全部已追蹤、無未提交變更）
git ls-files reorg/ | wc -l          # 應等於 find reorg -type f | wc -l
```

**測試結果**：`update14.sh`、`update15.sh` 皆已於 production server（`debian-freeswitch`）
實際執行並 `git push` 成功（`66d38d8..bac68bf..c25f47d`），`git status --porcelain -- reorg/`
確認乾淨無殘留 untracked 項目。
