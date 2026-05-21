---
name: webox-order
description: Order food from WeBox autonomously via the WeBox API. Fetches the full menu in one call, plans within the user's budget honoring preferences/dietary/reviews, then places orders via POST /api/orders. Use for normal ordering — "order my lunch for tomorrow", "order lunch and dinner next week", "get me 5 milks across this week". For favorites-only narrow scope, use webox-favorite.
---

# WeBox Order Skill

> **About `javascript_tool` return values:**
> Tool-result truncation is REAL — at ~1000 characters / ~50 lines, your model-context (not just display) is cut. **Two retrieval paths:**
> 1. **Download bypass (preferred):** JS triggers a `<a download>` Blob click → file lands in `~/Downloads/webox-*.json` → Bash `mv` to `~/Documents/WeBox/`. ONE JS call per file. Requires the user to have granted Chrome's "automatic downloads" permission for `[*.]webox.com` (one-time setup in `chrome://settings/content/automaticDownloads`).
> 2. **Chunked fallback:** if the file doesn't land in `~/Downloads`, stash data on `window.__webox*` and slice back in chunks of 5 items per call, flat JSON.

---

## Defaults

- **Meal types:** when not specified, order both **Lunch and Dinner** per day
- **Weekends:** skip Sat/Sun for multi-day ranges unless asked
- **Confirmation:** `auto` by default (set `confirm_before_order: true` in config.yaml for plan-first mode)
- **Budget:** hard cap from `config.yaml`; default `spend-up-to` mode fills the budget with variety

## WeBox Constraints

- **7-day window:** orders accepted up to 7 days ahead
- **Meal cutoffs:** the menu API simply won't return a slot once its cutoff has passed
- **One slot = one POST:** each `(date, meal)` is a separate `POST /api/orders` — sequential, never parallel

---

## Step 0: Prerequisite Check

```
tabs_context_mcp({ createIfEmpty: true })
```

Capture the `tabId`. Navigate to `https://www.webox.com` (login probe). Verify `a.cart.fr` exists.

Check that all required files exist in `~/Documents/WeBox/`:
- `config.yaml`, `user-profile.json`, `address-info.json`, `favorites.json`, `shipping-windows.json`

If any is missing:
> You haven't set up WeBox yet. Run `/webox-onboard` first — takes about 2 minutes.

---

## Step 1: Load Local State

### 1a. Structured config (`config.yaml`)
Parse the YAML. Extract: `budget`, `budget_mode`, `validate_budget`, `confirm_before_order`, `default_meals`, `skip_weekends`, `avoid_repeat_days` (default 7), `history_window_days` (default 28), `allow_repeat_categories`, `restrictions`, `avoid_allergens`, `preferred_cuisines`, `cuisines_to_avoid`, `foods_i_like`, `foods_to_avoid`, `order_drinks`, `avoid_sugary_drinks`, `preferred_drinks`. These are **hard constraints** (the planner must respect them).

### 1a'. Free-form preferences (`preferences.md`)
Read the markdown file. Treat any bullets / paragraphs the user has written as **soft constraints** (good intent to honor where possible). The structured fields in `config.yaml` always override `preferences.md` if there's a conflict.

