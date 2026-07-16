#!/usr/bin/env bash
# update23.sh — 補齊 Dialplan Context 切換 UI + 相關 bug 修復的文件記錄
#
# 範圍（依 PROJECT-OVERVIEW.md「未來記錄規則」）：
#   1. 新增 2 份 changelog-details（功能本身 + custom_regex 衝突檢查修復 + 全站 Authorization
#      header 修復，共 3 份，其中 auth-header 那份因範圍與本功能無關另立一份）
#   2. CHANGELOG.md 加 3 行索引
#   3. PROJECT-OVERVIEW.md：已知待處理事項第 3 點劃記完成、新增第 8/9 點已知限制、
#      下一步開發 checklist 打勾
#   4. feature-dialplan.md：移除「尚未實作」表格裡的 Context 切換 UI 項目、
#      實作進度總覽打勾、共用基礎設施補充 context 相關函式說明
#   5. feature-dialplan-routing-rule.md：新增 Context 支援章節、衝突檢查章節補充
#      context 分組說明、API 表補 GET /api/dialplan/contexts
#   6. feature-dialplan-custom.md：新增 Context 選單章節、API 表補
#      GET/POST /api/dialplan/contexts
#
# 這些檔案實際位於 reorg/ 底下（非 repo 根目錄），且整個 reorg/ 目錄的 git 追蹤
# 狀態曾經有過問題（見 changelog-details/20260715-reorg-git-tracking-fix.md），
# 本腳本結尾會額外用 git status 確認 reorg/ 底下沒有殘留 untracked 項目。
set -e

cd "$(dirname "$0")"

DOC_ROOT="reorg"

# ════════════════════════════════════════════════════════════════════════════
# 0. 自動歸檔
# ════════════════════════════════════════════════════════════════════════════
ARCHIVE_DIR="updateN"
SELF="$(basename "$0")"

mkdir -p "$ARCHIVE_DIR"
for f in update*.sh; do
  [ "$f" = "$SELF" ] && continue
  [ -f "$f" ] || continue
  git mv "$f" "${ARCHIVE_DIR}/$f" 2>/dev/null || mv "$f" "${ARCHIVE_DIR}/$f"
done
git add "${ARCHIVE_DIR}"
if ! git diff --cached --quiet; then
  git commit -m "chore: 歸檔已執行的 updateN.sh 腳本"
fi

# ════════════════════════════════════════════════════════════════════════════
# 1. 前置驗證
# ════════════════════════════════════════════════════════════════════════════
for f in "$DOC_ROOT/PROJECT-OVERVIEW.md" "$DOC_ROOT/CHANGELOG.md" \
         "$DOC_ROOT/features/feature-dialplan.md" \
         "$DOC_ROOT/features/feature-dialplan-routing-rule.md" \
         "$DOC_ROOT/features/feature-dialplan-custom.md"; do
  if [ ! -f "$f" ]; then
    echo "❌ 找不到 $f，請確認執行路徑（這些文件位於 reorg/ 底下，非 repo 根目錄）" >&2
    exit 1
  fi
done

if [ -f "$DOC_ROOT/changelog-details/20260716-dialplan-context-switch-feature.md" ]; then
  echo "ℹ️  changelog-details/20260716-dialplan-context-switch-feature.md 已存在，本次腳本可能已執行過，將以覆蓋方式重新產生（內容冪等）"
fi

TS=$(date +%Y%m%d%H%M%S)
for f in "$DOC_ROOT/PROJECT-OVERVIEW.md" "$DOC_ROOT/CHANGELOG.md" \
         "$DOC_ROOT/features/feature-dialplan.md" \
         "$DOC_ROOT/features/feature-dialplan-routing-rule.md" \
         "$DOC_ROOT/features/feature-dialplan-custom.md"; do
  cp "$f" "$f.bak.$TS"
done

# ════════════════════════════════════════════════════════════════════════════
# 2. 新增 3 份 changelog-details（完整覆寫，全新檔案，冪等安全）
# ════════════════════════════════════════════════════════════════════════════
mkdir -p "$DOC_ROOT/changelog-details"

cat > "$DOC_ROOT/changelog-details/20260716-dialplan-context-switch-feature.md" << 'DOC1_EOF'
# Dialplan Context 切換 UI（2026-07-16）

> 對應 `PROJECT-OVERVIEW.md` 中優先待辦「Dialplan Context 切換 UI」（已知待處理事項第 3 點）。
> 上層功能文件：[`feature-dialplan-routing-rule.md`](../features/feature-dialplan-routing-rule.md)、
> [`feature-dialplan-custom.md`](../features/feature-dialplan-custom.md)

