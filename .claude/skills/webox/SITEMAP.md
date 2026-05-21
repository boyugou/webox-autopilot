# WeBox Sitemap Reference

Verified API endpoints, URL patterns, and DOM selectors. **Prefer API calls over DOM scraping** wherever possible — APIs are ~10× faster, deterministic, return structured data, and don't fight virtual scrolling.

---

## API Surface (verified 2026-05-21, prefer these)

All endpoints are same-origin `fetch('/api/...', { credentials: 'include' })`. The page's session cookie is automatically attached.

### Identity & address (call once per session, cache result)

| Endpoint | Method | Returns |
|---|---|---|
| `/api/users/my` | GET | `{ data: { firstName, lastName, phone, email, timezone, id, ... } }` |
| `/api/v2/userAddresses/my` | GET | Addresses array — pick the default to get `addressId`, `kitchenId`, `timezone` |

### Menu

```
GET /api/productSpecials/v8/address/<ADDR_ID>/date/<YYYY-MM-DD>
```

Returns `{ code: 1, data: { ... } }` containing:

| Field | Shape | Notes |
|---|---|---|
| `lunchSpecials` | array (~2000) | Per-slot inventory for Lunch. Actual fields: `{id (=productSpecialId), productId, price, regularPrice, stockStatus, stockQuantity, kitchenId, dateShipping, timeShipping, pickupWindowId, ...}`. NOTE: `portionId`, `cutoffTime`, and `shippingTimeSectionId` are NOT on these entries — see Place Order section for where each really comes from. |
| `dinnerSpecials` | array (~1300) | Same shape, Dinner |
| `happyHourSpecials` | array | Same shape, HappyHour |
| `products` | array (~2400) | Catalog: `{id, brandId, category, extName: {enUs}, averageRating, salesCnt, glutenFree, dairyFree, halalCertified, nutFree, spicyLevel, veggieLevel, ...}` |
| `productBrands` | array (~100) | `{id, extName: {enUs, zhCn}, ...}` |
| `categoryList` | array | 27 categories |
| `soldOutTag` | object | Sold-out info |

**Join for the slot you want:**
```javascript
const j = await fetch(`/api/productSpecials/v8/address/${addrId}/date/${date}`, { credentials: 'include' }).then(r => r.json());
const { lunchSpecials, products, productBrands } = j.data;
const productById = new Map(products.map(p => [p.id, p]));
const brandById = new Map(productBrands.map(b => [b.id, b]));
const items = lunchSpecials.filter(s => s.stockStatus !== 'outofstock').map(s => {
  const p = productById.get(s.productId); if (!p) return null;
  // portionId source: product.extPortions (NOT lunchSpecials). Default portion preferred.
  const portion = (p.extPortions || []).find(x => x.isDefault) || (p.extPortions || [])[0];
  return {
    productSpecialId: s.id,                // from specials entry
    productId: p.id,
    portionId: portion?.id || null,        // from product.extPortions
    kitchenId: s.kitchenId,
    name: p.extName?.enUs,
    brand: brandById.get(p.brandId)?.extName?.enUs,
    price: s.price,
    rating: p.averageRating || null,
    category: p.category,
    dietary: { glutenFree: p.glutenFree, dairyFree: p.dairyFree, halal: p.halalCertified, nutFree: p.nutFree, vegan: p.veggieLevel === 'Vegan' }
  };
}).filter(Boolean);
// NOTE: shippingTimeSectionId and cutoffTime are NOT on lunchSpecials entries —
// they come from past orders' extShippingTimeSection (cached separately).
```

One call ≈ 1 second, full menu. No scrolling, no virtualization.

### Favorites & hidden ("Not Interested")

