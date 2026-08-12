# 新增「內線互撥」自訂 Dialplan 範本（限定分機清單）（2026-08-11）

> 承接 `changelog-details/20260811-dialplan-context-orphan-fix.md`：那次修好了「建立 context」
> 本身，但新建立的 context（如 `TC-ACSBC`）子資料夾內完全沒有任何規則，仍然無法撥打內線。
> 本篇記錄補上「讓自訂 context 也能撥打內部分機」的完整解法。

## 一、原始需求

`TC-ACSBC` 這個自訂 context 建好、也修復成 FreeSwitch 真正認得之後，使用者發現從這個
context 撥打內線分機（1126→1210）仍然打不通——因為 `default.xml` 的 `Local_Extension` 規則
只作用於 `default` context，自訂 context 完全沒有對應規則。

## 二、方案選擇

比對現有三種 Dialplan 管理入口：

| Tab | 定位 | 適用性 |
|---|---|---|
| 路由規則（類型一） | 外撥路由（Outbound Routing），欄位圍繞 `gateway_name` | 不適合，非為內線互打設計 |
| 系統內建（類型二） | `default.xml`/`public.xml` 唯讀 | 不能寫入自訂 context |
| 自定義（類型三） | 範本 + raw XML 編輯器 | ✅ 唯一可行路徑，但當時沒有內線互撥範本 |

決定在「自定義 Dialplan」新增一個「內線互撥」範本，而非要求使用者每次手動寫 raw XML。

## 三、設計決策

### 3.1 不比照 `default.xml` 開放整段號碼區間

`default.xml` 的 `Local_Extension` 用 `^(1[0-9]{3})$` 開放所有 `1xxx` 分機，這是「假設全部
分機都想在這個 context 互打」的設計。自訂 context（如只服務特定 SBC 來源的 `TC-ACSBC`）不一定
該有這種假設，改成讓使用者**明確勾選**要開放的分機清單，避免意外開放不該讓這個來源撥打的分機。

### 3.2 安全性考量：不重用 `/api/extensions/list`

原本想直接拿現有的分機清單 API 餵給前端勾選框，但那支 API 會**明碼回傳 SIP 密碼、語音信箱
密碼**：

```python
result.append({
    'id': ext_id,
    'password': params.get('password',''),        # ⚠️ 明碼
    'vm_password': params.get('vm-password',''),   # ⚠️ 明碼
    ...
})
```

單純為了畫面上列出分機號碼勾選，卻把所有密碼下載到前端（即使畫面沒顯示，開發者工具 Network
分頁看得到），且權限矩陣是 19 模組各自獨立設計（`feature-permissions-auth.md`），操作 Dialplan
頁面的人不一定該有 Extensions 模組的讀取權限。改為新增一支輕量端點
`GET /api/dialplan/custom/extension-options`，只回傳 `id`＋`caller_id_name`，掛在
`Module.DIALPLAN` 底下，不需要跨模組權限，也不會有密碼外洩風險。

### 3.3 表單框架擴充：`dynamic_multiselect` 欄位型別

既有 `TemplateField.type` 只有 `text/number/select/time` 四種，且 `select` 的選項是**寫死在
schema 裡的靜態清單**。新增 `dynamic_multiselect` 型別，多一個 `source` 屬性標示資料來源
（目前只有 `"extensions"`，為未來其他動態選項留擴充空間，例如未來可能的 gateway/sound 清單）。
這是表單框架本身的能力擴充，不是「只加一筆 TEMPLATES 就好」的常規範本新增。

## 四、途中發現並順手修復的既有 bug

排查過程中發現 `TemplateCreateRequest.context` 寫死：

```python
context: Literal["default", "public"] = "default"
```

但前端（`_dcContextOptionsHtml()`）早在 2026-07-16 就已經支援動態讀取 `/api/dialplan/contexts`
並可選任意既有 context——前後端行為互相矛盾，代表**範本模式自 2026-07-16 上線以來，其實從未
真正支援過 `default`/`public` 以外的 context**，選了必定被 Pydantic 擋在 422。這跟這次要做的
「內線互撥」範本直接相關：如果不修，新範本套用在 `TC-ACSBC` 上一樣會失敗。

一併修復：
- `TemplateCreateRequest.context` 改成格式驗證 + handler 內驗證「是否為真實存在的 context」
  （重用 `dialplan_routes.py` 的 `list_contexts()`，單向 import，不產生循環依賴）
