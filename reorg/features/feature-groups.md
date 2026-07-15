# 分機群組（Groups）

> 對應頁面：管理 → 分機群組｜前端：`static/js/extensions-groups.js`｜後端：`routers/groups.py`
> 演變歷史：[20260626 分機群組管理](../changelog-details/20260626-extension-group-manager-feature.md)

## 功能概述

同時／依序響鈴的分機群組 CRUD，成員多選 chip UI，無人接聽 fallback（voicemail / 轉接分機 / 掛斷），支援 🔄 變更號碼（比照分機管理的三步驟原子操作），儲存時做號碼衝突檢查（見 `feature-numbers-conflict-check.md`）。

## 檔名規則

- **新建**：`00_group_<id>.xml`（確保 Dialplan 載入順序在一般分機前）
- **舊格式相容**：`list`/`update`/`delete` 同時支援 `group_<id>.xml`
- **自動升級**：`PUT` 時若找到舊格式，自動備份並重命名為新格式

## XML 結構

- `<!-- DASHBOARD_GROUP_META: {...} -->` JSON 註解存放設定（響鈴模式、成員清單、fallback）
- 響鈴模式：`simultaneous`（同時響鈴）／`sequential`（依序響鈴）
- 無人接聽 fallback：voicemail / 轉接分機 / 掛斷

## 號碼建議

FreeSwitch 保留 `5001`/`5002` 給內建 Conference Bridge，群組號碼建議使用 `7XXX` 號段（見 `feature-numbers.md` 保留號碼段表）。

## 相關檔案

分機群組與「權限群組」（`feature-permissions-auth.md` 的 `perm_groups`）是完全不同的概念，命名容易混淆但資料表與程式碼刻意分開，group 這裡指的是撥號用的通話群組（callgroup 概念延伸）。
