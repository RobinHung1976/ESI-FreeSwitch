## 維運備忘

### 服務管理
```bash
systemctl restart fs-dashboard
systemctl status fs-dashboard --no-pager
journalctl -u fs-dashboard -n 50 --no-pager
```

### IVR 除錯
```bash
# 確認 Lua 腳本版本（應包含 "內建解析器" 字樣）
grep "內建解析器\|json_decode" /usr/share/freeswitch/scripts/ivr_runner.lua

# 確認 JSON 設定（確認有 offhour_sound、invalid_retries 等新欄位）
python3 -m json.tool /etc/freeswitch/ivr-menus/ESIAA.json | grep -E "offhour|retries|final"

# 確認 Dialplan META 有新欄位
head -1 /etc/freeswitch/dialplan/default/00_ivr_ESIAA.xml | python3 -c "
import sys,re,json; s=sys.stdin.read()
m=re.search(r'DASHBOARD_IVR_META: (\{.*?\}) -->', s)
if m: d=json.loads(m.group(1)); print('offhour_sound:', d.get('schedule',{}).get('offhour_sound','NOT FOUND'))
"

# 撥號後查看 Lua 執行日誌
tail -f /var/log/freeswitch/freeswitch.log | grep "\[ivr\]"
```

### 號碼目錄除錯
```bash
curl http://192.168.100.209:3000/api/numbers | python3 -m json.tool | grep '"number"'
```

### 號碼衝突檢查除錯
```bash
# 清除前端快取：在瀏覽器 console 執行
numClearCache()
```

### 分機即時狀態
```bash
journalctl -u fs-dashboard -f | grep "REG_LOG"
curl http://192.168.100.209:3000/api/ext/status
curl http://192.168.100.209:3000/api/reg/log
```

### 群組管理
```bash
ls /etc/freeswitch/dialplan/default/00_group_*.xml
curl http://192.168.100.209:3000/api/groups/list | python3 -m json.tool
```

### ESL 連線即時重連
```bash
curl -X POST http://192.168.100.209:3000/api/config/reload \
  -H "Content-Type: application/json" \
  -d '{"host":"127.0.0.1","port":8055,"password":"FSPyAdmin"}'
```

### CDR 歸檔
```bash
ls -la /var/log/freeswitch/cdr-csv/
curl -X POST http://192.168.100.209:3000/api/cdr/rotate -v
```

### Dialplan 編輯 API 測試
```bash
# 讀取檔案
curl "http://192.168.100.209:3000/api/dialplan/file?path=/etc/freeswitch/dialplan/default/00_ivr_ESIAA.xml"

# 儲存（含 XML 驗證 + reloadxml）
curl -X POST http://192.168.100.209:3000/api/dialplan/file \
  -H "Content-Type: application/json" \
  -d '{"path":"/etc/freeswitch/dialplan/default/custom_test.xml","content":"<include/>"}'
```

### 停用 mod_signalwire（廣告訊息）
```bash
fs_cli -H 127.0.0.1 -P 8055 -p FSPyAdmin -x "unload mod_signalwire"
# 永久停用：在 modules.conf.xml 中註解 <load module="mod_signalwire"/>