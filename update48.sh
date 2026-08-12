#!/bin/bash
# ============================================================
# update48.sh
# UX 改善（承接 update47.sh 的「內線互撥」範本）：
#   1. call_timeout 欄位新增真正的預設值（TemplateField.default），
#      新增時自動帶入 30，不用手動填才能通過必填驗證
#   2. 分機勾選區從固定 180px 單欄列表，改成 320px 可捲動格狀多欄排列，
#      並新增「全選」/「清除」快速按鈕（只作用於篩選後可見的項目）
# 對應：changelog-details/20260811-internal-extension-template.md
#
# 修改檔案：routers/dialplan_custom.py、static/js/dialplan.js（皆為精確字串替換）
# ============================================================
set -e

cd "$(dirname "$0")"

BACKEND="routers/dialplan_custom.py"
FRONTEND="static/js/dialplan.js"

# --- 0. 自動歸檔 ---
ARCHIVE_DIR="updateN"
SELF="$(basename "$0")"

mkdir -p "$ARCHIVE_DIR"
for f in update*.sh; do
  [ "$f" = "$SELF" ] && continue
  [ -f "$f" ] || continue
  git mv "$f" "${ARCHIVE_DIR}/$f" 2>/dev/null || mv "$f" "${ARCHIVE_DIR}/$f"
done
git add update*.sh "$ARCHIVE_DIR"/ 2>/dev/null || true
if ! git diff --cached --quiet 2>/dev/null; then
  git commit -m "chore: 歸檔已執行的 updateN.sh 腳本"
fi

# --- 1. 前置驗證 ---
echo "[前置驗證] 確認兩個目標檔案目前內容符合預期（已套用 update47，尚未套用本次改動）..."

for f in "$BACKEND" "$FRONTEND"; do
  [ -f "$f" ] || { echo "❌ 找不到 $f" >&2; exit 1; }
done

if grep -q '"default": Optional\[str\] = None' "$BACKEND" 2>/dev/null || grep -q "default: Optional\[str\] = None" "$BACKEND"; then
  echo "❌ $BACKEND 已包含 TemplateField.default，本次改動可能已套用過，中止避免重複套用" >&2
  exit 1
fi

if grep -q "_dcToggleAllDynamicOptions" "$FRONTEND"; then
  echo "❌ $FRONTEND 已包含 _dcToggleAllDynamicOptions，本次改動可能已套用過，中止避免重複套用" >&2
  exit 1
fi

if ! grep -q "internal_extension" "$BACKEND"; then
  echo "❌ $BACKEND 找不到 internal_extension，代表 update47 可能還沒套用，請先確認執行順序" >&2
  exit 1
fi

echo "  ✓ 前置驗證通過"

echo "[Step 1] 套用 $BACKEND 改動..."
cp "$BACKEND" "${BACKEND}.pre-update48.bak"
cp "$FRONTEND" "${FRONTEND}.pre-update48.bak"

python3 << 'PYEOF_BACKEND'
import sys

path = "routers/dialplan_custom.py"
with open(path, "r", encoding="utf-8") as f:
    content = f.read()

edits = []

old1 = '''class TemplateField(BaseModel):
    key: str
    label: str
    type: Literal["text", "number", "select", "time", "dynamic_multiselect"]
    required: bool = True
    options: Optional[list[str]] = None
    placeholder: Optional[str] = None
    help: Optional[str] = None
    # dynamic_multiselect 專用：前端依此值決定要向哪個 API 抓即時選項清單，
    # 目前只有 "extensions" 一種來源，保留擴充空間（未來如 gateway/sound 清單）
    source: Optional[str] = None'''

