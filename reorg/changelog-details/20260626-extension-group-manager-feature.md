# 分機群組管理功能 — 2026-06-26

> 原始來源：`extension-group-manager-feature-20260626.md`；現況已併入 `feature-groups.md`

檔名規則設計：新建統一用 `00_group_<id>.xml`（確保 Dialplan 載入順序在一般分機前），`list`/`update`/`delete` 同時支援舊格式 `group_<id>.xml` 向下相容，`PUT` 時若偵測到舊格式會自動備份並重命名為新格式。

XML 結構採 `<!-- DASHBOARD_GROUP_META: {...} -->` JSON 註解存放設定（同時/依序響鈴模式、成員清單、無人接聽 fallback：voicemail/轉接分機/掛斷）。

詳細現況已完整併入 `feature-groups.md`。
