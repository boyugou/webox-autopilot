---
name: webox-order
description: Autonomously order food from WeBox (webox.com) using the user's logged-in Chrome session. Smart default — scrapes favorites first for each meal slot, intelligently augments with categories if favorites are insufficient for the budget. Use for normal ordering. For explicit full-menu exploration, use webox-order-all instead.
---

# WeBox Order Skill

The default ordering skill. Favorites-first with smart fallback when favorites can't fulfill the slot.

Data directory: `~/Documents/WeBox/` (visible in Finder, plain text).

## JS-First Principle

**Always prefer JavaScript over computer use.** JS is faster, more reliable, works in background tabs. Use computer use (screenshots, `find`, coordinate clicks) ONLY for visually complex modals with 5+ option groups that genuinely need model judgment. Every other interaction has a verified JS selector documented in this skill.

## Defaults

- **Meal types:** When not specified, order both **Lunch and Dinner** per day.
- **Weekends:** Skip Saturday and Sunday for multi-day ranges unless asked.
- **Confirmation mode:** Default `auto` — order without asking, pause only on errors or genuine ambiguity. Set `confirm_before_order: true` in preferences for plan-first mode.

## WeBox Constraints

- **7-day window:** Can only order up to 7 days ahead.
- **Meal cutoffs:** Lunch has a mid-morning cutoff. Skip slots where cutoff has passed.
- **Budget per slot:** Each date+meal is a separate checkout.

---

## Step 0: Prerequisite Check

1. **Chrome connected?** Call `tabs_context_mcp`. If no tabs, stop:
   > Claude in Chrome doesn't seem to be connected. Make sure Chrome is running with the [Claude in Chrome extension](https://code.claude.com/docs/en/chrome) enabled.

2. **Preferences exist?** Check `~/Documents/WeBox/preferences.md`. If missing, stop:
   > You haven't set up WeBox yet. Run `/webox-onboard` first (or say "set up WeBox") — takes about 2 minutes.

---

## Step 1: Load Local State

### 1a. Preferences
Read `~/Documents/WeBox/preferences.md`. Extract:
- `budget`, `budget_mode`, `validate_budget`
- `confirm_before_order`, `default_meals`, `skip_weekends`
- `avoid_repeat_days` (default 7), `history_window_days` (default 28)
- `allow_repeat_categories`, `allow_repeat_patterns` (fillers exempt from variety rules)
- `category_mode` (all | whitelist | blacklist), `category_list`
- Dietary restrictions, allergens, preferred/avoided cuisines, drinks

### 1b. Item reviews
Read `~/Documents/WeBox/item-reviews.md` if it exists. Used in Step 4 for selection bias.

### 1c. Order history (slot occupancy + variety tracking)
Read `~/Documents/WeBox/order-history.md`. Only load entries within `history_window_days` into context. This file serves two purposes:
- **Slot occupancy:** which date+meal slots are already ordered (only `✅` blocks; `↩️ refunded` and `🚫 cancelled` are OPEN for re-ordering)
- **Variety tracking:** what items were ordered recently (avoid repeating within `avoid_repeat_days`)

If `last_synced` is more than 1 day old → re-sync in Step 2 before proceeding.
Malformed or missing → treat as empty and re-scrape.

---

## Step 2: Sync Order History (if stale)

*Skip if `order-history.md` was synced within the last day.*

Navigate to `https://www.webox.com/order/list/normal` and run:

