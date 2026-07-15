# 除錯指令速查

> 原始來源：`Operations-Notes-20260626.md`，內容原封不動搬移，僅補充少數新指令

## 服務管理

```bash
systemctl restart fs-dashboard
systemctl status fs-dashboard --no-pager
journalctl -u fs-dashboard -n 50 --no-pager
```

## 服務無法啟動時（`Could not import module "server"` 等）

```bash
cd /opt/fs-dashboard
/opt/myapp/venv/bin/python -c "import server"   # 取得完整 traceback（journalctl 摘要看不到）
find /opt/fs-dashboard -maxdepth 3 -iname "server.py"   # 確認檔案位置是否正確
```

## IVR 除錯

```bash
# 確認 Lua 腳本版本（應包含 "內建解析器" 字樣）
grep "內建解析器\|json_decode" /usr/share/freeswitch/scripts/ivr_runner.lua

# 確認 JSON 設定（確認有 offhour_sound、invalid_retries 等欄位）
python3 -m json.tool /etc/freeswitch/ivr-menus/<ID>.json | grep -E "offhour|retries|final"

# 確認 Dialplan META 有對應欄位
head -1 /etc/freeswitch/dialplan/default/00_ivr_<ID>.xml | python3 -c "
import sys,re,json; s=sys.stdin.read()
m=re.search(r'DASHBOARD_IVR_META: (\{.*?\}) -->', s)
if m: d=json.loads(m.group(1)); print('offhour_sound:', d.get('schedule',{}).get('offhour_sound','NOT FOUND'))
"

# 撥號後查看 Lua 執行日誌
tail -f /var/log/freeswitch/freeswitch.log | grep "\[ivr\]"
```

## 號碼目錄 / 衝突檢查除錯

```bash
curl http://<host>:3000/api/numbers | python3 -m json.tool | grep '"number"'
```
瀏覽器 console 清除前端快取：`numClearCache()`

## 分機即時狀態

```bash
journalctl -u fs-dashboard -f | grep "REG_LOG"
curl http://<host>:3000/api/ext/status
curl http://<host>:3000/api/reg/log
```

## 群組管理

```bash
ls /etc/freeswitch/dialplan/default/00_group_*.xml
curl http://<host>:3000/api/groups/list | python3 -m json.tool
```

## ESL 連線即時重連

```bash
curl -X POST http://<host>:3000/api/config/reload \
  -H "Content-Type: application/json" \
  -d '{"host":"127.0.0.1","port":8055,"password":"<esl_password>"}'
```

## CDR 歸檔

```bash
ls -la /var/log/freeswitch/cdr-csv/
curl -X POST http://<host>:3000/api/cdr/rotate -v
```

## CDR SQLite 驗證（見 feature-cdr.md）

```bash
sqlite3 /opt/fs-dashboard/data/cdr.db "SELECT COUNT(*) FROM cdr; SELECT COUNT(*) FROM cdr_daily_summary;"
```

## Dialplan 編輯 API 測試

```bash
curl "http://<host>:3000/api/dialplan/file?path=/etc/freeswitch/dialplan/default/00_ivr_<ID>.xml"

curl -X POST http://<host>:3000/api/dialplan/file \
  -H "Content-Type: application/json" \
  -d '{"path":"/etc/freeswitch/dialplan/default/custom_test.xml","content":"<include/>"}'
```

## 停用 mod_signalwire（廣告訊息）

```bash
fs_cli -H 127.0.0.1 -P 8055 -p <esl_password> -x "unload mod_signalwire"
# 永久停用：在 modules.conf.xml 中註解 <load module="mod_signalwire"/>
```

## SIP/ACL 除錯（見 feature-sip-profile-acl.md）

```bash
curl -s http://<host>:3000/api/sip-profile/internal | python3 -m json.tool
curl -s http://<host>:3000/api/acl/trusted-sbc | python3 -m json.tool
fs_cli -x "acl <測試IP> trusted_sbc"
fs_cli -x "sofia status profile <name>"
```

## FreeSWITCH ESL 診斷指令參考（見 feature-recordings.md）

```bash
cat /etc/freeswitch/directory/default/<ext>.xml
fs_cli -H 127.0.0.1 -P 8055 -p <esl_password> -x "user_data <ext>@<domain> var recording_enabled"
fs_cli -H 127.0.0.1 -P 8055 -p <esl_password> -x "domain_exists <domain>"
fs_cli -H 127.0.0.1 -P 8055 -p <esl_password> -x "show registrations"
fs_cli -H 127.0.0.1 -P 8055 -p <esl_password> -x "reloadxml"
grep "<UUID>" /var/log/freeswitch/freeswitch.log | grep -v "CRIT"
find /var/lib/freeswitch/recordings/ -type f
```

## 使用者權限系統除錯（見 feature-permissions-auth.md）

```bash
curl -X POST http://<host>:3000/api/auth/bootstrap    # 全新環境第一次啟動必須手動呼叫
curl -X POST http://<host>:3000/api/auth/login -H "Content-Type: application/json" \
  -d '{"username":"admin","password":"<初始密碼>"}'
```
