##除錯

### ✅ 通話約 32 秒自動掛斷（2026-06-18）
`internal.xml` 的 `ext-sip-ip`/`ext-rtp-ip` 誤用 STUN 公開 IP，ACK 遺失後 Timer H 逾時。
**修復**：在 `sip_profiles/internal.xml` 註解掉這兩個參數，`sofia profile internal restart`。

### ✅ 分機/Gateway 編輯刪除 500 錯誤（2026-06-18）
`import datetime` 與 `from datetime import datetime, date` 命名衝突。
**修復**：統一改為 `from datetime import datetime, timedelta, date`。

### ✅ 群組撥號 NORMAL_TEMPORARY_FAILURE（2026-06-22 / 2026-06-25）
**根本原因**：群組號碼 `5001` 被 FreeSwitch 內建 Conference Bridge Dialplan 攔截，連線至外部 `conference.freeswitch.org` 失敗。
**修復**：
- `FS_RESERVED` 清單補上 `5001`、`5002`
- `create_group` API 加入完整保留號碼比對
- 前端 `saveGroup()` 和 `changeGroupNumber()` 在確認前先做號碼衝突檢查
- 群組號碼改用 `7001`（`7XXX` 號段安全）

### ✅ 群組 bridge 字串 `@${domain_name}` 未展開（2026-06-22）
**修復**：改為 `user/1001`（不帶 domain），FreeSwitch 自動查預設 domain。

### ✅ 歷史日誌大檔造成瀏覽器卡頓（2026-06-22）
**修復**：後端分頁 API + 前端分頁瀏覽 + DocumentFragment 批次插入 DOM。

### ✅ 自動刷新與 WebSocket 狀態衝突（2026-06-23）
**修復**：完全移除 `setInterval` 輪詢，改為純事件驅動。

### ✅ 分機登錄狀態不即時更新（2026-06-23）
**根本原因**：① REGISTER 事件是 CUSTOM subclass，② ESL 封包 body 未解析，③ reg_user 帶 `@realm` 比對失敗。
**修復**：修正 `read_packet()` 解析 body、remap CUSTOM 事件、normalize reg_user。

### ✅ CDR 方向判斷不精準（2026-06-23）
**修復**：新增 `_cdr_direction()` 以 `context` 欄位為主要依據。

### ✅ 設定頁 ESL 連線設定無法即時套用（2026-06-23）
**修復**：新增 `POST /api/config/reload`；`esl_client.py` 加入 `reconnect()` 方法。

### ✅ `python-multipart` 未安裝導致服務無法啟動（2026-06-24）
**修復**：`/opt/myapp/venv/bin/pip install python-multipart`

### ✅ `mod_ivr` 不存在（2026-06-24）
**修復**：改用 `mod_lua`，通用引擎 `ivr_runner.lua` 讀取 JSON 設定執行 IVR。

### ✅ Dialplan 巢狀 condition 錯誤（2026-06-24）
**修復**：時段路由完全移入 Lua 層，Dialplan 只做 `answer` + `lua ivr_runner.lua <id>`。

### ✅ cjson 模組不可用（2026-06-24）
FreeSwitch Lua 環境未安裝 cjson，`JSON 解析失敗` 導致 IVR 掛斷。
**修復**：`ivr_runner.lua` 內建約 80 行純 Lua JSON 解析器，零外部依賴，支援 cjson → cjson.safe → dkjson → json → 內建解析器的優先順序。

### ✅ `os.date("*t")` 欄位 nil 導致 check_schedule 崩潰（2026-06-25）
**根本原因**：`string.format("%04d-%02d-%02d", t.year, t.month, t.mday)` 中 FreeSwitch Lua 環境的 `os.date("*t")` 回傳欄位為 nil。
**修復**：改用 `os.date("%Y")`、`os.date("%m")` 等字串格式各自取值。

### ✅ IVR 無效鍵/超時邏輯錯誤（2026-06-25）
**問題**：① `while attempts < retries` 迴圈在未達上限時 `attempts` 不增加造成邏輯矛盾；② 最後一次會同時播 `invalid_sound` 和 `invalid_final_sound` 衝突；③ 未達上限時沒有重播 IVR。
**修復**：改為 `while session:ready()` + `safety_limit=50` 安全上限；無效鍵/超時各自獨立計數；最後一次**跳過**每次提示音，只播最終語音。

### ✅ IVR 編輯器 UI 過窄（2026-06-25）
**修復**：左側由固定 `480px` 改為 `flex:3`（60%），右側改為 `flex:2`（40%，`max-width:480px`）；SVG 加 `viewBox` + `preserveAspectRatio` 自動 fit；全螢幕展開功能。