## 背景

`RouteRule` 的 `context` 欄位早就存在，但**實際檔案永遠寫死進 `/etc/freeswitch/dialplan/default/`**（`ROUTE_DIR` 常數寫死），`context` 欄位只是存進 meta JSON，沒有真的決定檔案位置；前端也完全沒有對應的選單。等於「有欄位但沒生效」。

## 設計決策

| 項目 | 決定 | 原因 |
|---|---|---|
| context 資料夾對應 | 一個 context = `/etc/freeswitch/dialplan/` 底下一個子資料夾 | 對齊 FreeSwitch 本身的 context/include 機制 |
| context 清單來源 | 動態掃描 `/etc/freeswitch/dialplan/` 底下實際存在的子資料夾（`GET /api/dialplan/contexts`），不開放自由輸入 | 避免打錯字造成「這個 context 永遠不會被撥打到」的規則 |
| 建立新 context 的入口 | 只放在「自定義 Dialplan」頁面（`POST /api/dialplan/contexts`，純 mkdir） | 路由規則頁面新增規則時只該選「已確定會生效」的 context；自定義 Dialplan 頁面本來就是使用者主動撰寫 XML 內容的地方，建立 context 後緊接著就會填入第一份內容，資料夾不會長時間空著 |
| 建立資料夾的風險提示 | 建立時強制顯示警語：純 mkdir 不會自動生效，需另外到 SIP Profile 或其他 dialplan 設定讓某個來源指向這個 context | 避免使用者誤以為建立資料夾＝功能立即生效 |
| 衝突檢查分組 | 同 context 才視為真衝突（阻擋儲存，409）；跨 context 的號碼樣式重疊只回傳 `other_context_matches` 當參考資訊，不阻擋 | FreeSwitch 是先進 context 再比對 pattern，不同 context 的規則本來就不會互相衝突 |
| 列表呈現 | 單一 context 沿用原本平面表格（零改動、零額外點擊）；篩選選到「全部 context」才切換成卡片總覽，點卡片下鑽進去看該 context 的規則，上方顯示麵包屑可返回 | 多次討論後選定卡片＋下鑽＋麵包屑，取代最初提案的手風琴摺疊表格，避免多 context 混在一起看不清楚，同時不影響現有單一 context（多數安裝情境）的操作路徑 |
| 現有規則遷移 | 不需任何搬移／回填 | 前端過去從未送出 `context` 欄位，後端一律套用預設值 `"default"`；現有規則的檔案本來就已經物理上放在 `default/` 資料夾，meta 記錄的 context 也已經是 `"default"`，兩者本來就一致 |

## 修改的檔案

### 後端 `routers/dialplan_routes.py`

- 新增 `DIALPLAN_ROOT`、`_route_dir(context)`、`list_contexts()`、`create_context_dir(context)`
- `_route_filepath(route_id, context=None)`：提供 `context` 時直接組出目標路徑（新增/搬移用）；不提供則跨所有 context 資料夾掃描既有檔案（更新/刪除/查詢/toggle 用）
- `_load_all_routes()`、`_legacy_scan_dirs()`：改為掃描所有 context 資料夾，不再只看 `default`/`public`
- `_parse_legacy_route_file()`：legacy 檔案的 context 改用實際所在資料夾名稱推斷（原本寫死 `"default" if "/default/" in filepath else "public"`）
- `find_conflicts()`：回傳值從 `List[dict]` 改為 `{"same_context": [...], "other_context": [...]}`，新增 `context` 參數決定分組依據
- `update_route()`：若 `context` 有變更，檔案要從舊資料夾搬到新資料夾——先在新位置寫入並 `reload_and_verify` 成功，才刪除舊檔案（`make_backup(old_filepath, suffix="bak.moved")`），失敗則 `rollback_new_file()` 清掉剛寫的新檔，維持升級前狀態
- 新增 `GET /api/dialplan/contexts`、`POST /api/dialplan/contexts`（後者只給自定義 Dialplan 頁面呼叫）
- `check_conflict` 端點新增 `context` 參數，回傳新增 `other_context_matches`

### 前端 `static/js/dialplan.js`

