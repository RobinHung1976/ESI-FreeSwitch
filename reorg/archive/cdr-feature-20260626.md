## 通話記錄 CDR 功能

### 雙 Tab 架構

**📞 即時 CDR**：`/api/cdr`（讀取 `Master.csv`）、關鍵字搜尋、狀態篩選、分頁、CSV 匯出

**📋 歷史 CDR**：日期下拉選單 `/api/cdr/archives`、前端解析 CSV、搜尋篩選分頁匯出

### CDR 方向判斷邏輯（後端 `_cdr_direction()`）

| context | caller_num | destination | 結果 |
|---------|-----------|-------------|------|
| `public` | 任意 | 任意 | `inbound`（來電） |
| `default` | ≤4 位數字 | ≤4 位數字 | `internal`（內線） |
| `default` | ≤4 位數字 | 其他 | `outbound`（出撥） |
| 其他 | 任意 | 任意 | `inbound`（來電） |

---