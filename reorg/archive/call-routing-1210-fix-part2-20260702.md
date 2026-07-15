## 除錯（承接 call-routing-1210-fix-20260702.md）

### ✅ 通話約 30 秒自動斷線（`external` profile 的 `ext-sip-ip`/`ext-rtp-ip` 誤用 STUN 公網 IP）（2026-07-02）

**現象**：外線 `+886277286126` 撥入分機 1210，可正常響鈴、接通、雙向有聲音，但約 30 秒後自動斷線；`sofia global siptrace` 顯示 FreeSWITCH 主動送出 BYE，`Reason: SIP;cause=408;text="ACK Timeout"`。

**根本原因**：
- `sip_profiles/external.xml` 的 `ext-sip-ip`/`ext-rtp-ip` 設為 `$${external_sip_ip}`（STUN 偵測到的公網 IP `59.125.29.120`），**寫死套用在該 profile 所有對外訊息**，不受 `local-network-acl`（`localnet.auto`）影響（已用 `acl 192.168.100.220 localnet.auto` 驗證回傳 `true`，證明 ACL 判斷正確但對 ext-ip 無作用）。
- 通話建立後，Teams 端觸發 mid-call re-INVITE，AudioCodes SBC（內網 `192.168.100.220`）依 200 OK 裡的 `Contact: sip:1210@59.125.29.120:5080` 把後續 in-dialog 請求送往這個公網 IP，SBC 送不到該位址 → INVITE 重傳 6 次逾時 → FreeSWITCH Timer 逾時後主動掛斷。
- 與 `Bug-Fix-Notes-20260630.md` 中 `internal.xml` 的 `ext-sip-ip`/`ext-rtp-ip` 誤用 STUN 公開 IP（32 秒斷線）為**同一類問題**，當時只修了 `internal.xml`，未同步修 `external.xml`。

**修復**（`/etc/freeswitch/sip_profiles/external.xml`）：
```xml
<!-- 修改前 -->
<param name="ext-rtp-ip" value="$${external_rtp_ip}"/>
<param name="ext-sip-ip" value="$${external_sip_ip}"/>

<!-- 修改後：註解停用，全部走內網 IP -->
<!-- <param name="ext-rtp-ip" value="$${external_rtp_ip}"/> -->
<!-- <param name="ext-sip-ip" value="$${external_sip_ip}"/> -->
```
```bash
fs_cli -H 127.0.0.1 -P 8055 -p FSPyAdmin -x "sofia profile external restart"
```

**驗證方式**：
```bash
fs_cli -H 127.0.0.1 -P 8055 -p FSPyAdmin -x "sofia status profile external"
# Ext-RTP-IP / Ext-SIP-IP 應為 192.168.100.209（不再是 59.125.29.120）
```
外線撥打 1210，通話維持 20 秒以上觸發 re-INVITE，確認不再於約 30 秒後斷線。

**提醒**：
- `local-network-acl` 只影響 NAT **偵測**（判斷來源是否可信），**不會**改變 `ext-sip-ip`/`ext-rtp-ip` 這種寫死的靜態值套用範圍；兩者是獨立機制，排查時勿混為一談。
- 若日後 `external` profile 需同時服務真正需要 STUN 公網 IP 的 NAT 對象（例如新增公網 SIP trunk），**不要**在同一 profile 上用 ACL 混用，應另建獨立 profile（複製 `external.xml`、保留 `ext-sip-ip`/`ext-rtp-ip`），並在該 provider 的 gateway XML 指向新 profile，避免內網／公網端點互相干擾。
- 此類設定屬 `vars.py` 的 `VARS_BLACKLIST`（`external_sip_ip`/`external_rtp_ip`），Dashboard 網頁本就禁止編輯，須 SSH 直接改設定檔。

---

### ✅ 外線來電錄音檔案存在但 Dashboard 找不到（檔名解析正規式不支援 `+` 號）（2026-07-02）