| Endpoint | Method | Body / Returns |
|---|---|---|
| `/api/fav/my` | GET | `{ data: { productIdList, brandIdList } }` |
| `/api/hide/my` | GET | Same shape — items the user "Not Interested"-ed |
| `/api/favProducts/<productId>?client=web` | POST | (no body) — heart a product |
| `/api/favBrands/<brandId>?client=web` | POST | (no body) — favorite a brand |
| `/api/userHide/addHide?client=web` | POST | `{ hideType: "Product"\|"Brand", hideId: <id> }` |
| `/api/userHide/removeHide?client=web` | POST | Same body — undo |

**Bulk operations** (e.g., "hide all sugary drinks"):
```js
const sugary = items.filter(i => i.category === 'Beverage' && /soda|sweet|cola|sugar/i.test(i.name));
for (const it of sugary) {
  await fetch('/api/userHide/addHide?client=web', {
    method: 'POST', credentials: 'include',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ hideType: 'Product', hideId: it.productId })
  });
}
```

### Order history (paginated)

```
GET /api/orders/list?client=web&status=Paid%2CPartialRefunded%2CPlanned%2CUnpaid%2CRefunded%2CCancelled%2COnHold&pageSize=10&pageIndex=N&type=Individual&orderBy=id&desc=true&referenceTypes=GROUP_ORDER_META
```

Returns `{ code: 1, data: { totalCount, result: [...] } }`. Each `result[i]` has:
- `order`: top-level meta (`id, status: "Paid"|"Refunded"|"Cancelled"|..., totalCharge, addressId, dateCreated, datePaid, customerId`)
- `orderPackages[]`: each has `dateShipping (unix ms), timeShipping ("Lunch"|"Dinner"|"HappyHour"), status, extItems[], extRefunds[]`
- `userPreAuth`: payment info

Filter for `status === "Paid"` to skip cancelled/refunded. Loop pages until you've fetched all `totalCount`. A 400-order history is ~40 calls × ~100ms ≈ 4s total.

### Place Order

```
POST /api/orders?client=web
```

Body shape (every value traceable):
```jsonc
{
  "order": {
    "firstName":  "<from /api/users/my>",
    "lastName":   "<from /api/users/my>",
    "phone":      "<from /api/users/my>",
    "email":      "<from /api/users/my>",
    "timezone":   "<from extAddress.timezone>",        // /api/users/my does NOT return timezone
    "addressId":  240212,                              // defaultAddr.addressId (NOT defaultAddr.id)
    "kitchenId":  12838,                               // defaultAddr.extAddress.kitchenId
    "currency":   "Dollar",
    "autoSelectCoupon": true
  },
  "orderPackages": [{
    "extItems": [{
      "productSpecialId": 56813079,                    // lunchSpecials[i].id
      "portionId":        144251,                      // products[i].extPortions.find(x => x.isDefault).id
      "quantity":         1,
      "cutoffTime":       1779462000000,               // LOCAL extFormCutoff time on target date, converted to UTC ms
      "extCartItemId":    "2026-05-22__27274__56813079__144251",  // <date>__<shipSecId>__<specId>__<portionId>
      "extChildren":      []
    }],
    "dateShipping":           1779408000000,           // UTC midnight of target date: new Date(date + 'T00:00:00Z').getTime()
    "timeShipping":           "Lunch",
    "shippingTimeSectionId":  27274,                   // per-meal constant; derive from past orders' extShippingTimeSection
    "kitchenId":              12838,
    "extCutleryQuantity":     0,
    "extBaseCutleryQuantity": 1
  }],
  "payType":            "Personal",
  "realTips":           0,
  "usePersonalWeBucks": true,
  "hasAddedWeBucks":    false,
  "suggestPoint":       -596734                        // any negative integer is accepted; the page computes via budget API
}
```

**Where each field comes from — important nuances:**

