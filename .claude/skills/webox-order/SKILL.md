---
name: webox-order
description: Autonomously order food from WeBox (webox.com) using the user's logged-in Chrome session. Scrapes menus, checks existing orders, selects items within budget based on user preferences, adds to cart, and checks out. Use when the user asks to order food on WeBox for specific dates/meals.
---

# WeBox Order Skill

Data directory: `~/Documents/WeBox/`  
All user data files are plain text — open in any editor or Finder.

## JS-First Principle

**Always prefer JavaScript over computer use for any operation that can be done in JS.** JS is dramatically faster, more reliable, and works in background tabs. Use computer use (screenshots, clicks by coordinate, `find` tool) ONLY when there's no DOM-based alternative — i.e., for visually complex modals with 5+ option groups that need model judgment.

This skill enumerates verified DOM selectors and JS snippets for every step of the ordering flow. Do not fall back to clicking by coordinate or using the `find` tool when a JS selector is documented below.

## Defaults

- **Meal types:** When not specified, order both **Lunch and Dinner** per day (separate cart/checkout each).
- **Weekends:** Skip Saturday and Sunday for multi-day ranges unless explicitly requested.
- **Confirmation mode:** Default `auto` — order without asking, pause only on errors or ambiguity. Set `confirm_before_order: true` for plan-first mode.

## WeBox Constraints

- **7-day window:** Can only order up to 7 days ahead.
- **Meal cutoffs:** Lunch has a mid-morning cutoff. Skip slots where cutoff has passed.
- **Budget per slot:** Each date+meal is a separate checkout. Budget applies per slot.

---

## Step 0: Prerequisite Check

1. **Chrome connected?** Call `tabs_context_mcp`. If no tabs, stop:
   > Claude in Chrome doesn't seem to be connected. Make sure Chrome is running with the [Claude in Chrome extension](https://code.claude.com/docs/en/chrome) enabled.

2. **Preferences exist?** Check `~/Documents/WeBox/preferences.md`. If missing, stop:
   > You haven't set up WeBox yet. Run `/webox-onboard` first (or say "set up WeBox") — takes about 2 minutes.

---

## Step 1: Load Preferences and History

### 1a. Preferences
Read `~/Documents/WeBox/preferences.md`. Extract:
- `budget`, `budget_mode`, `validate_budget`
- `confirm_before_order`
- `default_meals`, `skip_weekends`
- `avoid_repeat_days` (default: 7), `history_window_days` (default: 28 — ~3 weeks past + 7-day future window)
- `allow_repeat_categories`, `allow_repeat_patterns` — items matching these are exempt from variety rules (fillers like milk, water, salad, eggs that the user wants to repeat freely)
- `category_mode` (all | whitelist | blacklist), `category_list`
- Dietary restrictions, allergens, preferred/avoided cuisines, drinks

### 1b. Item reviews
Read `~/Documents/WeBox/item-reviews.md` if it exists. Keep loaded for Step 4.

### 1c. Order history (variety + slot occupancy)
Read `~/Documents/WeBox/order-history.md`. This single file serves two purposes:
- **Slot occupancy:** which date+meal slots are already ordered (skip them)
- **Variety tracking:** what items were ordered recently (avoid repeating within `avoid_repeat_days`)

Only load entries within the past `history_window_days` and any future planned entries into context. Older entries stay in the file but are not loaded.

If `last_synced` is more than 1 day old → re-scrape order history (Step 2) before proceeding.
If file is malformed or missing → treat as missing and re-scrape.

### 1d. Favorites cache
Read `~/Documents/WeBox/favorites-cache.md`:
- Fresh (≤ 7 days) → use as-is, skip scraping
- Stale or missing → scrape (Step 3), update the file
- Malformed → treat as missing, re-scrape

To force a refresh, dispatch `webox-sync-favorites` skill (say "refresh my favorites").

---

## Step 2: Sync Order History (if stale)

*Skip if `order-history.md` is fresh (Step 1c).*

Navigate to `https://www.webox.com/order/list/normal`. The page uses infinite scroll:

