## 號碼衝突檢查

分機、群組、IVR 新增/變更號碼時，自動比對號碼目錄（含 FreeSwitch 保留號碼）：

```javascript
async function numCheckConflict(inputId, conflictDivId, number, selfType)
let _numCache = null;  // 30 秒 TTL
function numClearCache()
```

**觸發時機：**
- 分機/IVR 號碼輸入欄 `oninput` 即時檢查
- 群組「🔄 變更號碼」confirm 之前
- `saveGroup()` 新增模式儲存之前

**顯示狀態：**

| 狀態 | 顯示 |
|------|------|
| 空白 | 無提示 |
| 可用 | `✓ 號碼可用`（綠色） |
| 衝突 | `⚠️ 號碼 XXXX 已被 🔒 FreeSwitch 內建「Conference Bridge」佔用`（紅色） |

---