| Place Order field | Source | Notes |
|---|---|---|
| `order.addressId` | `defaultAddr.addressId` from `/api/v2/userAddresses/my` | This is the **canonical address record** (e.g., 240212). NOT `defaultAddr.id` (459170, which is the user-address association). |
| `order.kitchenId` | `defaultAddr.extAddress.kitchenId` | Nested inside `extAddress`, not at the top level. |
| `order.timezone` | `defaultAddr.extAddress.timezone` | `/api/users/my` does NOT include timezone — must come from the address. |
| `extItems[].portionId` | `products[i].extPortions.find(x => x.isDefault).id` | Every product has at least one portion. 81 of ~2400 products have multiple (small/regular/large); use `isDefault` or first. |
| `extItems[].cutoffTime` | `new Date(date + 'T' + extFormCutoff + ':00').getTime()` | LOCAL (user timezone) interpretation of "HH:MM" on the shipping date, converted to epoch ms. `extFormCutoff` lives in `extShippingTimeSection.extFormCutoff` from past orders. |
| `orderPackages[].dateShipping` | `new Date(date + 'T00:00:00Z').getTime()` | UTC midnight of the shipping date — explicit `Z` matters. |
| `orderPackages[].shippingTimeSectionId` | Per-meal constant for the user's kitchen. Lunch=27274, Dinner=27275 for kitchen 12838. **Derive from `orderPackages[].shippingTimeSectionId` in past orders** — varies by kitchen. |

**Response:** `{ code: 1, data: { id: <orderNumber>, ... } }`. The order is placed immediately on success.

**Do NOT poll `/api/orders/list` to verify.** `code: 1` is the only success signal you need. A fresh order has `status: "Paid"`, not in the `Planned/OnHold/Unpaid` filter set most agents reach for. The orders-list API also has cache lag of several seconds. Polling causes the agent to incorrectly conclude the order failed, then retry — risk of duplicate charges.

**These IDs and times CANNOT be derived from the menu API alone.** The menu API gives you `productSpecialId` and `productId`, but `shippingTimeSectionId` + `extFormCutoff` come from past orders' `extShippingTimeSection` records, and `portionId` comes from `products[].extPortions`. The skill caches all three in `shipping-windows.json` and the menu cache.

### Order modifications (path-templated in bundle; capture-on-action before use)

| Endpoint | Method |
|---|---|
| `/api/orders/changeItemQuantity` | POST |
| `/api/orders/cancel/date/<DATE>/time/<MEAL>` | (verb TBD) |
| `/api/orders/cancel/<orderId>/package/<pkgId>/item/<itemId>` | (verb TBD) |
| `/api/orders/refund` | POST |

### Cart state (client-side)

Cart lives in `localStorage.CartService_cartItemArrMap`. Angular owns the UI render. For ordering, you don't need to touch the cart — `POST /api/orders` is a self-contained payload. The cart is just for the user-facing "Add to Cart" → "Place Order" UX flow.

### "Helper" endpoints (called by the page; usually unnecessary for the skill)

`/api/carts/calculateBudgetAvailable` (validation), `/api/orders/taxRate`, `/api/recommend/own/brand/products`, `/api/weBucksAccount/...`, `/api/operation/record/user` (telemetry).

---

## Local File Schemas (`~/Documents/WeBox/`)

Every file the skills write. Use these as the authoritative shape reference — and pair with the ingestion patterns below to read big ones efficiently.

### `config.yaml`
Schema-locked YAML with these top-level keys ONLY (validator in webox-onboard Step 7a enforces):
```
budget, budget_mode, validate_budget,
confirm_before_order, default_meals, skip_weekends,
avoid_repeat_days, history_window_days, allow_repeat_categories,
restrictions, avoid_allergens, preferred_cuisines, cuisines_to_avoid,
foods_i_like, foods_to_avoid,
order_drinks, avoid_sugary_drinks, preferred_drinks
```

### `preferences.md`
Free-form markdown. No schema. Read whole file, treat as soft constraint hints for the planner.

### `user-profile.json` (< 1 KB)
```json
{ "id": 401264, "firstName": "...", "lastName": "...", "phone": "...", "email": "...", "timezone": "..." }
```

