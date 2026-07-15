## 系統日誌功能

### Tab 1：📡 即時日誌
- SSE 串流 `tail -n 500 -f freeswitch.log`
- 分頁瀏覽（緩衝 5000 筆，每頁 100/200/500/1000 行）
- 等級過濾：ALL / ERR / WARN / NOTICE / INFO / DEBUG / 📞 通話 / 🔐 登錄

### Tab 2：📅 歷史日誌
- 日期下拉選單、等級篩選、關鍵字搜尋（後端）、分頁、下載

### Tab 3：🔐 登錄記錄
- ESL `REGISTER`/`UNREGISTER` 事件捕捉，最多 200 筆

### Tab 4：🗂 日誌管理
- 歷史日誌檔案列表、🔄 立即輪轉

### Log 每日自動排程（00:00:30）
1. 日誌歸檔 → `freeswitch-YYYY-MM-DD.log`
2. 日誌清理（超過 `log_retain_days` 天）
3. CDR 歸檔 → `cdr-YYYY-MM-DD.csv`
4. CDR 清理（超過 `cdr_retain_days` 天）
