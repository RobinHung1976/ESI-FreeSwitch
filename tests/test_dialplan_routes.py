import sys, os, json, tempfile, shutil

# 專案根目錄 = 本檔案所在 tests/ 的上一層（server.py / routers/ / core/ 所在處）
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import routers.dialplan_routes as dr

# 將 ROUTE_DIR 導向暫存目錄，避免動到真實 FreeSwitch 設定
TMP_DIALPLAN_DEFAULT = tempfile.mkdtemp(prefix="route_test_default_")
TMP_DIALPLAN_PUBLIC  = tempfile.mkdtemp(prefix="route_test_public_")
TMP_GATEWAY_DIR       = tempfile.mkdtemp(prefix="route_test_gw_")

dr.ROUTE_DIR = TMP_DIALPLAN_DEFAULT
dr.GATEWAY_SCAN_DIR = TMP_GATEWAY_DIR

# 覆寫 _legacy_scan_dirs，讓它直接回傳我們指定的暫存目錄（不依賴 ROUTE_DIR 的相對路徑推導）
dr._legacy_scan_dirs = lambda: [TMP_DIALPLAN_DEFAULT, TMP_DIALPLAN_PUBLIC]

# 建立一個假的 gateway 設定檔（模擬 AC220）
with open(os.path.join(TMP_GATEWAY_DIR, "AC220.xml"), "w", encoding="utf-8") as f:
    f.write("""<include>
  <gateway name="AC220">
    <param name="username" value="trunk1"/>
    <param name="password" value="secret"/>
    <param name="proxy" value="192.168.100.220"/>
    <param name="register" value="false"/>
  </gateway>
</include>""")

# 建立一個模擬 DP_AC220.xml 的舊有手寫 dialplan 檔案（沒有 META 標記）
# 注意：故意延後到 TEST 13 區塊才真正寫入檔案，避免與前面測試新增的一般規則
# （例如 prefix "6,7"）互相衝突，造成不相關的測試失敗。
LEGACY_DP_CONTENT = """<include>

  <extension name="AC220">
    <condition field="${toll_allow}" expression="local"/>
    <condition field="destination_number" expression="^[9](\\d*)$">
      <action application="log" data="INFO DIALPLAN HIT: my_rule matched dest=${destination_number} context=${context}"/>
      <action application="set" data="effective_caller_id_number=${outbound_caller_id_number}"/>
      <action application="set" data="effective_caller_id_name=${effective_caller_id_name}"/>
      <action application="bridge" data="sofia/gateway/192.168.100.220/$1"/>
    </condition>
  </extension>

</include>
"""

def _create_legacy_dp_file():
    with open(os.path.join(TMP_DIALPLAN_DEFAULT, "DP_AC220.xml"), "w", encoding="utf-8") as f:
        f.write(LEGACY_DP_CONTENT)



from fastapi import FastAPI
from fastapi.testclient import TestClient

app = FastAPI()
app.include_router(dr.router)
client = TestClient(app)

def jprint(label, resp):
    print(f"\n--- {label} [{resp.status_code}] ---")
    try:
        print(json.dumps(resp.json(), ensure_ascii=False, indent=2))
    except Exception:
        print(resp.text)

failures = []

def check(cond, msg):
    status = "PASS" if cond else "FAIL"
    print(f"[{status}] {msg}")
    if not cond:
        failures.append(msg)

# ════════════════════════════════════════════════════════════════════
print("=" * 70)
print("TEST 1: 列表為空")
r = client.get("/api/dialplan/routes")
jprint("list (empty)", r)
check(r.status_code == 200 and r.json()["total"] == 0, "初始列表應為空")

# ════════════════════════════════════════════════════════════════════
print("=" * 70)
print("TEST 2: 新增 prefix 規則（6,7開頭 → AC220）")
payload1 = {
    "name": "市話手機外撥",
    "pattern_type": "prefix",
    "pattern_value": "6,7",
    "gateway_name": "AC220",
    "caller_id_override": "",
    "toll_allow": "local",
    "enabled": True,
    "priority": 100,
}
r = client.post("/api/dialplan/routes", json=payload1)
jprint("create route1", r)
check(r.status_code == 200, "新增規則應成功")
route1_id = r.json().get("id")
check(bool(route1_id), "應回傳產生的 route id")