### ✅ 下班時段語音儲存後消失（2026-06-25）
**根本原因**：伺服器上的 `server.py` 是舊版，`IVRSchedule` Pydantic 模型無 `offhour_sound` 欄位，接收 JSON 時靜默忽略該欄位，永遠不寫入檔案。
**修復**：
1. `IVRSchedule` 新增 `offhour_sound: str = ''`
2. `_ivr_meta_dict` 加入 `'offhour_sound': data.schedule.offhour_sound`
3. `_ivrEdit()` 補齊舊資料缺失欄位（迴圈對照 `_ivrNewObj()` 預設值）
4. 加入 `_ivrSyncScheduleFromDOM()` 在儲存前統一同步 DOM 值到 `_ivrEditing`
5. **重啟服務**讓新版 Pydantic 模型生效

### ✅ 號碼目錄搜尋輸入一個字就跳掉（2026-06-24）
**修復**：首次渲染建立骨架（含固定 id 容器），之後搜尋/篩選只局部更新 `num-tbody`，搜尋欄不受影響。

### ✅ IVR 超時誤播無效鍵音檔（2026-06-25）
**修復**：改用 os.date("%Y")、os.date("%m") 等字串格式各自取值。下午2:07Claude responded: ✅ IVR 超時誤播無效鍵音檔（2026-06-25）✅ IVR 超時誤播無效鍵音檔（2026-06-25）
根本原因：playAndGetDigits 的第 7 個參數 invalid_file 在超時與無效鍵兩種情況下都會自動觸發播放，導致超時時先播 isound（無效鍵音），Lua 再接著播 esound（超時音），順序錯誤。

修復：將 playAndGetDigits 的 invalid_file 參數改為 ""，音檔播放邏輯完全交由 Lua 手動控制，超時與無效鍵提示音正確分離。
---

# 確認備份目錄
ls -lh /opt/fs-dashboard/backups/

# 手動觸發設定備份
curl -X POST http://192.168.100.209:3000/api/backup/run \
  -H "Content-Type: application/json" \
  -d '{"type":"config"}'

# 列出備份清單
curl http://192.168.100.209:3000/api/backup/list | python3 -m json.tool

# 確認 settings.json 備份設定
cat /opt/fs-dashboard/settings.json | python3 -m json.tool | grep backup

# 套件備份 manifest 確認（含 deb 數量與錯誤訊息）
tar xzf freeswitch-packages-*.tar.gz --to-stdout freeswitch-packages/manifest.json \
  2>/dev/null | python3 -m json.tool

# Bug Fix（測試發現）
時間輸入框 max-width:100px 在 12 小時制下顯示被截斷（只顯示「上午 0」），改為 width:180px 修正。

# 已解決問題：每日自動備份排程無法觸發
Bug 1：scheduler 從未啟動

修改 server.py 後未執行 systemctl restart fs-dashboard，新程式碼未被載入

Bug 2：設定時間變更後排程不感知（原始設計缺陷）
舊版 _log_rotate_scheduler() 用 asyncio.sleep(wait_secs) 一次睡到觸發時間，sleep 期間不讀新設定，導致手動變更備份時間後要等到原本喚醒時間才重新計算（此時目標時間早已錯過）。
修復方案：加入全域記憶體快取 + asyncio.Event 通知機制：

模組頂層（第 51 行後）
_scheduler_settings: dict = {
    "backup_auto_enabled": False,
    "backup_auto_time": "00:01",
}
_scheduler_wakeup: asyncio.Event = asyncio.Event()

POST /api/settings（第 752 行）改為 async，儲存後更新記憶體並喚醒 scheduler：

@app.post("/api/settings")
async def post_settings(body: dict = Body(...)):
    save_server_settings(body)
    _scheduler_settings.update({
        "backup_auto_enabled": body.get("backup_auto_enabled", False),
        "backup_auto_time":    body.get("backup_auto_time", "00:01"),
    })
    _scheduler_wakeup.set()
    return {"ok": True}

lifespan（第 519 行後）啟動時初始化記憶體設定：

_scheduler_settings.update({
    "backup_auto_enabled": _saved.get("backup_auto_enabled", False),
    "backup_auto_time":    _saved.get("backup_auto_time", "00:01"),
})

Bug 3：備份失敗靜默跳過且不重試
_backed_up_date = today 寫在 await run_in_executor 之前，exception 發生時已標記當天執行過，導致當天不再重試。
修復：移到確認成功後才標記：