**路由規則 Tab**：
- 新增 context 篩選下拉（`_routeFilterSelectHtml()`）：預設選中規則數最多的 context（單一 context 時行為與改版前完全一致）；選「🗂 全部 context」切換成卡片總覽（`_routeOverviewCardsHtml()`），點卡片下鑽（`_routeDrillIntoContext()`）進入該 context 的平面表格並顯示麵包屑（`_routeFlatTableHtml()`），可點「← 返回總覽」（`_routeBackToOverview()`）
- 表單新增 Context 選單（`_routeContextOptionsHtml()`），新增規則時預設帶入目前篩選的 context
- 衝突警告分兩個區塊：同 context 紅色阻擋、跨 context 藍色參考資訊（`_checkRouteConflict()`）
- 規則表格新增 Context 欄位

**自定義 Dialplan Tab**：
- `dc-context`（範本模式）、`dc-manual-context`（手動模式）兩個選單改成動態讀取 `/api/dialplan/contexts`，並加「+ 建立新 context...」選項（`_dcPromptNewContext()`／`_dcCreateNewContext()`），成功後自動選取新建立的 context

## 已知限制

- 建立新 context 資料夾後，仍需要使用者自行到 SIP Profile 或其他 dialplan 設定讓某個來源指向這個 context 名稱，通話才會真正進入——這是刻意設計（避免把高風險的 SIP Profile 綁定邏輯做進這次改動），已在建立當下顯示警語

## 相關修復（同一輪測試中一併發現並修復）

- `custom_regex` 對 `custom_regex` 衝突檢查失效，見 [`20260716-custom-regex-conflict-detection-fix.md`](20260716-custom-regex-conflict-detection-fix.md)
- 全站寫入操作缺少 `Authorization` header（與本功能無關的既有 bug，測試過程中順帶發現），見 [`20260716-auth-header-missing-fix.md`](20260716-auth-header-missing-fix.md)

## 驗證方式

```bash
curl -s http://127.0.0.1:3000/api/dialplan/contexts -H "Authorization: Bearer <token>"
python3 -m py_compile routers/dialplan_routes.py
node --check static/js/dialplan.js   # 若 server 有裝 node
```

瀏覽器實測：
- 路由規則 Tab：context 篩選（單一/全部總覽/下鑽/麵包屑返回）、新增/編輯規則的 Context 選單、同 context 衝突阻擋、跨 context 僅供參考
- 自定義 Dialplan Tab：建立新 context（含警語顯示）、建立後立即可在下拉選單選到
- 編輯既有規則變更 context：確認檔案從舊資料夾搬到新資料夾（`.bak.moved.*` 備份保留舊檔內容）、reloadxml 後撥號行為正常

**測試結果**：已於 production server（`debian-freeswitch`）實際部署（`update19.sh`）並經多輪瀏覽器實測驗證通過，含 context 篩選/總覽/下鑽/麵包屑、建立新 context、規則搬移 context 等情境。
DOC1_EOF

cat > "$DOC_ROOT/changelog-details/20260716-custom-regex-conflict-detection-fix.md" << 'DOC2_EOF'
# custom_regex 對 custom_regex 衝突檢查永遠偵測不到重疊（2026-07-16）

> 於 [Dialplan Context 切換 UI](20260716-dialplan-context-switch-feature.md) 功能測試過程中發現。

## 現象

新增兩條 `pattern_type=custom_regex` 且**正規式字串完全相同**的路由規則（同一 context），兩條都能成功儲存，衝突檢查完全沒有攔下來；把其中一條的正規式用「編輯」改成跟另一條一樣，也一樣能存檔成功。

## 根本原因

`find_conflicts()` 靠雙方樣本互測對方 regex 來偵測重疊：

```python
hit = any(exist_re.match(s) for s in new_samples) or \
      any(new_re.match(s) for s in exist_samples)
```

`generate_sample_numbers()` 對 `pattern_type=custom_regex` 一律回傳空陣列（regex 無法窮舉樣本，程式註解本來就寫「改用對方的樣本反向測試這顆 regex」）。這個設計在「一邊是 custom_regex、另一邊是 prefix/exact」時可以運作（用 prefix/exact 那邊的樣本去測 custom_regex）；但**當兩邊都是 custom_regex 時，雙方樣本都是空的，`any()` 對空陣列一律回傳 `False`，永遠測不出任何重疊**——即使兩條規則字串一模一樣。

此限制在 `find_conflicts()`/`generate_sample_numbers()` 原本的程式碼就存在，不是這次 Context 功能改動造成的，只是這次測試時用 `custom_regex` 才真正踩到。

## 修復

在 `find_conflicts()` 的比對迴圈補上一個特例：兩邊都是 `custom_regex` 且規則字串完全相同（`.strip()` 後比對）時，強制判定為衝突：