### `address-info.json` (< 1 KB)
```json
{ "addressId": 240212, "userAddressId": 459170, "kitchenId": 12838, "timezone": "America/Los_Angeles", "address1": "...", "city": "..." }
```
`addressId` is the canonical (used by all APIs); `userAddressId` is the per-user link record.

### `shipping-windows.json` (< 2 KB)
```json
{
  "synced_at": "ISO-8601",
  "windows": {
    "Lunch":  { "shippingTimeSectionId": 27274, "extFormCutoff": "08:00", "daysBefore": 0, ... },
    "Dinner": { "shippingTimeSectionId": 27275, "extFormCutoff": "14:30", "daysBefore": 0, ... }
  }
}
```

### `favorites.json` / `hidden.json` (~20 KB each)
```json
{
  "synced_at": "ISO-8601",
  "products": [
    { "id": 500874, "name": "Mongolian Beef Bento", "brand": "Xiangchuan Kitchen", "category": "Bentos" }
  ],
  "unresolvedProductIds": [202759, 183709],
  "brands": []
}
```
Read whole file. Derive ID Sets for fast lookup: `new Set([...products.map(p=>p.id), ...unresolvedProductIds])`.

### `orders/YYYY-Www.json` (~5–20 KB each)
```json
{
  "week": "2026-W21",
  "week_starts": "2026-05-18",
  "synced_at": "ISO-8601",
  "orders": [
    {
      "date": "2026-05-21", "day": "Thu", "meal": "Dinner",
      "orderId": "No.3259401", "status": "Paid", "total": 30.0,
      "items": [
        { "productId": 499852, "name": "Mongolian Beef Bento", "brand": "Xiangchuan Kitchen", "quantity": 1 }
      ]
    }
  ]
}
```
Order items intentionally **omit** `productSpecialId`, `portionId`, `price` — those live in the menu cache for Place Order body assembly, never consumed from order history.

### `menu-cache/YYYY-MM-DD-Meal.json` (~1 MB — the big one)
```json
{
  "cached_at": "ISO-8601",
  "date": "2026-05-22",
  "meal": "Lunch",
  "kitchenId": 12838,
  "items": [
    {
      "name": "...", "brand": "...", "price": 17.95, "category": "Bentos",
      "rating": 4.5, "in_favorites": true,
      "dietary": { "glutenFree": false, "dairyFree": false, "halal": false, "nutFree": false, "vegan": false, "vegetarian": false },
      "stockQuantity": 0,
      "productId": 499852, "productSpecialId": 56813079,
      "portionId": 144251, "portionCount": 1
    }
  ]
}
```
All 12 fields are consumed by the planner / Place Order body builder. Don't drop any.

### `item-reviews.md`
Free-form markdown with per-dish ratings + comments. No schema; agent appends dated lines.

---

## Ingestion patterns for big files

The menu cache is ~1 MB / ~2000 items. **Don't `Read` it whole into context** — that's ~250K tokens and most items are irrelevant to the current plan. Instead, run a small Bash + Python filter first and read only the result.

### Pattern A — filter menu cache by criteria, output ~30 candidates

```bash
uv run --no-project python3 << 'EOF'
import json, os, sys
cache = json.load(open(os.path.expanduser("~/Documents/WeBox/menu-cache/2026-05-22-Lunch.json")))
restrictions  = ['vegetarian']           # from config.yaml
max_price     = 30.00                    # from config.yaml budget
recent_pids   = {499852, 203853}         # set of productIds eaten in last 7 days
candidates = []
for it in cache['items']:
    if it['price'] > max_price: continue
    if 'vegetarian' in restrictions and not it['dietary'].get('vegetarian') and not it['dietary'].get('vegan'): continue
    if it['productId'] in recent_pids: continue  # variety
    score = 0
    if it['in_favorites']: score += 10
    if it['rating']: score += it['rating']
    candidates.append((score, it))
candidates.sort(key=lambda x: -x[0])
# Slim each item to plan-relevant fields, output top 30
out = [{
    "name": it["name"], "brand": it["brand"], "price": it["price"],
    "category": it["category"], "rating": it["rating"], "in_favorites": it["in_favorites"],
    "productId": it["productId"], "productSpecialId": it["productSpecialId"], "portionId": it["portionId"]
} for _, it in candidates[:30]]
json.dump(out, open("/tmp/webox-candidates.json","w"), indent=2)
print(f"✓ wrote {len(out)} candidates to /tmp/webox-candidates.json")
EOF
```

