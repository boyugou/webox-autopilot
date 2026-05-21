---
name: webox-sync
description: One-stop API sync — refresh order history, favorites, hidden list, and warm-cache upcoming menus. Then display this week and next week's slot calendar. Use when the user says "sync my WeBox", "show my calendar", "refresh favorites", "what's been ordered", "pull latest".
---

# WeBox Sync Skill

Refreshes all read-only state via API and shows the calendar.

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

## Step 2: Refresh Favorites + Hidden Lists (with enrichment)

Refreshing requires the current menu's `products` array to resolve IDs → human-readable names. The warm-cache step (Step 4) fetches the menu anyway, so do these together. Order: menu fetch first, then enrich + diff.

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
  const favEn = enrichP(favR.data?.productIdList);
  const hideEn = enrichP(hideR.data?.productIdList);
  return JSON.stringify({
    favorites: { synced_at: now, products: favEn.products, unresolvedProductIds: favEn.unresolved, brands: enrichB(favR.data?.brandIdList) },
    hidden:    { synced_at: now, products: hideEn.products, unresolvedProductIds: hideEn.unresolved, brands: enrichB(hideR.data?.brandIdList) },
    menuRaw: menuR.data  // pass through so Step 4 can use the same fetch for warm-cache
  });
})('<addrId>', '<tomorrow>')
```

**Diff before overwriting.** Read the existing `favorites.json` / `hidden.json` (compute the set of `products[].id` to compare). Compute symmetric diff against the new ID lists, surface changes in the Step 6 summary:
- New favorites: products in the new list but not the old → these are recent hearts
- Removed favorites: products in the old list but not the new → user un-hearted

Then write the new enriched objects to `favorites.json` and `hidden.json`.

**Schema (same as onboard Step 6):**
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

---

## Step 3: Refresh Order History (paginated API)

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
  // Filter to status === "Paid" (active), flatten by package
  const active = [];
  for (const r of all) {
    if (r.order?.status !== 'Paid') continue;
    for (const pkg of (r.orderPackages || [])) {
      const items = (pkg.extItems || []).map(it => ({
        productId: it.productId,
        productSpecialId: it.productSpecialId,
        quantity: it.quantity,
        price: (it.pricePerUnitCents ?? it.priceCents ?? 0) / 100
      }));
      active.push({
        orderId: 'No.' + r.order.id,
        dateShippingMs: pkg.dateShipping,
        timeShipping: pkg.timeShipping,
        total: r.order.totalCharge || 0,
        items
      });
    }
  }
  return JSON.stringify({ totalFetched: all.length, activeCount: active.length, orders: active });
})()
```

**Default loop bound:** stop early once you've fetched `history_window_days × 1.5` worth (≈ 30 weeks ≈ 60 pages ≈ 6 seconds). If the user says "pull all my history", remove that bound and fetch all `totalCount` orders.

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
  let kitchenId = null, shippingTimeSectionId = null;
  const items = specials
    .filter(s => s.stockStatus !== 'outofstock')
    .map(s => {
      const p = productById.get(s.productId);
      if (!p || hideIds.has(p.id)) return null;
      kitchenId = kitchenId || s.kitchenId;
      shippingTimeSectionId = shippingTimeSectionId || s.shippingTimeSectionId;
      return {
        productSpecialId: s.id, productId: p.id, portionId: s.portionId, cutoffTime: s.cutoffTime,
        name: p.extName?.enUs,
        brand: brandById.get(p.brandId)?.extName?.enUs,
        price: s.price,
        rating: p.averageRating || null,
        category: p.category,
        in_favorites: favIds.has(p.id),
        dietary: {
          glutenFree: !!p.glutenFree, dairyFree: !!p.dairyFree, halal: !!p.halalCertified,
          nutFree: !!p.nutFree, vegan: p.veggieLevel === 'Vegan', vegetarian: p.veggieLevel === 'Vegetarian'
        }
      };
    })
    .filter(Boolean);
  return JSON.stringify({ date, meal, kitchenId, shippingTimeSectionId, items });
})('2026-05-22', 'Lunch')
```

Write each to `~/Documents/WeBox/menu-cache/<DATE>-<MEAL>.json`:
```json
{
  "cached_at": "ISO-8601",
  "date": "2026-05-22",
  "meal": "Lunch",
  "kitchenId": 12838,
  "shippingTimeSectionId": 27274,
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
