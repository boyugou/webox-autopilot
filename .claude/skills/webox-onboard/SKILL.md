---
name: webox-onboard
description: First-time setup for webox-autopilot. Verifies Chrome + WeBox login, asks one natural-language question to capture food preferences, then fetches user profile + addresses + favorites + hidden + order history via API and creates all local data files. Run this once before using webox-order. Also handles skill updates from GitHub.
---

# WeBox Onboard Skill

First-time setup. Populates `~/Documents/WeBox/` with everything subsequent skills need.

**API-first.** All data fetched via WeBox's JSON API (verified, documented in `~/.claude/skills/webox/SITEMAP.md`). No DOM scraping.

## What gets created

- `config.yaml` — schema-locked structured settings (budget, restrictions, cuisines, etc.). Edit values, never add fields.
- `preferences.md` — free-form notes: anything that doesn't fit a structured field
- `user-profile.json` — `{firstName, lastName, phone, email, timezone, id}` (required for Place Order)
- `address-info.json` — `{addressId, userAddressId, kitchenId, timezone, address1, city, ...}` (required for Place Order)
- `shipping-windows.json` — per-meal `{shippingTimeSectionId, extFormCutoff, ...}` derived from past orders (required for Place Order body)
- `favorites.json` — enriched `{products: [{id, name, brand, category}], unresolvedProductIds, brands, synced_at}`
- `hidden.json` — same shape ("Not Interested" items)
- `orders/YYYY-Www.json` — per-ISO-week order history (active orders only)
- `item-reviews.md` — empty stub (`menu-cache/` is populated lazily on first order, not at onboard)

### Different users / addresses

Each WeBox user has their own delivery address (or multiple). The skill is per-user-correct because every value is derived dynamically from the WeBox API — nothing is hardcoded:

- `addressId` (e.g., 240212) is the **physical address record** shared by anyone delivering there. Used by all menu/order/tax APIs.
- `userAddressId` (e.g., 459170) is **your account's link** to that address. Per-user.
- `kitchenId` is **per-address** — different addresses may be served by different WeBox kitchens, each with their own menu and (potentially) their own `shippingTimeSectionId` per meal.
- `shipping-windows.json` is derived from the user's own order history, so it inherently reflects their kitchen's schedule.

When this skill runs for a different user, all values come from their `/api/v2/userAddresses/my` and `/api/orders/list`. The skill makes zero assumptions about specific IDs.

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

Already onboarded if all of these exist:
- `~/Documents/WeBox/config.yaml`
- `~/Documents/WeBox/user-profile.json`
- `~/Documents/WeBox/address-info.json`

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

## Step 4: Fetch Identity + Address Only

After the user replies, fetch identity. The favorites/hidden enrichment happens in Step 6 (after the menu is fetched, so we can resolve IDs → names).

```javascript
(async () => {
  const [profile, addresses] = await Promise.all([
    fetch('/api/users/my', { credentials: 'include' }).then(r => r.json()),
    fetch('/api/v2/userAddresses/my', { credentials: 'include' }).then(r => r.json())
  ]);
  const addrs = Array.isArray(addresses.data) ? addresses.data : (addresses.data?.list || []);
  const defaultAddr = addrs.find(a => a.isDefault) || addrs[0] || null;
  const ext = defaultAddr?.extAddress || {};
  return JSON.stringify({
    profile: profile.data ? {
      id: profile.data.id,
      firstName: profile.data.firstName,
      lastName: profile.data.lastName,
      phone: profile.data.phone,
      email: profile.data.email,
      timezone: profile.data.timezone || ext.timezone || 'America/Los_Angeles'
    } : null,
    address: defaultAddr ? {
      addressId:      defaultAddr.addressId,   // canonical — used by /api/productSpecials/.../address/<X>/..., POST /api/orders, etc.
      userAddressId:  defaultAddr.id,          // your account's link to the address — used only by address-book mutations
      kitchenId:      ext.kitchenId,
      timezone:       ext.timezone,
      address1:       ext.address1,
      address2:       ext.address2,
      city:           ext.city,
      state:          ext.state,
      postcode:       ext.postcode
    } : null
  });
})()
```

**The two address IDs explained:**

