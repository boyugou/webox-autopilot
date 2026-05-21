---
name: webox-onboard
description: First-time setup for webox-autopilot. Verifies Chrome + WeBox login, asks one natural-language question to capture food preferences, then fetches user profile + addresses + favorites + hidden + order history via API and creates all local data files. Run this once before using webox-order. Also handles skill updates from GitHub.
---

# WeBox Onboard Skill

First-time setup. Populates `~/Documents/WeBox/` with everything subsequent skills need.

**API-first.** All data fetched via WeBox's JSON API (verified, documented in `~/.claude/skills/webox/SITEMAP.md`). No DOM scraping.

## What gets created

- `preferences.md` — your settings (from your onboarding answer)
- `user-profile.json` — `{firstName, lastName, phone, email, timezone, id}` (required for Place Order)
- `address-info.json` — `{addressId, kitchenId, timezone, address1, city}` (required for Place Order)
- `favorites.json` — `{productIdList, brandIdList, synced_at}` (hearted items)
- `hidden.json` — `{productIdList, brandIdList, synced_at}` (Not-Interested items)
- `orders/YYYY-Www.json` — per-ISO-week order history (active orders only)
- `menu-cache/<TOMORROW>-Lunch.json` — warm cache for the first order
- `item-reviews.md` — empty stub

---

## Step 1: Open a Fresh Tab + Verify Login

### 1a. Get a clean tab
```
tabs_context_mcp({ createIfEmpty: true })
```
If an MCP tab group already exists, call `tabs_create_mcp()` to get a brand-new tab anyway. Capture the `tabId` and pass it to every subsequent call explicitly — don't rely on "current tab".

### 1b. Navigate to webox.com and probe login
```
navigate(<tabId>, "https://www.webox.com")
```
Wait ~2s for the page to load, then verify login via JS:
```javascript
({ loggedIn: !!document.querySelector('[class*="user-avatar"], [class*="user-name"], [class*="header-avatar"], a.cart.fr') })
```
If `loggedIn: false`:
> You're not logged into WeBox. Please log in at webox.com in Chrome and try again.

### 1c. Data directories
```bash
mkdir -p ~/Documents/WeBox/orders ~/Documents/WeBox/menu-cache
```

**Permission note:** Claude in Chrome may prompt for permission to navigate to webox.com on the first navigation per origin. This is normal — accept once.

---

## Step 2: Detect First-Run vs Returning User

Already onboarded if **both** files exist:
- `~/Documents/WeBox/preferences.md`
- `~/Documents/WeBox/user-profile.json`

**If already onboarded:**
> You're already set up. What would you like to do?
> 1. **Update preferences** — I'll ask what's changed
> 2. **Re-sync everything** — hands off to `/webox-sync`
> 3. **Update the skill** — pull the latest from GitHub
> 4. **Nothing** — just checking

For option 3, jump to "Step 8: Update Skill".

**If not yet onboarded:** continue to Step 3.

---

## Step 3: Ask the Preferences Question

Say:
> Before your first order, tell me about your food preferences — anything goes: budget, diet, allergens, cuisines you love or avoid, whether you want me to confirm before ordering, drink preferences, etc. Answer however feels natural — one sentence or a full paragraph, in any language.

**Wait for the user's reply** before any further work. No background scraping while they type — surprised tabs are bad UX.

---

## Step 4: Fetch Identity + Favorites + Hidden in One Call

After the user replies, run this single JS call on the existing tab to grab everything we need for both Place Order later and the warm-cache filter below:

```javascript
(async () => {
  const [profile, addresses, fav, hide] = await Promise.all([
    fetch('/api/users/my', { credentials: 'include' }).then(r => r.json()),
    fetch('/api/v2/userAddresses/my', { credentials: 'include' }).then(r => r.json()),
    fetch('/api/fav/my', { credentials: 'include' }).then(r => r.json()),
    fetch('/api/hide/my', { credentials: 'include' }).then(r => r.json())
  ]);
  const addrs = Array.isArray(addresses.data) ? addresses.data : (addresses.data?.list || []);
  const defaultAddr = addrs.find(a => a.isDefault) || addrs[0] || null;
  return JSON.stringify({
    profile: profile.data ? {
      id: profile.data.id,
      firstName: profile.data.firstName,
      lastName: profile.data.lastName,
      phone: profile.data.phone,
      email: profile.data.email,
      timezone: profile.data.timezone || defaultAddr?.timezone || 'America/Los_Angeles'
    } : null,
    address: defaultAddr ? {
      addressId: defaultAddr.id,
      kitchenId: defaultAddr.kitchenId,
      timezone: defaultAddr.timezone,
      address1: defaultAddr.address1,
      city: defaultAddr.city
    } : null,
    favorites: { productIdList: fav.data?.productIdList || [], brandIdList: fav.data?.brandIdList || [], synced_at: new Date().toISOString() },
    hidden: { productIdList: hide.data?.productIdList || [], brandIdList: hide.data?.brandIdList || [], synced_at: new Date().toISOString() }
  });
})()
```

Write each field to its own JSON file in `~/Documents/WeBox/`:
- `user-profile.json` ← `profile`
- `address-info.json` ← `address`
- `favorites.json` ← `favorites`
- `hidden.json` ← `hidden`

If `address` is null (no registered delivery address), stop:
> You don't have a delivery address set on WeBox yet. Please add one at webox.com first, then run `/webox-onboard` again.

---