# 檢查實際寫入的 XML 內容
fpath = dr._route_filepath(route1_id)
check(os.path.exists(fpath), f"檔案應存在於 {fpath}")
with open(fpath, encoding="utf-8") as f:
    xml_content = f.read()
print("\n--- 產生的 XML ---")
print(xml_content)
check("DASHBOARD_ROUTE_META" in xml_content, "XML 應含 META 註解")
check('sofia/gateway/AC220/$1' in xml_content, "bridge target 應使用 gateway 名稱 + $1")
check('toll_allow=local' in xml_content, "應寫入 toll_allow")

# ════════════════════════════════════════════════════════════════════
print("=" * 70)
print("TEST 3: 新增重疊規則應被拒絕（衝突檢查）")
payload2 = {
    "name": "國際電話",
    "pattern_type": "prefix",
    "pattern_value": "6",   # 與 route1 的 "6,7" 重疊
    "gateway_name": "AC220",
    "priority": 50,
}
r = client.post("/api/dialplan/routes", json=payload2)
jprint("create overlapping route (expect 409)", r)
check(r.status_code == 409, "重疊規則應回傳 409")

# ════════════════════════════════════════════════════════════════════
print("=" * 70)
print("TEST 4: 新增不重疊規則應成功（00開頭 → 國際線）")
payload3 = {
    "name": "國際電話",
    "pattern_type": "prefix",
    "pattern_value": "0",
    "gateway_name": "INTL-GW",
    "priority": 50,
}
r = client.post("/api/dialplan/routes", json=payload3)
jprint("create route3 (00 prefix)", r)
check(r.status_code == 200, "不重疊規則應新增成功")
route3_id = r.json().get("id")

# ════════════════════════════════════════════════════════════════════
print("=" * 70)
print("TEST 5: check-conflict 端點單獨測試")
r = client.post("/api/dialplan/routes/check-conflict", json={
    "pattern_type": "prefix",
    "pattern_value": "7",   # 與 route1 (6,7) 重疊
    "self_id": "",
})
jprint("check-conflict (overlap with route1)", r)
check(r.status_code == 200, "check-conflict 應回傳 200")
check(r.json()["has_conflict"] is True, "應偵測到與 route1 衝突")
check(len(r.json()["conflicts"]) >= 1, "應列出至少一個衝突規則")

r = client.post("/api/dialplan/routes/check-conflict", json={
    "pattern_type": "exact",
    "pattern_value": "12345",
    "self_id": "",
})
jprint("check-conflict (no overlap)", r)
check(r.json()["has_conflict"] is False, "exact 12345 不應與任何規則衝突")

# 編輯模式排除自身：用 route1 自己的 pattern 檢查，self_id=route1_id 應該不算衝突
r = client.post("/api/dialplan/routes/check-conflict", json={
    "pattern_type": "prefix",
    "pattern_value": "6,7",
    "self_id": route1_id,
})
jprint("check-conflict (self exclude)", r)
check(r.json()["has_conflict"] is False, "編輯模式排除自身後不應顯示衝突")

# ════════════════════════════════════════════════════════════════════
print("=" * 70)
print("TEST 6: 路由測試 test-number")
r = client.post("/api/dialplan/routes/test-number", json={"number": "61234"})
jprint("test-number 61234", r)
check(r.status_code == 200, "test-number 應回傳 200")
check(r.json()["matched_route"]["id"] == route1_id, "61234 應命中 route1（市話手機外撥）")

r = client.post("/api/dialplan/routes/test-number", json={"number": "00123456"})
jprint("test-number 00123456", r)
check(r.json()["matched_route"]["id"] == route3_id, "00123456 應命中 route3（國際電話）")