try:
    res = await asyncio.get_event_loop().run_in_executor(None, backup_dashboard_config)
    print(f"[backup-auto] 結果：{res}")
    if res.get("ok"):
        _backed_up_date = today  # 成功才標記
    else:
        print(f"[backup-auto] 備份失敗，下次重試：{res}")
except Exception as e:
    print(f"[backup-auto] 例外錯誤：{e}")

設計說明

自動備份只執行 backup_dashboard_config（config 備份），不含 FreeSwitch 套件備份（packages 備份耗時 1–5 分鐘、150–250MB，不適合每日自動執行）
測試結果：✅ 成功

### IVR 流程圖預覽功能除錯總結 ( 20260626 )
問題描述
取消勾選「啟用時段路由」後，IVR 流程圖預覽中的按鍵節點（key_*）消失，畫面被截斷。

根本原因
_ivrSVGFlowSized() 裡的 layerOf() 使用硬編碼層號：
entry    → layer 0
sched    → layer 1
work_t / off_t → layer 2
menu     → layer 1（有 entry、無 sched 時）
key_*    → layer 3  ← 永遠固定
當 sched.enabled = false 時，sched、work_t、off_t 節點都不會被建立，但 key_* 仍被分配到 layer 3，造成：
layer 1 → menu        （實際存在）
layer 2 →             （空洞！沒有節點）
layer 3 → key_*       （實際存在）
SVG 高度由 Object.keys(layers).length 計算為 2 層，但 key_* 的 y 座標卻用 parseInt(lIdx) * step = 3 * step 計算，超出 SVG 的 viewBox 範圍，節點被裁切看不見。

修正方式
兩個核心改動：
① layerOf 改為動態建構：根據實際存在的節點依序分配層號，不再硬編碼。
js// 修正前：硬編碼，key_* 永遠是 3
const layerOf = (id) => {
  if (id === 'entry') return 0;
  if (id === 'sched') return 1;
  if (id === 'menu')  return ...;
  if (id === 'work_t' || id === 'off_t') return 2;
  return 3;
};

// 修正後：動態累加，實際存在什麼節點才分配層號
let _layerSeq = 0;
const _layerMap = {};
if (hasEntry)         _layerMap['entry'] = _layerSeq++;
if (hasSched)         _layerMap['sched'] = _layerSeq++;
if (hasSchedChildren) _layerMap['__sched_children__'] = _layerSeq++;
_layerMap['menu']   = _layerSeq++;
const _keyLayer     = _layerSeq;  // key_* 緊接在 menu 後
② y 座標改用 rank（排名索引）而非原始層號：
js// 修正前：lIdx 可能是 0,1,3（有空洞）→ y 座標跳格
Object.entries(layers).forEach(([lIdx, lNodes]) => {
  const y = parseInt(lIdx) * (NODE_H + GAP_Y) + GAP_Y;
  ...
});

// 修正後：用排序後的 rank（0,1,2...）確保連續
sortedLayerKeys.forEach((lIdx, rank) => {
  const y = rank * (NODE_H + GAP_Y) + GAP_Y;  // rank 永遠連續
  ...
});

影響範圍
場景修正前修正後啟用時段路由✅ 正常✅ 正常停用時段路由❌ key 節點截斷✅ 正常無入口號碼（子選單）✅ 正常✅ 正常全螢幕展開模式❌ 同樣問題✅ 一併修正

### 分機管理除錯總結 ( 20260626 )
問題現象
分機管理頁面出現 2 個異常卡片（$$default_pro... 和 SEP0011GAABBCC），且無法刪除。
根本原因
異常卡片原因$$default_pro...FreeSwitch 預設 template XML 的 <user id> 為空字串，被 list_extensions() 掃入清單SEP0011GAABBCCCisco IP Phone 自動在 /etc/freeswitch/directory/default/ 建立的設備 XML，檔名格式為 SEP<MAC>.xml，非分機用途卻被掃入無法刪除delete_extension() 用 ext_id 組檔名，但這兩個異常 XML 的 id 不等於檔名，導致找不到檔案回傳 404
修改內容
server.py — list_extensions()（第 1248 行）
python# 修改前
ext_id = user.get('id','')

# 修改後
ext_id = user.get('id','').strip()
if not ext_id:
    continue
if not ext_id.isdigit():    # 過濾 SEP...、template 等非數字 id
    continue
