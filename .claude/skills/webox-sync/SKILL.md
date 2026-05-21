---
name: webox-sync
description: One-stop API sync — refresh order history, favorites, hidden list, and warm-cache upcoming menus. Then display this week and next week's slot calendar. Use when the user says "sync my WeBox", "show my calendar", "refresh favorites", "what's been ordered", "pull latest".
---

# WeBox Sync Skill

Refreshes all read-only state via API and shows the calendar.

> **CRITICAL — about `javascript_tool` return values:**
> Tool-result truncation is REAL — at ~1000 characters / ~50 lines, your displayed AND model-context content is cut, with everything after `[TRUNCATED]` lost. Verified empirically. **Never write to `~/Downloads/`** or use blob/download tricks. The reliable pattern is chunked retrieval: stash data on `window.__webox*`, slice it back in deterministic chunks of 5 items per call with **flat (no pretty-print) JSON**. Larger chunks silently drop data.

**Inputs:** existing `user-profile.json`, `address-info.json` in `~/Documents/WeBox/` (from `/webox-onboard`).
**Outputs (refreshed):**
- `orders/YYYY-Www.json` — per-ISO-week order history (active orders only)
- `favorites.json` — `{productIdList, brandIdList, synced_at}`
- `hidden.json` — same shape (Not-Interested list)
- `menu-cache/YYYY-MM-DD-{Lunch,Dinner}.json` — next 1–2 orderable slots

All API-based. No DOM scraping. See `~/.claude/skills/webox/SITEMAP.md` for endpoint details.

---

## Step 1: Prerequisite Check

```
tabs_context_mcp({ createIfEmpty: true })
```
If a tab group exists, create a fresh tab (`tabs_create_mcp()`) to avoid stale state. Capture the `tabId`. Navigate it to `https://www.webox.com` and verify login:
```javascript
({ loggedIn: !!document.querySelector('a.cart.fr') })
```
If not logged in: ask user to log in. If `address-info.json` is missing locally: tell the user to run `/webox-onboard` first.

---

## Step 2: Refresh Favorites + Hidden Lists (download bypass + diff)

Use the **same flow as `webox-onboard` Step 6** — see that skill for the empirically-tested scripts. Brief recap below.

### 2a — Fetch + enrich + stash + download favorites.json (one JS call)

```javascript
(async (addrId, date) => {
  const [menuR, favR, hideR] = await Promise.all([
    fetch(`/api/productSpecials/v8/address/${addrId}/date/${date}`, { credentials: 'include' }).then(r => r.json()),
    fetch('/api/fav/my', { credentials: 'include' }).then(r => r.json()),
    fetch('/api/hide/my', { credentials: 'include' }).then(r => r.json())
  ]);
  if (menuR.code !== 1) return JSON.stringify({ error: 'menu fetch failed', code: menuR.code });
  const { products, productBrands } = menuR.data;
  const productById = new Map(products.map(p => [p.id, p]));
  const brandById = new Map(productBrands.map(b => [b.id, b]));
  const enrichP = (idList) => {
    const ps = [], unresolved = [];
    for (const id of idList || []) {
      const p = productById.get(id);
      if (!p) { unresolved.push(id); continue; }
      ps.push({ id, name: p.extName?.enUs, brand: brandById.get(p.brandId)?.extName?.enUs, category: p.category });
    }
    return { products: ps, unresolved };
  };
  const enrichB = (idList) => (idList || []).map(id => {
    const b = brandById.get(id);
    return b ? { id, name: b.extName?.enUs } : { id, name: null };
  });
  const now = new Date().toISOString();
  const favEn  = enrichP(favR.data?.productIdList);
  const hideEn = enrichP(hideR.data?.productIdList);
  window.__favPayload  = { synced_at: now, products: favEn.products,  unresolvedProductIds: favEn.unresolved,  brands: enrichB(favR.data?.brandIdList) };
  window.__hidePayload = { synced_at: now, products: hideEn.products, unresolvedProductIds: hideEn.unresolved, brands: enrichB(hideR.data?.brandIdList) };
  window.__weboxMenuRaw = menuR.data;
  const favJson = JSON.stringify(window.__favPayload, null, 2);
  const blob = new Blob([favJson], { type: 'application/json' });
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url;
  a.download = `webox-favorites-${Date.now()}.json`;
  document.body.appendChild(a); a.click(); document.body.removeChild(a);
  setTimeout(() => URL.revokeObjectURL(url), 2000);
  return JSON.stringify({
    downloadedAs: a.download, favBytes: favJson.length,
    favCount: favEn.products.length, favUnresolved: favEn.unresolved.length,
    hideCount: hideEn.products.length, hideUnresolved: hideEn.unresolved.length,
    synced_at: now
  });
})(/* addrId integer */, /* 'YYYY-MM-DD' tomorrow */)
```

