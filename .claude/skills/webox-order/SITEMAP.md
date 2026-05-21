# WeBox Sitemap Reference

Verified URL patterns and DOM behavior. Read this for any new task involving WeBox the agent hasn't seen before.

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
| `https://www.webox.com/menu/section/My%20Favorites?date=YYYY-MM-DD&shippingTime=Lunch` | User's hearted favorites | **Date-bound** — returns hearted items available on this date, NOT the user's full hearted list. |

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