```javascript
(async () => {
  await new Promise(r => setTimeout(r, 1500));  // initial paint
  let lastCount = 0, stable = 0;
  for (let i = 0; i < 8; i++) {
    window.scrollTo(0, document.body.scrollHeight);
    await new Promise(r => setTimeout(r, 350));
    const cnt = document.querySelectorAll('.order-item').length;
    if (cnt === lastCount) { if (++stable >= 2) break; } else { stable = 0; }
    lastCount = cnt;
  }
  const orders = [...document.querySelectorAll('.order-item')].map(o => {
    const orderId = o.querySelector('.order-id')?.innerText?.trim();        // "No.3258614"
    const orderStatus = o.querySelector('.order-status')?.innerText?.trim();  // "Refunded" | "Cancelled" | "Paid" | absent
    const lines = o.innerText.split('\n').map(l => l.trim()).filter(Boolean);
    const dateLine = lines.find(l => /^(Mon|Tue|Wed|Thu|Fri|Sat|Sun)\s+\d{2}\/\d{2}$/.test(l));
    const mealLine = lines.find(l => /^(Lunch|Dinner|HappyHour)(\s|\(|$)/.test(l));
    const meal = mealLine?.match(/^(Lunch|Dinner|HappyHour)/)?.[1];
    const itemLines = lines.filter(l =>
      l !== dateLine && l !== mealLine && l !== orderId && l !== orderStatus &&
      !/^(Order|Invoice|Details|Reorder|Cancel|View|Track|Total:|Refunded|Paid|No\.\d)/i.test(l) &&
      !/^\$/.test(l) && l.length > 3
    );
    const isActive = !orderStatus || !/refund|cancel/i.test(orderStatus);
    return { date: dateLine, meal, orderId, orderStatus: orderStatus || 'active', isActive, items: itemLines };
  }).filter(o => o.date && o.meal);
  return JSON.stringify(orders);
})()
```

Merge results into `~/Documents/WeBox/order-history.md`:
- New active slots → `✅ #ORDERNUM`
- Refunded → `↩️ refunded` (slot still OPEN for re-order)
- Cancelled → `🚫 cancelled` (slot still OPEN)
- Update `last_synced` line

Skip any target date+meal currently marked `✅` (active).

---

## Step 3: Scrape Menu (smart favorites-first)

For each meal slot needing menu data, follow this decision tree:

### 3a. Cache check

Check `~/Documents/WeBox/menu-cache/YYYY-MM-DD-Meal.json`:
- Fresh (cached_at < 60 min ago) → use it; skip to Step 4
- Stale or missing → continue to scrape

The cache may have been written by either skill. The `sources` array tells what was scraped:
- `["favorites"]` → from a previous webox-order run
- `["Chinese", "Japanese", ...]` (or includes "all") → from webox-order-all
- Use whatever's there. If favorites isn't represented and you need favorites bias, scrape just favorites and merge.

### 3b. Scrape favorites for the slot