## Step 5: Fetch Order History via Paginated API

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
  // Filter to active only + flatten the per-package structure
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
        total: (r.order.totalCharge || 0),
        items
      });
    }
  }
  return JSON.stringify({ totalFetched: all.length, activeCount: active.length, orders: active });
})()
```

Convert each entry to a per-week JSON file. ISO-week computation:

```javascript
// Pseudocode for the agent: convert dateShippingMs → YYYY-MM-DD → "YYYY-Www" → week file
```

For each active order, group by `isoWeek(dateShipping)` and write to `~/Documents/WeBox/orders/YYYY-Www.json`:

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

**Resolving product names**: the orders API returns `productId` but not the human-readable name. Two options:
- (Recommended) Fetch the menu API once for **tomorrow's date** (Step 6 anyway) and use its `products` array as a lookup for orders that contain those products. For older orders with productIds no longer in the current menu, omit the name (use `"<unknown>"` placeholder) — the `productId` alone is enough for variety tracking.
- Or call `POST /api/products` with the list of unique productIds for full name resolution.

**Edge case:** if `activeCount === 0` (brand-new user), create `~/Documents/WeBox/orders/.empty` as a marker so Step 2 detection succeeds next time.

---

## Step 6: Fetch Tomorrow's Menu as Warm Cache

```javascript
(async () => {
  // Tomorrow's date in YYYY-MM-DD
  const tmr = new Date(Date.now() + 86400000).toISOString().slice(0, 10);
  const addrId = /* from address-info.json */;
  const favIds = new Set(/* from favorites.json productIdList */);
  const hideIds = new Set(/* from hidden.json productIdList */);
  const r = await fetch(`/api/productSpecials/v8/address/${addrId}/date/${tmr}`, { credentials: 'include' });
  const j = await r.json();
  if (j.code !== 1) return JSON.stringify({ error: 'menu fetch failed', code: j.code, msg: j.msg });
  const { lunchSpecials, products, productBrands } = j.data;
  const productById = new Map(products.map(p => [p.id, p]));
  const brandById = new Map(productBrands.map(b => [b.id, b]));
  let kitchenId = null, shippingTimeSectionId = null;
  const items = lunchSpecials
    .filter(s => s.stockStatus !== 'outofstock')
    .map(s => {
      const p = productById.get(s.productId);
      if (!p || hideIds.has(p.id)) return null;
      kitchenId = kitchenId || s.kitchenId;
      shippingTimeSectionId = shippingTimeSectionId || s.shippingTimeSectionId;
      return {
        productSpecialId: s.id,
        productId: p.id,
        portionId: s.portionId,
        cutoffTime: s.cutoffTime,
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
  return JSON.stringify({ count: items.length, kitchenId, shippingTimeSectionId, items });
})()
```

Write to `~/Documents/WeBox/menu-cache/<TOMORROW>-Lunch.json`:
```json
{
  "cached_at": "ISO-8601",
  "date": "<TOMORROW>",
  "meal": "Lunch",
  "kitchenId": 12838,
  "shippingTimeSectionId": 27274,
  "items": [ ... ]
}
```

---

## Step 7: Write Preferences + Reviews Stub, Print Summary

### 7a. Parse and write preferences

The canonical template is `preferences.md` in the webox-autopilot repo root. Read it and write the exact same content to `~/Documents/WeBox/preferences.md`, **only changing values the user explicitly mentioned in their onboarding reply**.

#### CRITICAL: defaults are sacred

For any field the user did not mention, **keep the template default exactly as-is**. Don't infer or "improve":
- Don't downgrade the default budget because the user "sounds frugal"
- Don't switch `confirm_before_order` to true because the user seems cautious
- Don't add `vegetarian` because the user mentioned liking salad
- Don't shorten `history_window_days`

Only change a field if the user clearly named it or a synonym ("budget"/"spend"/"上限" → `budget`; "vegetarian"/"vegan"/"no meat" → `restrictions`; etc.).

Free-text observations that don't map to a structured field go into the `## Notes` section at the bottom (preserve the template's helper comment above it).

### 7b. Create empty item-reviews.md (if missing)

```markdown
# Item Reviews

<!-- Add reviews here, or just tell Claude Code about a dish and it will record them for you. -->
<!-- Examples: -->
<!--   "The Mongolian Beef bento from Xiangchuan Kitchen is amazing, 5/5" -->
<!--   "这个超级咸，别再点了" -->
```

### 7c. Summary

Echo only what CHANGED from defaults — and confirm the per-file counts:

```
✅ WeBox setup complete.

Changed from defaults:
  - budget: 25.00 (was 30.00)
  - restrictions: [vegetarian]
Everything else kept default.

Files in ~/Documents/WeBox/:
  preferences.md           — your settings (edit in Finder anytime)
  user-profile.json        — Boyu Gou, boyu.gou@..., 6145568304
  address-info.json        — 1881 Page Mill Rd (kitchen 12838)
  favorites.json           — 131 hearted products
  hidden.json              — 180 "Not Interested" products
  orders/                  — 407 past active orders across N weeks
  menu-cache/<TOMORROW>.json — X items for tomorrow's Lunch
  item-reviews.md          — empty (grows as you order)

You're ready to order. Try:
  "Order my lunch for tomorrow"        (curated full menu via webox-order)
  "Order from my favorites tomorrow"   (narrow scope via webox-favorite)
  "Show my WeBox calendar"             (via webox-sync)
```

If the user said nothing specific:
```
✅ WeBox setup complete using all default preferences.
```

---

## Step 8: Update Skill (if user picked Option 3 in Step 2)

```bash
git clone https://github.com/boyugou/webox-autopilot.git /tmp/webox-autopilot-update
cd /tmp/webox-autopilot-update && git log --oneline -1
bash /tmp/webox-autopilot-update/install.sh
rm -rf /tmp/webox-autopilot-update
```

After update:
- Report which commit was just installed.
- Note: the current Claude Code session is still running the old skill files in memory. **Restart Claude Code** for the new version to take effect.
- `~/Documents/WeBox/` files (preferences, profile, history, reviews) are never touched by updates.