r = client.post("/api/dialplan/routes/test-number", json={"number": "999999"})
jprint("test-number 999999 (no match)", r)
check(r.json()["matched_route"] is None, "999999 不應命中任何規則")
check(len(r.json()["all_checked"]) == 2, "all_checked 應列出兩條已啟用的規則")

# ════════════════════════════════════════════════════════════════════
print("=" * 70)
print("TEST 7: 更新規則（變更 gateway，並確認 reload 容錯）")
payload1_updated = dict(payload1)
payload1_updated["gateway_name"] = "AC220-NEW"
payload1_updated["id"] = route1_id
r = client.put(f"/api/dialplan/routes/{route1_id}", json=payload1_updated)
jprint("update route1", r)
check(r.status_code == 200, "更新規則應成功")
check(os.path.exists(r.json()["backup"]), "更新前應產生備份檔")

r = client.get(f"/api/dialplan/routes/{route1_id}")
check(r.json()["gateway_name"] == "AC220-NEW", "更新後 gateway_name 應變更")

# ════════════════════════════════════════════════════════════════════
print("=" * 70)
print("TEST 8: 停用規則（toggle）後測試應不再命中")
r = client.patch(f"/api/dialplan/routes/{route1_id}/toggle", json={"enabled": False})
jprint("toggle route1 disabled", r)
check(r.status_code == 200, "toggle 應成功")

r = client.post("/api/dialplan/routes/test-number", json={"number": "61234"})
jprint("test-number 61234 after disable", r)
check(r.json()["matched_route"] is None, "停用後 61234 不應再命中 route1")

# 重新啟用後應恢復
r = client.patch(f"/api/dialplan/routes/{route1_id}/toggle", json={"enabled": True})
check(r.status_code == 200, "重新啟用應成功")
r = client.post("/api/dialplan/routes/test-number", json={"number": "61234"})
check(r.json()["matched_route"]["id"] == route1_id, "重新啟用後應再次命中")

# ════════════════════════════════════════════════════════════════════
print("=" * 70)
print("TEST 9: custom_regex 型態")
r = client.post("/api/dialplan/routes", json={
    "name": "VIP直撥",
    "pattern_type": "custom_regex",
    "pattern_value": r"^999(\d{4})$",
    "gateway_name": "VIP-GW",
    "priority": 10,
})
jprint("create custom_regex route", r)
check(r.status_code == 200, "custom_regex 規則應新增成功")
custom_id = r.json().get("id")

r = client.post("/api/dialplan/routes/test-number", json={"number": "9991234"})
jprint("test-number 9991234 (custom_regex match)", r)
check(r.json()["matched_route"]["id"] == custom_id, "9991234 應命中 VIP直撥")

# 非法 regex 應被拒絕
r = client.post("/api/dialplan/routes", json={
    "name": "壞掉的規則",
    "pattern_type": "custom_regex",
    "pattern_value": "^(unclosed",
    "gateway_name": "X",
})
jprint("create invalid regex (expect 400)", r)
check(r.status_code == 400, "非法正規式應回傳 400")

# ════════════════════════════════════════════════════════════════════
print("=" * 70)
print("TEST 10: 刪除規則")
r = client.delete(f"/api/dialplan/routes/{custom_id}")
jprint("delete custom route", r)
check(r.status_code == 200, "刪除應成功")
r = client.get("/api/dialplan/routes")
ids = [x["id"] for x in r.json()["routes"]]
check(custom_id not in ids, "刪除後不應出現在列表中")
# 備份檔應存在
bak_files = [f for f in os.listdir(TMP_DIALPLAN_DEFAULT) if f.startswith(f"00_route_{custom_id}.xml.bak")]
check(len(bak_files) >= 1, "刪除前應產生備份檔")

# ════════════════════════════════════════════════════════════════════
print("=" * 70)
print("TEST 11: 刪除/更新不存在的規則應回傳 404")
r = client.delete("/api/dialplan/routes/no_such_id")
check(r.status_code == 404, "刪除不存在規則應回傳 404")
r = client.put("/api/dialplan/routes/no_such_id", json=payload1)
check(r.status_code == 404, "更新不存在規則應回傳 404")

