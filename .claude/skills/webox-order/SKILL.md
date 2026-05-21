---
name: webox-order
description: Autonomously order food from WeBox (webox.com) using the user's logged-in Chrome session. Smart default — scrapes favorites first for each meal slot, intelligently augments with categories if favorites are insufficient for the budget. Use for normal ordering. For explicit full-menu exploration, use webox-order-all instead.
---

# WeBox Order Skill

The default ordering skill. Favorites-first with smart fallback when favorites can't fulfill the slot.

Data directory: `~/Documents/WeBox/` (visible in Finder, plain text).

## JS-First Principle (strict)

**EVERY operation in this skill has a verified JavaScript or URL-navigation path.** Use computer use (screenshots, `find` tool, coordinate clicks) ONLY as the absolute last resort for visually complex modals with 5+ option groups that genuinely need model judgment.

Hierarchy (use the first that applies):
1. **URL navigation** — change the page state by navigating, not clicking (e.g., `?queryText=NAME` for item search)
2. **JS selector + click/scroll** — for DOM interactions (cart, qty, checkout, modal)
3. **`find` tool** — fallback when a JS selector is unknown
4. **Computer use (screenshot + coordinate click)** — last resort only

Slow image-and-coordinate operations are a bug to be fixed in this skill, not a workaround to use. If you find yourself reaching for a screenshot to click something, first check if a JS selector exists below.

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

### 1c. Order history (per-week JSON, slot occupancy + variety tracking)

Order history lives in `~/Documents/WeBox/orders/` as **per-week JSON files**, one file per ISO week:
- `~/Documents/WeBox/orders/2026-W21.json` (covers Mon 2026-05-18 through Sun 2026-05-24)
- `~/Documents/WeBox/orders/2026-W22.json` (Mon 2026-05-25 through Sun 2026-05-31)
- ...

**Only load the week files that overlap your `history_window_days` window** — typically the last 4 weeks plus the current/next week. Don't load the entire directory.

```javascript
// Pseudocode: ISO week computation
function isoWeek(date) { /* returns "2026-W21" */ }
const weeksToLoad = lastNWeeks(history_window_days);  // e.g. ["2026-W18", ..., "2026-W22"]
const orders = weeksToLoad.flatMap(w => readJSON(`~/Documents/WeBox/orders/${w}.json`)?.orders ?? []);
```

This file structure serves two purposes:
- **Slot occupancy:** every entry blocks its slot (cancelled/refunded are filtered out at sync time, so anything that appears is treated as a real order)
- **Variety tracking:** items in recent entries → avoid repeating within `avoid_repeat_days`

If `synced_at` (in the latest week file or in a top-level `_meta.json`) is more than 1 day old → re-sync in Step 2.
Malformed or missing files → treat as empty and re-scrape.

### Per-week JSON schema

```json
{
  "week": "2026-W21",
  "week_starts": "2026-05-18",
  "synced_at": "2026-05-21T14:30:00",
  "orders": [
    {
      "date": "2026-05-18",
      "day": "Mon",
      "meal": "Lunch",
      "orderId": "No.3258400",
      "status": "active",            // active | planned (no cancelled/refunded ever written)
      "total": 28.30,
      "items": [
        { "brand": "Xiangchuan Kitchen", "name": "Mongolian Beef Bento", "qty": 1, "price": 17.45 },
        { "brand": "Northwest China Cuisine", "name": "Tea Egg", "qty": 2, "price": 2.45 }
      ]
    },
    {
      "date": "2026-05-22",
      "day": "Thu",
      "meal": "Lunch",
      "status": "planned",
      "total": 25.95,
      "items": [ ... ]
    }
  ]
}
```

**Cancelled / refunded orders are NOT written to these files** — they're treated as "never happened" so the slot stays openable. The WeBox order list page (`/order/list/normal`) remains the source of truth if the user wants to audit.

---

## Step 2: Sync Order History (if stale)