### 2a-bash — Move + diff against existing local file

```bash
sleep 1.5
F="$HOME/Downloads/<downloadedAs from JS>"
if [ -f "$F" ]; then
  # Compare new with old, log the diff, then overwrite.
  python3 << 'EOF'
import json, os
new = json.load(open(os.path.expanduser("$F")))
new_ids = {p["id"] for p in new["products"]}
target = os.path.expanduser("~/Documents/WeBox/favorites.json")
if os.path.exists(target):
    old = json.load(open(target))
    old_ids = {p["id"] for p in old.get("products", [])}
    added = new_ids - old_ids
    removed = old_ids - new_ids
    if added: print(f"  + Hearted since last sync: {len(added)}")
    if removed: print(f"  - Unhearted since last sync: {len(removed)}")
import shutil
shutil.move(os.path.expanduser("$F"), target)
print(f"✓ favorites.json: {len(new['products'])} products, {len(new['unresolvedProductIds'])} unresolved")
EOF
else
  echo "Download didn't land — falling back to chunked. See 2-fallback below."
fi
```

### 2b — Download hidden.json (second JS call)

```javascript
(async () => {
  const hideJson = JSON.stringify(window.__hidePayload, null, 2);
  const blob = new Blob([hideJson], { type: 'application/json' });
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url;
  a.download = `webox-hidden-${Date.now()}.json`;
  document.body.appendChild(a); a.click(); document.body.removeChild(a);
  setTimeout(() => URL.revokeObjectURL(url), 2000);
  return JSON.stringify({ downloadedAs: a.download, bytes: hideJson.length, hideCount: window.__hidePayload.products.length });
})()
```

**Then run Bash immediately:**
```bash
sleep 1.5
F="$HOME/Downloads/<downloadedAs from JS>"
if [ -f "$F" ]; then
  python3 << 'EOF'
import json, os, shutil
new = json.load(open(os.path.expanduser("$F")))
new_ids = {p["id"] for p in new["products"]}
target = os.path.expanduser("~/Documents/WeBox/hidden.json")
if os.path.exists(target):
    old = json.load(open(target))
    old_ids = {p["id"] for p in old.get("products", [])}
    added = new_ids - old_ids
    removed = old_ids - new_ids
    if added: print(f"  + Hidden since last sync: {len(added)}")
    if removed: print(f"  - Un-hidden since last sync: {len(removed)}")
shutil.move(os.path.expanduser("$F"), target)
print(f"✓ hidden.json: {len(new['products'])} products, {len(new['unresolvedProductIds'])} unresolved")
EOF
fi
```

**Reminder:** `~/Downloads` is intermediate only. Every webox-*.json triggered by JS MUST be moved into `~/Documents/WeBox/` immediately. The downstream skills only read from `~/Documents/WeBox/`.

### 2-fallback — Chunked retrieval (when download bypass fails)

If a file didn't land in `~/Downloads`, Chrome's automatic-downloads permission isn't granted for `[*.]webox.com`. Tell the user to set it up (`chrome://settings/content/automaticDownloads`) and fall back to:

```javascript
// favorites chunk; loop offset = 0, 5, 10, ... until done: true
(async (offset) => {
  const products = window.__favPayload?.products || [];
  const chunk = products.slice(offset, offset + 5);
  return JSON.stringify({ offset, total: products.length, chunkCount: chunk.length, done: offset + chunk.length >= products.length, products: chunk });
})(/* offset integer */)
```

Then tail call for brands + unresolved, assemble in agent state, Write tool. Identical pattern for `__hidePayload`. ~40 round-trips total.

---

## Step 3: Refresh Order History (paginated API)

Same accumulate-on-page + return-summary pattern as webox-onboard Step 5. Stash the full list on `window.__weboxOrders`, return only a summary + shipping-windows, then paginate the orders back in chunks.