### 1b. Identity caches (JSON)
- `user-profile.json` → `{firstName, lastName, phone, email, timezone}` (for Place Order body)
- `address-info.json` → `{addressId, userAddressId, kitchenId, timezone}` (`addressId` is the canonical address record; `userAddressId` is your account's link — Place Order uses `addressId`, not `userAddressId`)
- `shipping-windows.json` → `{windows: {Lunch: {shippingTimeSectionId, extFormCutoff, ...}, Dinner: {...}}}` (derived from past orders by webox-onboard/sync)
- `favorites.json` → `{products: [{id, name, brand, category}], unresolvedProductIds: [], brands: [], synced_at}`. Derive the favorite-ID Set in JS: `new Set(favorites.products.map(p => p.id).concat(favorites.unresolvedProductIds))`.
- `hidden.json` → same shape. Derive the hidden-ID Set similarly.

### 1c. Item reviews (`item-reviews.md`)
Heavily injected into Step 4 selection.

### 1d. Order history (per-week JSON) — LOCAL CACHE ONLY, refresh next
Read week files overlapping `history_window_days` (typically last 4 weeks + current/next). Two purposes:
- **Slot occupancy:** any `✅` (active) or `📝 planned` entry blocks that slot
- **Variety tracking:** productIds in recent entries → avoid repeating (mains only)

**These local files are stale by default** — they're only fully refreshed during `/webox-onboard` or `/webox-sync`. Step 1e below is REQUIRED before you trust them for slot-occupancy decisions.

### 1e. ALWAYS refresh recent orders before planning (mandatory)

**Critical:** local `orders/YYYY-Www.json` files only get fully synced during `/webox-onboard` or `/webox-sync`. Orders placed between syncs are invisible if you trust the local files alone. This caused a real bug where the agent said "no orders this week" when the user actually had several active orders that just hadn't been synced locally yet.

**Mandatory step:** before any planning, fetch the latest ~30 orders from the WeBox API and merge into local state. One quick call, ~300ms.

**Important:** Include ALL statuses in the URL (Paid + Planned + ... + Refunded + Cancelled). Why: orders that the user has CANCELLED since the last sync need to disappear from local "✅ ordered" markings to free up the slot. If you exclude Cancelled/Refunded from the URL, your merge won't know that a previously-active order is now dead.

```javascript
(async () => {
  // ALL statuses in URL — including Refunded/Cancelled so we can detect newly-dead orders.
  const params = 'client=web&status=Paid%2CPartialRefunded%2CPlanned%2CUnpaid%2CRefunded%2CCancelled%2COnHold&pageSize=30&pageIndex=1&type=Individual&orderBy=id&desc=true&referenceTypes=GROUP_ORDER_META';
  const r = await fetch(`/api/orders/list?${params}`, { credentials: 'include' });
  const j = await r.json();
  if (j.code !== 1) return JSON.stringify({ error: 'orders fetch failed', code: j.code });
  const all = [];
  for (const o of (j.data.result || [])) {
    for (const pkg of (o.orderPackages || [])) {
      all.push({
        orderId: 'No.' + o.order.id,
        status: o.order.status,                       // keep status so merge step knows what to do
        dateShippingMs: pkg.dateShipping,
        timeShipping: pkg.timeShipping,
        total: o.order.totalCharge || 0,
        items: (pkg.extItems || []).map(it => ({
          productId: it.productId,
          quantity: it.quantity
          // name/brand are added by the Python merge step using the menu cache as a lookup
        }))
      });
    }
  }
  return JSON.stringify({ count: all.length, totalCount: j.data.totalCount, all });
})()
```

**Merge semantics in Bash/Python after this fetch:**
1. For each `all[i]` whose status is `Paid` / `Planned` / `PartialRefunded` / `Unpaid` / `OnHold` → upsert into the per-week file (it occupies a slot).
2. For each `all[i]` whose status is `Refunded` / `Cancelled` → **remove any matching local entry** by `orderId` (the slot is now free again).

Then **merge into the appropriate per-week file** with proper Cancelled/Refunded eviction:
```bash
# Paste the JS-returned 'all' array as a Python literal:
uv run --no-project python3 << 'EOF'
import json, os, datetime, glob
RECENT = $ALL_JSON  # the 'all' array from the JS above
DEAD_STATUSES = {'Refunded', 'Cancelled'}
out_dir = os.path.expanduser("~/Documents/WeBox/orders")
os.makedirs(out_dir, exist_ok=True)

# Build a productId → {name, brand} lookup from whatever menu caches we already have on disk.
# We don't fetch the menu API here (Step 1e is fast — ~300ms). If a productId isn't found in
# any local menu cache, we leave name/brand as null (still queryable by productId).
product_lookup = {}
for f in glob.glob(os.path.expanduser("~/Documents/WeBox/menu-cache/*.json")):
    try:
        for it in json.load(open(f)).get("items", []):
            product_lookup.setdefault(it["productId"], {"name": it.get("name"), "brand": it.get("brand")})
    except Exception: pass
def enrich(items):
    return [{**i, **product_lookup.get(i["productId"], {"name": None, "brand": None})} for i in items]

# Bucket fetched orders by week and into upsert/evict sets
upserts_by_week, dead_orderIds = {}, set()
for o in RECENT:
    d = datetime.datetime.fromtimestamp(o["dateShippingMs"]/1000, tz=datetime.timezone.utc).date()
    week_key = f"{d.isocalendar()[0]}-W{d.isocalendar()[1]:02d}"
    if o["status"] in DEAD_STATUSES:
        dead_orderIds.add(o["orderId"])  # mark for removal
    else:
        upserts_by_week.setdefault(week_key, []).append({
            "date": d.isoformat(), "day": d.strftime("%a"),
            "meal": o["timeShipping"], "orderId": o["orderId"],
            "status": o["status"], "total": o["total"], "items": enrich(o["items"])
        })

# All weeks that need rewriting: upsert weeks PLUS any weeks containing dead orderIds
affected_weeks = set(upserts_by_week.keys())
for path in glob.glob(f"{out_dir}/*.json"):
    try:
        d = json.load(open(path))
        if any(e.get("orderId") in dead_orderIds for e in d.get("orders", [])):
            affected_weeks.add(os.path.splitext(os.path.basename(path))[0])
    except Exception: pass

now = datetime.datetime.now(datetime.timezone.utc).isoformat()
n_upserts, n_evicts = 0, 0
for week in affected_weeks:
    path = f"{out_dir}/{week}.json"
    if os.path.exists(path):
        cur = json.load(open(path))
        existing = {e["orderId"]: e for e in cur.get("orders", []) if e.get("orderId") not in dead_orderIds}
        n_evicts += len(cur.get("orders", [])) - len(existing)
    else:
        existing = {}
    for e in upserts_by_week.get(week, []):
        if e["orderId"] not in existing:
            n_upserts += 1
        existing[e["orderId"]] = e
    ws = datetime.date.fromisocalendar(int(week[:4]), int(week[6:]), 1).isoformat()
    json.dump({"week": week, "week_starts": ws, "synced_at": now,
               "orders": sorted(existing.values(), key=lambda x: x["date"], reverse=True)},
              open(path, "w"), indent=2)
print(f"✓ merged: +{n_upserts} new/updated, −{n_evicts} cancelled/refunded, across {len(affected_weeks)} week files")
EOF
```

This way:
- A newly-placed order shows up (upsert).
- An order the user cancelled disappears from local state (evict), freeing the slot.
- Existing untouched orders are preserved (we only modify the affected weeks).

**Status filter rationale:** include `Paid` (active), `Planned` (future-scheduled — common case where the user pre-ordered for later in the week), `PartialRefunded`, `Unpaid`, `OnHold`. Exclude only `Refunded` and `Cancelled` — those slots are open again.

Without this step, slot-occupancy checks lie and the planner happily double-orders a slot that's already booked.

---

## Step 2: Fetch Menu for Each Target Slot

For each `(date, meal)` the user wants:

### 2a. Menu cache check
Read `~/Documents/WeBox/menu-cache/<DATE>-<MEAL>.json`. If `cached_at < 60 minutes ago`, reuse it.

### 2b. Fresh fetch via API + download-bypass write (~1s per slot)

The menu for a slot is ~1500 items × ~250 bytes = ~400KB. Returning it through `javascript_tool` would truncate at ~1000 chars. Two paths:

- **Download-bypass (fast — preferred):** JS builds the full menu JSON, triggers a Blob download via `<a download>` click. File lands in `~/Downloads`, Bash moves it to `~/Documents/WeBox/menu-cache/`. ONE round trip per slot.
- **Chunked fallback (slow but always works):** JS stashes items on `window.__weboxMenu`, agent retrieves in chunks of 5. ~300 round trips per slot.

The download-bypass requires Chrome's "automatic downloads" permission for webox.com (one-time grant — see "First-run permission" below). If the bypass fails, fall back to chunked automatically.

#### 2b-i — JS: fetch + filter + trigger download

```javascript
(async () => {
  const addrId = /* from address-info.json */;
  const date = '<YYYY-MM-DD>';
  const meal = '<Lunch|Dinner|HappyHour>';
  const r = await fetch(`/api/productSpecials/v8/address/${addrId}/date/${date}`, { credentials: 'include' });
  const j = await r.json();
  if (j.code !== 1) return JSON.stringify({ error: 'menu_fetch_failed', code: j.code, msg: j.msg });
  const specialsKey = meal.toLowerCase() + 'Specials';
  const specials = j.data[specialsKey] || [];
  const { products, productBrands } = j.data;
  const productById = new Map(products.map(p => [p.id, p]));
  const brandById   = new Map(productBrands.map(b => [b.id, b]));
  const favIds  = new Set(/* favorites.json: products.map(p => p.id).concat(unresolvedProductIds) */);
  const hideIds = new Set(/* hidden.json: products.map(p => p.id).concat(unresolvedProductIds) */);
  let kitchenId = null;
  const items = specials
    .filter(s => s.stockStatus !== 'outofstock')
    .map(s => {
      const p = productById.get(s.productId);
      if (!p || hideIds.has(p.id)) return null;
      kitchenId = kitchenId || s.kitchenId;
      const portion = (p.extPortions || []).find(x => x.isDefault) || (p.extPortions || [])[0];
      return {
        name:  p.extName?.enUs,
        brand: brandById.get(p.brandId)?.extName?.enUs,
        price: s.price,
        category: p.category,
        rating: p.averageRating || null,
        in_favorites: favIds.has(p.id),
        dietary: {
          glutenFree: !!p.glutenFree, dairyFree: !!p.dairyFree, halal: !!p.halalCertified,
          nutFree: !!p.nutFree, vegan: p.veggieLevel === 'Vegan', vegetarian: p.veggieLevel === 'Vegetarian'
        },
        stockQuantity: s.stockQuantity,
        productId: p.id,
        productSpecialId: s.id,
        portionId: portion?.id || null,
        portionCount: (p.extPortions || []).length
      };
    })
    .filter(Boolean);
  // Build the final cache file
  const cache = { cached_at: new Date().toISOString(), date, meal, kitchenId, items };
  const json = JSON.stringify(cache, null, 2);
  // Stash for fallback retrieval
  window.__weboxMenu = items;
  window.__weboxMenuCache = cache;
  // Trigger download
  const blob = new Blob([json], { type: 'application/json' });
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url;
  a.download = `webox-menu-${date}-${meal}-${Date.now()}.json`;
  document.body.appendChild(a);
  a.click();
  document.body.removeChild(a);
  setTimeout(() => URL.revokeObjectURL(url), 2000);
  return JSON.stringify({ downloadedAs: a.download, bytes: json.length, itemCount: items.length, kitchenId });
})()
```

#### 2b-ii — Bash: wait, verify, move

```bash
sleep 1.5
F="$HOME/Downloads/<filename from JS return>"
if [ -f "$F" ]; then
  mkdir -p ~/Documents/WeBox/menu-cache
  mv "$F" ~/Documents/WeBox/menu-cache/<DATE>-<MEAL>.json
  python3 -c "import json; d=json.load(open('$HOME/Documents/WeBox/menu-cache/<DATE>-<MEAL>.json')); print('✓ menu-cache written:', len(d['items']), 'items')"
else
  echo "Download didn't land — falling back to chunked retrieval"
  # See 2b-fallback below
fi
```

#### 2b-fallback — Chunked retrieval (when download bypass fails)

If the file didn't appear in `~/Downloads`:
1. The user hasn't granted Chrome's "automatic downloads" permission for webox.com — see "First-run permission" below
2. Or the page lost focus / was reloaded mid-call

Items are already stashed on `window.__weboxMenu` by the JS above. Loop:
```javascript
(async (offset) => {
  const items = window.__weboxMenu || [];
  const chunk = items.slice(offset, offset + 5);
  return JSON.stringify({ offset, total: items.length, done: offset + chunk.length >= items.length, items: chunk });
})(/* offset */)
```

Then write the assembled file with the Write tool, using the metadata from `window.__weboxMenuCache` (`cached_at`, `date`, `meal`, `kitchenId`).

#### First-run permission (one-time setup)

Chrome silently blocks subsequent programmatic downloads from an origin unless the user grants "Allow multiple automatic downloads". To enable:

1. Open Chrome: `chrome://settings/content/automaticDownloads`
2. Under "Allowed to automatically download multiple files", click "Add"
3. Enter `[*.]webox.com` and save

After this, all download-bypass calls work freely. Without it, the skill falls back to chunked retrieval (slower but functional).

#### Final notes

**What the agent plans against:** each cached item has name, brand, price, category, rating, in_favorites, dietary flags — all the fields needed for selection. The IDs (`productId`, `productSpecialId`, `portionId`) are metadata at the END of each entry; the agent doesn't read them during planning, only when assembling the Place Order body in Step 6.

**`shippingTimeSectionId` is NOT in the menu cache** — it's per-meal (constant within a kitchen), stored once in `shipping-windows.json` by webox-onboard / webox-sync, not duplicated per item.

**Hidden items and sold-out items are pre-filtered** in 2b-i. The cache is clean and ready for planning.

If `j.code !== 1` or items is empty: cutoff has likely passed. Tell the user; suggest picking a later slot.

---

## Step 3: Build the Order Plan

Build a complete plan for ALL requested slots **before placing anything**.

### Budget
- `spend-up-to` (default): aim to use most of the budget; prioritize variety
- `ceiling-only`: best picks, no fill-up
- Cap is on food item total only (no fees/tax)

### Quantities (× N notation)
Budget validation: `unit_price × qty`.

**Respect `stockQuantity` at plan time.** Each cached menu item carries `stockQuantity`:
- `stockQuantity === 0` → **unlimited stock** (the item isn't being tracked). Order any quantity.
- `stockQuantity > 0` → **finite remaining**. NEVER plan a quantity larger than `stockQuantity`. If the user explicitly asks for more (e.g., "5 fuji apples" but only 2 in stock), say so up front:
  > Only 2 Fuji Apples available — picking those + filling the rest with [substitute] to stay within budget?

This avoids POST-time stock failures for low-stock items.

### Selection priority

1. **Hard constraints (never violate):**
   - `restrictions` (vegetarian/vegan/halal/etc.) — filter via `dietary.*` flags
   - `avoid_allergens` — filter via dietary flags + free-text in review comments
   - Items rated 1/5 or tagged `never-again` in reviews → exclude
   - Strongly-negative review comments ("超级咸", "肉太少", "inedible") → exclude
   - Budget cap

2. **Strong preferences:**
   - Items rated 4–5/5 → top candidates
   - User's prompt constraints (e.g., "Chinese only today")
   - `preferred_cuisines` (match `category`)

3. **Variety (mains only) — HARD GATE, not a suggestion:**
   - ONLY apply to mains (entrées, bowls, bento, noodles, hot pots).
   - Items whose `category` is listed in `allow_repeat_categories` (e.g., Beverage, Appetizer, Snacks) are EXEMPT — they can repeat freely; ordering 5 of the same is fine.
   - **Build the recent set BEFORE picking** (see "Step 3a — variety context" below).
   - **Validate the plan AFTER picking** (see "Step 3c — variety validation").
   - **If any picked main violates the recent set, REPLAN with that productId+brand excluded** — don't ship the plan.

4. **Soft preferences:**
   - `in_favorites: true` items get a small bias
   - Fill remaining budget with complementary fillers if `spend-up-to`
   - Prompt-requested cuisine restricts the MAIN only — fillers can come from any category

### Item reviews — how to read

Reviews are free-form prose in any language with optional ratings. Both matter:
- "5/5" / "amazing" / "always order" → top
- "4/5" / "good" → preferred
- "2-3/5" / "ok" → deprioritize
- "1/5" / "never again" / "超级咸" → exclude (even without a number)

If comments diverge across dates, trust the most recent. When a review influences a decision, mention it:
> Skipping Spicy Hot Pot — review notes "too oily, didn't finish" (2026-05-15).

### Step 3a — Build the variety context (run BEFORE picking)

Compute the "recently ordered" set from per-week files. Use this as a hard exclusion list when picking mains.

```bash
uv run --no-project python3 << 'EOF'
import json, os, glob, datetime
AVOID_DAYS = 7  # from config.yaml avoid_repeat_days
ALLOW_REPEAT_CATEGORIES = ['Beverage', 'Appetizer', 'Snacks', 'Salads']  # from config.yaml
today = datetime.date.today()
cutoff = today - datetime.timedelta(days=AVOID_DAYS)

# Collect productIds and brand+productId pairs from recent orders
recent_pids = set()       # block exact productId repeats
recent_brand_pids = set() # block same productId from same brand even if different ID variant

for f in glob.glob(os.path.expanduser("~/Documents/WeBox/orders/*.json")):
    try:
        d = json.load(open(f))
        for o in d.get("orders", []):
            dt = datetime.date.fromisoformat(o["date"])
            if not (cutoff <= dt <= today + datetime.timedelta(days=7)):
                continue
            for it in o.get("items", []):
                pid, brand, name = it.get("productId"), it.get("brand"), (it.get("name") or "")
                # Skip filler categories — they're allowed to repeat
                # (Best-effort category check via menu cache lookup; fall back to allowing all if no info)
                recent_pids.add(pid)
                if brand and pid:
                    recent_brand_pids.add((brand, pid))

# Also compute a "frequent brand" set — brands appearing 2+ times in the recent window
from collections import Counter
brand_counts = Counter()
for f in glob.glob(os.path.expanduser("~/Documents/WeBox/orders/*.json")):
    try:
        d = json.load(open(f))
        for o in d.get("orders", []):
            dt = datetime.date.fromisoformat(o["date"])
            if not (cutoff <= dt <= today + datetime.timedelta(days=7)):
                continue
            for it in o.get("items", []):
                if it.get("brand"):
                    brand_counts[it["brand"]] += 1
    except Exception: pass
overused_brands = {b for b, c in brand_counts.items() if c >= 3}  # ≥3 entries in 7d window

out = {
    "today": today.isoformat(),
    "window": f"{cutoff.isoformat()} to {(today + datetime.timedelta(days=7)).isoformat()}",
    "recent_productIds": sorted(recent_pids),
    "overused_brands": sorted(overused_brands),
    "brand_counts_top": dict(brand_counts.most_common(10))
}
json.dump(out, open("/tmp/webox-variety-context.json", "w"), indent=2)
print(f"✓ {len(recent_pids)} productIds + {len(overused_brands)} overused brands in {AVOID_DAYS}d window")
EOF
```

**Read `/tmp/webox-variety-context.json` and reference it during planning.** Specifically:
- Any candidate main whose `productId` is in `recent_productIds` is **disqualified** — pick a different main.
- Any candidate main whose `brand` is in `overused_brands` is **strongly deprioritized** — only pick if no better alternative exists.

If the user's prompt explicitly overrides ("yes I want this exact dish again, I love it"), honor the override and skip the variety gate for that single item — but say so out loud in the plan.

### Plan output

```
📋 Order Plan — Mon May 25 – Fri May 29

Variety context: blocking 14 recently-ordered productIds; deprioritizing brands [Xiangchuan, Lee&Bai] (3+ entries in last 7d)

📅 Mon May 25, Lunch — $30.00 budget
  - Special Noodle Soup — Hainan Chicken × 1 — $17.15
  - Northwest China Cuisine — Tea Egg × 3 — $7.35   ($2.45 × 3, exempt: Appetizer category)
  - WeBox Fresh — Apple Gala × 1 — $3.95
  Total: $28.45 ✓
```

### Step 3c — VALIDATE plan against variety context (MANDATORY before confirming)

After building the plan but BEFORE presenting it to the user, run:

```bash
uv run --no-project python3 << 'EOF'
import json
PLAN = $PLAN_AS_JSON  # the picked items per slot, e.g.,
# [{"date":"2026-05-28","meal":"Dinner","items":[
#    {"productId":499852,"name":"Chiu Chow Brined Duck","brand":"Special Noodle Soup","category":"MainDishes"},
#    ...
#  ]}]
ALLOW_REPEAT_CATEGORIES = {'Beverage', 'Appetizer', 'Snacks', 'Salads'}  # from config.yaml
ctx = json.load(open("/tmp/webox-variety-context.json"))
blocked_pids = set(ctx["recent_productIds"])
overused = set(ctx["overused_brands"])

violations = []
for slot in PLAN:
    for it in slot["items"]:
        if it.get("category") in ALLOW_REPEAT_CATEGORIES:
            continue  # filler items exempt
        if it.get("productId") in blocked_pids:
            violations.append(f"{slot['date']} {slot['meal']}: {it['name']} (productId {it['productId']}) was ordered in the last 7 days")
        if it.get("brand") in overused:
            violations.append(f"{slot['date']} {slot['meal']}: brand '{it['brand']}' is overused (3+ recent entries) — pick a different brand if possible")
if violations:
    print("❌ VIOLATIONS — replan required:")
    for v in violations: print(f"  - {v}")
    exit(1)
print("✓ variety check passed")
EOF
```

If the script exits with violations: **DO NOT proceed**. Re-pick the offending mains with their productIds + (if possible) brands explicitly excluded from candidates. Loop up to **2 replan attempts** per slot. After 2 attempts, fall back to telling the user:
> Couldn't honor strict variety for [date meal]: only viable option is [item] which was last ordered [N] days ago. Want me to skip this slot or order it anyway?

Wait for explicit user choice.

---

## Step 3b: Validate Budget (if `validate_budget: true`)

```bash
uv run --no-project python -c "
items = [(17.45, 1), (2.45, 2), (5.95, 1)]  # (unit_price, qty)
budget = 30.0
total = sum(p * q for p, q in items)
assert total <= budget, f'Over budget: \${total:.2f} > \${budget:.2f}'
print(f'OK: \${total:.2f} / \${budget:.2f}')
"
```

If assertion fails: remove the most expensive non-essential and re-validate.

---

## Step 4: Confirm or Proceed

**Auto mode** (default): print plan, proceed immediately. Pause only for ambiguity, errors, or out-of-window dates.

**Confirm mode** (`confirm_before_order: true`):
```
Does this plan look good? Say "yes" to confirm, or tell me what to change.
```
Wait for reply, apply changes, re-confirm once before proceeding.

---

## Step 5: Save Plan to Order History (planned status)

For each slot, write/merge into `~/Documents/WeBox/orders/YYYY-Www.json` with `planned: true`:
```json
{
  "date": "2026-05-25",
  "day": "Mon",
  "meal": "Lunch",
  "planned": true,
  "total": 28.30,
  "items": [
    {
      "productSpecialId": 56813079, "productId": 499852, "portionId": 144251,
      "name": "Mongolian Beef Bento", "brand": "Xiangchuan Kitchen", "price": 17.45, "quantity": 1
    }
  ]
}
```

`planned: true` distinguishes "I told the user we'd order this" from "this is in WeBox". After Step 6 success, remove the flag and add the real `orderId`.

---

## Step 6: Place Each Order via API (sequential)

For each slot in the plan, call `POST /api/orders` with the body assembled from:
- The planned items (with `productSpecialId`, `portionId`, `quantity`)
- `~/Documents/WeBox/user-profile.json` (identity)
- `~/Documents/WeBox/address-info.json` (`addressId`, `kitchenId`, `timezone`)
- `~/Documents/WeBox/shipping-windows.json` (the per-meal `shippingTimeSectionId` and `extFormCutoff`)

```javascript
(async (slot, profile, address, shippingWindows) => {
  const win = shippingWindows.windows[slot.meal];
  if (!win) throw new Error(`No shipping window for ${slot.meal} — derive from past orders first or use DOM fallback.`);
  // dateShipping = UTC midnight of the shipping date (WeBox's canonical form). Explicit 'Z' matters.
  const dateShipping = new Date(slot.date + 'T00:00:00Z').getTime();
  // cutoffTime = LOCAL extFormCutoff time on (shipping date - daysBefore), as ms since epoch.
  // Uses browser local timezone — assumes browser tz matches user's WeBox tz.
  // Empirically verified against intercepted Place Order body: matches exactly.
  const [yy, mm, dd] = slot.date.split('-').map(Number);
  const cutDate = new Date(yy, mm - 1, dd - (win.daysBefore || 0));
  const cyyyy = cutDate.getFullYear();
  const cmm = String(cutDate.getMonth() + 1).padStart(2, '0');
  const cdd = String(cutDate.getDate()).padStart(2, '0');
  const cutoffTime = new Date(`${cyyyy}-${cmm}-${cdd}T${win.extFormCutoff}:00`).getTime();
  const body = {
    order: {
      firstName: profile.firstName,
      lastName:  profile.lastName,
      phone:     profile.phone,
      email:     profile.email,
      timezone:  profile.timezone || address.timezone || 'America/Los_Angeles',
      addressId: address.addressId,                // CANONICAL — not userAddressId
      kitchenId: address.kitchenId,
      currency:  'Dollar',
      autoSelectCoupon: true
    },
    orderPackages: [{
      extItems: slot.items.map(it => ({
        productSpecialId: it.productSpecialId,
        portionId:        it.portionId,
        quantity:         it.quantity,
        cutoffTime:       cutoffTime,
        extCartItemId:    `${slot.date}__${win.shippingTimeSectionId}__${it.productSpecialId}__${it.portionId}`,
        extChildren:      []
      })),
      dateShipping,
      timeShipping:           slot.meal,
      shippingTimeSectionId:  win.shippingTimeSectionId,
      kitchenId:              address.kitchenId,
      extCutleryQuantity:     0,
      extBaseCutleryQuantity: 1
    }],
    payType:            'Personal',
    realTips:           0,
    usePersonalWeBucks: true,
    hasAddedWeBucks:    false
  };
  const r = await fetch('/api/orders?client=web', {
    method: 'POST', credentials: 'include',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body)
  });
  const j = await r.json();
  return JSON.stringify({ status: r.status, code: j.code, msg: j.msg || j.message, orderId: j.data?.id });
})(<slot>, <profile>, <address>, <shippingWindows>)
```

**If `shipping-windows.json` is empty or missing the meal type** (rare — only on brand-new accounts with zero history): fall back to the DOM path for that one order (navigate to `/?date=X&shippingTime=Y`, DOM-click an item, navigate to `/checkout`, intercept the Place Order POST to learn the `shippingTimeSectionId`, then write it to `shipping-windows.json` for future orders). After the first successful order, all subsequent orders use the API path.

**On success** (`code === 1`, `orderId` returned):
- Update the per-week JSON entry: remove `planned: true`, add `"orderId": "No.<id>"`
- Print: `✅ Order placed! Order #<orderId> — <date> <meal> — $<total>`
- **Move on immediately. Do NOT verify by polling the orders list.**

> **CRITICAL — `code: 1` is the only success signal you need.** The order is placed in WeBox's database the moment the POST returns successfully. Do NOT then call `/api/orders/list?status=Planned,OnHold,Unpaid` or any other "did it work?" query.
>
> Real failure mode observed: agent placed an order (POST returned `code: 1`, orderId in hand), then polled `/api/orders/list?status=Planned%2COnHold%2CUnpaid` to "verify" — but a fresh paid order's status is `Paid` (NOT in that filter), and the API has cache lag besides. The agent saw `totalCount: 0`, panicked, retried, polled more, got stuck for minutes while the order was already done.
>
> The Place Order POST is your source of truth. `code: 1` + `data.id` = the order exists. Move on.

**On failure** (`code !== 1`):
- Print `msg` to the user verbatim — that's the truth about what went wrong
- Keep `planned: true` in the per-week file so the slot is retry-eligible
- Cap automatic retries at **2 per slot** (`__retryCount` on the planned entry). After 2 failures, surface the error and ask the user what to do.

**Failure-case recipe — stock issues (the most common):**

WeBox menu data can lag behind real stock by minutes. An item the menu API showed as `Instock` may already be sold out by the time you POST. The `msg` typically contains the keyword `stock`, `out of stock`, `sold out`, `insufficient`, `not available`, or `unavailable`. Handle in this exact order:

1. **Re-fetch the menu for that exact (date, meal)** — bypass the local `menu-cache` (the cache may itself be stale; fetch fresh).
2. **Locate the failing item in the fresh menu**:
   - If it's now `stockStatus === "outofstock"` or absent → item is genuinely gone. Find a **substitute**: same `category`, similar `price` (±$1.00), prefer `in_favorites: true`. Announce the swap to the user in one sentence (e.g., "Apple Fuji out of stock. Swapping in Apple Gala (same price, same brand category)."). Then retry POST with the substitute.
   - If it's still listed with `stockQuantity > 0 && stockQuantity < requestedQty` → reduce the qty to `stockQuantity` and refill the leftover budget with a different filler. Retry POST.
   - If it's still listed as in-stock and stockQuantity is 0/unlimited → the menu data was right but WeBox's stock service is briefly inconsistent. Wait ~1.5 seconds and retry the same POST exactly once. If it fails again, treat it like the "genuinely gone" case above.
3. After substitution + retry, if the second POST still fails with a stock error → surface to user. Don't try a third time silently.

**Other common failure cases:**
- `"cutoff passed"` / `"cutoffTime"` in msg → slot's order window has closed. Don't retry. Tell the user; suggest a later slot.
- `"duplicate order"` / `"already exists"` in msg → slot already has an active order. Check `orders/YYYY-Www.json` for an existing entry — likely a previous run succeeded but the local state wasn't updated. Do NOT retry; instead, fetch the existing order from `/api/orders/list?status=Paid&...` and reconcile the local file.
- `"budget"` in msg → backend rejected the budget. Trim the most expensive non-essential item and retry once.

**Sequential, never parallel.** Place Order is a real mutation — race conditions could cause duplicate charges. Always one at a time, including retries.

---

## Step 7: Repeat per Slot

Loop Step 6 over each slot in the plan. Each is independent; ~1s per slot.

Final summary:
```
🎉 All done!

  Mon May 25 Lunch  $28.30 ✅ #XXXXXXX
  Mon May 25 Dinner $20.25 ✅ #XXXXXXX
  Tue May 26 Lunch  $29.50 ✅ #XXXXXXX
```

---

## Step 8: Post-Order Feedback

If no feedback was given this session, invite it:
> Done! Any feedback on dishes you've tried — good or bad — just tell me. Free-form: "too dry", "loved it", "这个超级咸", etc.

Parse and append to `~/Documents/WeBox/item-reviews.md`. Create the file if missing.

### Review format
```markdown
# Item Reviews

## Xiangchuan Kitchen — Mongolian Beef Bento
Rating: 5/5
Tags: favorite, lunch-regular
Comments:
- 2026-05-22: Always order this. Amazing.
- 2026-05-22: Prefer purple rice option.

## Northwest China Cuisine — Spicy Hot Pot
Comments:
- 2026-05-15: 这个超级咸，肉太少
- 2026-05-20: 又点了一次，还是咸，不会再点了
Inferred: hard exclude.
```

Append dated comments rather than overwriting. Only update `Rating:` if the user gives a number explicitly.

---

## Error Handling

| Situation | Response |
|---|---|
| Menu API code != 1 | Print `msg`; ask user to try later or pick different slot |
| 0 items for a slot | Cutoff likely passed; suggest later slot |
| Place Order code != 1 | Print `msg`; leave `planned: true` for retry |
| Budget exceeded mid-plan | Drop most expensive non-essential, re-plan |
| Outside 7-day window | Skip silently, note in summary |
| Identity cache missing | Direct user to `/webox-onboard` |
| User has no address | Tell user to add a delivery address on webox.com first |

---

## DOM Fallback (last resort)

If the API is unavailable (schema change, etc.), see `~/.claude/skills/webox/SITEMAP.md` "DOM patterns" section for the legacy DOM-scraping + cart-clicking + .place-btn flow. Slower (~30s per slot vs ~1s) and more fragile but works.