# ════════════════════════════════════════════════════════════════════
print("=" * 70)
print("TEST 12: 驗證輸入（pydantic field_validator）")
r = client.post("/api/dialplan/routes", json={
    "name": "",
    "pattern_type": "exact",
    "pattern_value": "1234",
    "gateway_name": "X",
})
check(r.status_code == 422, "空白名稱應被 pydantic 擋下 (422)")

r = client.post("/api/dialplan/routes", json={
    "name": "測試",
    "pattern_type": "prefix",
    "pattern_value": "",
    "gateway_name": "X",
})
check(r.status_code == 422, "prefix 型態空白 pattern_value 應被擋下 (422)")

r = client.post("/api/dialplan/routes", json={
    "name": "測試",
    "pattern_type": "exact",
    "pattern_value": "1234",
    "gateway_name": "",
})
check(r.status_code == 422, "空白 gateway_name 應被擋下 (422)")

r = client.post("/api/dialplan/routes", json={
    "name": "測試",
    "pattern_type": "exact",
    "pattern_value": "1234",
    "gateway_name": "X",
    "priority": 9999,
})
check(r.status_code == 422, "超出範圍的 priority 應被擋下 (422)")

# ════════════════════════════════════════════════════════════════════
print("=" * 70)
print("TEST 13: 列表應包含舊有手寫檔案 DP_AC220.xml（反解析）")
_create_legacy_dp_file()   # 此時才真正建立檔案，避免與前面測試的一般規則衝突
r = client.get("/api/dialplan/routes")
jprint("list (includes legacy DP_AC220)", r)
check(r.status_code == 200, "列表應回傳 200")
all_routes = r.json()["routes"]
legacy_entries = [x for x in all_routes if x.get("legacy")]
check(len(legacy_entries) == 1, "應偵測到 1 筆舊有檔案")
if legacy_entries:
    legacy = legacy_entries[0]
    check(legacy["id"] == "legacy:DP_AC220.xml", "legacy id 應為 legacy:DP_AC220.xml")
    check(legacy["pattern_type"] == "prefix", "應反解析出 pattern_type=prefix")
    check(legacy["pattern_value"] == "9", f"應反解析出 pattern_value=9，實際={legacy['pattern_value']}")
    check(legacy["gateway_name"] == "AC220", f"應透過 proxy IP 192.168.100.220 反查回 gateway 名稱 AC220，實際={legacy['gateway_name']}")
    check(legacy["toll_allow"] == "local", "應反解析出 toll_allow=local")

# ════════════════════════════════════════════════════════════════════
print("=" * 70)
print("TEST 14: 單獨讀取 legacy 規則詳細內容")
r = client.get("/api/dialplan/routes/legacy:DP_AC220.xml")
jprint("get legacy route detail", r)
check(r.status_code == 200, "讀取 legacy 規則應回傳 200")
check(r.json()["legacy"] is True, "legacy 欄位應為 True")

r = client.get("/api/dialplan/routes/legacy:NOT_EXIST.xml")
check(r.status_code == 404, "讀取不存在的 legacy 檔案應回傳 404")

# ════════════════════════════════════════════════════════════════════
print("=" * 70)
print("TEST 15: legacy 規則應參與衝突檢查")
r = client.post("/api/dialplan/routes/check-conflict", json={
    "pattern_type": "prefix",
    "pattern_value": "9",   # 與 DP_AC220 的 "9" 重疊
    "self_id": "",
})
jprint("check-conflict against legacy DP_AC220", r)
check(r.json()["has_conflict"] is True, "新規則應偵測到與 legacy DP_AC220 衝突")
conflict_names = [c["name"] for c in r.json()["conflicts"]]
check("AC220" in conflict_names, f"衝突清單應包含 AC220，實際={conflict_names}")