**現象**：斷線問題修復後，1210 通話錄音檔實際已產生在 `/var/lib/freeswitch/recordings/YYYYMMDD/`，但 Dashboard 錄音管理頁面查無此筆記錄。

**根本原因**：`routers/recordings.py` 的檔名解析正規式只接受純數字開頭：
```python
_REC_FNAME_RE = _re.compile(
    r'^(?P<caller>\d+)_(?P<callee>\d+)_(?P<date>\d{8})_(?P<time>\d{6})_(?P<uuid>[^.]+)\.\w+$'
)
```
外線來電檔名為 `+886277286126_1210_20260702_155034_<uuid>.wav`（`caller_id_number` 帶 `+`），`\d+` 匹配不到開頭的 `+`，導致 `_parse_rec_filename()` 回傳全空字串。檔案仍會被 `sync_recordings_to_db()` insert 進 DB，但 `rec_dt` 為空字串，在 SQL 字串比較中恆小於任何 `YYYYMMDD_HHMMSS`，被前端預設的日期區間篩選排除，因此清單看不到。

**修復**（`routers/recordings.py`）：
```python
# 正規式放行選填的開頭 +
_REC_FNAME_RE = _re.compile(
    r'^(?P<caller>\+?\d+)_(?P<callee>\+?\d+)_(?P<date>\d{8})_(?P<time>\d{6})_(?P<uuid>[^.]+)\.\w+$'
)

def _parse_rec_filename(fname: str) -> dict:
    """從檔名解析 caller/callee/date/time，解析失敗回傳空字串"""
    m = _REC_FNAME_RE.match(fname)
    if m:
        return {
            "caller": m.group("caller"),   # 保留原始格式（含 + 號），與 CDR（cdr_db.py 存的 caller_id_number）格式一致
            "callee": m.group("callee"),
            "rec_date": m.group("date"),
            "rec_time": m.group("time"),
            "rec_dt":   m.group("date") + "_" + m.group("time"),
        }
    return {"caller": "", "callee": "", "rec_date": "", "rec_time": "", "rec_dt": ""}
```

> ⚠️ 曾一度改為 `.lstrip("+")` 去掉 `+` 號，但這會造成錄音表的 `caller` 跟 CDR 報表（`cdr_db.py` 直接存 FreeSWITCH 原始 `caller_id_number`，含 `+`）格式不一致，兩處統計對不起來，故最終**不 strip，保留原始格式**。

**套用**（改完程式後，清空索引 DB 強制以新規則重新解析既有檔案）：
```bash
python3 -c "
import sqlite3
conn = sqlite3.connect('/var/lib/freeswitch/recordings/.rec_index.db')
conn.execute('DELETE FROM recordings')
conn.commit()
conn.close()
"
systemctl restart fs-dashboard
```
> 環境未安裝 `sqlite3` CLI，改用 Python 標準庫 `sqlite3` 模組操作，效果相同。

**驗證方式**：
```bash
curl -s "http://127.0.0.1:<PORT>/api/recordings?extension=1210" | python3 -m json.tool
```
確認 `caller` 欄位為 `+886277286126`（與 CDR 格式一致）、`rec_date`/`rec_dt` 非空，Dashboard 錄音列表可正常顯示、播放。

**提醒**：
- 任何從 FreeSWITCH channel 變數（`caller_id_number` 等）組出的檔名／識別碼，只要來源可能是外線（PSTN），就必須考慮 `+` 國際碼前綴，正規式/解析邏輯不能假設純數字。
- 錄音庫（`recordings.py`）與 CDR（`cdr_db.py`）是兩套獨立儲存，號碼格式沒有共用的正規化層，未來若其中一邊改動號碼格式，需同步檢查另一邊是否對得起來。

---

**測試結果**：以上兩項修改已通過測試驗證，外線轉接分機 1210 通話穩定不再中途斷線，錄音檔案可正常被索引、顯示、播放，且來源號碼格式與 CDR 報表一致。