```javascript
(async () => {
  const params = 'client=web&status=Paid%2CPartialRefunded%2CPlanned%2CUnpaid%2CRefunded%2CCancelled%2COnHold&pageSize=10&type=Individual&orderBy=id&desc=true&referenceTypes=GROUP_ORDER_META';
  const all = [];
  let pageIndex = 1;
  while (pageIndex <= 100) {
    const r = await fetch(`/api/orders/list?${params}&pageIndex=${pageIndex}`, { credentials: 'include' });
    const j = await r.json();
    if (j.code !== 1 || !j.data?.result?.length) break;
    all.push(...j.data.result);
    if (all.length >= j.data.totalCount) break;
    pageIndex++;
  }
  // Also derive shipping-windows from package's extShippingTimeSection
  const shippingWindows = {};
  // Filter to active + flatten by package
  const active = [];
  for (const r of all) {
    for (const pkg of (r.orderPackages || [])) {
      const ts = pkg.timeShipping;
      const ext = pkg.extShippingTimeSection;
      if (ext && !shippingWindows[ts]) {
        shippingWindows[ts] = {
          shippingTimeSectionId: pkg.shippingTimeSectionId,
          extFormCutoff: ext.extFormCutoff,
          daysBefore: ext.daysBefore || 0,
          extFormShippingBegin: ext.extFormShippingBegin,
          extFormShippingEnd: ext.extFormShippingEnd,
          cutoff_local_ms: ext.cutoff,
          shippingBegin_local_ms: ext.shippingBegin,
          shippingEnd_local_ms: ext.shippingEnd
        };
      }
      if (['Refunded', 'Cancelled'].includes(r.order?.status)) continue;  // keep Paid + Planned + PartialRefunded + Unpaid + OnHold
      const items = (pkg.extItems || []).map(it => ({
        productId: it.productId,
        productSpecialId: it.productSpecialId,
        portionId: it.portionId,
        quantity: it.quantity,
        price: (it.pricePerUnitCents ?? it.priceCents ?? 0) / 100
      }));
      active.push({
        orderId: 'No.' + r.order.id,
        dateShippingMs: pkg.dateShipping,
        timeShipping: ts,
        total: r.order.totalCharge || 0,
        items
      });
    }
  }
  // Stash the FULL active list on the page. Return only summary + shipping-windows + 20 recent orders.
  window.__weboxOrders = active;
  return JSON.stringify({
    totalFetched: all.length,
    activeCount: active.length,
    shippingWindows,
    recentOrders: active.slice(0, 20)
  });
})()
```

**Then download the full orders list in one call (preferred — needs Chrome auto-download permission):**

```javascript
(async () => {
  const orders = window.__weboxOrders || [];
  const json = JSON.stringify({ count: orders.length, orders }, null, 2);
  const blob = new Blob([json], { type: 'application/json' });
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url;
  a.download = `webox-orders-${Date.now()}.json`;
  document.body.appendChild(a); a.click(); document.body.removeChild(a);
  setTimeout(() => URL.revokeObjectURL(url), 2000);
  return JSON.stringify({ downloadedAs: a.download, bytes: json.length, count: orders.length });
})()
```

Bash — wait, group by ISO week, write per-week files (preserves any `planned: true` entries):
```bash
sleep 1.5
F="$HOME/Downloads/<downloadedAs from JS>"
if [ -f "$F" ]; then
  uv run --no-project python3 << 'EOF'
import json, os, datetime, glob
src = json.load(open(os.path.expanduser("$F")))
out_dir = os.path.expanduser("~/Documents/WeBox/orders")
os.makedirs(out_dir, exist_ok=True)
# Preserve any existing planned: true entries
planned = {}
for f in glob.glob(f"{out_dir}/*.json"):
    try:
        d = json.load(open(f))
        for o in d.get("orders", []):
            if o.get("planned"):
                planned[(o["date"], o["meal"])] = o
    except Exception: pass
weeks = {}
for o in src["orders"]:
    d = datetime.datetime.fromtimestamp(o["dateShippingMs"]/1000, tz=datetime.timezone.utc).date()
    iy, iw, _ = d.isocalendar()
    key = f"{iy}-W{iw:02d}"
    weeks.setdefault(key, []).append({
        "date": d.isoformat(), "day": d.strftime("%a"),
        "meal": o["timeShipping"], "orderId": o["orderId"],
        "total": o["total"], "items": o["items"],
    })
# Merge in planned entries that aren't already in the synced set
for (date, meal), p in planned.items():
    iy, iw, _ = datetime.date.fromisoformat(date).isocalendar()
    key = f"{iy}-W{iw:02d}"
    existing = next((x for x in weeks.get(key, []) if x["date"] == date and x["meal"] == meal), None)
    if not existing:
        weeks.setdefault(key, []).append(p)
for week, entries in weeks.items():
    ws = datetime.date.fromisocalendar(int(week[:4]), int(week[6:]), 1).isoformat()
    json.dump({"week": week, "week_starts": ws,
               "synced_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
               "orders": sorted(entries, key=lambda x: x["date"], reverse=True)},
              open(f"{out_dir}/{week}.json","w"), indent=2)
print(f"✓ wrote {len(weeks)} week files, {sum(len(v) for v in weeks.values())} orders")
EOF
  rm "$F"
else
  echo "Download didn't land. Falling back to chunked retrieval."
fi
```

