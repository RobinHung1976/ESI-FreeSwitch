# GitHub 連線與 updateN.sh / deploy.sh 工作流程

Repo：`ESI-FreeSwitch`（GitHub 帳號 `RobinHung1976`）

## 一、Server 連上 GitHub（SSH Deploy Key）

### 1. 在 server 上產生一組專用金鑰（不與個人 SSH key 混用）

```bash
ssh-keygen -t ed25519 -C "esi-freeswitch-deploy" -f ~/.ssh/esi_freeswitch_deploy -N ""
```

### 2. 設定 SSH 別名

```bash
cat >> ~/.ssh/config << 'EOF'
Host github.com-esi-freeswitch
  HostName github.com
  User git
  IdentityFile ~/.ssh/esi_freeswitch_deploy
  IdentitiesOnly yes
EOF
chmod 600 ~/.ssh/config
```

### 3. 把公鑰貼到 GitHub

`cat ~/.ssh/esi_freeswitch_deploy.pub` 複製後貼到：Repo → Settings → Deploy keys → Add deploy key

- 若在 server 上直接 `git commit`+`git push`（本專案採用此方式）→ 勾選 **Allow write access**
- 若只在 server 上 `git pull`，push 從其他機器執行 → 不勾選，更安全

### 4. 測試連線

```bash
ssh -T git@github.com-esi-freeswitch
# 預期：Hi <帳號>/ESI-FreeSwitch! You've successfully authenticated...
```

### 5. Clone / 轉換既有目錄

**全新 clone**：
```bash
cd /opt
git clone github.com-esi-freeswitch:RobinHung1976/ESI-FreeSwitch.git fs-dashboard
```

**既有目錄轉 git 管理**（本專案實際情況：`/opt/fs-dashboard` 已有現成檔案）：
1. 確認遠端狀態：`git ls-remote github.com-esi-freeswitch:RobinHung1976/ESI-FreeSwitch.git`
2. **先建立 `.gitignore`**（`git init` 之前）：
   ```bash
   cat > .gitignore << 'EOF'
   settings.json
   data/
   backups/
   __pycache__/
   *.pyc
   *.pyo
   EOF
   ```
   `settings.json`（ESL 密碼、JWT 金鑰）與 `data/auth.db`（密碼雜湊）絕不能進 git
3. `git init` + `git remote add origin ...` + `git branch -M main`
4. 若遠端已有初始 commit（如 GitHub 自動產生的 README）：`git fetch origin` + `git merge origin/main --allow-unrelated-histories`
5. **檢查點**：`git add -A` 後跑 `git status`，確認 `.gitignore` 排除的項目沒有出現在待 commit 清單，且沒有其他不該進版控的東西（venv、log、錄音檔案）
6. `git commit` + `git push`

### remote URL 帳號大小寫

GitHub 帳號大小寫需與 remote URL 一致，避免每次 push 都出現 "This repository moved" 轉址提示：

```bash
git remote set-url origin git@github.com-esi-freeswitch:RobinHung1976/ESI-FreeSwitch.git
git fetch origin   # 確認不再出現轉址提示
```

## 二、`updateN.sh` 撰寫與執行 SOP

### 核心原則

1. 動手寫前，先看過所有要改動的檔案**目前實際內容**（不要假設等於文件記錄的版本）
2. **改動範圍大 → 完整覆寫**（`cat > path << 'EOF'`）；**改動範圍小（1-2 處）→ python3 精確字串比對**，對不上直接中止
3. 同一支腳本內若對同一檔案有多個修改步驟，後面步驟的比對字串要以「前面步驟執行完之後」的狀態為準，不能假設是原始內容
4. 每支腳本開頭固定加入「前置驗證」：`grep`/檔案存在檢查應該有的特徵字串，對不上就直接中止，不寫入任何檔案
5. 每支腳本開頭固定執行「自動歸檔」（把非本次腳本的其他 `updateM.sh` 搬進**固定名稱**的 `updateN/` 資料夾，**不是**用當次腳本編號建立新資料夾），且與功能改動**分開 commit**（`chore:` vs `feat:`/`fix:`）
6. 重跑修正腳本時，對於上一次執行可能已建立的全新檔案，一律用完整覆寫處理，不假設它們不存在或內容乾淨（`git reset --hard` 不會清掉 untracked 檔案）
7. 執行完 `updateN.sh` 後，腳本結尾自動印出 `git log --oneline -1` 確認 commit 真的產生
8. 每支腳本附上明確的「驗證重點清單」給使用者核對
9. `push` 與 `deploy.sh` 執行步驟刻意保留手動確認，不做自動化串接

