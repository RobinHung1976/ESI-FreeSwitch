# 使用者密碼管理工具新增 + reset-password 開放 force_change 參數

日期:2026-07-15
對應腳本:`update8.sh`(已在 production server `debian-freeswitch` 執行成功並部署)
背景:需要一套方便重設使用者密碼的工具(含「重設後是否強制下次登入改密碼」的選項),以及忘記所有 admin 密碼時的救援手段。過程中發現後端 API 尚未開放這個選項,順手修正。

## 一、核對現況與釐清的誤解

動手前先核對了 `routers/users.py`、`core/auth.py`、`core/auth_db.py` 原始碼,釐清兩個原本以為的假設:

1. **密碼是單向雜湊(`hashlib.pbkdf2_hmac`,600,000 次迭代),沒有辦法「查看」既有使用者的密碼**,任何工具都只能「重設」,不能「顯示」或「還原」。
2. **`core/auth_db.py` 的 `reset_password(user_id, new_password, force_change=True)` 其實本來就支援 `force_change` 參數**,問題出在 `routers/users.py` 的 `ResetPasswordRequest` 沒有開放這個欄位、呼叫時寫死 `force_change=True`,導致 API 層無法選擇「是否強制改密碼」。

## 二、後端修改(`update8.sh`)

`routers/users.py` 兩處精確字串取代:

```python
# 修改前
class ResetPasswordRequest(BaseModel):
    new_password: str = Field(min_length=8)
...
    auth_db.reset_password(user_id, body.new_password, force_change=True)

# 修改後
class ResetPasswordRequest(BaseModel):
    new_password: str = Field(min_length=8)
    force_change: bool = True  # 是否強制下次登入改密碼(預設 True,維持原行為)
...
    auth_db.reset_password(user_id, body.new_password, force_change=body.force_change)
```

`core/auth_db.py` **未修改**(它本來就支援這個參數)。

**部署步驟**:`update8.sh` → `systemctl restart fs-dashboard`(Pydantic 欄位變更必須重啟才生效,純新增可選欄位、預設值不變,向下相容)。

## 三、新增的兩支維運工具

### 1. `userpwreset.sh`(平時操作用,呼叫既有 REST API)

- 在管理者自己的電腦(或任何能連到 dashboard 的機器)執行,不需要在 server 上跑
- 流程:登入拿 JWT → 列出所有使用者(`GET /api/users`,顯示帳號/群組/分機/狀態/待改密碼標籤)→ 選擇要重設密碼的使用者 → 選擇自動產生或手動輸入新密碼 → 選擇是否強制下次登入改密碼 → 呼叫 `POST /api/users/{id}/reset-password`
- 需要 `curl` + `jq`

### 2. `admin-recover.py`(緊急救援用,忘記所有 admin 密碼時使用)

- **必須在 server 本機(`/opt/fs-dashboard`)用專案的 venv 執行**,完全繞過 HTTP/JWT 驗證
- 直接 `import core.auth_db`,呼叫系統本來的 `list_users()` / `reset_password()` 函式,雜湊邏輯與正常 API 完全一致,不會弄壞密碼格式
- 設計原則:救援門檻設在「有沒有主機檔案系統存取權」,而非任何知道帳號名稱的人都能透過網路觸發,避免救援機制本身變成攻擊面
- 執行前會提示先備份 `data/auth.db`

## 四、測試過程中發現並修復的 bug

### `userpwreset.sh` 的 `login()` 函式:多餘 `echo` 污染回傳值

- **現象**:在 server 上實際執行時,`jq: parse error: Invalid numeric literal at line 1, column 8`,登入本身用 `curl` 手動測試是正常的,但腳本跑起來就出錯
- **原因**:`login()` 函式裡,密碼輸入完後有一行單純為了畫面換行用的 `echo`,沒有導向 `stderr`,導致這個空白換行被 `token=$(login)` 一併捕捉進去,使 `token` 變數變成 `"\n<真正的token>"`(開頭多一個換行字元)。之後組 `Authorization: Bearer ${token}` header 時,header 值裡含有非法的換行字元,導致後續 `GET /api/users` 的請求不如預期,回應內容無法被 `jq` 正確解析
- **修復**:`echo` 改成 `echo >&2`,不再污染函式的 stdout 回傳值
- **驗證**:重新執行,使用者清單正常顯示,後續重設密碼流程(含 `force_change:false`)實測正常

## 五、Production 實測結果

於 `debian-freeswitch` 實機測試 `admin`(id=1)帳號:

| 操作 | 結果 |
|---|---|
| `force_change:false` | `must_change_password` 欄位變為 `0` ✅ |
| `force_change:true`(或省略,測試預設值) | `must_change_password` 欄位變為 `1` ✅,向下相容沒有被破壞 |

`update8.sh` 執行前也做過沙箱 git repo 的完整流程實測(含重複執行的冪等性測試),確認前置驗證、精確字串取代、自動歸檔、commit 皆正常。

## 六、已知後續待處理

- `userpwreset.sh`、`admin-recover.py` 目前已由使用者手動 `git rm --cached` 移出版控追蹤(避免救援工具本身的存在被記錄在 repo 歷史裡),`.gitignore` 已補上對應項目
- `feature-permissions-auth.md` 第五節的 API 端點清單需要同步更新 `reset-password` 的 request body 說明(見下方對照表),本次未直接改動該文件,待使用者自行套用
- Server 的 SSH session locale 未設 UTF-8,導致 `git log --oneline` 中文 commit message 在終端機顯示亂碼(僅顯示問題,commit 內容本身正常),非本次改動範圍,不影響功能

### `feature-permissions-auth.md` 建議同步更新的內容

第五節 `routers/users.py` 端點清單下方,建議在 `reset-password` 端點旁補充:

> `POST /api/users/{id}/reset-password` 的 request body 新增 `force_change: bool = True`(預設 `True` 維持原行為),可選擇重設後是否強制下次登入改密碼。`core/auth_db.py` 的 `reset_password()` 函式本來就支援此參數,是 API 層原本沒開放。詳見 `changelog-details/20260715-user-password-management-tools.md`。

---

**測試結果**:`update8.sh` 已於 production server 實際執行並部署成功(含服務重啟、健康檢查、實測 `force_change=true/false` 兩種情境),`userpwreset.sh` 修復後於同一台 server 實測使用者清單顯示與密碼重設流程皆正常。