**Fallback (when bypass fails):**
```javascript
(async (offset) => {
  const chunk = (window.__weboxOrders || []).slice(offset, offset + 3);
  return JSON.stringify({ offset, count: chunk.length, orders: chunk });
})(/* offset */)
```
Loop until `count === 0`. ~135 round-trips for a 400-order history. Process per-week in agent state.

**Default loop bound:** stop early once you've fetched `history_window_days × 1.5` worth (≈ 30 weeks ≈ 60 pages ≈ 6 seconds). If the user says "pull all my history", remove that bound and fetch all `totalCount` orders.

**Write `shipping-windows.json`** in `~/Documents/WeBox/`:
```json
{
  "synced_at": "2026-05-21T14:30:00Z",
  "windows": {
    "Lunch":  { "shippingTimeSectionId": 27274, "extFormCutoff": "08:00", "extFormShippingBegin": "11:00", "extFormShippingEnd": "12:30", "cutoff_local_ms": 28800000, "shippingBegin_local_ms": 39600000, "shippingEnd_local_ms": 45000000 },
    "Dinner": { "shippingTimeSectionId": 27275, "extFormCutoff": "14:30", "extFormShippingBegin": "17:00", "extFormShippingEnd": "18:30", "cutoff_local_ms": 52200000, "shippingBegin_local_ms": 61200000, "shippingEnd_local_ms": 66600000 }
  }
}
```

Merge with any existing local copy (don't lose a meal type that's in the local file but not in the new sync — e.g., HappyHour that's in older orders we didn't refetch).

### Convert to per-week JSON

For each active order, compute the ISO week of its `dateShippingMs`, group, and write `~/Documents/WeBox/orders/YYYY-Www.json` with schema:

```json
{
  "week": "2026-W21",
  "week_starts": "2026-05-18",
  "synced_at": "2026-05-21T14:30:00Z",
  "orders": [
    {
      "date": "2026-05-21",
      "day": "Thu",
      "meal": "Lunch",
      "orderId": "No.3259401",
      "total": 21.95,
      "items": [
        { "productId": 499852, "name": "Mongolian Beef Bento", "brand": "Xiangchuan Kitchen", "price": 17.45, "quantity": 1 }
      ]
    }
  ]
}
```

Per-week file ISO-week computation (JS):
```javascript
function isoWeek(d) {
  const dt = new Date(d); dt.setHours(0,0,0,0);
  dt.setDate(dt.getDate() + 4 - (dt.getDay() || 7));
  const ys = new Date(dt.getFullYear(), 0, 1);
  return `${dt.getFullYear()}-W${String(Math.ceil((((dt - ys) / 86400000) + 1) / 7)).padStart(2,'0')}`;
}
```

**Merge semantics:** preserve any local entries with `planned: true` (those are pending checkouts written by `webox-order` before placement). Overwrite all other entries.

**Resolving product names:** the orders API returns `productId` but not the human-readable name. Use the menu cache from Step 4 below as a lookup. For older orders whose products are no longer in any current menu cache, use `"<unknown>"` for `name` (productId alone is enough for variety tracking; the user can see the order on WeBox itself if they want details).

---

## Step 4: Warm-Cache Upcoming Menus

Identify the next 1–2 orderable Lunch slots (and corresponding Dinners if within the 7-day window). For each, fetch + trigger download — same pattern as `webox-order` Step 2b. One JS call + one Bash mv per slot:

