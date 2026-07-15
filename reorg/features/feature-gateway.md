# Gateway / SIP Trunk

> 對應頁面：管理 → Gateway / SIP Trunk｜前端：`static/js/gateway.js`｜後端：`routers/gateway.py`

## 功能概述

Gateway（SIP Trunk）CRUD，解析 `sofia status` 顯示 Profile 與 Gateway 即時狀態，寫入後自動 `reloadxml` + `sofia profile external rescan`。

## 儲存位置

XML 檔案：`/etc/freeswitch/sip_profiles/external/<name>.xml`

```xml
<include>
  <gateway name="{name}">
    <param name="username" value="{username}"/>
    <param name="password" value="{password}"/>
    <param name="proxy" value="{proxy}"/>
    <param name="register" value="{register}"/>
    <param name="extension" value="{extension or username}"/>
    <param name="caller-id-in-from" value="{caller_id_in_from}"/>
  </gateway>
</include>
```

## 後端 API

| Method | Endpoint | 說明 |
|---|---|---|
| `GET` | `/api/gateway/list` | 列出所有 Gateway XML |
| `POST` | `/api/gateway` | 新增（409 若同名已存在） |
| `PUT` | `/api/gateway/{name}` | 更新（自動備份 `.bak.<timestamp>`） |
| `DELETE` | `/api/gateway/{name}` | 刪除（自動備份） |

新增/更新/刪除皆自動呼叫 `esl.api('reloadxml')` + `esl.api('sofia profile external rescan')`。

## 前端顯示

**Sofia Profile 表**：解析 `sofia status` 文字輸出，抓 `profile`/`gateway`/`alias` 三種 type 分行。

**Gateway/Trunk 表**：狀態顏色對照：

| state | 顯示 |
|---|---|
| `RUNNING*` | RUNNING（綠） |
| `REGED` | REGED（綠） |
| `NOREG` | NOREG（灰，代表不需註冊型 Trunk） |
| `FAILED` | FAILED（紅） |
| `ALIASED` | ALIASED（黃） |

每列同時顯示該 Gateway 目前通話數（比對 `/api/calls` 的 dest/name 是否含 gateway host）、Proxy 位址，以及編輯/刪除/重掃按鈕。若 XML 設定檔缺失（僅 `sofia status` 有資料但無對應設定檔），顯示「無設定檔」，隱藏編輯/刪除按鈕。