```python
if not hit and pattern_type == "custom_regex" and route.get("pattern_type") == "custom_regex":
    if pattern_value.strip() == (route.get("pattern_value") or "").strip():
        hit = True
```

同時把 `check_conflict` 端點回傳的 `note` 文字改得更精確，明確說明目前只能偵測「規則字串完全相同」的重複：

> 自訂正規式採取樣比對，僅能偵測規則字串完全相同的重複；若是語意相同但寫法不同的正規式（例如 `^6\d{3}$` 與 `^(6\d{3})$`）無法自動偵測，請務必搭配下方路由測試工具手動驗證。

## 已知殘留限制

語意相同但寫法不同的兩條 `custom_regex`（例如 `^6\d{3}$` 與 `^(6\d{3})$`）目前仍無法自動偵測，這是「取樣比對法」本身的天花板——要徹底解決需要真正的 regex 語意比對（例如把兩顆 regex 都轉成有限自動機再比較語言是否有交集），目前評估成本高於效益，先靠 UI 提示搭配路由測試工具人工確認，暫不列入本次修復範圍。

## 修改的檔案

- `routers/dialplan_routes.py`：`find_conflicts()` 加特例判斷（2 處精確字串取代，`update22.sh`）

## 驗證方式

```bash
python3 -m py_compile routers/dialplan_routes.py
systemctl restart fs-dashboard   # Python 程式碼改動必須重啟才生效
```

瀏覽器實測：
1. 新增一條 `custom_regex` 規則（例如 `^(9\d{3})$`），成功
2. 同一 context 再新增一條完全相同的正規式 → 應被紅色警告攔下、無法儲存
3. 換一個 context 用同樣正規式新增 → 應顯示藍色跨 context 提示、不阻擋儲存
4. 編輯既有規則把正規式改成跟另一條同 context 規則完全相同 → 應被攔下

**測試結果**：已於 production server（`debian-freeswitch`）實際執行 `update22.sh` 並 `systemctl restart` 後，依上述步驟重新測試通過（第一次測試因忘記重啟服務誤判修復未生效，重啟後確認正常）。
DOC2_EOF

cat > "$DOC_ROOT/changelog-details/20260716-auth-header-missing-fix.md" << 'DOC3_EOF'
# 全站寫入操作缺少 Authorization header，導致新增/編輯/刪除一律 401（2026-07-16）

> 於 [Dialplan Context 切換 UI](20260716-dialplan-context-switch-feature.md) 功能瀏覽器實測階段發現，
> 範圍與 Dialplan Context 功能無關，是既有 bug，一併修復。

## 現象

「Dialplan 路由設定」測試「新增路由規則」時，畫面顯示「缺少登入憑證」，儲存失敗。Network 分頁顯示 `POST /api/dialplan/routes` 401；但同一頁面的 `GET /api/dialplan/routes`/`/api/gateway/list`/`/api/dialplan/contexts` 都正常回 200。

排查過程中，用同一組登入狀態測試「Gateway / SIP Trunk」頁面新增 Gateway，也同樣 401（`gateway.js` 完全沒被這次改動碰過），確認是**全站性、跟這次功能開發無關**的既有問題。

## 根本原因

`static/js/common.js` 的 `apiFetch()` 有正確自動帶 `Authorization: Bearer <token>`：

```javascript
async function apiFetch(path, options = {}) {
  const token = getToken();
  const headers = { ...(options.headers || {}) };
  if (token) headers['Authorization'] = `Bearer ${token}`;
  ...
}
```

但專案中多支前端檔案的「新增/編輯/刪除」寫入操作**直接呼叫原生 `fetch()`**，完全沒有帶這個 header；GET 讀取類請求則多半有透過 `apiFetch()` 走，所以查詢正常、寫入卻 401。此問題自使用者權限系統上線（約 2026-07-10，見 `feature-permissions-auth.md`）之後就存在，只是先前的測試多集中在讀取類功能，這次才真正撞到。

用以下指令可以列出所有繞過 `apiFetch()` 直接呼叫 `fetch()` 的地方：

```bash
cd static/js
grep -n "await fetch(" *.js | grep -v "apiFetch\|common.js"
```

## 修復範圍（共 10 支檔案）