| Field | Example | What it identifies |
|---|---|---|
| `addressId` | 240212 | **The canonical address record.** This is what every WeBox API uses: `/api/productSpecials/v8/address/<addressId>/...`, the menu API, the Place Order body's `order.addressId`, tax-rate, kitchen lookup, etc. |
| `userAddressId` | 459170 | The user-address association — the pointer in your account's address book. Useful only for address-book operations (set default, delete an address). NOT used in ordering. |
| `kitchenId` | 12838 | Which WeBox kitchen serves that address. From `extAddress.kitchenId`. Needed in the Place Order body. |
| `timezone` | "America/Los_Angeles" | The address's local timezone. From `extAddress.timezone`. Needed in the Place Order body. |

Write each field to its own JSON file in `~/Documents/WeBox/`:
- `user-profile.json` ← `profile`
- `address-info.json` ← `address` (now includes both `addressId` and `userAddressId` for completeness)

If `address` is null (no registered delivery address), stop:
> You don't have a delivery address set on WeBox yet. Please add one at webox.com first, then run `/webox-onboard` again.

---

## Step 5: Fetch Order History via Paginated API + Derive Shipping Windows

The full order history for a long-time user can be 400+ orders × multiple items each. Doing the entire fetch + return-all in one JS call could exceed the tool's practical payload size. Instead: run a single JS call that **accumulates into `window.__weboxOrders` and returns ONLY a summary + the small shipping-windows + the most recent few orders** for the agent to verify. The full data stays on the page object.

```javascript
(async () => {
  const params = 'client=web&status=Paid%2CPartialRefunded%2CPlanned%2CUnpaid%2CRefunded%2CCancelled%2COnHold&pageSize=10&type=Individual&orderBy=id&desc=true&referenceTypes=GROUP_ORDER_META';
  const active = [];
  const shippingWindows = {};
  let pageIndex = 1, totalCount = 0;
  while (pageIndex <= 100) {
    const r = await fetch(`/api/orders/list?${params}&pageIndex=${pageIndex}`, { credentials: 'include' });
    const j = await r.json();
    if (j.code !== 1 || !j.data?.result?.length) break;
    totalCount = j.data.totalCount;
    for (const o of j.data.result) {
      for (const pkg of (o.orderPackages || [])) {
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
        if (o.order?.status !== 'Paid') continue;
        active.push({
          orderId: 'No.' + o.order.id,
          dateShippingMs: pkg.dateShipping,
          timeShipping: ts,
          total: o.order.totalCharge || 0,
          items: (pkg.extItems || []).map(it => ({
            productId: it.productId,
            productSpecialId: it.productSpecialId,
            portionId: it.portionId,
            quantity: it.quantity,
            price: (it.pricePerUnitCents ?? it.priceCents ?? 0) / 100
          }))
        });
      }
    }
    if (j.data.result.length < 10) break;
    pageIndex++;
  }
  // Stash the FULL active list on the page so a follow-up call can paginate it back.
  window.__weboxOrders = active;
  // Return only a small summary + shipping-windows. The full list is fetched in chunks next.
  return JSON.stringify({
    totalCount,
    activeCount: active.length,
    pagesFetched: pageIndex,
    shippingWindows,
    // Just the latest 20 active orders inline — enough to seed orders/YYYY-Www.json for the current week.
    recentOrders: active.slice(0, 20)
  });
})()
```