Navigate to (use today's or target date in `YYYY-MM-DD`):
```
https://www.webox.com/menu/section/My%20Favorites?date=YYYY-MM-DD&shippingTime=Lunch
```
Replace `Lunch` with `Dinner` for dinner slots. (Favorites are date-bound — items shown vary by date.)

⚠️ **`/menu/section/X` only works for `My%20Favorites`.** For cuisine categories (Chinese, Japanese, etc.), `/menu/section/X` silently falls back to favorites and returns wrong data. Always use the query-param URL in 3c for cuisine categories.

Smart-scroll + scrape:
```javascript
(async () => {
  await new Promise(r => setTimeout(r, 1500));
  const SELECTORS = 'app-product-menu-item.menu-section-product-item, .new-menu-product-item';
  let lastCount = 0, stable = 0;
  for (let i = 0; i < 12; i++) {
    window.scrollTo(0, document.body.scrollHeight);
    await new Promise(r => setTimeout(r, 350));
    const cnt = document.querySelectorAll(SELECTORS).length;
    if (cnt === lastCount) { if (++stable >= 2) break; } else { stable = 0; }
    lastCount = cnt;
  }
  return [...document.querySelectorAll(SELECTORS)].map(item => {
    const w = item.querySelector('.product-item-content-wrapper');
    const brand = w?.querySelector('.brand-wrapper')?.innerText?.trim();
    const name = w?.querySelector('.product-menu-title')?.innerText?.trim();
    const priceText = w?.querySelector('.product-price')?.innerText?.trim();
    const price = parseFloat(priceText?.replace('$', '') || '0');
    const rating = parseFloat(w?.querySelector('.product-menu-new-and-rating-wrapper')?.innerText?.trim().split('\n')[0]) || null;
    const soldOutEl = item.querySelector('.product-menu-top-sold-out-wrapper');
    const soldOut = soldOutEl ? getComputedStyle(soldOutEl).display !== 'none' : false;
    return { brand, name, price, priceText, rating, soldOut };
  }).filter(i => i.name && !i.soldOut);
})()
```

Mark every returned item with `in_favorites: true`, `categories: ["favorites"]`.

### 3c. Sufficiency check → maybe augment

Attempt to draft a plan from favorites alone (use Step 4 selection logic on the favorites items). Then check:
- Plan total ≥ `budget × 0.4`? AND
- At least 1 main dish (price > $10 not in `allow_repeat_categories`)?

If both yes → favorites are sufficient. Cache and proceed to Step 4.

If either no → **augment with category scrapes:**
1. Determine which categories to scrape (small set, NOT all 33):
   - All cuisines in `preferred_cuisines`
   - Filler categories: `Drink, Side, Snack, Dairy & Eggs, Produce`
   - User's prompt-requested cuisine (if any)
   - Skip anything in `cuisines_to_avoid`
2. Scrape these categories in parallel (wave of 5 tabs at a time — see "Parallel Multi-Tab Execution" below)
3. Merge with favorites results. Dedupe by `(brand, name)` key. Items appearing in favorites AND a category keep `in_favorites: true` and accumulate `categories: ["favorites", "Chinese"]`.

In your output to the user, mention the augmentation:
> Favorites alone were limited for Tue Lunch — also pulled in Chinese and Drink categories to fill the budget.

### 3d. Cache the merged result

Write `~/Documents/WeBox/menu-cache/YYYY-MM-DD-Meal.json`:
```json
{
  "cached_at": "2026-05-20T21:30:00",
  "date": "2026-05-21",
  "meal": "Lunch",
  "sources": ["favorites", "Chinese", "Drink"],
  "items": [
    {
      "brand": "Xiangchuan Kitchen",
      "name": "BBQ Teriyaki Chicken Cutlet",
      "price": 14.95,
      "priceText": "$14.95",
      "rating": 4.5,
      "in_favorites": true,
      "categories": ["favorites", "Chinese"]
    }
  ]
}
```
Create the `menu-cache/` directory if it doesn't exist. Auto-prune cache files older than 24 hours when loading.

### Cuisine-cuisine URL for categories

Use the ROOT URL with query params, not `/menu/section/X`:
```
https://www.webox.com/?date=YYYY-MM-DD&shippingTime=Lunch&objType=CUISINE&objId=NAME&objName=NAME
```

URL-encoded category values (verified from the WeBox DOM):

| Category | URL value |
|----------|-----------|
| Deals | `Deals` |
| Chinese | `Chinese` |
| Bowl | `Bowl` |
| American | `American` |
| Drink | `Drink` |
| Side | `Side` |
| Entrée | `Entr%C3%A9e` |
| Noodles | `Noodles` |
| Salad | `Salad` |
| Japanese | `Japanese` |
| Snack | `Snack` |
| Korean | `Korean` |
| Produce | `Produce` |
| Thai | `Thai` |
| Sandwich | `Sandwich` |
| Italian | `Italian` |
| Vietnamese | `Vietnamese` |
| Mexican | `Mexican` |
| Burger | `Burger` |
| Mediterranean | `Mediterranean` |
| Wrap | `Wrap` |
| Indian | `Indian` |
| Dairy & Eggs | `Dairy%20%26%20Eggs` |
| Greek | `Greek` |
| Dessert | `Dessert` |
| French | `French` |
| Taco | `Taco` |
| Sushi | `Sushi` |
| Burrito | `Burrito` |
| Pizza | `Pizza` |
| Filipino | `Filipino` |
| Burmese | `Burmese` |
| Nepalese | `Nepalese` |

### Parallel Multi-Tab Execution

Open up to 5 tabs concurrently. Background tabs DO execute JS scroll/scrape correctly for menu pages (verified). For >5 categories, batch in waves of 5.

Pattern:
```
# Wave: create N tabs, navigate all (one browser_batch)
browser_batch([
  tabs_create_mcp({ url: <cat_url_1> }),
  tabs_create_mcp({ url: <cat_url_2> }),
  ... (up to 5)
])
# After capturing the returned tab IDs, run scrape JS in all tabs (second browser_batch)
browser_batch([
  javascript_tool({ tabId: <id_1>, text: <scrape_js> }),
  javascript_tool({ tabId: <id_2>, text: <scrape_js> }),
  ...
])
# Close tabs (third browser_batch)
browser_batch([
  tabs_close_mcp({ tabId: <id_1> }),
  ...
])
```

`browser_batch` runs items sequentially in one round-trip, but each JS script is mostly `await sleep()` waiting for lazy-load → the scrapes overlap in time and total ~= max(per-tab time), not sum.

### Rate-limit recovery

If a scraped page returns 0 items twice in a row, or HTTP fails, wait 30s and retry once. If 3+ pages fail, ask user:
> WeBox seems to be rate-limiting. Want to wait 60s and retry, or proceed with what I have?

---

## Step 4: Build the Order Plan

Build a complete plan for ALL slots before touching any cart.

### Budget Rules
- `spend-up-to` (default): aim to use most of budget per slot, prioritize variety over max value
- `ceiling-only`: pick what looks best without filling
- Budget applies to food item total only (not fees/tax)

### Quantity Handling
Items can be ordered in quantities > 1. Represent as `× N`:
```
- Northwest China Cuisine — Tea Egg × 6 — $14.70   ($2.45 × 6)
```
Budget validation: unit price × quantity.

### Selection Priority

1. **Hard constraints (never violate):**
   - Dietary restrictions, allergens
   - Items rated 1/5 or tagged `never-again` in reviews
   - Strongly-negative review comments ("超级咸", "肉太少", "inedible") → hard exclude even without numeric rating
   - Budget cap

2. **Strong preferences:**
   - Items rated 4–5/5 → top candidates
   - User's prompt constraints
   - `preferred_cuisines`

3. **Variety (mains only):**
   - Apply ONLY to main dishes (entrées, bowls, bento, noodles, hot pots).
   - Fillers (items matching `allow_repeat_categories` or `allow_repeat_patterns`) are EXEMPT — milk, water, tea egg, side salad can repeat freely; ordering 5 of the same is fine.
   - For mains: avoid items in recent entries of `order-history.md` (within `avoid_repeat_days`)
   - Cross-day variety: don't pick the same main twice in this ordering session

4. **Soft preferences:**
   - Items with `in_favorites: true` get a small bias over non-favorites
   - Fill remaining budget with complementary fillers if `spend-up-to`
   - User's prompt-requested cuisine restricts the MAIN only — fillers can come from any category

### Item Reviews — How to Read

Reviews mix optional ratings with free-form comments in any language. Both matter:
- "5/5" / "amazing" / "always order" → top preference
- "4/5" / "good" → preferred
- "2-3/5" / "ok" / "a bit X" → deprioritize
- "1/5" / "never again" / "超级咸" → hard exclude (even without number)
- Free-text option notes ("always purple rice") → apply when modal opens

If multiple comments diverge across dates, trust the most recent.

When a review influences a decision, mention it:
> Skipping Spicy Hot Pot — review notes "too oily, didn't finish" (2026-05-15).

### Plan Output

```
📋 Order Plan — Mon May 25 – Fri May 29

📅 Mon May 25, Lunch — $30.00 budget
  - Xiangchuan Kitchen — Mongolian Beef Bento × 1 — $17.45
  - Northwest China Cuisine — Tea Egg × 3 — $7.35   ($2.45 × 3)
  - Mediterranean Grill House — Taboulleh Salad × 1 — $5.95
  Total: $30.75 ❌ → drop one Tea Egg → $28.30 ✓
```

---

## Step 4b: Validate Budget (if `validate_budget: true`)

```bash
uv run --no-project python -c "
items = [(17.45, 1), (2.45, 2), (5.95, 1)]  # (unit_price, quantity)
budget = 30.0
total = sum(p * q for p, q in items)
assert total <= budget, f'Over budget: \${total:.2f} > \${budget:.2f}'
print(f'OK: \${total:.2f} / \${budget:.2f}')
"
```

If assertion fails: remove most expensive non-essential item, re-validate.

---

## Step 5: Confirm or Proceed

**Auto mode** (`confirm_before_order: false`, default): Print plan, proceed immediately. Pause only for unresolvable ambiguity, errors, out-of-window dates.

**Confirm mode** (`confirm_before_order: true`):
```
Does this plan look good? Say "yes" to confirm, or tell me what to change.
```
Wait for reply, apply changes, re-confirm once before proceeding.

---

## Step 6: Save Plan to Order History

Before touching any cart, write each planned slot to `~/Documents/WeBox/order-history.md` with status `📝 planned`. After successful checkout, update to `✅ #ORDERNUM`.

### Order History Format

```markdown
# WeBox Order History
last_synced: YYYY-MM-DD

<!-- Long-term record. Recent entries (within history_window_days) are loaded for variety tracking. -->

## 2026-05

### Mon 05/25 Lunch ✅ #3258700 — $28.30
- Xiangchuan Kitchen — Mongolian Beef Bento × 1 — $17.45
- Northwest China Cuisine — Tea Egg × 2 — $4.90
- Mediterranean Grill House — Taboulleh Salad × 1 — $5.95

### Mon 05/25 Dinner 📝 planned — $20.25
- Ox 9 Lanzhou — Sliced Spicy Beef 8oz × 1 — $12.35
- Horizon — Organic Milk × 2 — $7.90
```

Status icons:
- `✅` ordered (with order number)
- `📝` planned (not yet placed)
- `↩️` refunded (slot OPEN for re-order)
- `🚫` cancelled (slot OPEN for re-order)
- `⏰` cutoff passed
- `🔒` outside 7-day window

---

## Step 7: Add Items to Cart (one item at a time)

Navigate to the date+meal URL before adding. Each date's cart is independent — switching the date URL resets cart context.

### Critical: handle items ONE AT A TIME

The biggest pitfall: chaining multiple add-to-cart clicks in one JS scope breaks when an item opens a modal mid-loop (subsequent clicks hit modal background, not the next item). **Each item must be its own discrete add operation** with explicit modal handling between.

### Per-item add helper

```javascript
(async () => {
  const targetName = 'ITEM_NAME_HERE';   // partial match, case-insensitive
  const qty = 1;
  const SELECTORS = 'app-product-menu-item.menu-section-product-item, .new-menu-product-item';
  const items = [...document.querySelectorAll(SELECTORS)];
  const match = items.find(item => {
    const title = item.querySelector('.product-menu-title');
    return title && title.innerText.toLowerCase().includes(targetName.toLowerCase());
  });
  if (!match) return { status: 'item_not_found' };
  // Two button types: .btn.plus-add (most items) or .product-add-wrapper (items with required options)
  const btn = match.querySelector('.btn.plus-add') || match.querySelector('.product-add-wrapper');
  if (!btn) return { status: 'no_button' };
  btn.click();
  await new Promise(r => setTimeout(r, 1000));
  const modal = document.querySelector('[class*="product-detail-header"]');
  if (modal) {
    return { status: 'modal_opened', qty_remaining: qty };
  }
  // No modal — increment further if qty > 1
  for (let i = 1; i < qty; i++) {
    btn.click();
    await new Promise(r => setTimeout(r, 400));
  }
  return { status: `added_direct_x${qty}` };
})()
```

If result is `modal_opened`:

```javascript
(async () => {
  // Check items-with-options.md cache for this item's preferred option (read separately first)
  // Click "Add to Cart" inside modal
  document.querySelector('st-button.add-button')?.click();
  await new Promise(r => setTimeout(r, 1000));
  // Close modal (does NOT auto-close)
  document.querySelector('.anticon.anticon-close, [class*="ant-modal-close"]')?.click();
  await new Promise(r => setTimeout(r, 600));
  return { modalGone: !document.querySelector('[class*="product-detail-header"]') };
})()
```

If qty > 1 and the item had a modal: after adding the first unit, navigate to `/checkout` and use the cart's qty stepper:

```javascript
(async () => {
  const targetName = 'ITEM_NAME_HERE';
  const targetQty = 3;
  const steppers = [...document.querySelectorAll('.input-number-wrapper.isCart')];
  const stepper = steppers.find(s => {
    const card = s.closest('[class*="cart-item"], [class*="cart-product"]') || s.parentElement?.parentElement;
    return card?.innerText.toLowerCase().includes(targetName.toLowerCase());
  });
  if (!stepper) return 'item not in cart';
  const currentQty = parseInt(stepper.querySelector('input')?.value || '0', 10);
  const diff = targetQty - currentQty;
  for (let i = 0; i < Math.abs(diff); i++) {
    const btn = stepper.querySelector(diff > 0 ? '.btn.plus' : '.btn.minus:not(.unable)');
    btn?.click();
    await new Promise(r => setTimeout(r, 350));
  }
  return `qty set to ${stepper.querySelector('input')?.value}`;
})()
```

### items-with-options cache

Before clicking the modal's "Add to Cart", check `~/Documents/WeBox/items-with-options.md` to see if this item has a known preferred option. Format:
```markdown
- [Brand] [Item Name] — options: "Choose Rice" (single, default: White Rice) — chosen: Purple Rice — date: YYYY-MM-DD
```

If cached, find and click the matching option in the modal before clicking Add to Cart. Otherwise, accept the default pre-selected option.

After a new options-modal encounter, append to the cache. Create file if missing.

### Complex options (5+ option groups)

This is the only case where computer use is justified. Take a screenshot, use judgment to select reasonable options, then run the modal-add JS above.

### Item not found / sold out at cart time

1. Re-scrape the slot's menu (force cache miss)
2. Pick a substitute from the cached menu items meeting the same criteria
3. Note the substitution inline in `order-history.md`:
   ```
   ### Mon 05/25 Lunch ✅ #XXX — was: Mongolian Beef (sold out → Sliced Spicy Beef)
   ```

---

## Step 8: Checkout (pure JS, 2 clicks)

```javascript
(async () => {
  // 1. Cart icon click → navigates to /checkout
  document.querySelector('a.cart.fr')?.click();
  await new Promise(r => setTimeout(r, 2500));
  if (location.pathname !== '/checkout') return { status: 'failed_to_reach_checkout' };

  // 2. Cart-vs-plan verification
  const lineItems = [...document.querySelectorAll('.input-number-wrapper.isCart')].map(s => {
    const card = s.closest('[class*="cart-item"], [class*="cart-product"]') || s.parentElement?.parentElement;
    return {
      name: card?.querySelector('[class*="name"], [class*="title"]')?.innerText?.trim(),
      qty: s.querySelector('input')?.value
    };
  });
  return { status: 'at_checkout', lineItems };
})()
```

**Cart drift check:** compare `lineItems` against the planned items for this slot. If they don't match (different items, qtys, or unexpected additions from a modal default), STOP and report to the user. Don't blindly Place Order.

If everything matches:
```javascript
(async () => {
  document.querySelector('.place-btn')?.click();
  await new Promise(r => setTimeout(r, 3000));
  const success = /\/order\/finish\/\d+/.test(location.pathname);
  const orderNumber = location.pathname.match(/\/order\/finish\/(\d+)/)?.[1];
  return { success, orderNumber, url: location.pathname };
})()
```

After success, immediately update `~/Documents/WeBox/order-history.md`:
- `📝 planned` → `✅ #ORDERNUM`
- Update total if different from planned

```
✅ Order placed! Order #XXXXXXX
   Mon May 25, Lunch — $28.30
```

---

## Step 9: Repeat for Each Slot

Repeat Steps 7–8 per date+meal in the plan. Slots are independent — different carts.

For multiple slots: consider opening one tab per slot for parallel execution (3–5 concurrent). Each tab adds its items and checks out separately.

Final summary:
```
🎉 All done!

  Mon May 25 Lunch  $28.30 ✅ #XXXXXXX
  Mon May 25 Dinner $20.25 ✅ #XXXXXXX
  Tue May 26 Lunch  $29.50 ✅ #XXXXXXX
```

---

## Step 10: Post-Order Feedback

If the user hasn't given feedback this session, invite it:
> Done! Any feedback on dishes you've tried — good or bad — just tell me. Free-form is fine: "too dry", "loved it", "这个超级咸", etc.

Parse feedback and append to `~/Documents/WeBox/item-reviews.md`. Create the file if missing.

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

Append dated comments rather than overwriting. Only update Rating if user gives a number explicitly.

---

## DOM Reference (Verified 2026-05-20 end-to-end)

### Menu pages
| Selector | Purpose |
|----------|---------|
| `app-product-menu-item.menu-section-product-item, .new-menu-product-item` | Product card |
| `.product-item-content-wrapper` | Content area |
| `.brand-wrapper` | Brand name |
| `.product-menu-title` | Item name (clean text — don't use parent wrappers) |
| `.product-price` | Price text e.g. "$17.55" |
| `.product-menu-new-and-rating-wrapper` | Rating (first line is score) |
| `.product-menu-top-sold-out-wrapper` | Sold-out — element is ALWAYS in DOM; check `getComputedStyle(el).display !== 'none'` |
| `.btn.plus-add` | Add for most items (DIV, not `<button>`) |
| `.product-add-wrapper` | Add for items with required options (SPAN, always opens modal) |

### Options modal
| Selector | Purpose |
|----------|---------|
| `[class*="product-detail-header"]` | Modal-open indicator |
| `st-button.add-button` | "Add to Cart" inside modal |
| `.anticon.anticon-close` | Close icon — modal does NOT auto-close after Add to Cart |

### Header / cart
| Selector | Purpose |
|----------|---------|
| `a.cart.fr` | Cart icon. Click → navigates to `/checkout` |
| `.cart-count` | Header cart count text "X items" |

### Checkout page (`/checkout`)
| Selector | Purpose |
|----------|---------|
| `.input-number-wrapper.isCart` | Qty stepper per line item |
| `.btn.plus` / `.btn.minus` (inside stepper) | Increment / decrement qty |
| `.btn.minus.unable` | Disabled state at minimum |
| `.place-btn` | Place Order button (DIV, first matching one works) |
| `button` with text "Remove" | Confirmation modal when decrementing qty to 0 |

### Order list (`/order/list/normal`)
| Selector | Purpose |
|----------|---------|
| `.order-item` | One per order |
| `.order-id` | "No.3258614" |
| `.order-status` | "Refunded" / "Cancelled" / "Paid" / absent (= active) |

Note: active/paid orders show meal text as "Dinner (Delivered at 5:49 PM)" — that's why the meal regex uses `(\s|\(|$)` after the meal name.

### Success URL
After successful checkout, URL = `/order/finish/<NUMBER>`.

---

## Error Handling

| Situation | Response |
|-----------|----------|
| Item not found in DOM | Re-scrape, then substitute from cached menu |
| Sold out at cart time | Re-scrape, pick substitute, note inline in history |
| Budget exceeded mid-plan | Drop most expensive non-essential, re-plan |
| Cart drift at checkout | STOP, report to user, don't auto-place |
| Modal with 5+ option groups | Screenshot + judgment + run modal-add JS |
| Page hangs / CDP timeout | Wait 3s, retry once; skip slot if still failing |
| Outside 7-day window | Skip silently, note in summary |
| Favorites returns 0 items | Augment with category scrapes (Step 3c) |
| Favorites blocked / rate-limited | Hand off to `webox-order-all` |
| 3+ scrapes fail in a row | Ask user to wait 60s |
| Cache file malformed | Treat as missing, re-scrape |
| New user, no order history | Continue with empty variety state |