| 批次 | 檔案 | 處數 |
|---|---|---|
| `update20.sh` | `gateway.js` | 2（`saveGw`/`deleteGw`） |
| `update20.sh` | `dialplan.js` | 8（`saveRoute`/`deleteRoute`/`toggleRouteEnabled`/`testRouteNumber`/`_dcUpdatePreview`/`dcSaveTemplateForm`/`_checkRouteConflict`/`_dcCreateNewContext`） |
| `update21.sh` | `cdr.js` | 1（歸檔下載） |
| `update21.sh` | `extensions-groups.js` | 8（分機/群組的儲存/建立/刪除，含改號流程的雙步驟建立+刪除） |
| `update21.sh` | `ivr.js` | 3（音檔上傳/刪除/強制刪除） |
| `update21.sh` | `logs.js` | 4（歷史日期清單、歷史查詢、log rotate） |
| `update21.sh` | `recordings.js` | 1（刪除錄音） |
| `update21.sh` | `settings-vars.js` | 4（CDR 歸檔/刪除歸檔、Dialplan 手動編輯儲存、備份還原） |
| `update21.sh` | `sip-profile.js` | 5（參數更新、ACL 套用重啟、ACL 新增/刪除、NAT 精靈） |
| `update21.sh` | `sounds.js` | 3（音檔上傳/刪除/強制刪除） |

共約 39 處。修法一律是在原本的 `fetch()` 呼叫的 `headers` 裡補上：

```javascript
'Authorization': `Bearer ${getToken()}`
```

檔案上傳（`FormData` body，如 `sounds/upload`、`backup/restore`）刻意**不**加 `Content-Type`，只加 `Authorization`，避免蓋掉瀏覽器自動產生的 `multipart/form-data` boundary。

## 未涵蓋範圍

`static/js/` 底下若還有其他檔案（本次以外未列在上表的）也用同樣手法直接呼叫 `fetch()` 做寫入操作，理論上會有同樣問題，但截至本次修復尚未發現其他遺漏（已用上述 grep 指令排查過整個 `static/js/` 目錄）。之後新增前端檔案時，寫入操作應優先使用 `apiFetch()`，而不是直接呼叫 `fetch()`，避免重蹈覆轍。

## 修改的檔案

- `static/js/gateway.js`
- `static/js/dialplan.js`
- `static/js/cdr.js`
- `static/js/extensions-groups.js`
- `static/js/ivr.js`
- `static/js/logs.js`
- `static/js/recordings.js`
- `static/js/settings-vars.js`
- `static/js/sip-profile.js`
- `static/js/sounds.js`

## 驗證方式

純前端檔案改動，瀏覽器強制重新整理（Ctrl+Shift+R）即生效，不需要 `systemctl restart`。

```bash
cd static/js
grep -n "await fetch(" *.js | grep -v "apiFetch\|Authorization"   # 應無殘留漏補的寫入操作
```

瀏覽器逐項實測（每項都確認不再 401）：Gateway 新增、路由規則新增/編輯/刪除/啟停用/測試、CDR 歸檔下載、分機新增/改號/刪除、群組新增/改號/刪除、IVR 音檔上傳/刪除、系統日誌歷史查詢/rotate、錄音刪除、設定頁 CDR 歸檔/刪除/Dialplan 手動編輯/備份還原、SIP Profile 參數/ACL/NAT 精靈、音檔庫上傳/刪除。

**測試結果**：已於 production server（`debian-freeswitch`）實際執行 `update20.sh`/`update21.sh`，瀏覽器實測 Gateway 新增與路由規則存/刪/啟停用皆確認不再 401；其餘頁面因範圍較大，建議後續使用時留意是否仍有 401，若有請回報補測。
DOC3_EOF

git add "$DOC_ROOT/changelog-details/20260716-dialplan-context-switch-feature.md" \
        "$DOC_ROOT/changelog-details/20260716-custom-regex-conflict-detection-fix.md" \
        "$DOC_ROOT/changelog-details/20260716-auth-header-missing-fix.md"

echo "✓ 新增 3 份 changelog-details"

# ════════════════════════════════════════════════════════════════════════════
# 3. 精確字串比對，更新既有文件
# ════════════════════════════════════════════════════════════════════════════
python3 << 'DOC_EDIT_PY_EOF'
import sys

def apply_edits(path, edits):
    with open(path, "r", encoding="utf-8") as f:
        content = f.read()

    failures = []
    already_applied = []
    to_apply = []

    for label, old, new in edits:
        if new in content:
            already_applied.append(label)
            continue
        count = content.count(old)
        if count == 1:
            content = content.replace(old, new, 1)
            to_apply.append(label)
        else:
            failures.append((label, count))

    if failures:
        print(f"❌ {path} 以下項目比對失敗：", file=sys.stderr)
        for label, count in failures:
            print(f"   - {label}：找到 {count} 次（預期剛好 1 次）", file=sys.stderr)
        return False

    with open(path, "w", encoding="utf-8") as f:
        f.write(content)

    print(f"✓ {path}：套用 {len(to_apply)} 項，{len(already_applied)} 項已存在略過")
    for label in to_apply:
        print(f"   (已套用) {label}")
    for label in already_applied:
        print(f"   (已存在，略過) {label}")
    return True