```javascript
(async () => {
  // Smart scroll: stop early when no new items load.
  let lastCount = 0, stable = 0;
  for (let i = 0; i < 8; i++) {
    window.scrollTo(0, document.body.scrollHeight);
    await new Promise(r => setTimeout(r, 350));
    const cnt = document.querySelectorAll('.order-item').length;
    if (cnt === lastCount) { if (++stable >= 2) break; } else { stable = 0; }
    lastCount = cnt;
  }
  const orders = [...document.querySelectorAll('.order-item')].map(o => {
    // Structured selectors (preferred)
    const orderId = o.querySelector('.order-id')?.innerText?.trim();       // "No.3258614"
    const orderStatus = o.querySelector('.order-status')?.innerText?.trim(); // "Refunded" | "Cancelled" | absent (= active)
    // Date and meal aren't in dedicated selectors; extract from text
    const lines = o.innerText.split('\n').map(l => l.trim()).filter(Boolean);
    const dateLine = lines.find(l => /^(Mon|Tue|Wed|Thu|Fri|Sat|Sun)\s+\d{2}\/\d{2}$/.test(l));
    const mealLine = lines.find(l => /^(Lunch|Dinner|HappyHour)(\s|\(|$)/.test(l));
    const meal = mealLine?.match(/^(Lunch|Dinner|HappyHour)/)?.[1];
    // Item lines: skip metadata / descriptions / prices / refund flags
    const itemLines = lines.filter(l =>
      l !== dateLine && l !== mealLine && l !== orderId && l !== orderStatus &&
      !/^(Order|Invoice|Details|Reorder|Cancel|View|Track|Total:|Refunded|No\.\d)/i.test(l) &&
      !/^\$/.test(l) && l.length > 3
    );
    // active = the slot is taken; refunded/cancelled slots are open for re-ordering
    const isActive = !orderStatus || !/refund|cancel/i.test(orderStatus);
    return { date: dateLine, meal, orderId, orderStatus: orderStatus || 'active', isActive, items: itemLines };
  }).filter(o => o.date && o.meal);
  return JSON.stringify(orders);
})()
```

**Slot-occupancy rule:** Only orders with `isActive: true` block their slot. A slot with a `Refunded` or `Cancelled` order is treated as **open** — the user can re-order it.

