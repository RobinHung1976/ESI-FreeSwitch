# 「建立新 context」功能只做半套，導致空殼 context 造成分機無法撥出（2026-08-11）

> 對應 `PROJECT-OVERVIEW.md` 已知待處理事項第 13 點（原記錄為「分機 Context 表單缺少防呆」，
> 排查後發現根因層級更高，本篇記錄完整修復，第 13 點結案）。承接
> `changelog-details/20260811-user-not-registered-verification.md` 查證過程中意外發現的插曲。

## 一、現象

分機 1126 的 Context 欄位被設成 `TC-ACSBC`，導致該分機完全無法撥出任何電話，log 顯示：

```
Processing ESI-Robin1126 <1126>->1210 in context TC-ACSBC
Context TC-ACSBC not found
No Route, Aborting
Hangup ... [NO_ROUTE_DESTINATION]
```

使用者已自行把該分機的 context 改回 `default` 排除故障。原本以為是「分機表單缺少防呆，讓人選到不存在的 context」，但查證後發現問題比這個假設嚴重得多。

## 二、根因排查

### 2.1 第一層假設（錯誤）：`TC-ACSBC` 資料夾不存在

原本假設是分機表單允許填入清單外的值。查證：

```bash
ls -la /etc/freeswitch/dialplan/TC-ACSBC/
```

**結果：資料夾確實存在**（`Jul 16 13:42` 建立，剛好是「Dialplan Context 切換 UI」功能
2026-07-16 上線同一天），但**內容完全是空的**。這推翻了第一層假設——`/api/dialplan/contexts`
是掃資料夾產生清單的，`TC-ACSBC` 本來就會出現在下拉選單裡，不是「選到清單外的值」。

### 2.2 第二層排查：FreeSwitch 到底認不認得這個 context

```bash
grep -rl 'context name="TC-ACSBC"' /etc/freeswitch/
```

**結果：完全零命中**。整個 `/etc/freeswitch/` 底下，從未有任何地方真正定義過
`<context name="TC-ACSBC">`。

FreeSwitch 要真正認得一個 context，需要在 `/etc/freeswitch/dialplan/` **頂層**有一個 XML
檔案定義 `<context name="...">`（例如 `default.xml` 裡的 `<context name="default">`）。
子資料夾（如 `TC-ACSBC/`）只是被這個頂層檔案用 `<X-PRE-PROCESS cmd="include"
data="TC-ACSBC/*.xml"/>` 引入規則檔案用的容器，**單純 `mkdir` 一個子資料夾，FreeSwitch
完全不會把它視為合法 context**。

### 2.3 追到真正根因：`routers/dialplan_routes.py` 的 `create_context_dir()` 從一開始就只做半套

```python
def create_context_dir(context: str) -> str:
    """建立新的 context 資料夾（純 mkdir，不做任何 SIP Profile／轉接綁定）。"""
    ...
    os.makedirs(path, exist_ok=False)
    return path
```

這支函式自 2026-07-16「Dialplan Context 切換 UI」功能上線以來，就只做 `mkdir`，從未產生
FreeSwitch 真正需要的頂層 `<context name="...">` 定義檔。`feature-dialplan-custom.md`
其實有記載一句警語：「純 mkdir，仍需另外到 SIP Profile 或其他 dialplan 設定中讓某個來源指向
這個 context 才會生效」——但這句話的措辭把問題講得太輕描淡寫，讓人誤以為「只要之後補一個來源
綁定就能用」，實際上**即使真的補了來源綁定，通話依然會 100% 失敗**，因為 FreeSwitch 的 XML
設定層根本不認識這個 context 名稱，跟有沒有來源指向它完全無關。

### 2.4 影響範圍確認

```bash
for dir in /etc/freeswitch/dialplan/*/; do
  ctx=$(basename "$dir")
  [ "$ctx" = "skinny-patterns" ] && continue
  if ! grep -rq "context name=\"$ctx\"" /etc/freeswitch/ 2>/dev/null; then
    echo "⚠ 空殼 context：$ctx"
    ls -la "$dir"
  fi
done
```

**結果：只有 `TC-ACSBC` 一個空殼**，沒有擴散到其他 context，是單一個案，非普遍性資料損毀。

## 三、修復（`update46.sh`，commit `7b2d987`）

### 3.1 `create_context_dir()`：從「只做半套」改成「真正做完整」

```python
CONTEXT_TOP_LEVEL_TEMPLATE = """<include>
  <context name="{ctx}">
    <X-PRE-PROCESS cmd="include" data="{ctx}/*.xml"/>
  </context>
</include>
"""
```

建立新 context 時同時：
1. 建立子資料夾（跟原本一樣）
2. **新增**：在頂層寫入 `<ctx>.xml`，內容比照 `default.xml` 的骨架
3. **新增**：呼叫 `force_reload()` 讓 FreeSwitch 立即生效，不需等下次重啟或手動 reloadxml
4. 任一步失敗就清掉已建立的東西，不留下另一個半成品
5. 擋掉 `default`／`public` 這兩個 FreeSwitch 系統保留字，避免誤建同名 context 蓋掉系統內建