DOC_ROOT = "reorg"
ok = True

# ── CHANGELOG.md ──────────────────────────────────────────────────────────
ok &= apply_edits(f"{DOC_ROOT}/CHANGELOG.md", [
    ("2026-07-16 三筆索引",
"""## 2026-07

- 07-15 feat: 登錄記錄（reg_log）SQLite 持久化，取代原本服務重啟即歸零的記憶體 list，新增保留天數設定與每日自動清理 → [詳情](changelog-details/20260715-reg-log-persistence.md)""",
"""## 2026-07

- 07-16 feat: Dialplan Context 切換 UI（context 篩選/全部總覽下鑽 + 自定義 Dialplan 建立新 context，衝突檢查依 context 分組） → [詳情](changelog-details/20260716-dialplan-context-switch-feature.md)
- 07-16 fix: custom_regex 對 custom_regex 衝突檢查因取樣比對法限制永遠偵測不到重疊，補上規則字串完全相同時強制判定衝突 → [詳情](changelog-details/20260716-custom-regex-conflict-detection-fix.md)
- 07-16 fix: 全站 10 支前端檔案共約 39 處寫入操作缺少 Authorization header，導致新增/編輯/刪除一律 401（既有 bug，非本次功能造成） → [詳情](changelog-details/20260716-auth-header-missing-fix.md)
- 07-15 feat: 登錄記錄（reg_log）SQLite 持久化，取代原本服務重啟即歸零的記憶體 list，新增保留天數設定與每日自動清理 → [詳情](changelog-details/20260715-reg-log-persistence.md)"""),
])

# ── PROJECT-OVERVIEW.md ─────────────────────────────────────────────────────
ok &= apply_edits(f"{DOC_ROOT}/PROJECT-OVERVIEW.md", [
    ("已知待處理事項標題日期更新",
"## 五、已知待處理事項(截至 2026-07-13)",
"## 五、已知待處理事項(截至 2026-07-16)"),

    ("已知待處理事項第 3 點劃記完成",
"3. **Dialplan Context 切換 UI**:後端 `RouteRule` 已有 `context` 欄位,前端加選單即可。",
"3. ~~**Dialplan Context 切換 UI**:後端 `RouteRule` 已有 `context` 欄位,前端加選單即可。~~ → 已於 2026-07-16 完成，見 `changelog-details/20260716-dialplan-context-switch-feature.md`。"),

    ("新增已知待處理事項第 8/9 點",
"""7. **導覽列權限隱藏尚未全面驗證**:2026-07-13 新增的 `applyAuthUI()` 是全站性邏輯,但只針對「使用者管理」測試過,其餘既有 18 個頁面的模組名稱對應建議找時間補測。
## 六、下一步開發""",
"""7. **導覽列權限隱藏尚未全面驗證**:2026-07-13 新增的 `applyAuthUI()` 是全站性邏輯,但只針對「使用者管理」測試過,其餘既有 18 個頁面的模組名稱對應建議找時間補測。
8. **custom_regex 語意相同但寫法不同無法自動偵測衝突**:衝突檢查採取樣比對法，只能攔截規則字串完全相同的重複，`^6\\d{3}$` 與 `^(6\\d{3})$` 這類語意相同但寫法不同的正規式仍測不出來，需搭配路由測試工具人工確認。詳見 `changelog-details/20260716-custom-regex-conflict-detection-fix.md`。
9. **全站 Authorization header 缺漏修復（`update20.sh`/`update21.sh`）僅涵蓋當時排查到的 10 支檔案**:之後新增前端檔案時，寫入操作應優先使用 `apiFetch()`，避免重蹈覆轍。詳見 `changelog-details/20260716-auth-header-missing-fix.md`。
## 六、下一步開發"""),

    ("下一步開發標題日期更新",
"## 六、下一步開發(優先順序,截至 2026-07-13)",
"## 六、下一步開發(優先順序,截至 2026-07-16)"),

    ("下一步開發中優先打勾",
"""- [x] 登錄記錄(`reg_log`)持久化（已完成，2026-07-15，見 `changelog-details/20260715-reg-log-persistence.md`）
- [ ] Dialplan Context 切換 UI
- [ ] 導覽列權限隱藏全面驗證(見已知待處理事項第 7 點)""",
"""- [x] 登錄記錄(`reg_log`)持久化（已完成，2026-07-15，見 `changelog-details/20260715-reg-log-persistence.md`）
- [x] Dialplan Context 切換 UI（已完成，2026-07-16，見 `changelog-details/20260716-dialplan-context-switch-feature.md`）
- [ ] 導覽列權限隱藏全面驗證(見已知待處理事項第 7 點)"""),
])