### 自動歸檔固定寫法

⚠️ **2026-07-15 更正**：先前版本用 `update${CURRENT}`（依當次腳本編號）當資料夾名稱，執行 `update8.sh` 時因此誤建了一個新的 `update8/` 資料夾，跟本專案實際上一直沿用的「統一歸檔進固定資料夾 `updateN/`」不一致（`update2.sh`~`update7.sh` 都在同一個 `updateN/` 底下）。已改為固定資料夾名稱，並用 `$(basename "$0")` 動態取得目前腳本檔名，不用再手動設定 `CURRENT` 編號變數：

```bash
ARCHIVE_DIR="updateN"
SELF="$(basename "$0")"

mkdir -p "$ARCHIVE_DIR"
for f in update*.sh; do
  [ "$f" = "$SELF" ] && continue
  [ -f "$f" ] || continue
  git mv "$f" "${ARCHIVE_DIR}/$f" 2>/dev/null || mv "$f" "${ARCHIVE_DIR}/$f"
done
git add -A
if ! git diff --cached --quiet; then
  git commit -m "chore: 歸檔已執行的 updateN.sh 腳本"
fi
```

若誤用舊寫法建立了 `updateM/`（M 為某次腳本編號）這種錯誤資料夾，修正方式見 `changelog-details/20260715-updaten-archive-folder-fix.md`（`update9.sh` 的修復記錄）。

### 前置驗證固定寫法

```bash
if ! grep -q "<上一支腳本會留下的特徵字串>" "<受影響的檔案路徑>"; then
  echo "❌ 尚未包含上一支腳本的改動，請先確認上一支腳本是否已成功套用" >&2
  exit 1
fi
```

### 交付方式

由於下載檔案的方式有時不可行，退回**貼上存檔**方式：

1. 在對話中整份貼出 `updateN.sh` 內容
2. 在 server 上 `cat > updateN.sh << 'UPDATEN_EOF' ... UPDATEN_EOF` 整份存檔
3. `wc -l updateN.sh` 核對行數，確認沒有貼漏
4. `chmod +x updateN.sh && ./updateN.sh`
5. **不管成功、失敗、或前置驗證中止，都把完整輸出貼回來核對**
6. 確認腳本產生的 commit 沒問題後，`push`/`deploy.sh` 由使用者自己手動執行

### 已知編號歷史

`update1.sh`：基於已知過時的版本寫成，**從未執行、已正式作廢**。實際第一支執行過的腳本是 `update2.sh`（孤兒檔案清理 + `calls.router` 重複掛載修正）。

⚠️ **2026-07-16 教訓**：撰寫「登錄記錄去重」修復時，誤將編號判斷為 `update23.sh`，但該編號當時已被另一支無關腳本（Dialplan Context 切換 UI 文件收尾）使用，`update24.sh` 也已存在。原因是只依賴 changelog-details 的既有記錄推斷「下一個可用編號」，而 changelog 文件記錄本身有滯後性（最後 1～2 支腳本常來不及補文件）。後續改用 `update25.sh` 銜接，未造成 commit 遺失。**往後產生新腳本前，一律先請使用者在 server 上實際執行** `ls updateN/*.sh update*.sh 2>/dev/null` **確認真正的最大編號，不再只憑文件記錄推斷**。

## 三、`deploy.sh` 使用方式

見 `ops-deployment.md` 的「基於 Git 的部署」段落。核心是：部署前檢查工作目錄乾淨、備份 `settings.json`、`git reset --hard`、還原 `settings.json`、健康檢查、印出回滾指令。