```javascript
(async (date, meal) => {
  const addrId = /* from address-info.json */;
  const r = await fetch(`/api/productSpecials/v8/address/${addrId}/date/${date}`, { credentials: 'include' });
  const j = await r.json();
  if (j.code !== 1) return JSON.stringify({ error: 'menu fetch failed', date, meal, code: j.code });
  const specialsKey = meal.toLowerCase() + 'Specials';
  const specials = j.data[specialsKey];
  const { products, productBrands } = j.data;
  const productById = new Map(products.map(p => [p.id, p]));
  const brandById = new Map(productBrands.map(b => [b.id, b]));
  const favIds = new Set(/* favorites.json: products.map(p => p.id).concat(unresolvedProductIds) */);
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
        name: p.extName?.enUs,
        brand: brandById.get(p.brandId)?.extName?.enUs,
        price: s.price, category: p.category,
        rating: p.averageRating || null,
        in_favorites: favIds.has(p.id),
        dietary: {
          glutenFree: !!p.glutenFree, dairyFree: !!p.dairyFree, halal: !!p.halalCertified,
          nutFree: !!p.nutFree, vegan: p.veggieLevel === 'Vegan', vegetarian: p.veggieLevel === 'Vegetarian'
        },
        stockQuantity: s.stockQuantity,
        productId: p.id, productSpecialId: s.id,
        portionId: portion?.id || null,
        portionCount: (p.extPortions || []).length
      };
    })
    .filter(Boolean);
  const cache = { cached_at: new Date().toISOString(), date, meal, kitchenId, items };
  const json = JSON.stringify(cache, null, 2);
  // Stash for fallback
  window[`__weboxMenu_${date}_${meal}`] = items;
  // Trigger download
  const blob = new Blob([json], { type: 'application/json' });
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url;
  a.download = `webox-menu-${date}-${meal}-${Date.now()}.json`;
  document.body.appendChild(a); a.click(); document.body.removeChild(a);
  setTimeout(() => URL.revokeObjectURL(url), 2000);
  return JSON.stringify({ downloadedAs: a.download, bytes: json.length, itemCount: items.length, date, meal });
})(/* 'YYYY-MM-DD' */, /* 'Lunch' | 'Dinner' */)
```

Bash:
```bash
sleep 1.5
F="$HOME/Downloads/<downloadedAs from JS>"
if [ -f "$F" ]; then
  mkdir -p ~/Documents/WeBox/menu-cache
  mv "$F" ~/Documents/WeBox/menu-cache/<DATE>-<MEAL>.json
fi
```

If download didn't land → fall back to chunked retrieval from `window.__weboxMenu_<date>_<meal>` (same 5-item chunk pattern as Step 2 fallback).

Skip this step entirely if the user said "just sync orders, don't touch menus".

Schema written to `~/Documents/WeBox/menu-cache/<DATE>-<MEAL>.json`:
```json
{
  "cached_at": "ISO-8601",
  "date": "2026-05-22",
  "meal": "Lunch",
  "kitchenId": 12838,
  "items": [ ... ]
}
```

Skip this step if the user explicitly said "just sync orders, don't touch menus".

---

## Step 5: Display the Active Window

Load `orders/YYYY-Www.json` for this week and next week. Display Mon–Fri (include weekends only if the user asked):

```
📅 WeBox Order Calendar — Week of May 18 & May 25

This week (May 18–22)
  Mon May 18  Lunch  ✅  Mongolian Beef bento, Tea Egg ×2, Taboulleh
              Dinner —   not ordered
  Tue May 19  Lunch  ✅
              Dinner —   not ordered
  Wed May 20  Lunch  ⏰  cutoff passed
  Thu May 21  Lunch  ✅
  Fri May 22  Lunch  ✅
              Dinner —   not ordered

Next week (May 25–29)
  Mon May 25  Lunch  ○   available
              Dinner ○   available
  ...
```

Legend: ✅ ordered (active) | 📝 planned (from webox-order, not yet placed) | ○ open | ⏰ cutoff passed | 🔒 outside 7-day window | — not ordered. Only ✅ and 📝 block a slot.

---

## Step 6: Summary + Offer

```
✅ Synced.
  Favorites:   131 items (+2 / -1 vs last sync)
  Hidden:      180 items
  Orders:      407 active orders across 41 weeks
  Menus:       refreshed Fri 05/22 Lunch (X items), Mon 05/25 Lunch (Y items)

This week: 4/10 slots ordered.
Next week: 0/10 slots ordered — 7 open within the 7-day window.
```

If favorites or hidden CHANGED since last sync, surface the diff:
```
  + Hearted: "Baby Mixed Greens Salad (Northwest China Cuisine)"
  - Unhearted: "Spicy Hot Pot"
```

Then offer:
```
Want me to order the open slots? Just say which days or meals.
```