# ── features/feature-dialplan.md ─────────────────────────────────────────────
ok &= apply_edits(f"{DOC_ROOT}/features/feature-dialplan.md", [
    ("移除尚未實作表格的 Context 切換 UI 列",
"""| 功能 | 優先度 | 說明 |
|---|---|---|
| Context 切換 UI | 中 | 後端 `RouteRule` 已有 `context` 欄位，前端加選單即可 |
| 編輯二次確認 | 低 | 儲存前彈窗確認 |
| 備份歷史列表與一鍵還原 | 低 | 列出所有 `.bak.*`，提供還原按鈕 |""",
"""| 功能 | 優先度 | 說明 |
|---|---|---|
| 編輯二次確認 | 低 | 儲存前彈窗確認 |
| 備份歷史列表與一鍵還原 | 低 | 列出所有 `.bak.*`，提供還原按鈕 |"""),

    ("實作進度總覽打勾",
"""| XML 語法驗證（共用） | 通用 | ✅ |
| Context 切換 UI | 通用 | 🔲 |
| 備份歷史列表與一鍵還原 | 通用 | 🔲 |""",
"""| XML 語法驗證（共用） | 通用 | ✅ |
| Context 切換 UI（context 篩選/全部總覽下鑽/建立新 context） | 通用 | ✅（2026-07-16，見 [`20260716-dialplan-context-switch-feature.md`](../changelog-details/20260716-dialplan-context-switch-feature.md)） |
| 備份歷史列表與一鍵還原 | 通用 | 🔲 |"""),

    ("共用基礎設施補充 context 說明",
"`build_regex()`/`find_conflicts()` 這類「路由規則」特有的號碼樣式比對邏輯，刻意留在 `dialplan_routes.py`，不搬進共用模組——類型三的範本語意不同，硬共用會綁死擴充彈性。",
"""`build_regex()`/`find_conflicts()` 這類「路由規則」特有的號碼樣式比對邏輯，刻意留在 `dialplan_routes.py`，不搬進共用模組——類型三的範本語意不同，硬共用會綁死擴充彈性。

`list_contexts()`/`create_context_dir()`（2026-07-16 新增）也放在 `dialplan_routes.py`，透過 `GET`/`POST /api/dialplan/contexts` 供類型一（路由規則）與類型三（自定義）共用；一個 context 對應 `/etc/freeswitch/dialplan/` 底下一個子資料夾，建立入口只開放在類型三（自定義）頁面，類型一只能選既有清單，詳見 [`20260716-dialplan-context-switch-feature.md`](../changelog-details/20260716-dialplan-context-switch-feature.md)。"""),
])

# ── features/feature-dialplan-routing-rule.md ────────────────────────────────
ok &= apply_edits(f"{DOC_ROOT}/features/feature-dialplan-routing-rule.md", [
    ("新增 Context 支援章節 + 衝突檢查章節補充 context 分組說明",
"""## 號碼樣式衝突檢查

新增/編輯時雙向取樣比對（`generate_sample_numbers()` 產生代表性樣本互相測試對方正規式），重疊回傳 409 並列出衝突清單（名稱/優先序/啟用狀態）。表單 400ms debounce 自動觸發（`onRoutePatternInput()`），編輯模式排除自身（`self_id`）。""",
"""## Context 支援（2026-07-16）

規則實際寫入的資料夾由 `context` 欄位決定（`/etc/freeswitch/dialplan/<context>/`），列表/衝突檢查/legacy 掃描皆跨所有 context 資料夾進行。前端列表可依 context 篩選（單一 context 平面表格；選「全部 context」切換成卡片總覽 + 點擊下鑽 + 麵包屑返回）。表單只能從既有 context 清單選擇，建立新 context 資料夾的入口在「自定義 Dialplan」頁面（見 [`feature-dialplan-custom.md`](feature-dialplan-custom.md)）。編輯規則時若變更 context，檔案會從舊資料夾搬到新資料夾（先寫新檔驗證成功才刪舊檔）。

## 號碼樣式衝突檢查

新增/編輯時雙向取樣比對（`generate_sample_numbers()` 產生代表性樣本互相測試對方正規式），**只有同一 context 內的重疊才視為真衝突**（回傳 409 並列出衝突清單：名稱/優先序/啟用狀態），跨 context 的重疊只回傳為參考資訊（`other_context_matches`），不阻擋儲存。`custom_regex` 對 `custom_regex` 額外攔截「規則字串完全相同」的重複（2026-07-16 修復，見 [`20260716-custom-regex-conflict-detection-fix.md`](../changelog-details/20260716-custom-regex-conflict-detection-fix.md)），語意相同但寫法不同的 regex 仍無法自動偵測。表單 400ms debounce 自動觸發（`onRoutePatternInput()`），編輯模式排除自身（`self_id`）。"""),

    ("API 表補 GET /api/dialplan/contexts",
"| `POST` | `/api/dialplan/routes/legacy/upgrade` | 升級舊有手寫檔案 |",
"""| `POST` | `/api/dialplan/routes/legacy/upgrade` | 升級舊有手寫檔案 |
| `GET` | `/api/dialplan/contexts` | 取得目前存在的 context 清單（與類型三共用） |"""),
])