# ════════════════════════════════════════════════════════════════════
print("=" * 70)
print("TEST 16: legacy 規則應參與路由測試（test-number）")
r = client.post("/api/dialplan/routes/test-number", json={"number": "912345"})
jprint("test-number 912345 should hit legacy DP_AC220", r)
check(r.json()["matched_route"]["id"] == "legacy:DP_AC220.xml", "912345 應命中 legacy DP_AC220 規則")

# ════════════════════════════════════════════════════════════════════
print("=" * 70)
print("TEST 17: legacy 規則禁止直接 update/delete/toggle，只能走升級流程")
r = client.put("/api/dialplan/routes/legacy:DP_AC220.xml", json=payload1)
check(r.status_code == 400, "直接 PUT legacy 規則應被拒絕 (400)")
r = client.delete("/api/dialplan/routes/legacy:DP_AC220.xml")
check(r.status_code == 400, "直接 DELETE legacy 規則應被拒絕 (400)")
r = client.patch("/api/dialplan/routes/legacy:DP_AC220.xml/toggle", json={"enabled": False})
check(r.status_code == 400, "直接 toggle legacy 規則應被拒絕 (400)")

# ════════════════════════════════════════════════════════════════════
print("=" * 70)
print("TEST 18: 升級 legacy 規則（衝突情況應被擋下）")
r = client.post("/api/dialplan/routes/legacy/upgrade", json={
    "legacy_id": "legacy:DP_AC220.xml",
    "data": {
        "name": "AC220外撥",
        "pattern_type": "prefix",
        "pattern_value": "0",   # 故意跟 route3 (國際電話, "0") 衝突
        "gateway_name": "AC220",
        "toll_allow": "local",
        "priority": 90,
    }
})
jprint("upgrade with conflicting pattern (expect 409)", r)
check(r.status_code == 409, "升級時若與既有規則衝突應回傳 409")

print("\nTEST 18b: 升級 legacy 規則（正常情況應成功）")
r = client.post("/api/dialplan/routes/legacy/upgrade", json={
    "legacy_id": "legacy:DP_AC220.xml",
    "data": {
        "name": "AC220外撥",
        "pattern_type": "prefix",
        "pattern_value": "9",
        "gateway_name": "AC220",
        "toll_allow": "local",
        "priority": 90,
    }
})
jprint("upgrade DP_AC220 (expect success)", r)
check(r.status_code == 200, "升級應成功")
check(r.json().get("upgraded_from") == "DP_AC220.xml", "回應應標明升級來源檔名")
check(os.path.exists(r.json()["backup"]), "升級前應備份原始檔案")
upgraded_id = r.json()["id"]

check(not os.path.exists(os.path.join(TMP_DIALPLAN_DEFAULT, "DP_AC220.xml")),
      "升級後原始 DP_AC220.xml 應被移除（已備份）")
check(os.path.exists(dr._route_filepath(upgraded_id)), "升級後應產生新的 00_route_*.xml 檔案")

r = client.get("/api/dialplan/routes")
ids = [x["id"] for x in r.json()["routes"]]
check("legacy:DP_AC220.xml" not in ids, "升級後列表不應再出現 legacy:DP_AC220.xml")
check(upgraded_id in ids, "升級後列表應出現新的正式規則 id")

r = client.patch(f"/api/dialplan/routes/{upgraded_id}/toggle", json={"enabled": False})
check(r.status_code == 200, "升級後的規則應可正常 toggle")
r = client.patch(f"/api/dialplan/routes/{upgraded_id}/toggle", json={"enabled": True})
check(r.status_code == 200, "升級後的規則應可重新啟用")

# ════════════════════════════════════════════════════════════════════
print("=" * 70)
print(f"\n總結：{'全部通過' if not failures else f'{len(failures)} 項失敗'}")
if failures:
    print("失敗項目：")
    for f in failures:
        print(f"  - {f}")

shutil.rmtree(TMP_DIALPLAN_DEFAULT, ignore_errors=True)
shutil.rmtree(TMP_DIALPLAN_PUBLIC, ignore_errors=True)
shutil.rmtree(TMP_GATEWAY_DIR, ignore_errors=True)
sys.exit(1 if failures else 0)