server.py — list_extensions() result.append（第 1263 行）
python'filename': os.path.basename(filepath),   # 新增，回傳實際檔名
server.py — delete_extension()（第 1325 行）
python# 新增 filename 參數，讓刪除走實際檔名路徑
def delete_extension(ext_id: str, filename: str = Query(None)):
    if filename:
        safe = os.path.basename(filename)
        filepath = f"{EXT_DIR}/{safe}"
    else:
        filepath = f"{EXT_DIR}/{ext_id}.xml"
index.html — 卡片刪除按鈕（第 1604 行）
javascriptonclick="deleteExt('${e.id}', '${e.filename || ''}')"
index.html — deleteExt() 函數（第 1879 行）
javascriptasync function deleteExt(id, filename) {
  const qs  = filename ? `?filename=${encodeURIComponent(filename)}` : '';
  const res = await fetch(`${API_BASE}/api/extensions/${encodeURIComponent(id)}${qs}`, { method: 'DELETE' });
根治邏輯
過濾非純數字的分機 id，讓異常 XML 從源頭就不進入清單，不顯示就不會有刪除問題。filename 參數是保險機制，萬一未來有其他格式的異常檔案仍需手動清除時可用。

### 除錯修復總結 (20260626 修改更新)
問題一：分機狀態無法即時顯示「通話」「響鈴」
根本原因
FreeSwitch ESL 事件中的 Channel-Name header 值為：
sofia/internal/1126%40192.168.100.209
@ 被 URL encode 成 %40，導致 _ext_from_channel_name() 無法正確解析分機號碼，回傳空字串後 early return，狀態更新完全失效。
修改檔案：server.py 第 58～72 行
_ext_from_channel_name() 加入 %40 decode，並限制只處理內線 profile，加上 .isdigit() 防止外線號碼誤判：
pythondef _ext_from_channel_name(ch_name: str) -> str:
    if not ch_name:
        return ""
    try:
        ch_name = ch_name.replace("%40", "@")  # ← 關鍵修復
        parts = ch_name.split("/")
        if len(parts) < 3:
            return ""
        profile = parts[1].lower()
        if profile not in ("internal", "default"):
            return ""
        num = parts[2].split("@")[0].strip()
        if not num.isdigit():
            return ""
        return num
    except Exception:
        return ""
同步修復的其他問題（server.py）
問題修復B leg CHANNEL_CREATE 把 talking 狀態退回 ringingCHANNEL_CREATE 前檢查 cur.get("status") not in ("talking", "holding")分機 offline 後 CHANNEL_DESTROY 誤設回 idleCHANNEL_DESTROY 前檢查 cur.get("status") != "offline"

問題二：分機互打立即 disconnect
根本原因
/etc/freeswitch/dialplan/default.xml 的 Local_Extension regex 只匹配 1000～1019：
xmlexpression="^(10[01][0-9])$"
分機 1200 不在範圍內，Dialplan 跌落到 enum extension 後找不到路由直接掛斷。
修改檔案：default.xml 第 248 行
xml<!-- 修改前 -->
<condition field="destination_number" expression="^(10[01][0-9])$">

<!-- 修改後：匹配 1000～1999 所有四位數分機 -->
<condition field="destination_number" expression="^(1[0-9]{3})$">
修改後執行：
bashfs_cli -H 127.0.0.1 -P 8055 -p FSPyAdmin -x "reloadxml"

### 被叫方錄音未啟動 發現日期：2026-06-29

問題描述：分機 1126 啟用錄音、1200 未啟用。當 1200 撥給 1126 時，1126 的錄音未啟動。

根本原因
global extension 的錄音 condition 只查詢 主叫（caller） 的 recording_enabled：
xmlfield="${user_data(${caller_id_number}@192.168.100.209 var recording_enabled)}"
當通話方向為 1200 → 1126 時：

${caller_id_number} = 1200 → recording_enabled = false → 不錄音
1126 是被叫（callee），${destination_number}，完全未被查詢


修正
在主叫 condition 之後，補加一個查詢 被叫 的 condition：
xml<!-- 原有：主叫啟用錄音 -->
<condition field="${user_data(${caller_id_number}@192.168.100.209 var recording_enabled)}" expression="^true$" break="never">
  <action application="set" data="RECORD_STEREO=true"/>
  <action application="set" data="recording_follow_transfer=true"/>
  <action application="system" data="mkdir -p /var/lib/freeswitch/recordings/${strftime(%Y%m%d)}"/>
  <action application="set" data="record_file=/var/lib/freeswitch/recordings/${strftime(%Y%m%d)}/${caller_id_number}_${destination_number}_${strftime(%Y%m%d_%H%M%S)}_${uuid}.wav"/>
  <action application="record_session" data="${record_file}"/>
</condition>

<!-- 新增：被叫啟用錄音 -->
<condition field="${user_data(${destination_number}@192.168.100.209 var recording_enabled)}" expression="^true$" break="never">
  <action application="set" data="RECORD_STEREO=true"/>
  <action application="set" data="recording_follow_transfer=true"/>
  <action application="system" data="mkdir -p /var/lib/freeswitch/recordings/${strftime(%Y%m%d)}"/>
  <action application="set" data="record_file=/var/lib/freeswitch/recordings/${strftime(%Y%m%d)}/${caller_id_number}_${destination_number}_${strftime(%Y%m%d_%H%M%S)}_${uuid}.wav"/>
  <action application="record_session" data="${record_file}"/>
</condition>
兩個 condition 都用 break="never"，確保無論哪一方啟用錄音都會觸發，且不影響後續 dialplan 繼續執行。

套用腳本
bashcat > /tmp/fix_recording.py << 'PYEOF'
#!/usr/bin/env python3
import shutil, datetime, subprocess

DIALPLAN = "/etc/freeswitch/dialplan/default.xml"

with open(DIALPLAN, 'r', encoding='utf-8') as f:
    content = f.read()

if 'user_data(${destination_number}' in content:
    print("INFO: 被叫錄音 condition 已存在，無需重複套用")
    exit(0)

OLD_MARKER = 'user_data(${caller_id_number}@192.168.100.209 var recording_enabled)'
if OLD_MARKER not in content:
    print("ERROR: 找不到主叫錄音 condition")
    exit(1)

CALLEE_BLOCK = """
        <condition field="${user_data(${destination_number}@192.168.100.209 var recording_enabled)}" expression="^true$" break="never">
          <action application="set" data="RECORD_STEREO=true"/>
          <action application="set" data="recording_follow_transfer=true"/>
          <action application="system" data="mkdir -p /var/lib/freeswitch/recordings/${strftime(%Y%m%d)}"/>
          <action application="set" data="record_file=/var/lib/freeswitch/recordings/${strftime(%Y%m%d)}/${caller_id_number}_${destination_number}_${strftime(%Y%m%d_%H%M%S)}_${uuid}.wav"/>
          <action application="record_session" data="${record_file}"/>
        </condition>"""

pos = content.find(OLD_MARKER)
close_pos = content.find('</condition>', pos)
insert_at = close_pos + len('</condition>')
new_content = content[:insert_at] + CALLEE_BLOCK + content[insert_at:]

backup = DIALPLAN + ".bak." + datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
shutil.copy2(DIALPLAN, backup)
print(f"備份至 {backup}")

with open(DIALPLAN, 'w', encoding='utf-8') as f:
    f.write(new_content)

subprocess.run(["fs_cli", "-H", "127.0.0.1", "-P", "8055", "-p", "FSPyAdmin", "-x", "reloadxml"])
print("Done.")
PYEOF

python3 /tmp/fix_recording.py

更新後錄音觸發規則
通話方向主叫查詢被叫查詢錄音結果1126（啟用）→ 1200✓ truefalse✅ 錄音1200 → 1126（啟用）false✓ true✅ 錄音兩方都啟用✓ true✓ true✅ 錄音（record_session 重複呼叫無害，後者覆蓋前者）兩方都未啟用falsefalse❌ 不錄音


### 日誌保留設定 / CDR 設定互相覆寫 2026-06-30 發現, 更新修正
根因：設定頁採樹狀分頁結構，[data-setting] 元素只存在於當前顯示的分頁 DOM 中。原本的 saveSettings() 每次都用空物件重新組裝、整包覆寫 localStorage：
javascriptconst cfg = {};  // 從空物件開始，只抓得到目前分頁的欄位
document.querySelectorAll('[data-setting]').forEach(...)
localStorage.setItem(..., JSON.stringify(cfg));  // 覆寫掉其他分頁已存的設定
→ 在 CDR 設定頁存檔時，DOM 裡沒有 log_retain_days 元素，整包覆寫後該值就從 localStorage 消失，下次讀取時 fallback 回預設值 30。
修正：saveSettings() 改為先 loadSettings() 取得既有完整設定，再用當前頁面欄位覆蓋對應 key，其餘分頁設定不受影響。
提醒：此模式（分頁表單、querySelectorAll 組裝待存物件）若未來新增分頁，仍需注意同樣陷阱——任何 save 函式不能假設「DOM 上看得到的欄位＝全部設定」。

兩項修改已通過你的測試驗證，檔案已更新並提供下載。