new1 = '''class TemplateField(BaseModel):
    key: str
    label: str
    type: Literal["text", "number", "select", "time", "dynamic_multiselect"]
    required: bool = True
    options: Optional[list[str]] = None
    placeholder: Optional[str] = None
    help: Optional[str] = None
    # dynamic_multiselect 專用：前端依此值決定要向哪個 API 抓即時選項清單，
    # 目前只有 "extensions" 一種來源，保留擴充空間（未來如 gateway/sound 清單）
    source: Optional[str] = None
    # 新增時自動帶入的實際值（不是灰字 placeholder），避免每次都要手動填常見值
    # 造成儲存時卡在必填驗證。與 placeholder 不同：這個值會真的寫進表單欄位。
    default: Optional[str] = None'''

edits.append(("TemplateField.default", old1, new1))

old2 = '''            TemplateField(key="call_timeout", label="通話逾時秒數", type="number",
                          placeholder="30", help="對方響鈴多久沒接算失敗（5-300 秒）"),'''
new2 = '''            TemplateField(key="call_timeout", label="通話逾時秒數", type="number",
                          default="30", placeholder="30", help="對方響鈴多久沒接算失敗（5-300 秒）"),'''
edits.append(("call_timeout default", old2, new2))

for name, old, new in edits:
    count = content.count(old)
    if count != 1:
        print(f"❌ 比對錨點「{name}」在 {path} 中出現 {count} 次（預期 1 次），中止", file=sys.stderr)
        sys.exit(1)
    content = content.replace(old, new)

with open(path, "w", encoding="utf-8") as f:
    f.write(content)

print("  ✓ routers/dialplan_custom.py 兩處改動皆已套用")
PYEOF_BACKEND

if [ $? -ne 0 ]; then
  echo "❌ routers/dialplan_custom.py 字串替換失敗，還原備份並中止" >&2
  cp "${BACKEND}.pre-update48.bak" "$BACKEND"
  cp "${FRONTEND}.pre-update48.bak" "$FRONTEND"
  exit 1
fi

echo "[Step 2] 套用 $FRONTEND 改動..."

python3 << 'PYEOF_FRONTEND'
import sys

path = "static/js/dialplan.js"
with open(path, "r", encoding="utf-8") as f:
    content = f.read()

edits = []

# Edit 1: _dcFieldInputHtml 套用 default 值
old1 = """function _dcFieldInputHtml(field, value) {
  const v = value !== undefined && value !== null ? value : '';
  const common = `id="dc-field-${field.key}" data-key="${field.key}" class="settings-input" style="max-width:320px"`;
  if (field.type === 'dynamic_multiselect') {"""
new1 = """function _dcFieldInputHtml(field, value) {
  let v = value !== undefined && value !== null ? value : '';
  // 新增模式下欄位還沒有值時，帶入 field.default 當作實際初始值（不只是灰字
  // placeholder），避免每次都要手動填常見值，也不會卡在必填驗證
  if (v === '' && field.default !== undefined && field.default !== null) v = field.default;
  const common = `id="dc-field-${field.key}" data-key="${field.key}" class="settings-input" style="max-width:320px"`;
  if (field.type === 'dynamic_multiselect') {"""
edits.append(("_dcFieldInputHtml default", old1, new1))

# Edit 2: 佔位容器放大
old2 = """    return `<div id="dc-field-${field.key}" data-key="${field.key}"
                 data-source="${_escAttr(field.source || '')}"
                 data-prefill="${_escAttr(v)}"
                 style="max-width:420px;border:1px solid var(--border);border-radius:4px;
                        padding:8px;max-height:180px;overflow-y:auto;background:var(--panel2)">
              <div style="font-size:12px;color:var(--muted)">載入中...</div>
            </div>`;"""
new2 = """    return `<div id="dc-field-${field.key}" data-key="${field.key}"
                 data-source="${_escAttr(field.source || '')}"
                 data-prefill="${_escAttr(v)}"
                 style="width:100%;box-sizing:border-box;border:1px solid var(--border);border-radius:4px;
                        padding:8px;max-height:320px;overflow-y:auto;background:var(--panel2)">
              <div style="font-size:12px;color:var(--muted)">載入中...</div>
            </div>`;"""
edits.append(("佔位容器放大", old2, new2))