**Then write `shipping-windows.json` immediately** (it's small — just two-three meal entries).

**Then paginate `window.__weboxOrders` back in chunks of 3** to build the per-week files. Run this JS as many times as needed:

```javascript
// Return chunk by offset; agent loops offset += 3 until empty
(async () => {
  const offset = /* agent passes 0, 50, 100, ... */;
  const chunk = (window.__weboxOrders || []).slice(offset, offset + 3);
  return JSON.stringify({ offset, count: chunk.length, orders: chunk });
})()
```

For a user with 400 active orders that's ~135 small (~800-byte each) round trips, each easily within tool limits. Process each chunk into per-week JSON before the next call.

**Write `~/Documents/WeBox/shipping-windows.json`** with the `shippingWindows` field:
```json
{
  "synced_at": "2026-05-21T14:30:00Z",
  "windows": {
    "Lunch": {
      "shippingTimeSectionId": 27274,
      "extFormCutoff": "08:00",
      "extFormShippingBegin": "11:00",
      "extFormShippingEnd": "12:30",
      "cutoff_local_ms": 28800000,
      "shippingBegin_local_ms": 39600000,
      "shippingEnd_local_ms": 45000000
    },
    "Dinner": {
      "shippingTimeSectionId": 27275,
      "extFormCutoff": "14:30",
      "extFormShippingBegin": "17:00",
      "extFormShippingEnd": "18:30",
      "cutoff_local_ms": 52200000,
      "shippingBegin_local_ms": 61200000,
      "shippingEnd_local_ms": 66600000
    }
  }
}
```

**Brand-new users (zero past orders):** `shipping-windows.json` will be empty. The first time the user places an order, `webox-order` will detect the missing entry, fall back to the DOM-driven path for ONE order to capture the shippingTimeSection, then save it. After that first order, future orders use the API path. (Most users have order history, so this fallback rarely triggers.)

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

## Step 6: Fetch Menu + Enrich Favorites/Hidden + Build Warm Cache

This step enriches favorites + hidden ID lists into human-readable `{id, name, brand, category}` objects using the menu API's `products` array as a lookup. **Run the three JS snippets below in order — they are designed to keep each tool-result under the safe display limit.**

> **About `javascript_tool` return values:**
> Tool-result truncation is REAL — at ~1000 characters / ~50 lines, your displayed AND model-context content is cut. Anything after `[TRUNCATED]` is lost (empirically verified — a 7438-byte single-string return arrives with only ~870 chars and the end marker missing). The chunked pattern below is mandatory for any payload that might exceed this limit.
>
> **Never write data to `~/Downloads`** or use blob/URL-download tricks. They don't work.

### Step 6a — Fetch + enrich + stash, return summary only

```javascript
(async () => {
  const tmr = new Date(Date.now() + 86400000).toISOString().slice(0, 10);
  const addrId = /* paste integer from address-info.json's addressId */;
  const [menuR, favR, hideR] = await Promise.all([
    fetch(`/api/productSpecials/v8/address/${addrId}/date/${tmr}`, { credentials: 'include' }).then(r => r.json()),
    fetch('/api/fav/my', { credentials: 'include' }).then(r => r.json()),
    fetch('/api/hide/my', { credentials: 'include' }).then(r => r.json())
  ]);
  if (menuR.code !== 1) return JSON.stringify({ error: 'menu fetch failed', code: menuR.code, msg: menuR.msg });
  const { products, productBrands } = menuR.data;
  const productById = new Map(products.map(p => [p.id, p]));
  const brandById   = new Map(productBrands.map(b => [b.id, b]));
  const enrichProducts = (idList) => {
    const out = [], unresolved = [];
    for (const id of idList || []) {
      const p = productById.get(id);
      if (!p) { unresolved.push(id); continue; }
      out.push({ id, name: p.extName?.enUs, brand: brandById.get(p.brandId)?.extName?.enUs, category: p.category });
    }
    return { products: out, unresolved };
  };
  const enrichBrands = (idList) => (idList || []).map(id => {
    const b = brandById.get(id);
    return b ? { id, name: b.extName?.enUs } : { id, name: null };
  });
  const favE  = enrichProducts(favR.data?.productIdList);
  const hideE = enrichProducts(hideR.data?.productIdList);
  const now = new Date().toISOString();
  // Stash the FULL enriched objects on window for chunked retrieval below.
  window.__favPayload  = { synced_at: now, products: favE.products,  unresolvedProductIds: favE.unresolved,  brands: enrichBrands(favR.data?.brandIdList) };
  window.__hidePayload = { synced_at: now, products: hideE.products, unresolvedProductIds: hideE.unresolved, brands: enrichBrands(hideR.data?.brandIdList) };
  window.__weboxMenuRaw = menuR.data;  // For any optional follow-up
  return JSON.stringify({
    favCount: favE.products.length,
    favUnresolved: favE.unresolved.length,
    favBrandCount: (favR.data?.brandIdList || []).length,
    hideCount: hideE.products.length,
    hideUnresolved: hideE.unresolved.length,
    hideBrandCount: (hideR.data?.brandIdList || []).length,
    synced_at: now
  });
})()
```

This returns a small summary (~200 bytes). Record `favCount`, `hideCount`, and `synced_at` from the response — you'll use them in Step 6c.

### Step 6b — Pull favorites in chunks of 5 (deterministic, single-line JSON)

> **The tool-result truncation is REAL, not cosmetic.** It is enforced by Claude Code at roughly 50–60 lines of pretty-printed output OR ~1000 characters. Both your visual display AND your model-context will be truncated at this point. You CANNOT trust that data after `[TRUNCATED]` reached you. So chunk-fetch is mandatory for any payload that might exceed this.
>
> **DO NOT try larger chunks. DO NOT use pretty-printing. DO NOT switch to compact array formats mid-loop.** Follow the EXACT script below.

Loop the EXACT snippet below with `offset = 0, 5, 10, 15, ...` until the returned `done` flag is `true`. The return is FLAT (no pretty-print), 5 items per chunk, capped well under the 1000-char truncation limit:

```javascript
(async (offset) => {
  const products = window.__favPayload?.products || [];
  const chunk = products.slice(offset, offset + 5);
  // FLAT JSON — no whitespace, no newlines, no nesting indent. Avoids line-count truncation.
  return JSON.stringify({
    offset,
    total: products.length,
    chunkCount: chunk.length,
    done: offset + chunk.length >= products.length,
    products: chunk
  });
})(/* paste offset integer, e.g., 0 */)
```

Each chunk is ~600–800 chars on a single line — within the truncation limit regardless of how the terminal renders it.

For a ~100-item favorites list that's ~20 round trips. Accumulate the `products` arrays from each chunk into your own state until `done: true`.

**Sanity check on every chunk:** verify `chunkCount === 5` (or `< 5` only when `done: true`). If a chunk returns fewer items unexpectedly, something is wrong — re-fetch that offset.

### Step 6b-tail — One call for brands + unresolvedProductIds

After all chunks are done, one final call:
```javascript
JSON.stringify({
  synced_at: window.__favPayload.synced_at,
  brands: window.__favPayload.brands,
  unresolvedProductIds: window.__favPayload.unresolvedProductIds,
  unresolvedCount: window.__favPayload.unresolvedProductIds.length,
  brandCount: window.__favPayload.brands.length
})
```

This is small (~brands and unresolved IDs only) — usually fits in one call. If `unresolvedCount > 100`, chunk this too (replace the inline arrays with `slice(offset, offset+30)`).

### Step 6b-write — Write the assembled file

Build the final object in your own state:
```json
{
  "synced_at": "<from the tail call above>",
  "products": [ <concatenation of all chunked products arrays> ],
  "unresolvedProductIds": [ <from tail call> ],
  "brands": [ <from tail call> ]
}
```

Use the **Write tool** to save it to `~/Documents/WeBox/favorites.json`.

### Step 6c — Same chunked pattern for hidden.json

Identical structure, substitute `__favPayload` → `__hidePayload`:

```javascript
(async (offset) => {
  const products = window.__hidePayload?.products || [];
  const chunk = products.slice(offset, offset + 5);
  return JSON.stringify({ offset, total: products.length, chunkCount: chunk.length, done: offset + chunk.length >= products.length, products: chunk });
})(/* paste offset, e.g., 0 */)
```

Tail call for brands/unresolved (substitute `__favPayload` → `__hidePayload`). Assemble and write `~/Documents/WeBox/hidden.json`.

### Why this is necessary (don't be tempted to skip)

Empirically verified 2026-05-21: a `javascript_tool` returning a 7438-byte single-string payload arrives in the model context truncated at ~870 characters, with the rest lost (verified by missing end-marker). The agent gets ONLY the visible portion — not "the full data with a cosmetic display abbreviation". Earlier guidance in this skill that suggested otherwise was incorrect; it has been removed.

Smaller chunks = no truncation. The fixed 5-items-per-chunk + flat JSON keeps every chunk within limits regardless of product name length.

### Verification

After writing, sanity-check the files:
```bash
python3 -c "import json; d = json.load(open('$HOME/Documents/WeBox/favorites.json')); print('favorites:', len(d['products']), 'products,', len(d['unresolvedProductIds']), 'unresolved')"
python3 -c "import json; d = json.load(open('$HOME/Documents/WeBox/hidden.json'));    print('hidden:',    len(d['products']), 'products,', len(d['unresolvedProductIds']), 'unresolved')"
```

The counts must match what Step 6a reported. If they don't, something was lost mid-chunk — re-run Step 6b/6c from where the count diverged.

### Schemas

**`~/Documents/WeBox/favorites.json`**:
```json
{
  "synced_at": "2026-05-21T14:30:00Z",
  "products": [
    { "id": 500874, "name": "Mongolian Beef Bento", "brand": "Xiangchuan Kitchen", "category": "Chinese" },
    { "id": 496445, "name": "Tea Egg", "brand": "Lee&Bai Chinese Bao Shop", "category": "Chinese" }
  ],
  "unresolvedProductIds": [202759, 183709],
  "brands": []
}
```

**`~/Documents/WeBox/hidden.json`** — same shape.

**Skip the warm menu-cache.** The first `/webox-order` call fetches the menu on demand (~1 second). Not worth shipping a ~400KB payload at onboard.

### Why this is human-readable

Open `favorites.json` in Finder and see "Mongolian Beef Bento — Xiangchuan Kitchen", not "500874". The bare ID Set used by selection logic is derivable in JS:
```js
const favIds = new Set(favorites.products.map(p => p.id).concat(favorites.unresolvedProductIds));
```

### About `unresolvedProductIds`

Items the user hearted (or hid) in the past but that no longer appear in the current menu — brand rotated out, item discontinued, etc. We keep their IDs so the data isn't lost; if you need their names later, `POST /api/products` with the ID list resolves them.

---

## Step 7: Write Preferences + Reviews Stub, Print Summary

### 7a. Write two files: `config.yaml` (schema-locked) + `preferences.md` (free-form)

WeBox settings live in TWO files. This separation is deliberate:

- **`~/Documents/WeBox/config.yaml`** — structured fields with a fixed schema. Downstream skills (`webox-order` etc.) only read these specific keys. **You may NOT invent new keys here.** Edit values; never rename or add fields.
- **`~/Documents/WeBox/preferences.md`** — free-form markdown. Anything goes — meal composition rules, "5/10 Chinese", "prefer purple rice", incident notes. Downstream skills read this as a soft hint and apply it on a best-effort basis.

This gives you safety (config can't drift off-schema) and freedom (notes can capture anything).

#### Procedure

1. Read the canonical templates:
   - `~/.claude/skills/webox-onboard/config.yaml` → the locked schema
   - `~/.claude/skills/webox-onboard/preferences.md` → the free-form starter

2. Write `~/Documents/WeBox/config.yaml` as a **verbatim copy** of the template, then modify ONLY the values of existing keys per the user's onboarding reply. No new keys. No renames.

3. Write `~/Documents/WeBox/preferences.md` starting from the template, then add the user's free-text intent as bullets. Anything that doesn't map cleanly to a structured `config.yaml` field belongs here.

#### CRITICAL: config.yaml schema is fixed

**Bad agent behavior we have seen and must not repeat:** earlier runs produced a preferences file with fabricated keys like `target_per_meal`, `soft_cap`, `strictly_avoid`, `prefer_instead`, `chinese_target_per_week`, `per_meal_structure`. **None of these exist in the schema.** They break every downstream skill that reads the canonical keys.

The complete set of allowed top-level keys in `config.yaml` (from the template — no others):
`budget`, `budget_mode`, `validate_budget`, `confirm_before_order`, `default_meals`, `skip_weekends`, `avoid_repeat_days`, `history_window_days`, `allow_repeat_categories`, `restrictions`, `avoid_allergens`, `preferred_cuisines`, `cuisines_to_avoid`, `foods_i_like`, `foods_to_avoid`, `order_drinks`, `avoid_sugary_drinks`, `preferred_drinks`.

#### Defaults are sacred

For any field the user did not mention, keep the template default exactly as-is. Don't infer or "improve":
- Don't downgrade `budget` because the user "sounds frugal"
- Don't switch `confirm_before_order: true` because they seem cautious
- Don't add `vegetarian` because they mentioned liking salad
- Don't shorten `history_window_days`

Only change a value if the user clearly named it or a synonym.

#### Field-mapping cheat sheet (intent → config.yaml field OR preferences.md note)

| User says (any language) | Where to encode |
|---|---|
| budget / spend / 上限 / 预算 | `config.yaml`: `budget` (numeric). Cap is always hard — planner never exceeds. |
| "use the full budget" / 尽可能用到满 / "fill up to budget" | `config.yaml`: `budget_mode: spend-up-to` (already default; this is what means "fill the budget"). The alternative `ceiling-only` means best picks without filling. |
| sugary drinks / sodas / 含糖饮料 / 汽水 / 奶茶 / boba | `config.yaml`: `avoid_sugary_drinks: true` + add patterns ("soda", "boba", "milk tea") to `foods_to_avoid`. |
| yogurt no | `config.yaml`: add `yogurt` to `foods_to_avoid`. |
| raw fish / sashimi / 生鱼 / 生食 | `config.yaml`: add `sashimi`, `raw fish`, `ceviche`, `tartare`, `salmon raw`, `tuna raw` to `foods_to_avoid`. |
| 健康 / healthy / lean / 少油 | `config.yaml`: add `fried`, `deep-fried`, `heavily oily` to `foods_to_avoid`. |
| 中餐 / Chinese | `config.yaml`: `preferred_cuisines: [Chinese, ...]`. |
| "at least N Chinese meals per week" | `preferences.md`: free-text bullet — no structured field for ratios. |
| fresh fruit / milk preferred for filling | `config.yaml`: add `fresh fruit`, `milk` to `foods_i_like`. |
| vegetarian / vegan / halal / kosher / gluten-free | `config.yaml`: `restrictions: [...]`. |
| nut / shellfish / dairy / eggs allergy | `config.yaml`: `avoid_allergens: [...]`. |
| "don't ask, just order" / 不用问 | `config.yaml`: `confirm_before_order: false` (already default). |
| "show me the plan first" / 让我确认 | `config.yaml`: `confirm_before_order: true`. |
| "skip weekends" / 不要周末 | `config.yaml`: `skip_weekends: true` (already default). |
| "include weekends" / 要周末 | `config.yaml`: `skip_weekends: false`. |
| meal composition (1 main + sides vs big bowl) | `preferences.md`: free-text — no structured field. |
| portion size hints / "not a big eater" | `preferences.md`: free-text. |
| anything not covered above | `preferences.md`. |

#### Verification before declaring done

After writing `~/Documents/WeBox/config.yaml`, run this schema-check:
```bash
python3 -c "
import re
with open('$HOME/Documents/WeBox/config.yaml') as f: text = f.read()
allowed = {'budget','budget_mode','validate_budget','confirm_before_order','default_meals','skip_weekends',
           'avoid_repeat_days','history_window_days','allow_repeat_categories',
           'restrictions','avoid_allergens','preferred_cuisines','cuisines_to_avoid',
           'foods_i_like','foods_to_avoid','order_drinks','avoid_sugary_drinks','preferred_drinks'}
keys = set(re.findall(r'^(\w+):', text, re.M))
extra = keys - allowed
print('UNKNOWN KEYS — REWRITE FROM TEMPLATE:' if extra else 'OK: all keys canonical.', sorted(extra) if extra else '')
"
```

If anything is reported UNKNOWN, the file is off-schema — rewrite it from the template before finishing the onboarding.

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
  config.yaml              — structured settings (budget, restrictions, drinks, ...)
  preferences.md           — free-form notes (edit in Finder anytime)
  user-profile.json        — Boyu Gou, boyu.gou@..., 6145568304
  address-info.json        — 1881 Page Mill Rd (kitchen 12838)
  shipping-windows.json    — Lunch + Dinner cutoff windows (from your past orders)
  favorites.json           — 131 hearted products
  hidden.json              — 180 "Not Interested" products
  orders/                  — 407 past active orders across N weeks
  item-reviews.md          — empty (grows as you order)

You're ready to order. Try:
  "Order my lunch for tomorrow"        (full menu via webox-order)
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
