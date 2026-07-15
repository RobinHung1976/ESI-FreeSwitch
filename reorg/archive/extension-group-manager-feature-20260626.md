## 分機群組管理

### 檔名規則
- **新建**：`00_group_<id>.xml`（確保 Dialplan 載入順序在一般分機前）
- **舊格式相容**：`list`、`update`、`delete` 同時支援 `group_<id>.xml`
- **自動升級**：PUT 時若找到舊格式，自動備份並重命名為新格式

### XML 結構
- `<!-- DASHBOARD_GROUP_META: {...} -->` JSON 註解存放設定
- 支援 `simultaneous`（同時響鈴）和 `sequential`（依序響鈴）
- fallback：voicemail / 轉接分機 / 掛斷