# Edit 3: 格狀排列 + 全選/清除按鈕
old3 = """      const filterId = `dc-filter-${f.key}`;
      const listId   = `dc-list-${f.key}`;
      container.innerHTML = `
        <input id="${filterId}" class="settings-input" style="width:100%;box-sizing:border-box;
               margin-bottom:6px;font-size:12px" placeholder="搜尋分機號碼或名稱..."
               oninput="_dcFilterDynamicOptions('${listId}', this.value)">
        <div id="${listId}">
          ${options.map(o => `
            <label style="display:flex;align-items:center;gap:6px;padding:3px 0;font-size:12px;cursor:pointer"
                   data-search="${_escAttr((o.id + ' ' + (o.caller_id_name || '')).toLowerCase())}">
              <input type="checkbox" value="${_escAttr(o.id)}" ${prefillSet.has(String(o.id)) ? 'checked' : ''}>
              <span>${_escHtml(o.id)}${o.caller_id_name ? ` <span style="color:var(--muted)">(${_escHtml(o.caller_id_name)})</span>` : ''}</span>
            </label>`).join('')}
        </div>`;"""
new3 = """      const filterId = `dc-filter-${f.key}`;
      const listId   = `dc-list-${f.key}`;
      container.innerHTML = `
        <div style="display:flex;gap:6px;margin-bottom:8px">
          <input id="${filterId}" class="settings-input" style="flex:1;box-sizing:border-box;font-size:12px"
                 placeholder="搜尋分機號碼或名稱..." oninput="_dcFilterDynamicOptions('${listId}', this.value)">
          <button type="button" class="btn" style="font-size:11px;white-space:nowrap;padding:4px 10px"
                  onclick="_dcToggleAllDynamicOptions('${listId}', true)">全選</button>
          <button type="button" class="btn" style="font-size:11px;white-space:nowrap;padding:4px 10px"
                  onclick="_dcToggleAllDynamicOptions('${listId}', false)">清除</button>
        </div>
        <div id="${listId}" style="display:grid;grid-template-columns:repeat(auto-fill,minmax(150px,1fr));gap:2px 12px">
          ${options.map(o => `
            <label style="display:flex;align-items:center;gap:6px;padding:3px 0;font-size:12px;cursor:pointer"
                   data-search="${_escAttr((o.id + ' ' + (o.caller_id_name || '')).toLowerCase())}">
              <input type="checkbox" value="${_escAttr(o.id)}" ${prefillSet.has(String(o.id)) ? 'checked' : ''}>
              <span>${_escHtml(o.id)}${o.caller_id_name ? ` <span style="color:var(--muted)">(${_escHtml(o.caller_id_name)})</span>` : ''}</span>
            </label>`).join('')}
        </div>`;"""
edits.append(("格狀排列+全選清除按鈕", old3, new3))

# Edit 4: 新增 _dcToggleAllDynamicOptions
old4 = """function _dcFilterDynamicOptions(listId, keyword) {
  const kw = (keyword || '').trim().toLowerCase();
  const list = document.getElementById(listId);
  if (!list) return;
  Array.from(list.children).forEach(label => {
    const hay = label.getAttribute('data-search') || '';
    label.style.display = (!kw || hay.includes(kw)) ? 'flex' : 'none';
  });
}"""
new4 = """function _dcFilterDynamicOptions(listId, keyword) {
  const kw = (keyword || '').trim().toLowerCase();
  const list = document.getElementById(listId);
  if (!list) return;
  Array.from(list.children).forEach(label => {
    const hay = label.getAttribute('data-search') || '';
    label.style.display = (!kw || hay.includes(kw)) ? 'flex' : 'none';
  });
}

function _dcToggleAllDynamicOptions(listId, checked) {
  const list = document.getElementById(listId);
  if (!list) return;
  // 只作用在目前搜尋篩選後看得到的項目，避免誤勾/誤清已被篩選掉、畫面外的分機
  Array.from(list.children).forEach(label => {
    if (label.style.display === 'none') return;
    const cb = label.querySelector('input[type="checkbox"]');
    if (cb) cb.checked = checked;
  });
  // 觸發一次 change 事件冒泡到外層容器，讓即時預覽跟著更新
  list.dispatchEvent(new Event('change', { bubbles: true }));
}"""
edits.append(("_dcToggleAllDynamicOptions", old4, new4))