### 3.2 `list_contexts()`：加上真偽校驗（防禦性更強，防住任何來源造成的空殼）

新增 `_context_has_definition(ctx)`，檢查頂層是否真的存在 `<context name="ctx">` 定義。
只有「資料夾存在」且「頂層有定義」兩個條件都滿足，才會出現在 `/api/dialplan/contexts`
清單裡。這樣即使未來有人繞過 Dashboard 直接 SSH 建立空資料夾，也不會出現在可選清單，不會再
有人選到壞掉的選項——不只是修好 API 這條路徑，是從資料真偽本身做防禦。

### 3.3 API 警語文字同步更新

`POST /api/dialplan/contexts` 的回應警語從「已建立資料夾，但尚未與任何來源綁定」改為
「已建立可用的 context（含頂層定義，FreeSwitch 已可辨識並立即生效）。仍需自行到 SIP
Profile 或其他 dialplan 設定中，讓某個來源實際指向這個 context 名稱，該來源的通話才會真正
進入此 context」——講清楚「context 本身已經能用」跟「還要另外設定來源才會有電話真的打進來」
是兩件獨立的事，不要再讓人誤解。

## 四、部署與實機驗證

### 4.1 程式碼修復部署

`update46.sh`：前置驗證 + 整份覆寫 `routers/dialplan_routes.py` + 語法檢查 + 自動歸檔，
本機模擬環境完整測試 6 種情境（空殼被排除／新建正確生效／保留字擋下／重複建立擋下／格式驗證／
補完後重新出現）全數通過後才部署到 production server。

實機驗證（`systemctl restart fs-dashboard` 後）：

```bash
curl -s http://127.0.0.1:3000/api/dialplan/contexts -H "Authorization: Bearer $TOKEN"
# {"contexts":["default","public","skinny-patterns"]}  ← TC-ACSBC 正確消失

curl -s -X POST http://127.0.0.1:3000/api/dialplan/contexts \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"context":"test_ctx_verify"}'
# {"ok":true, ...}

cat /etc/freeswitch/dialplan/test_ctx_verify.xml
# <include><context name="test_ctx_verify">...</context></include>  ← 頂層定義正確產生

curl -s http://127.0.0.1:3000/api/dialplan/contexts -H "Authorization: Bearer $TOKEN"
# {"contexts":[...,"test_ctx_verify"]}  ← 免手動 reloadxml，立即生效

curl -s -X POST http://127.0.0.1:3000/api/dialplan/contexts \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"context":"default"}'
# {"detail":"「default」為 FreeSwitch 系統保留 context 名稱，不可重複建立"}  ← 保留字正確擋下
```

全數符合預期，測試殘留 `test_ctx_verify` 已清除。

### 4.2 `TC-ACSBC` 既有空殼補完（方案 A：補完整，使用者決議）

比照 `create_context_dir()` 修復後產生的完全相同樣板，手動補上頂層定義：

```bash
cat > /etc/freeswitch/dialplan/TC-ACSBC.xml << 'EOF'
<include>
  <context name="TC-ACSBC">
    <X-PRE-PROCESS cmd="include" data="TC-ACSBC/*.xml"/>
  </context>
</include>
EOF
fs_cli -x "reloadxml"
```

驗證：

```bash
curl -s http://127.0.0.1:3000/api/dialplan/contexts -H "Authorization: Bearer $TOKEN"
# {"contexts":["TC-ACSBC","default","public","skinny-patterns"]}  ← 重新出現

# 全域空殼掃描，確認不再有任何空殼 context
for dir in /etc/freeswitch/dialplan/*/; do ... done
# 無輸出 ← 確認乾淨
```

`TC-ACSBC` 現在是 FreeSwitch 真正認得的合法 context，但**子資料夾內容仍是空的**（沒有任何
路由規則）。若原本規劃要在裡面放特定撥號規則，或要讓某個 SIP Trunk/Gateway 指向它，需要
另外設定，不在本次修復範圍內。

## 五、結論

- `TC-ACSBC` 空殼問題已完整修復，且從根本上修好造成問題的功能（`create_context_dir()`），
  不是單純針對 1126 這一支分機補洞
- 影響範圍確認為單一個案，未擴散
- `feature-dialplan-custom.md` 的警語文字需要同步更新，反映修復後的正確行為描述（見
  「後續待辦」）

## 六、後續待辦

- `feature-dialplan-custom.md`／`feature-dialplan.md` 的 Context 相關描述需要更新，反映
  `create_context_dir()` 修復後的正確行為（目前仍描述舊版「純 mkdir」的行為）
- `TC-ACSBC` 子資料夾仍是空的，若有計畫要實際使用（放路由規則、綁定 SIP Trunk 來源），
  需要另外處理，非本次範圍
