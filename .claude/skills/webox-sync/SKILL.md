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

## Step 2: Refresh Favorites + Hidden Lists (chunked, with diff)

Refreshing requires the current menu's `products` array to resolve IDs → readable names. Use the **same Step-6a/6b/6c chunked pattern** as `webox-onboard`. Detailed scripts there; condensed below.

### 2a — Fetch + enrich + stash, return summary only

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
  window.__weboxMenuRaw = menuR.data;  // available for Step 4 warm-cache
  return JSON.stringify({
    favCount: favEn.products.length, favUnresolved: favEn.unresolved.length, favBrandCount: (favR.data?.brandIdList||[]).length,
    hideCount: hideEn.products.length, hideUnresolved: hideEn.unresolved.length, hideBrandCount: (hideR.data?.brandIdList||[]).length,
    synced_at: now
  });
})(/* addrId integer */, /* 'YYYY-MM-DD' */)
```

### 2b/2c — Chunked retrieval (5 products per call, flat JSON)

```javascript
// favorites chunk; loop offset = 0, 5, 10, ... until done: true
// 5 items per chunk + flat JSON keeps every return under the ~1000-char tool-result truncation limit
(async (offset) => {
  const products = window.__favPayload?.products || [];
  const chunk = products.slice(offset, offset + 5);
  return JSON.stringify({ offset, total: products.length, chunkCount: chunk.length, done: offset + chunk.length >= products.length, products: chunk });
})(/* offset integer */)
```

**On every chunk, verify `chunkCount === 5`** (or `< 5` only when `done: true`). If a chunk returns fewer items unexpectedly, re-fetch that offset. Do NOT use larger chunk sizes — they will silently drop data past the truncation limit.

Then tail call for brands + unresolved:
```javascript
JSON.stringify({ synced_at: window.__favPayload.synced_at, brands: window.__favPayload.brands, unresolvedProductIds: window.__favPayload.unresolvedProductIds })
```

Identical for `__hidePayload` → `hidden.json`.

### 2d — Diff vs the existing local file before overwriting

Before writing the new `favorites.json`, read the old one (if it exists) and compute the symmetric diff on `products[].id`. Surface in the Step 6 summary:
- Hearted since last sync: products in new list but not old
- Unhearted since last sync: products in old list but not new

Then write the new enriched objects.

### Schema (same as onboard Step 6)

```json
{
  "synced_at": "ISO-8601",
  "products": [
    { "id": 500874, "name": "Mongolian Beef Bento", "brand": "Xiangchuan Kitchen", "category": "Chinese" }
  ],
  "unresolvedProductIds": [202759],
  "brands": []
}
```

### Verification

```bash
python3 -c "import json; d=json.load(open('$HOME/Documents/WeBox/favorites.json')); print('favorites:', len(d['products']), 'products,', len(d['unresolvedProductIds']), 'unresolved')"
```

Must match the counts from 2a. If short, a chunk got dropped — re-run from the missing offset.

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
      if (r.order?.status !== 'Paid') continue;
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

**Then paginate `window.__weboxOrders` back in chunks of 3** to build the per-week files:
```javascript
(async () => {
  const offset = /* agent: 0, 50, 100, ... */;
  const chunk = (window.__weboxOrders || []).slice(offset, offset + 3);
  return JSON.stringify({ offset, count: chunk.length, orders: chunk });
})()
```
Loop until `count === 0`. Each chunk ~10KB — well within tool limits.

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

Identify the next 1–2 orderable Lunch slots (and corresponding Dinners if within the 7-day window). For each, fetch the menu via API. Loop:

```javascript
(async (date, meal) => {
  const addrId = /* from address-info.json */;
  const r = await fetch(`/api/productSpecials/v8/address/${addrId}/date/${date}`, { credentials: 'include' });
  const j = await r.json();
  if (j.code !== 1) return JSON.stringify({ error: 'menu fetch failed', date, meal, code: j.code });
  const specialsKey = meal.toLowerCase() + 'Specials';  // lunchSpecials | dinnerSpecials | happyHourSpecials
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
        price: s.price,
        category: p.category,
        rating: p.averageRating || null,
        in_favorites: favIds.has(p.id),
        dietary: {
          glutenFree: !!p.glutenFree, dairyFree: !!p.dairyFree, halal: !!p.halalCertified,
          nutFree: !!p.nutFree, vegan: p.veggieLevel === 'Vegan', vegetarian: p.veggieLevel === 'Vegetarian'
        },
        stockQuantity: s.stockQuantity,                   // 0 = unlimited; >0 = finite remaining
        productId: p.id, productSpecialId: s.id,
        portionId: portion?.id || null,                  // from product.extPortions (isDefault preferred)
        portionCount: (p.extPortions || []).length       // >1 means user-facing portion choice exists
      };
    })
    .filter(Boolean);
  return JSON.stringify({ date, meal, kitchenId, items });
})('2026-05-22', 'Lunch')
```

Write each to `~/Documents/WeBox/menu-cache/<DATE>-<MEAL>.json`:
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
