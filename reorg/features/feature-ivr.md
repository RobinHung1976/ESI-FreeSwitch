# IVR 管理

> 對應頁面：管理 → IVR 管理｜前端：`static/js/ivr.js`｜後端：`ivr_runner.lua` + server 端 IVR API
> 演變歷史：[20260626 IVR 功能與直撥分機](../changelog-details/20260626-ivr-feature.md)

## 功能概述

按鍵選單、直撥分機、時段路由（含 offhour 語音）、無效鍵/超時重播次數控制、SVG 流程圖即時預覽。編輯器左側表單（60%）+ 右側即時流程圖預覽（40%，可全螢幕展開）。

## 按鍵動作類型

| action_type | 說明 | target |
|---|---|---|
| `extension` | 轉接分機 | 分機號碼 |
| `group` | 轉接群組 | 群組號碼 |
| `ivr` | 子選單 | IVR ID |
| `voicemail` | 語音信箱 | 分機號碼 |
| `playback` | 播放後掛斷 | 音檔完整路徑 |
| `hangup` | 掛斷 | 空 |

特殊按鍵 `t`（超時）、`i`（無效鍵）在「無效鍵/超時行為設定」整合卡片設定，不在一般按鍵清單顯示。

## 直接轉接 / 播後轉接

- `auto_transfer`：進入 IVR 後立即轉接，跳過語音與按鍵
- `post_greeting_transfer`：播完 greeting 後自動轉接，不等按鍵
- 兩者結構相同：`{ enabled, action_type, target }`

## 無效鍵 / 超時重播控制

`invalid_retries`/`timeout_retries` 設定第幾次觸發才執行最終行為：

| 次數 | 無效鍵行為 | 超時行為 |
|---|---|---|
| 前 N-1 次 | 播 `invalid_sound` → 重播 `menu_sound` | 播 `exit_sound` → 重播 `menu_sound` |
| 第 N 次（最後） | 播 `invalid_final_sound` → 執行 `keys["i"]` | 播 `timeout_final_sound` → 執行 `keys["t"]` |

最後一次跳過每次提示音，只播最終語音，避免重疊。

## 時段路由（Schedule）

```json
{
  "schedule": {
    "enabled": true, "work_start": "09:00", "work_end": "18:00", "work_days": [1,2,3,4,5],
    "offhour_action": { "action_type": "group", "target": "7001" },
    "holiday_action": { "action_type": "voicemail", "target": "1001" },
    "offhour_sound": "/path/to/offwork.wav",
    "holiday_dates": []
  }
}
```

`offhour_action`/`holiday_action` 支援所有 `action_type`，優先於舊式 `offhour_target`/`holiday_target` 字串（向下相容 fallback，舊 IVR 設定不需重存即可繼續運作）。`offhour_sound` 播完後才路由。

## 直撥分機

來電者可直接輸入完整分機號碼轉接，不需預先在按鍵選單逐一定義。單鍵選單與直撥並存，按鍵比對優先。`direct_ext_dialing`/`direct_ext_digits`/`direct_ext_prefix` 控制位數與前綴。

## 可搜尋下拉選單

分機/群組/IVR 子選單選擇器改用自製 Searchable Select（`_ivrSearchableSelect()`），純原生 HTML/CSS/JS，取代原生 `<select>`（超過 20 項後難以搜尋）。

## SVG 流程圖

動態計算層號（依實際存在節點決定優先序，避免空洞），節點含：入口 → 排程（若啟用）→ 選單 → 直接轉接/播後轉接/按鍵節點。可全螢幕展開檢視大流程圖。

## 音檔選擇

IVR 各語音欄位（greeting/menu_sound/invalid_sound 等）從音檔庫（見 `feature-sounds.md`）選擇，共用同一組 `/api/sounds/*` API。
