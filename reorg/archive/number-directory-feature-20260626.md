## 號碼目錄

### 資料來源整合

| 來源 | 類型標籤 | 掃描方式 |
|------|---------|---------|
| `/etc/freeswitch/directory/default/*.xml` | 📞 分機 | 現有 API |
| `00_group_*.xml` | ▣ 群組 | 現有 API |
| `00_ivr_*.xml`（有入口號碼者） | 🎛 IVR | 現有 API |
| 全 Dialplan 目錄（排除 Dashboard 管理檔） | 📋 自定義 | 後端掃描 |
| 硬編碼清單 | 🔒 FreeSwitch 內建 | 保留號碼段（見下表） |

### FreeSwitch 保留號碼段（禁用）

| 號碼段 | 用途 |
|--------|------|
| `0000–0002` | 測試音訊（echo、MoH、info） |
| `2000–2002` | Conference Bridge 會議室 |
| `3000–3013` | Call Center 相關 |
| `4000` | Valet Parking |
| `5000` | Directory（dial-by-name） |
| **`5001–5002`** | **Conference Bridge（外連 conference.freeswitch.org，⚠ 曾導致 NORMAL_TEMPORARY_FAILURE）** |
| `6000` | Park & Retrieve |
| `9195–9199` | 測試音訊 |
| `9888` | Voicemail 入口 |

> ✅ **建議群組使用 `7XXX`（如 7001、7002），IVR 使用 `9900`、`9901` 等**

### 前端功能

- **統計卡片**：各類型數量，可點擊篩選
- **禁用號碼清單卡片**：可摺疊，展示所有保留號碼段及說明，`5001/5002` 特別標示 ⚠️
- **類型 Tab 篩選**：全部 / 分機 / 群組 / IVR / 自定義 / 內建
- **即時搜尋**：局部更新 tbody，搜尋欄焦點不丟失
- **→ 前往管理**：點擊跳轉對應管理頁（分機/群組/IVR）
- **⬇ 匯出 CSV**：UTF-8 BOM，Excel 可直接開啟中文

---