Then `Read /tmp/webox-candidates.json` (~5 KB) and pick from it. **The agent never reads the 1 MB file directly.**

### Pattern B — count slot occupancy from order history (fast, no whole-file read)

```bash
uv run --no-project python3 << 'EOF'
import json, glob, os, datetime
today = datetime.date.today()
windows = {}  # date+meal → orderId
for f in glob.glob(os.path.expanduser("~/Documents/WeBox/orders/*.json")):
    for o in json.load(open(f)).get("orders", []):
        d = datetime.date.fromisoformat(o["date"])
        if 0 <= (d - today).days <= 7:
            windows[(o["date"], o["meal"])] = o.get("orderId")
print(json.dumps(windows, indent=2))
EOF
```

### Pattern C — quick lookup against favorites/hidden (small files; Read is fine)

```python
fav  = json.load(open(os.path.expanduser("~/Documents/WeBox/favorites.json")))
hide = json.load(open(os.path.expanduser("~/Documents/WeBox/hidden.json")))
fav_ids  = set(p["id"] for p in fav["products"])  | set(fav["unresolvedProductIds"])
hide_ids = set(p["id"] for p in hide["products"]) | set(hide["unresolvedProductIds"])
```

### Rule of thumb

- File < 30 KB → `Read` tool directly is fine (favorites, hidden, orders/<week>, address-info, user-profile, shipping-windows, config.yaml, preferences.md)
- File > 100 KB → use Bash + Python to filter first, then `Read` the smaller result (menu cache, big concatenated orders dumps)

---

## DOM patterns (legacy / fallback)

The DOM patterns below were the primary mechanism in earlier versions. They still work and are useful for: cart UI interactions, debugging, and any case where the API path isn't available. **Prefer API where possible.**

---

## URL Patterns

### Menu / catalog pages

| URL pattern | What it does | Notes |
|---|---|---|
| `https://www.webox.com/` | Homepage | Limited "featured" view, not the full menu |
| `https://www.webox.com/?date=YYYY-MM-DD&shippingTime=Lunch` | Date+meal default landing | ~30-40 curated items, NOT exhaustive |
| `https://www.webox.com/?date=YYYY-MM-DD&shippingTime=Lunch&queryText=NAME` | **Search** within a slot | **Use this for cart-add per item.** First result = best match. Returns up to 50 items. URL-encode spaces (`%20`). |
| `https://www.webox.com/?date=YYYY-MM-DD&shippingTime=Lunch&objType=CUISINE&objId=NAME&objName=NAME` | Cuisine category (Chinese, Japanese, Korean, Thai, etc.) | `objId` and `objName` = same human-readable name. Use for ethnic cuisine categories. |
| `https://www.webox.com/?date=YYYY-MM-DD&shippingTime=Lunch&objType=CATEGORY&objId=<NUM>&objName=NAME` | Food-type category (Drink, Side, Snack, Bowl, Dessert, etc.) | `objId` is a NUMERIC database ID. Must be discovered from the navbar at runtime (click the icon, capture the URL). |
| `https://www.webox.com/menu/section/My%20Favorites?date=YYYY-MM-DD&shippingTime=Lunch` | User's hearted favorites | **Slot-bound and future-only.** Returns hearted items available for THIS specific date+meal slot, NOT the user's full hearted list. ⚠️ If the slot's order cutoff has passed (e.g., today's Lunch after mid-morning), **WeBox silently redirects to the next orderable slot's full-menu view** (URL becomes `/menu/section/?date=NEXT&shippingTime=...&primaryType=CATEGORY`) and returns 100+ items that are NOT favorites. Always use a date+meal slot that's still in the orderable future. After navigating, verify `location.href` still contains `My%20Favorites` — if not, you were redirected and got wrong data. |