# ── features/feature-dialplan-custom.md ──────────────────────────────────────
ok &= apply_edits(f"{DOC_ROOT}/features/feature-dialplan-custom.md", [
    ("新增 Context 選單章節",
"已實作範本：時段路由（time_route）、黑名單（blacklist）。",
"""已實作範本：時段路由（time_route）、黑名單（blacklist）。

## Context 選單（2026-07-16）

範本模式（`dc-context`）與手動模式（`dc-manual-context`）的 Context 選單改為動態讀取 `/api/dialplan/contexts`，並加入「+ 建立新 context...」選項——選取後彈出命名輸入框，呼叫 `POST /api/dialplan/contexts` 建立空資料夾並顯示警語（純 mkdir，仍需另外到 SIP Profile 或其他 dialplan 設定讓某個來源指向這個 context 才會生效），成功後自動選取新建立的 context。這是全站唯一能建立新 context 的入口，詳見 [`20260716-dialplan-context-switch-feature.md`](../changelog-details/20260716-dialplan-context-switch-feature.md)。"""),

    ("API 表補 GET/POST /api/dialplan/contexts",
"| `POST` | `/api/dialplan/custom/preview` | 表單即時預覽 XML |",
"""| `POST` | `/api/dialplan/custom/preview` | 表單即時預覽 XML |
| `GET` | `/api/dialplan/contexts` | 取得目前存在的 context 清單（與類型一共用） |
| `POST` | `/api/dialplan/contexts` | 建立新 context 資料夾（純 mkdir；只有本頁面開放此功能，類型一路由規則頁面只能選不能建） |"""),
])

if not ok:
    sys.exit(1)
DOC_EDIT_PY_EOF

git add "$DOC_ROOT/CHANGELOG.md" "$DOC_ROOT/PROJECT-OVERVIEW.md" \
        "$DOC_ROOT/features/feature-dialplan.md" \
        "$DOC_ROOT/features/feature-dialplan-routing-rule.md" \
        "$DOC_ROOT/features/feature-dialplan-custom.md"

# ════════════════════════════════════════════════════════════════════════════
# 4. Commit
# ════════════════════════════════════════════════════════════════════════════
if ! git diff --cached --quiet; then
  git commit -m "docs: Dialplan Context 切換 UI 功能與相關 bug 修復的文件記錄"
else
  echo "ℹ️  沒有變更需要 commit（可能已經套用過）"
fi

# ════════════════════════════════════════════════════════════════════════════
# 5. reorg/ 版控狀態確認（比照 20260715-reorg-git-tracking-fix.md 的教訓）
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "reorg/ 版控狀態檢查（應無任何輸出，代表全部已追蹤、無未提交變更）："
git --no-pager status --porcelain -- "$DOC_ROOT/"

echo ""
echo "════════════════════════════════════════════════════"
git --no-pager log --oneline -6
echo "════════════════════════════════════════════════════"
echo ""
echo "文件變更清單（本次 commit）："
git --no-pager diff --stat HEAD~1 HEAD -- "$DOC_ROOT/" 2>/dev/null || true
echo ""
echo "⚠️  提醒：push 與 deploy.sh 保留手動確認（見 ops-github-workflow.md），"
echo "   請自行執行 git push，文件本身不需要 deploy.sh／systemctl restart。"