for name, old, new in edits:
    count = content.count(old)
    if count != 1:
        print(f"❌ 比對錨點「{name}」在 {path} 中出現 {count} 次（預期 1 次），中止", file=sys.stderr)
        sys.exit(1)
    content = content.replace(old, new)

with open(path, "w", encoding="utf-8") as f:
    f.write(content)

print("  ✓ static/js/dialplan.js 四處改動皆已套用")
PYEOF_FRONTEND

if [ $? -ne 0 ]; then
  echo "❌ static/js/dialplan.js 字串替換失敗，還原全部備份並中止" >&2
  cp "${BACKEND}.pre-update48.bak" "$BACKEND"
  cp "${FRONTEND}.pre-update48.bak" "$FRONTEND"
  exit 1
fi

# --- 語法驗證 ---
echo "[Step 3] 語法檢查..."
PY=python3
command -v /opt/myapp/venv/bin/python3 >/dev/null 2>&1 && PY=/opt/myapp/venv/bin/python3

$PY -c "import ast; ast.parse(open('$BACKEND').read())" \
  && echo "  ✓ $BACKEND 語法檢查通過" \
  || { echo "❌ $BACKEND 語法檢查失敗，還原全部備份" >&2; cp "${BACKEND}.pre-update48.bak" "$BACKEND"; cp "${FRONTEND}.pre-update48.bak" "$FRONTEND"; exit 1; }

if command -v node >/dev/null 2>&1; then
  node -c "$FRONTEND" \
    && echo "  ✓ $FRONTEND 語法檢查通過" \
    || { echo "❌ $FRONTEND 語法檢查失敗，還原全部備份" >&2; cp "${BACKEND}.pre-update48.bak" "$BACKEND"; cp "${FRONTEND}.pre-update48.bak" "$FRONTEND"; exit 1; }
else
  echo "  ⚠ 找不到 node，略過前端語法檢查"
fi

rm -f "${BACKEND}.pre-update48.bak" "${FRONTEND}.pre-update48.bak"

# --- git commit ---
echo "[Step 4] git commit..."
git add "$BACKEND" "$FRONTEND"
git status
git commit -m "style: 內線互撥範本 UX 改善——通話逾時秒數新增真正預設值(30)避免卡在必填驗證，分機勾選區放大改格狀多欄排列並新增全選/清除按鈕"

echo ""
echo "======================================================"
echo " ✓ update48.sh 執行完成"
echo ""
git log --oneline -1
echo ""
echo " ⚠️ 本次修改 $BACKEND（後端），依慣例需要重啟服務："
echo "    systemctl restart fs-dashboard"
echo "    $FRONTEND 是純前端檔案，瀏覽器強制重新整理即可"
echo ""
echo " 驗證重點清單："
echo "  1. systemctl restart fs-dashboard 後確認正常啟動、無 500"
echo "  2. 進「自定義 Dialplan」→ 從範本建立 → 內線互撥："
echo "     - 「通話逾時秒數」欄位應該一開始就顯示 30（不是空白）"
echo "     - 分機勾選區應該明顯變大（320px 高、多欄排列），且上方多了「全選」「清除」按鈕"
echo "     - 搜尋分機後按「全選」，應該只勾選篩選出來的項目，其他未篩選出的分機不受影響"
echo "     - 不手動填任何欄位、只勾選分機後直接存檔，應該能成功（不再跳「通話逾時秒數為必填」）"
echo "  3. 確認 push 前 git status 乾淨、git log 看到本次 style: commit"
echo "  4. push 由你自己手動執行"
echo "======================================================"