### ⚠️ Anti-pattern (DO NOT use)

| Wrong URL | What actually happens |
|---|---|
| `/menu/section/Chinese?date=X&shippingTime=Y` | Silently falls back to **favorites**! Returns wrong data while looking like it worked. |
| `/menu/section/Drink?date=X&shippingTime=Y` | Same — silently falls back to favorites. |

`/menu/section/X` ONLY works for `My%20Favorites`. For everything else, use the root URL with `objType` + `objId` query parameters.

### Order / cart pages

| URL pattern | What it does |
|---|---|
| `https://www.webox.com/order/list/normal` | User's order history (Paid, Refunded, Cancelled). Infinite scroll. |
| `https://www.webox.com/checkout?date=X&shippingTime=Y` | Full checkout page (Place Order). Reached by clicking `a.cart.fr`. |
| `https://www.webox.com/order/finish/<NUMBER>` | Success page after Place Order. URL contains the order number — parse it. |

---

## Cuisine categories (objType=CUISINE, objId=NAME)

These are the 15 known cuisines (ethnic categories). The `objId` and `objName` are just the human-readable name (URL-encoded where needed):

| Cuisine | URL value |
|---|---|
| Chinese | `Chinese` |
| Japanese | `Japanese` |
| Korean | `Korean` |
| Thai | `Thai` |
| Vietnamese | `Vietnamese` |
| Indian | `Indian` |
| Mexican | `Mexican` |
| Italian | `Italian` |
| French | `French` |
| Greek | `Greek` |
| Mediterranean | `Mediterranean` |
| American | `American` |
| Burmese | `Burmese` |
| Nepalese | `Nepalese` |
| Filipino | `Filipino` |

## Food-type categories (objType=CATEGORY, objId=<NUM>)

These have NUMERIC database IDs. Known/discovered so far:

| Category | objId (numeric) |
|---|---|
| Deals | `504` |
| Drink | `38` |

**For others** (Bowl, Side, Entrée, Noodles, Salad, Snack, Produce, Sandwich, Burger, Wrap, Dairy & Eggs, Dessert, Taco, Sushi, Burrito, Pizza), the numeric IDs must be discovered at runtime:

```javascript
// Run on the menu page to extract a category's URL by clicking its icon
(async () => {
  const target = [...document.querySelectorAll('.category-item-name')].find(e => /^DRINK$/i.test(e.innerText.trim()));
  target?.click();
  await new Promise(r => setTimeout(r, 1300));
  const params = new URLSearchParams((location.href.split('?')[1] || ''));
  return { objType: params.get('objType'), objId: params.get('objId'), objName: params.get('objName') };
})()
```

Then update this table with the discovered ID.

---

## DOM Reference

### Favorites page detection (avoid silent redirect to full menu)

The favorites page renders this header when it's actually showing favorites:

```
.menu-section-header__title   →  innerText = "My Favorites"
```

When WeBox silently redirects (cutoff passed for that slot), this element either disappears entirely or shows a different title. Always check both:

```javascript
const urlOk = /My%20Favorites|My Favorites/.test(location.href);
const headerEl = [...document.querySelectorAll('.menu-section-header__title')]
  .find(e => /My Favorites/i.test(e.innerText || ''));
if (!urlOk || !headerEl) { /* redirected — retry with a later orderable slot */ }
```

### Menu page product card