Merge into `~/Documents/WeBox/order-history.md`:
- Add new ordered slots (don't overwrite existing entries — local data may have more detail than the scrape)
- Update `last_synced` line
- If the scrape returns empty (new user, no orders), write a `# Order History\nlast_synced: DATE\n\n<!-- No orders yet -->` placeholder

Skip any target date+meal already in the history.

---

## Step 3: Scrape Menu

### URL Reference

**Favorites (primary):**
```
https://www.webox.com/menu/section/My%20Favorites?date=YYYY-MM-DD&shippingTime=Lunch
```
Replace `Lunch` with `Dinner` for dinner. Favorites list is the same for both shippingTimes — scrape once per date.

**Full menu:**
```
https://www.webox.com/?date=YYYY-MM-DD&shippingTime=Lunch
```

**By category** (`objId`/`objName` = URL-encoded category name):
```
https://www.webox.com/?date=YYYY-MM-DD&shippingTime=Lunch&objType=CUISINE&objId=CATEGORY&objName=CATEGORY
```

**All categories** (use these exact URL values):

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

### Category Filter (whitelist / blacklist)

Apply `category_mode` from preferences:
- `all` → consider all categories when expanding beyond favorites
- `whitelist` → only consider categories in `category_list`
- `blacklist` → consider all categories EXCEPT those in `category_list`

The user's `preferred_cuisines` always takes priority — if "Chinese" is in `preferred_cuisines`, scrape Chinese even if not in the whitelist (assume the user wants it).

### Scraping Function

```javascript
(async () => {
  const SELECTORS = 'app-product-menu-item.menu-section-product-item, .new-menu-product-item';
  // Smart scroll with early termination
  let lastCount = 0, stable = 0;
  for (let i = 0; i < 12; i++) {
    window.scrollTo(0, document.body.scrollHeight);
    await new Promise(r => setTimeout(r, 350));
    const cnt = document.querySelectorAll(SELECTORS).length;
    if (cnt === lastCount) { if (++stable >= 2) break; } else { stable = 0; }
    lastCount = cnt;
  }
  return [...document.querySelectorAll(SELECTORS)].map(item => {
    const wrapper = item.querySelector('.product-item-content-wrapper');
    const brand = wrapper?.querySelector('.brand-wrapper')?.innerText?.trim();
    const name = wrapper?.querySelector('.product-menu-title')?.innerText?.trim();
    const priceText = wrapper?.querySelector('.product-price')?.innerText?.trim();
    const price = parseFloat(priceText?.replace('$', '') || '0');
    const rating = wrapper?.querySelector('.product-menu-new-and-rating-wrapper')?.innerText?.trim().split('\n')[0];
    const soldOutEl = item.querySelector('.product-menu-top-sold-out-wrapper');
    const soldOut = soldOutEl ? getComputedStyle(soldOutEl).display !== 'none' : false;
    return { brand, name, price, priceText, rating, soldOut };
  }).filter(i => i.name && !i.soldOut);
})()
```

### Parallel Scraping (multi-tab strategy)

When scraping multiple dates or categories, **open separate tabs in parallel** rather than navigating sequentially in one tab:

```
For each date or category to scrape:
  1. tabs_create_mcp → new tabId
  2. navigate that tab to the target URL
  3. (don't wait — kick off next tab immediately)

Then for each tab:
  4. run scraping JS once the page is loaded
  5. tabs_close_mcp when done
```

Practical limit: 3–5 concurrent tabs. Cuts total scraping time roughly N×.

### What to Scrape — Decision Tree

1. **Menu cache hit?** Check `~/Documents/WeBox/menu-cache/YYYY-MM-DD-Meal.json` first. If it exists and is < 60 minutes old, use it — no scraping needed. This makes **replan** instant: after ordering, if the user says "actually I don't like that, replan with something else", you have the full menu already cached.

2. **Favorites first** (use favorites-cache if fresh; scrape if stale). Covers all meal slots for that date.

3. **If favorites returns 0 items** (or insufficient given budget): fall back to category pages.
   - Use `category_mode` + `category_list` to pick which categories.
   - Always include `preferred_cuisines`.
   - Skip anything in `cuisines_to_avoid`.

4. **If user prompt requests specific cuisine** ("I want Thai today"): the cuisine constraint applies to the **main dish only**. Fillers (drinks, sides, fruit, eggs, milk) come from any category and are used to fill the budget.
   - Scrape the requested cuisine for the main.
   - Also scrape filler-eligible categories (Drink, Side, Snack, Dairy & Eggs, Produce) for budget-filling.
   - Don't restrict fillers to match the main's cuisine — Chinese tea + Thai curry + general fruit is a fine plan.

5. **After scraping (any mode)**: **deduplicate** by `(brand, name)` key — the same dish can appear in multiple categories (e.g., a Chinese snack shows in both `Chinese` and `Snack`). Keep one copy per (brand, name), but record all source categories in the cached item's `categories` array.

6. **Cache the result** to `~/Documents/WeBox/menu-cache/YYYY-MM-DD-Meal.json`:
   ```json
   {
     "cached_at": "2026-05-20T21:30:00",
     "date": "2026-05-21",
     "meal": "Lunch",
     "sources": ["favorites", "Chinese", "Drink"],
     "items": [
       {"brand": "...", "name": "...", "price": 17.45, "rating": 4.5, "categories": ["favorites", "Chinese"]}
     ]
   }
   ```
   `categories` records which sources surfaced the item (for debugging / explanation). The menu-cache directory should be created if it doesn't exist.

### Menu Cache Hygiene

- TTL: 60 minutes (menus can change as items sell out)
- Auto-prune: when loading, drop cache files older than 24 hours
- The cache is per-slot; multiple cached slots can coexist
- If the user explicitly says "re-scrape" or "refresh menu", ignore the cache and re-fetch

---

## Step 4: Build the Full Order Plan

Build all-days plan before touching cart.

### Budget Rules
- `spend-up-to` (default): aim to use most of the budget per slot; prioritize variety
- `ceiling-only`: pick what looks best without filling the budget
- Cap is on food item totals (not delivery fees or tax)

### Quantity Handling
Items can be ordered in quantities > 1 (e.g., 6 tea eggs, 10 milks). Represent as `× N`:
```
- Northwest China Cuisine — Tea Egg × 6 — $14.70   ($2.45 × 6)
```
Budget validation must multiply unit price × quantity.

### Selection Priority

1. **Hard constraints (never violate):**
   - Dietary restrictions, allergens
   - Items rated 1/5 or tagged `never-again` in reviews
   - Strongly-negative review comments (e.g., "这个超级咸", "肉太少", "inedible") → treat as hard exclude even without rating
   - Budget cap (including quantities)

2. **Strong preferences:**
   - Items rated 4–5/5 or with consistently positive comments → top candidates
   - User's prompt constraints
   - `preferred_cuisines` from preferences

3. **Variety (main dishes only):**
   - Variety rules apply ONLY to **main dishes** (entrées, bowls, bento, noodles, hot pots — the focal item of a meal).
   - Items in `allow_repeat_categories` (Drink, Side, Snack, Dairy & Eggs, Produce by default) and items matching `allow_repeat_patterns` (milk, water, tea egg, etc.) are treated as **fillers** and are EXEMPT from variety rules. They can repeat day after day, and ordering multiple of the same (e.g., 5 waters) is fine.
   - For mains: avoid items ordered within `avoid_repeat_days` (check recent entries in `order-history.md`)
   - Cross-day variety within this session: don't pick the same main twice across consecutive days

4. **Soft preferences:**
   - WeBox favorites > non-favorites
   - Fill remaining budget with complementary fillers (sides, drinks) if `spend-up-to`
   - If the user clearly wants to stock up on a filler ("get me 10 milks for the week"), spread the quantity across days OR put them all in one slot — use judgment based on prompt phrasing.

### Item Reviews — How to Read Them

Reviews mix structured fields (rating, tags) with **free-form natural-language comments**. Both matter:

- **Rating** (when present): 5/5 = strong prefer, 1/5 = hard exclude
- **Comments** (always weighted): synthesize sentiment yourself
  - "超级咸" / "too salty" / "inedible" → hard exclude (treat as 1/5)
  - "肉太少" / "small portion" → deprioritize, only pick if budget forces
  - "love this" / "amazing" / "always order" → top preference
  - "好吃但有点贵" / "good but pricey" → consider price-performance
- **Multiple comments stack:** if comments diverge across dates (loved it once, hated it later), trust the most recent
- **No rating, only comments:** infer sentiment; don't ignore the item just because no number was given

When selection is influenced by a review, mention it in plan reasoning:
> Skipping Spicy Hot Pot — review says "too oily, didn't finish" (2026-05-15).

### Plan Format

```
📋 Order Plan — Mon May 25 – Fri May 29

📅 Mon May 25, Lunch — $30.00 budget
  - Xiangchuan Kitchen — Mongolian Beef Bento × 1 — $17.45
  - Northwest China Cuisine — Tea Egg × 3 — $7.35  ($2.45 × 3)
  - Mediterranean Grill House — Taboulleh Salad × 1 — $5.95
  Total: $30.75 ❌  → over budget, drop Tea Egg × 1 → $28.30 ✓
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

If assertion fails: remove the most expensive non-essential item and re-validate.

---

## Step 5: Confirm or Proceed

**Auto mode** (default): Print plan, proceed immediately. Pause only for unresolvable ambiguity, errors, or out-of-window dates.

**Confirm mode** (`confirm_before_order: true`):
```
Does this plan look good? Say "yes" to confirm, or tell me what to change.
```
Wait for reply, apply changes, re-confirm once before proceeding.

---

## Step 6: Save Plan to Order History

Write the plan to `~/Documents/WeBox/order-history.md` before any cart action. Use the unified format below — each slot is one entry, marked `📝 planned` initially, updated to `✅ ordered` after checkout.

### Unified Order History Format

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

### Tue 05/26 Lunch ⏰ cutoff passed — not ordered

### Wed 05/27 Lunch ✅ #3258742 — $25.95 (was: Mongolian Beef × 1, sold out → substituted Sliced Spicy Beef)
- Ox 9 Lanzhou — Sliced Spicy Beef 8oz × 1 — $12.35
- Mediterranean Grill House — Taboulleh Salad × 1 — $5.95
- Northwest China Cuisine — Tea Egg × 3 — $7.35
```

Status icons:
- `✅` ordered (with order number)
- `📝` planned (not yet placed)
- `⏰` cutoff passed
- `🚫` skipped (sold out, no substitute, user cancelled, etc.)
- `🔒` outside 7-day window

Rules:
- Append new slots; never overwrite existing entries
- Update status from `📝` to `✅` after checkout, set the order number and actual total
- Note substitutions inline (e.g., "was: X, sold out → substituted Y")
- Older entries stay forever (long-term record); only the recent window is loaded into context

---

## Step 7: Add Items to Cart

Navigate to the date+meal URL before adding. Each cart is per-slot.

### Add Item Script

```javascript
(async () => {
  const targetName = 'ITEM_NAME_HERE'; // partial match, case-insensitive
  const qty = 1;
  const SELECTORS = 'app-product-menu-item.menu-section-product-item, .new-menu-product-item';
  const items = [...document.querySelectorAll(SELECTORS)];
  const match = items.find(item => {
    const title = item.querySelector('.product-menu-title');
    return title && title.innerText.toLowerCase().includes(targetName.toLowerCase());
  });
  if (!match) return 'item_not_found';
  const btn = match.querySelector('.btn.plus-add') || match.querySelector('.product-add-wrapper');
  if (!btn) return 'no_button_found';
  for (let i = 0; i < qty; i++) {
    btn.click();
    await new Promise(r => setTimeout(r, 350));
  }
  const modal = document.querySelector('[class*="product-detail-header"]');
  return modal ? 'modal_opened' : `added_directly_x${qty}`;
})()
```

**Quantity > 1:** Click `qty` times (the `+` increments the counter). For items with required-options modals, click "Add to Cart" once, then use the cart's `+` stepper for additional units.

**If `no_button_found`:** Debug:
```javascript
(async () => {
  const items = [...document.querySelectorAll('app-product-menu-item.menu-section-product-item, .new-menu-product-item')];
  const match = items.find(i => i.querySelector('.product-menu-title')?.innerText?.includes('SEARCH_TERM'));
  if (!match) return 'no match';
  return [...match.querySelectorAll('[class*="plus"],[class*="add"],[class*="btn"],[role="button"],button')]
    .map(b => b.tagName + '.' + b.className.slice(0, 60)).join(' | ');
})()
```

### Handling Options Modal (pure JS — no computer use needed)

When `addItem(...)` returns `modal_opened`:

1. **Check the items-with-options cache** at `~/Documents/WeBox/items-with-options.md`. If this item is cached with a specific option, find and click the matching option radio first.

2. **Click "Add to Cart" inside the modal:**
```javascript
document.querySelector('st-button.add-button')?.click();
await new Promise(r => setTimeout(r, 800));
```

3. **Close the modal:** (The modal does NOT auto-close after Add to Cart — must close explicitly.)
```javascript
document.querySelector('.anticon.anticon-close')?.click();
await new Promise(r => setTimeout(r, 350));
```

4. **Verify item added:**
```javascript
const cartCount = document.querySelector('.cart-count')?.innerText;
const modalGone = !document.querySelector('.product-detail-header');
```

5. **Record the new options encounter** by appending to `~/Documents/WeBox/items-with-options.md`:
```
- [Brand] [Item Name] — options: "Choose Rice" (single, default: White Rice) — chosen: White Rice — date: YYYY-MM-DD
```
Create the file if missing.

**Complex options (5+ option groups, build-your-own bowls)** — this is the ONLY case where computer use is justified: take a screenshot, use model judgment to select reasonable options, then run the JS Add-to-Cart + close above.

### Setting Quantity After Add (cart-side stepper)

If you couldn't loop the `.btn.plus-add` for qty > 1 (e.g., item had a modal), navigate to `/checkout` and use the cart's qty stepper:

```javascript
// Find the stepper for a specific item by name
(async () => {
  const targetName = 'ITEM_NAME_HERE';
  const steppers = [...document.querySelectorAll('.input-number-wrapper.isCart')];
  // Each stepper sits next to its item name
  const stepper = steppers.find(s => {
    const card = s.closest('[class*="cart-item"], [class*="cart-product"]') || s.parentElement?.parentElement;
    return card && card.innerText.toLowerCase().includes(targetName.toLowerCase());
  });
  if (!stepper) return 'item not in cart';
  const currentQty = parseInt(stepper.querySelector('input')?.value || '0', 10);
  const targetQty = 3; // desired final qty
  const diff = targetQty - currentQty;
  for (let i = 0; i < Math.abs(diff); i++) {
    const btn = stepper.querySelector(diff > 0 ? '.btn.plus' : '.btn.minus:not(.unable)');
    btn?.click();
    await new Promise(r => setTimeout(r, 350));
  }
  return `qty set to ${stepper.querySelector('input')?.value}`;
})()
```

### Remove Item from Cart

Decrementing qty to 0 triggers a confirmation modal. Handle it:

```javascript
(async () => {
  const stepper = [...document.querySelectorAll('.input-number-wrapper.isCart')]
    .find(s => s.closest('[class*="cart-item"], [class*="cart-product"]')?.innerText.toLowerCase().includes('ITEM_NAME'));
  if (!stepper) return 'not found';
  // Decrement to 1 first if needed, then once more to trigger confirm
  while (parseInt(stepper.querySelector('input')?.value || '0', 10) > 1) {
    stepper.querySelector('.btn.minus')?.click();
    await new Promise(r => setTimeout(r, 300));
  }
  stepper.querySelector('.btn.minus')?.click();
  await new Promise(r => setTimeout(r, 800));
  const removeBtn = [...document.querySelectorAll('button')].find(b => /^Remove$/i.test((b.innerText || '').trim()));
  removeBtn?.click();
  return 'removed';
})()
```

### Item Not Found

1. Try category URL and re-scrape
2. If still missing, substitute with next-best from plan; note substitution inline in `order-history.md`

---

## Step 8: Checkout (pure JS — no computer use needed)

Two JS clicks place the order:

```javascript
(async () => {
  // 1. Click cart icon — navigates to /checkout
  document.querySelector('a.cart.fr')?.click();
  await new Promise(r => setTimeout(r, 2500));
  if (location.pathname !== '/checkout') return 'failed to reach checkout';

  // 2. Verify cart contents match plan before placing
  const lineItems = [...document.querySelectorAll('.input-number-wrapper.isCart')].map(s => ({
    name: s.closest('[class*="cart-item"], [class*="cart-product"]')?.querySelector('[class*="name"], [class*="title"]')?.innerText?.trim(),
    qty: s.querySelector('input')?.value
  }));
  // If lineItems doesn't match the plan, abort and report — don't place an off-plan order.

  // 3. Click Place Order
  const placeBtn = document.querySelector('.place-btn');
  placeBtn?.click();
  await new Promise(r => setTimeout(r, 3000));

  // 4. Verify success — URL should be /order/finish/<NUMBER>
  const success = /\/order\/finish\/\d+/.test(location.pathname);
  const orderNumber = location.pathname.match(/\/order\/finish\/(\d+)/)?.[1];
  return JSON.stringify({ success, orderNumber, url: location.pathname });
})()
```

After success, **immediately** update `~/Documents/WeBox/order-history.md`:
- Change `📝 planned` → `✅ #ORDERNUM`
- Update total if it differs from planned

```
✅ Order placed! Order #XXXXXXX
   Mon May 25, Lunch — $28.30
```

---

## Step 9: Repeat for Each Slot

Repeat Steps 7–8 per date+meal. Final summary:

```
🎉 All done!

  Mon May 25 Lunch  $28.30 ✅ #XXXXXXX
  Mon May 25 Dinner $20.25 ✅ #XXXXXXX
  ...
```

---

## Step 10: Post-Order Feedback

Invite reviews if no feedback was given this session:
> Done! Any feedback on dishes you've tried — good or bad — just tell me. Free-form is fine: "the Mongolian beef was too dry", "loved the salad", etc.

Parse any feedback and append to `~/Documents/WeBox/item-reviews.md`. Create the file if missing.

### Item Review Format

Reviews are flexible. Comments can be free-form natural language in any language. Rating is optional.

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
Inferred: hard exclude (consistently negative).

## Ox 9 Lanzhou — Cold Noodles
Rating: 4/5
Comments:
- 2026-05-18: Good but the broth was lukewarm — maybe avoid in winter.
```

When the user gives feedback:
- New item → append a new `## Brand — Item Name` section
- Existing item → append a dated comment to its `Comments:` list
- Don't overwrite past comments; let them stack as a timeline
- Update rating only if user explicitly gives a number; otherwise infer sentiment in selection logic

---

## DOM Reference (Verified 2026-05-20 via end-to-end testing)

### Menu pages
| Selector | Purpose |
|----------|---------|
| `app-product-menu-item.menu-section-product-item, .new-menu-product-item` | Product card |
| `.product-item-content-wrapper` | Content area |
| `.brand-wrapper` | Brand name |
| `.product-menu-title` | Item name (clean text) |
| `.product-price` | Price text e.g. "$17.55" |
| `.product-menu-new-and-rating-wrapper` | Rating (first line is the score) |
| `.product-menu-top-sold-out-wrapper` | Sold-out flag — use `getComputedStyle(el).display !== 'none'` (the element is ALWAYS in the DOM) |
| `.btn.plus-add` | Add-to-cart for most items (DIV, not `<button>`) |
| `.product-add-wrapper` | Add-to-cart for items with required options (SPAN, always opens modal) |

### Options modal
| Selector | Purpose |
|----------|---------|
| `.product-detail-header` | Modal-open indicator (exists when modal is open) |
| `st-button.add-button` | "Add to Cart" button inside the modal |
| `.anticon.anticon-close` | Close-X button. Modal does NOT auto-close after Add to Cart — click this explicitly. |

### Header / cart
| Selector | Purpose |
|----------|---------|
| `a.cart.fr` | Cart icon in top-right. Click → navigates to `/checkout`. |
| `.cart-count` | Text "X items" in header |

### Checkout page (`/checkout`)
| Selector | Purpose |
|----------|---------|
| `.input-number-wrapper.isCart` | Qty stepper container per cart line item |
| `.btn.plus` (inside stepper) | Increment qty |
| `.btn.minus` (inside stepper) | Decrement qty. Class `.unable` added when at min. |
| `.input-number-wrapper input` | Reads current qty as `.value` |
| `.place-btn` | "Place Order" button (DIV; multiple instances on page — first one works) |
| `button` with text "Remove" | Confirmation modal that appears when decrementing qty to 0 |

### Order list (`/order/list/normal`)
| Selector | Purpose |
|----------|---------|
| `.order-item` | One per order |
| `.order-id` | Order number text e.g. "No.3258614" |
| `.order-status` | "Refunded" / "Cancelled" / absent (= active). Refunded/cancelled = slot is OPEN. |

### After successful checkout
- URL changes to `/order/finish/<ORDER_NUMBER>` — parse the number from the URL.

## Parallel Multi-Tab Execution

For multi-slot orders (e.g., Mon–Fri × 2 meals = 10 slots), execute **all slots in parallel** across multiple tabs:

```
Plan all slots first → For each slot:
  1. tabs_create_mcp → new tabId
  2. navigate to date+meal menu URL in that tab
  3. (kick off next tab immediately)

Then in parallel for each tab:
  4. Add items via JS (smart loop, handle modals)
  5. Click cart icon → /checkout
  6. Click Place Order
  7. Capture order number from URL
  8. tabs_close_mcp
```

**Verified:** Background tabs (visibilityState=hidden) DO execute scroll/JS — menu pages lazy-load correctly. So multi-tab parallel works for scraping AND for execution.

Practical concurrency: 3–5 tabs at a time is safe; beyond that the browser may throttle. For 10 slots, batch in waves of 5.

## Error Handling

| Error | Response |
|-------|----------|
| Item not found | Substitute from plan, note in history |
| Sold out at cart time | Re-scrape date, pick substitute |
| Budget exceeded | Remove most expensive non-essential, retry |
| Modal with unexpected options | Screenshot + judgment |
| Page not loading | Wait 3s, retry once; skip slot if still failing |
| Outside 7-day window | Skip silently, note in summary |
| Empty favorites for date | Fall back to category pages (respect category_mode) |
| Cache file malformed | Treat as missing, re-scrape |
| New user, no order history | Continue with empty variety state |