- `list_custom_files()` 原本寫死只掃描 `("default", "public")`，導致寫進其他自訂 context 的
  範本檔案永遠不會出現在列表——改成掃描 `list_contexts()` 回傳的所有真實存在 context

## 五、實作與測試

### 5.1 後端（`routers/dialplan_custom.py`，`update47.sh`）

- `_gen_internal_extension()`：產生 XML，只開放勾選的分機（alternation pattern），支援
  「找不到人時：掛斷／轉語音信箱」
- 本機測試涵蓋：正常案例（XML 格式、`lxml` 驗證合法）、語音信箱模式、四種非法輸入（非數字分機、
  逾時超出範圍、缺欄位、非法選項）、XML 特殊字元 escape，全數通過
- `TemplateCreateRequest.context` 驗證邏輯獨立測試（`TC-ACSBC` 通過格式驗證、非法字元擋下、
  預設值向下相容），全數通過

### 5.2 前端（`static/js/dialplan.js`，`update47.sh`）

- `_dcFieldInputHtml()` 新增 `dynamic_multiselect` 渲染（先給占位容器，內容非同步填入）
- `_dcPopulateDynamicFields()`：非同步抓取選項、渲染勾選框 + 搜尋篩選
- `_dcCollectValues()`／`_dcBindFormEvents()` 同步支援新型別（收集勾選值、change 事件監聽）
- `node -c` 語法檢查通過，括號配對正確

### 5.3 實機驗證（`update47.sh` 部署後）

使用者實際测試：**用範本建立內線互撥後，1126 改用 `TC-ACSBC` 的 context 撥打 1210，成功接通**。

## 六、UX 迭代（實機測試後的回饋，`update48.sh`／`update49.sh`）

### 6.1 `update48.sh`：兩項可用性改善

1. **通話逾時秒數需要手動填才能存檔**：新增 `TemplateField.default`（真正的預設值，非僅
   placeholder），`call_timeout` 欄位新增時自動帶入 `"30"`，不動它也能通過必填驗證直接存檔
2. **100 支分機時勾選畫面太小**：勾選區從 180px 單欄列表放大成 320px 可捲動 + CSS Grid 多欄
   自動排列，新增「全選」「清除」按鈕（只作用於搜尋篩選後可見的項目，避免誤勾/誤清畫面外的
   分機）

本機用 Node.js 模擬 DOM 邏輯測試全選/清除的「只影響可見項目」邏輯，驗證通過。

### 6.2 `update49.sh`：修正版面被擠壓的問題

`update48.sh` 部署後實機測試發現：分機勾選區雖然放大了，但因為跟其他一般欄位共用同一種
「標籤＋輸入框＋說明文字」單行三欄版型，實際可用寬度被兩側標籤/說明文字擠壓變窄，導致還是
需要橫向捲動才看得到「清除」按鈕。

修復：`dynamic_multiselect` 型別的欄位改用**獨立直向版型**（標籤獨立一行、欄位佔滿整行寬度、
說明文字移到下方），不再跟其他欄位共用單行三欄版型；全選/清除按鈕列加上 `flex-wrap`，視窗
較窄時自動換行而非截斷。

實機驗證：使用者確認「測試結果正確」。

## 七、部署記錄

| Commit | 內容 |
|---|---|
| `update47.sh` | 新增內線互撥範本、修復 context 寫死 bug、新增輕量分機端點 |
| `update48.sh` | UX：預設逾時秒數、勾選區放大＋全選/清除 |
| `update49.sh` | UX：修正勾選區版面擠壓問題 |

三次部署皆先在本機模擬環境完整測試（前置驗證、精確字串替換、語法檢查、重複執行防護）後才
上線，且每次都有實機驗證或使用者實測確認。

## 八、後續待辦

- `TC-ACSBC` 目前已經有一條「內線互撥」規則（1126、1210），若之後有更多分機要加入，回到
  「自定義 Dialplan」頁面編輯該檔案即可（`editable_as_template` 機制支援範本建立的檔案回到
  表單編輯）
- `dynamic_multiselect` 型別目前只有 `source="extensions"` 一種來源，架構已為未來擴充留空間
  （例如若之後想做「選擇 Gateway」「選擇音檔」等類似的勾選型欄位，可以直接沿用同一套機制）