```
app-product-menu-item.menu-section-product-item, .new-menu-product-item
├── .product-item-content-wrapper
│   ├── .brand-wrapper                              → restaurant name
│   ├── .product-menu-title                         → clean dish name
│   ├── .product-price                              → "$17.55"
│   ├── .product-menu-new-and-rating-wrapper        → first line is the rating
│   └── .product-menu-allergy-wrapper               → allergen icons
├── .product-menu-top-sold-out-wrapper              → ALWAYS in DOM; check getComputedStyle(el).display !== 'none'
├── .btn.plus-add                                   → add to cart (DIV, not <button>)
└── .product-add-wrapper                            → add to cart for items with required options (SPAN, opens modal)
```

### Options modal

```
[class*="product-detail-header"]                    → modal-open indicator
.anticon.anticon-close                              → close X (NOT auto-closed after Add)
st-button.add-button                                → Add to Cart button inside modal
.product-detail-footer                              → footer container holding the add button
```

Modal layout on the right side shows:
- Recommended Options (preset combos like "Last ordered on X")
- Portion Size (radio)
- Required option groups (e.g., "Choose Your Protein")
- "Special requests" text input

### Header / cart

```
a.cart.fr                                           → cart icon link (click → /checkout)
.cart-count                                         → "X items" text in header
```

When a side-drawer cart variant is shown (some page states render the cart as a drawer):
```
[class*="drawer-cart"], .menu-section-drawer-cart   → drawer container
.cart-header / .cart-title / .cart-count / .cart-close  → drawer header parts
.cart-sub-item                                      → line item in drawer
```

### Checkout page (`/checkout`)

```
.input-number-wrapper.isCart                        → qty stepper per line item
.btn.plus                                           → increment
.btn.minus                                          → decrement
.btn.minus.unable                                   → disabled state (qty at minimum)
input (inside stepper)                              → reads current qty via .value
.place-btn                                          → Place Order button (DIV; multiple instances on page — first works)
button:contains("Remove")                           → confirm dialog "Remove" button (appears when decrementing qty to 0)
```

### Order list (`/order/list/normal`)

```
.order-item                                         → one per order
├── .order-id                                       → "No.3258614"
├── .order-status                                   → "Refunded" / "Cancelled" / "Paid" / absent (= active)
├── .order-type                                     → "Order"
└── inner text contains:
    - date line e.g. "Fri 05/22"
    - meal line e.g. "Lunch" or "Dinner (Delivered at 5:49 PM)"
    - item lines
    - $price lines
    - "Reorder" button text
```

Active/delivered orders show meal as `"Dinner (Delivered at 5:49 PM)"`.
Cancelled/refunded orders show plain `"Dinner"`.

Meal regex must match both: `/^(Lunch|Dinner|HappyHour)(\s|\(|$)/`

---

## Two Checkout Paths

WeBox has two ways to reach Place Order, depending on page state and where you click:

### Path A — Full checkout page (recommended)

1. Click `a.cart.fr` (cart icon, top-right) → page navigates to `/checkout?date=X&shippingTime=Y`
2. On `/checkout`, click `.place-btn` → page navigates to `/order/finish/<NUMBER>`

This is the documented happy path. Both clicks are pure JS, no modal handling needed.

### Path B — Side drawer "Quick Checkout"

