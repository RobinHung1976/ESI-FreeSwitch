# custom_regex 對 custom_regex 衝突檢查永遠偵測不到重疊（2026-07-16）

> 於 [Dialplan Context 切換 UI](20260716-dialplan-context-switch-feature.md) 功能測試過程中發現。

## 現象

新增兩條 `pattern_type=custom_regex` 且**正規式字串完全相同**的路由規則（同一 context），兩條都能成功儲存，衝突檢查完全沒有攔下來；把其中一條的正規式用「編輯」改成跟另一條一樣，也一樣能存檔成功。

## 根本原因

`find_conflicts()` 靠雙方樣本互測對方 regex 來偵測重疊：

```python
hit = any(exist_re.match(s) for s in new_samples) or \
      any(new_re.match(s) for s in exist_samples)
```

`generate_sample_numbers()` 對 `pattern_type=custom_regex` 一律回傳空陣列（regex 無法窮舉樣本，程式註解本來就寫「改用對方的樣本反向測試這顆 regex」）。這個設計在「一邊是 custom_regex、另一邊是 prefix/exact」時可以運作（用 prefix/exact 那邊的樣本去測 custom_regex）；但**當兩邊都是 custom_regex 時，雙方樣本都是空的，`any()` 對空陣列一律回傳 `False`，永遠測不出任何重疊**——即使兩條規則字串一模一樣。

此限制在 `find_conflicts()`/`generate_sample_numbers()` 原本的程式碼就存在，不是這次 Context 功能改動造成的，只是這次測試時用 `custom_regex` 才真正踩到。

## 修復

在 `find_conflicts()` 的比對迴圈補上一個特例：兩邊都是 `custom_regex` 且規則字串完全相同（`.strip()` 後比對）時，強制判定為衝突：

```python
if not hit and pattern_type == "custom_regex" and route.get("pattern_type") == "custom_regex":
    if pattern_value.strip() == (route.get("pattern_value") or "").strip():
        hit = True
```

同時把 `check_conflict` 端點回傳的 `note` 文字改得更精確，明確說明目前只能偵測「規則字串完全相同」的重複：

> 自訂正規式採取樣比對，僅能偵測規則字串完全相同的重複；若是語意相同但寫法不同的正規式（例如 `^6\d{3}$` 與 `^(6\d{3})$`）無法自動偵測，請務必搭配下方路由測試工具手動驗證。

## 已知殘留限制

語意相同但寫法不同的兩條 `custom_regex`（例如 `^6\d{3}$` 與 `^(6\d{3})$`）目前仍無法自動偵測，這是「取樣比對法」本身的天花板——要徹底解決需要真正的 regex 語意比對（例如把兩顆 regex 都轉成有限自動機再比較語言是否有交集），目前評估成本高於效益，先靠 UI 提示搭配路由測試工具人工確認，暫不列入本次修復範圍。

## 修改的檔案

- `routers/dialplan_routes.py`：`find_conflicts()` 加特例判斷（2 處精確字串取代，`update22.sh`）

## 驗證方式

```bash
python3 -m py_compile routers/dialplan_routes.py
systemctl restart fs-dashboard   # Python 程式碼改動必須重啟才生效
```

瀏覽器實測：
1. 新增一條 `custom_regex` 規則（例如 `^(9\d{3})$`），成功
2. 同一 context 再新增一條完全相同的正規式 → 應被紅色警告攔下、無法儲存
3. 換一個 context 用同樣正規式新增 → 應顯示藍色跨 context 提示、不阻擋儲存
4. 編輯既有規則把正規式改成跟另一條同 context 規則完全相同 → 應被攔下

**測試結果**：已於 production server（`debian-freeswitch`）實際執行 `update22.sh` 並 `systemctl restart` 後，依上述步驟重新測試通過（第一次測試因忘記重啟服務誤判修復未生效，重啟後確認正常）。