*Skip if the most recent week file in `~/Documents/WeBox/orders/` has `synced_at` within the last day.*

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
  }).filter(o => o.date && o.meal && o.isActive);  // FILTER cancelled/refunded out at the source
  return JSON.stringify(orders);
})()
```

Merge each scraped order into the appropriate per-week file:
1. Convert `"Mon 05/18"` to a full ISO date using the current year (or previous year if the date is in the future this year).
2. Compute the ISO week (`2026-W21`).
3. Read or create `~/Documents/WeBox/orders/<YYYY-Www>.json` (schema in Step 1c).
4. Dedupe by `orderId` and merge new orders. Preserve any local `status: "planned"` entries.
5. Update `synced_at` to the current timestamp on every touched week file.

**Cancelled/refunded orders are filtered out at the scrape step** (`.filter(... && o.isActive)`) — they never get written. The slot stays openable for re-ordering. If the user wants to audit cancelled history, point them at `/order/list/normal`.

Skip any target date+meal that has an entry in the loaded week files (since cancelled/refunded are filtered, anything present = real active order).

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
2. Scrape these categories **sequentially in a single tab** (~5s each; ~35s total for ~7 categories). Parallel multi-tab is unreliable for lazy-load — see "Scraping Strategy" section below.
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

### Category URLs — two flavors

WeBox categories fall into TWO groups with different URL patterns:

**Cuisines (ethnic):** `objType=CUISINE`, `objId` = human-readable name
- Chinese, Japanese, Korean, Thai, Vietnamese, Indian, Mexican, Italian, French, Greek, Mediterranean, American, Burmese, Nepalese, Filipino
- Example: `?objType=CUISINE&objId=Chinese&objName=Chinese`

**Food types:** `objType=CATEGORY`, `objId` = NUMERIC database ID
- Drink (id=38), Deals (id=504), and others — IDs must be discovered at runtime
- Example: `?objType=CATEGORY&objId=38&objName=Drink`

**See `SITEMAP.md`** (sibling file in this skill directory) for the full reference and runtime-discovery snippet for unknown numeric IDs.

⚠️ **Anti-pattern:** `/menu/section/Chinese` (or any non-favorites category) silently falls back to favorites. Always use the root URL with query params.

### Scraping Strategy: Sequential by Default

**Default: sequential scraping, one tab.** Lazy-load is driven by Intersection Observer which can behave unpredictably in hidden background tabs — items may load partially. A single foreground tab with smart-scroll is the safest contract.

Per-scrape time is ~3-5s (smart scroll with 350ms wait, terminates at 2 stable counts). For the smart-default flow that's at most ~7 scrapes (favorites + 6 augment categories) = ~30s. Acceptable.

**Parallel multi-tab is NOT recommended** for production scrapes:
- Background tabs may return INCOMPLETE results (silent partial loads)
- The `browser_batch` round-trip "looks" parallel but each tab still runs lazy-load sequentially-ish under throttling
- The wall-time gain is modest and the correctness risk is real

If parallelism is genuinely needed (e.g., user wants the full menu fast), consider:
- Opening N tabs sequentially with full smart-scroll in each foreground turn (slow but correct)
- Or accept partial results and document the limitation

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

## Step 7: Add Items to Cart (URL search + per-item)

**The fast, reliable approach uses URL-based search per item — NOT navigating to a slot menu and DOM-scrolling to find each item.**

### Per-item add flow (sequential, one item at a time)

For each item in the plan:

1. **Navigate via URL search** (instead of menu navigation + DOM-find):
   ```
   https://www.webox.com/?date=YYYY-MM-DD&shippingTime=Lunch&queryText=<urlencoded-item-name>
   ```
   This loads the menu pre-filtered to items matching the search. **Verified: 50-result limit, first result is the exact match when searching for a specific dish name.**

2. **Click the first result** via JS:
   ```javascript
   (async () => {
     await new Promise(r => setTimeout(r, 2500));  // wait for search results to render
     const SELECTORS = 'app-product-menu-item.menu-section-product-item, .new-menu-product-item';
     const items = [...document.querySelectorAll(SELECTORS)];
     if (!items.length) return { status: 'no_results' };
     // First result; verify it matches the intended item name to guard against fuzzy-match misses
     const target = items[0];
     const name = target.querySelector('.product-menu-title')?.innerText?.trim();
     // SAFETY: if the first result name doesn't contain key tokens from the intended name, abort
     const intended = 'INTENDED_ITEM_NAME';  // pass in
     const tokens = intended.toLowerCase().split(/\s+/).filter(t => t.length > 3);
     const matchesEnough = tokens.filter(t => name?.toLowerCase().includes(t)).length >= Math.max(1, Math.floor(tokens.length / 2));
     if (!matchesEnough) return { status: 'mismatch', firstResult: name, intended };
     // Click add button
     const btn = target.querySelector('.btn.plus-add') || target.querySelector('.product-add-wrapper');
     if (!btn) return { status: 'no_button', name };
     btn.click();
     await new Promise(r => setTimeout(r, 1200));
     const modal = !!document.querySelector('[class*="product-detail-header"]');
     return { status: modal ? 'modal_opened' : 'added_direct', name };
   })()
   ```

3. **If `modal_opened`**: handle the modal (see "Modal handling" below). The script returns the modal state — do NOT chain more clicks in the same JS scope; that's the bug that caused unintended items in earlier tests.

4. **Then proceed to next item** with a fresh navigation.

### Why URL search beats DOM-scroll-find

- **Reliable:** search is server-side, results are deterministic
- **Fast:** ~2.5s per item (search load + render) vs ~5-10s scraping the slot menu
- **No partial matching ambiguity:** the search engine picks the best match; we verify by token-overlap on the result name
- **No state pollution:** each item is an independent navigation; cart accumulates correctly

### Modal handling (pure JS)

If add returns `modal_opened`:

```javascript
(async () => {
  // 1. (Optional) Check ~/Documents/WeBox/items-with-options.md for cached options.
  //    If cached, find and click the matching option radio first:
  //    [...document.querySelectorAll('.option-item, [class*="option"]')].find(el => el.innerText.includes('PREFERRED_OPTION'))?.click();
  // 2. Click Add to Cart inside modal
  document.querySelector('st-button.add-button')?.click();
  await new Promise(r => setTimeout(r, 1000));
  // 3. Close modal (it does NOT auto-close after Add)
  document.querySelector('.anticon.anticon-close')?.click();
  await new Promise(r => setTimeout(r, 500));
  return { added: true, modalGone: !document.querySelector('[class*="product-detail-header"]') };
})()
```

After encountering a new item with options, append to `~/Documents/WeBox/items-with-options.md`:
```
- [Brand] [Item Name] — options: "Choose Rice" (single, default: White Rice) — chosen: Purple Rice — date: YYYY-MM-DD
```

### Quantity > 1

Two paths depending on whether the item had a modal:

**Item without modal:** the search-and-click script above can loop the click N times (same scope safely — no modal opens). Modify it to take `qty` and loop:
```javascript
for (let i = 0; i < qty; i++) {
  btn.click();
  await new Promise(r => setTimeout(r, 400));
}
```

**Item with modal:** add once via modal flow, then navigate to `/checkout` and use cart qty stepper:
```javascript
(async () => {
  const targetName = 'ITEM_NAME';
  const targetQty = 3;
  const steppers = [...document.querySelectorAll('.input-number-wrapper.isCart')];
  const stepper = steppers.find(s => {
    const card = s.closest('[class*="cart-item"], [class*="cart-product"]') || s.parentElement?.parentElement;
    return card?.innerText.toLowerCase().includes(targetName.toLowerCase());
  });
  if (!stepper) return 'not_in_cart';
  const currentQty = parseInt(stepper.querySelector('input')?.value || '0', 10);
  const diff = targetQty - currentQty;
  for (let i = 0; i < Math.abs(diff); i++) {
    stepper.querySelector(diff > 0 ? '.btn.plus' : '.btn.minus:not(.unable)')?.click();
    await new Promise(r => setTimeout(r, 300));
  }
  return `qty=${stepper.querySelector('input')?.value}`;
})()
```

### Removing an item (decrement qty to 0)

Decrementing to 0 opens a confirm dialog. Pure JS handler:
```javascript
(async () => {
  // ...find stepper as above...
  // Decrement until qty=1
  while (parseInt(stepper.querySelector('input')?.value || '0', 10) > 1) {
    stepper.querySelector('.btn.minus')?.click();
    await new Promise(r => setTimeout(r, 250));
  }
  // One more decrement triggers confirm
  stepper.querySelector('.btn.minus')?.click();
  await new Promise(r => setTimeout(r, 700));
  [...document.querySelectorAll('button')].find(b => /^Remove$/i.test((b.innerText || '').trim()))?.click();
  await new Promise(r => setTimeout(r, 700));
  return 'removed';
})()
```

### Search returns no results / wrong item

If the search-and-click script returns:
- `no_results` → try a shorter search query (drop modifiers); if still nothing, the item may be sold out on this date. Substitute from the cached menu, note in `order-history.md`.
- `mismatch` → first result doesn't match. Try a more specific query (include brand name) or substitute.
- `no_button` → unlikely with URL search; if it happens, retry once or substitute.

### Complex options (5+ option groups)

Last-resort fallback to computer use. Take a screenshot, use judgment to pick options, then click the modal's Add to Cart via JS as above. Document the chosen options in `items-with-options.md` so future runs use JS.

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

Repeat Steps 7–8 per date+meal in the plan **sequentially**. Slots are independent — different carts — but multi-tab parallelism is not recommended (untested for cart/checkout, risk of cart drift across tabs). Each slot takes ~20-30s end-to-end (a few items + checkout).

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