In some page states (observed when you've just added an item to cart and cart drawer pops up on the right side), the drawer has its own "Quick Checkout" button.

- Drawer container: `[class*="drawer-cart"]` or `.menu-section-drawer-cart`
- Drawer line items: `.cart-sub-item` (each contains a qty stepper)
- Drawer qty stepper: same selectors as `/checkout` page (`.input-number-wrapper.isCart`)
- Drawer Quick Checkout button: search the drawer for an element whose text matches `/Quick Checkout/i`

Path A is more reliable for automation because the navigation is explicit and the URL changes are observable. Prefer Path A unless the drawer is already open and Path A would cause an extra navigation.

---

## Successful checkout indicators

After clicking Place Order:
- URL changes to `/order/finish/<NUMBER>`
- Page shows "Thank you for your order"
- An order number is visible

Parse the order number from URL:
```javascript
location.pathname.match(/\/order\/finish\/(\d+)/)?.[1]
```

---

## Login state probe

User is logged in if any of these are present:
- `a.cart.fr` (the cart icon link — only rendered for authenticated users)
- `[class*="user-avatar"]`
- `[class*="user-name"]`
- `[class*="header-avatar"]`

```javascript
const loggedIn = !!document.querySelector('a.cart.fr, [class*="user-avatar"], [class*="user-name"], [class*="header-avatar"]');
```

---

## Notes on background tab behavior

- Menu pages CAN lazy-load in background tabs (verified for individual category scrapes).
- BUT we've observed inconsistent results when scraping multiple tabs in parallel — some background scrapes may return partial item lists silently.
- Safest contract: **scrape one tab at a time, in the foreground**. The wall-time cost is acceptable (~3-5s per scrape with smart-scroll).

## Multi-window parallelism (not feasible)

Claude in Chrome's MCP tools cannot programmatically open a second window of the same Chrome profile.

Available tools and their limits:
- `tabs_create_mcp` — creates a new TAB in the existing tab group (same window)
- `tabs_context_mcp(createIfEmpty: true)` — creates a new window with a fresh tab group, but ONLY when there's no existing MCP group. Once one exists, this call is a no-op. So Claude is effectively single-windowed per session.
- `list_connected_browsers` / `switch_browser` — these switch between separate Chrome instances (different processes / profiles, e.g. Chrome + Chrome Canary). They DO NOT share cookies or login state, so they don't help for "same user, multiple windows."

Practical implication: parallel multi-tab in one window is the only parallelism available, and it's unreliable for lazy-loaded pages (see "Notes on background tab behavior" above). **Stick with sequential scraping for production paths.**

If you genuinely need multi-window parallel automation, you'd need a headless-driver approach (Playwright / Puppeteer) — that's a different project, not within Claude in Chrome's scope.

---

## Useful tiny scripts

### Search and report (no add)
```javascript
// On https://www.webox.com/?date=X&shippingTime=Y&queryText=NAME
(async () => {
  await new Promise(r => setTimeout(r, 2500));
  const items = [...document.querySelectorAll('app-product-menu-item.menu-section-product-item, .new-menu-product-item')];
  return items.slice(0, 10).map(i => ({
    name: i.querySelector('.product-menu-title')?.innerText?.trim(),
    brand: i.querySelector('.brand-wrapper')?.innerText?.trim(),
    price: i.querySelector('.product-price')?.innerText?.trim()
  }));
})()
```

### Cart inspection (run on any page)
```javascript
(async () => {
  document.querySelector('a.cart.fr')?.click();
  await new Promise(r => setTimeout(r, 2500));
  return [...document.querySelectorAll('.input-number-wrapper.isCart')].map(s => ({
    qty: s.querySelector('input')?.value,
    name: s.closest('[class*="cart-item"], [class*="cart-product"]')?.querySelector('[class*="name"], [class*="title"]')?.innerText?.trim()
  }));
})()
```

### Clear cart (decrement everything to 0)
```javascript
(async () => {
  while (true) {
    const stepper = document.querySelector('.input-number-wrapper.isCart');
    if (!stepper) break;
    while (parseInt(stepper.querySelector('input')?.value || '0', 10) > 1) {
      stepper.querySelector('.btn.minus')?.click();
      await new Promise(r => setTimeout(r, 250));
    }
    stepper.querySelector('.btn.minus')?.click();
    await new Promise(r => setTimeout(r, 700));
    const removeBtn = [...document.querySelectorAll('button')].find(b => /^Remove$/i.test((b.innerText || '').trim()));
    if (!removeBtn) break;
    removeBtn.click();
    await new Promise(r => setTimeout(r, 700));
  }
  return 'cart cleared';
})()
```
