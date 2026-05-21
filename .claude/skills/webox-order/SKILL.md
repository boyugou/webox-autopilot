---
name: webox-order
description: Autonomously order food from WeBox (webox.com) using the user's logged-in Chrome session. Scrapes menus, checks existing orders, selects items within budget based on user preferences, adds to cart, and checks out. Use when the user asks to order food on WeBox for specific dates/meals.
---

# WeBox Order Skill

You are ordering food from WeBox on behalf of the user. Use the `mcp__claude-in-chrome__*` tools to control their Chrome browser (already logged in).

## Defaults

- **Meal types:** When not specified, order both **Lunch and Dinner** for each day (each is a separate cart/checkout).
- **Weekends:** When ordering "next week" or a multi-day range, **skip Saturday and Sunday** unless the user explicitly requests them. Weekends typically only offer HappyHour (Self Pay), not subsidized Lunch/Dinner.
- **Confirmation mode:** Default is `auto` — decide and order without asking, unless an error or ambiguity requires clarification. If set to `confirm` in preferences, present the full plan and wait for approval before placing any orders.

## Known WeBox Constraints

- **7-day ordering window:** WeBox only allows ordering up to 7 days in advance. Do not attempt dates beyond this window — they won't appear on the menu.
- **Weekend availability:** Saturday and Sunday typically only have HappyHour (Self Pay), not subsidized Lunch/Dinner.
- **Meal cutoff times:** Orders for a given meal must be placed before the cutoff (usually mid-morning for Lunch). If the meal time has passed, skip that slot.
- **Budget applies per meal slot** (one checkout per day/meal). Each date+mealtime is a separate cart and checkout.

---

## Step 1: Load User Preferences and Caches

### 1a. Read preferences
Read `~/.webox-autopilot/user-preferences.md`. If it doesn't exist, proceed with defaults and note you'll infer preferences from order history.

Key settings to extract:
- `budget` and `budget_mode` (spend-up-to vs ceiling-only)
- `confirm_before_order` (auto vs confirm)
- `validate_budget` (Python price check)
- `plan_cache_days` (default: 14)
- `avoid_repeat_days` (default: 3)
- Dietary restrictions, preferred cuisines, drink policy

### 1b. Prune stale plan cache entries
Read `~/.webox-autopilot/plan-cache.md` and drop any entries older than `plan_cache_days`. Use remaining entries for variety tracking (avoid items ordered in the past `avoid_repeat_days` days).

### 1c. Load favorites cache
Check `~/.webox-autopilot/favorites-cache.md`:
- If it exists and `last_updated` is within **7 days**: use the cached list, skip scraping the favorites page.
- If missing or stale: scrape the favorites page (Step 3), then write the results to `favorites-cache.md`.

**Cache format:**
```markdown
# Favorites Cache
last_updated: YYYY-MM-DD

- Brand | Item Name | $XX.XX | rating X.X
- Brand | Item Name | $XX.XX | rating X.X
...
```

To force a refresh, the user can say "refresh my favorites" and you should delete or ignore the cache.

### 1d. Load order history cache
Check `~/.webox-autopilot/order-history-cache.json`:
- If it exists and `cached_at` is within **1 hour**: use it, skip navigating to `/order/list/normal`.
- Otherwise: scrape order history (Step 2), then write to the cache file.

**Cache format:** `{"cached_at": "2026-05-20T14:30:00", "orders": [...]}`

## Step 2: Check Existing Orders (Avoid Double-Ordering)

*Skip if order history cache is fresh (see Step 1d).*

Navigate to `https://www.webox.com/order/list/normal` and extract already-ordered dates. Do this **once per session** and reuse the result for all days — don't re-scrape between slots.

```javascript
(async () => {
  const orders = [...document.querySelectorAll('.order-item')].map(o => {
    const lines = o.innerText.split('\n').map(l => l.trim()).filter(Boolean);
    const dateLine = lines.find(l => /^(Mon|Tue|Wed|Thu|Fri|Sat|Sun)\s+\d{2}\/\d{2}$/.test(l));
    const mealLine = lines.find(l => /Lunch|Dinner|HappyHour|Breakfast/.test(l));
    return { date: dateLine, meal: mealLine };
  }).filter(o => o.date);
  return JSON.stringify(orders.slice(0, 30));
})()
```

Skip any target date+meal already in this list. Save result to `~/.webox-autopilot/order-history-cache.json`.

## Step 3: Scrape Menu for Each Target Date

For each **date** (not each meal slot) that needs ordering, scrape the favorites page once — the favorites list is the same regardless of whether you're ordering Lunch or Dinner on that day.

*If favorites-cache is fresh (Step 1c), skip this step entirely for dates within its validity window.*

### URL Format
- **Favorites:** `https://www.webox.com/menu/section/My%20Favorites?date=YYYY-MM-DD&shippingTime=Lunch`
- **Main menu:** `https://www.webox.com/?date=YYYY-MM-DD&shippingTime=Lunch`
- **By cuisine:** `https://www.webox.com/?date=YYYY-MM-DD&shippingTime=Lunch&objType=CUISINE&objId=Chinese&objName=Chinese`

Note: `shippingTime` can be `Lunch` or `Dinner` — availability may differ, but favorites are the same.

### Scraping Function

```javascript
(async () => {
  for (let i = 0; i < 10; i++) {
    window.scrollTo(0, document.body.scrollHeight);
    await new Promise(r => setTimeout(r, 600));
  }
  const SELECTORS = 'app-product-menu-item.menu-section-product-item, .new-menu-product-item';
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

After a fresh scrape, update `~/.webox-autopilot/favorites-cache.md`.

### What to Scrape

Always scrape **Favorites** first. Only scrape additional categories if:
- No favorites are available for that date
- The user's prompt requests a specific cuisine not in favorites
- Budget can accommodate more items after favorites are selected

## Step 4: Build the Full Order Plan

After scraping all needed dates, build the complete plan for **all days at once** before touching the cart.

### Budget Rules
- **Default budget:** $30.00 per meal slot (strict cap on food item total)
- **spend-up-to mode (default):** Aim to use most of the budget, prioritize variety over maximizing value
- **ceiling-only mode:** Pick what seems best without trying to fill the budget

### Selection Heuristics
1. **Prioritize favorites** (items the user has hearted)
2. **Avoid recent repeats** — check plan-cache.md for items ordered in the past 3–5 days
3. **Apply dietary restrictions and cuisine preferences** from preferences file
4. **Apply user's prompt** (e.g., "healthy", "Chinese food", "something light")
5. **Cross-day variety** — don't pick identical items across days in the same ordering session
6. **Budget constraint** — food item total must not exceed budget per slot

### Plan Format

Produce the full plan in this format:

```
📋 Order Plan — [Date Range]

📅 Mon May 25, Lunch — $30.00 budget
  - [Item Name] from [Brand] — $XX.XX
  - [Item Name] from [Brand] — $XX.XX
  Total: $XX.XX

📅 Mon May 25, Dinner — $30.00 budget
  - [Item Name] from [Brand] — $XX.XX
  Total: $XX.XX

📅 Tue May 26, Lunch — $30.00 budget
  ...
```

## Step 4b: Validate Budget (if enabled)

If `validate_budget: true` in preferences, run a Python one-liner to strictly verify each slot's item total before proceeding. This catches any arithmetic errors in Claude's selection.

```bash
python3 -c "
prices = [PRICE1, PRICE2, ...]  # Replace with actual selected prices for this slot
budget = BUDGET
total = sum(prices)
assert total <= budget, f'Budget exceeded: \${total:.2f} > \${budget:.2f}'
print(f'Budget OK: \${total:.2f} / \${budget:.2f}')
"
```

If the assertion fails: remove the most expensive non-essential item and re-validate. Do not proceed to cart until validation passes.

If `validate_budget: false` (default): skip this step and trust the arithmetic from Step 4.

## Step 5: Confirm or Proceed

### Auto mode (default: `confirm_before_order: false`)

Print the plan, then immediately proceed to Step 6 without waiting. Only pause to ask the user if:
- An item is ambiguous and requires a choice that preferences don't resolve
- An unexpected error occurs that you can't recover from automatically
- A date is outside the 7-day ordering window

### Confirm mode (`confirm_before_order: true`)

After printing the plan, **stop and ask:**

```
Does this plan look good? Reply "yes" to confirm, or tell me what to change.
```

Wait for the user's response. Apply any requested changes to the plan, then confirm once more before proceeding. Only proceed to Step 6 after explicit approval.

## Step 6: Save Plan to Cache

Before placing any orders, write the plan to `~/.webox-autopilot/plan-cache.md`.

### Cache File Format

```markdown
# WeBox Order Plan Cache
Last updated: YYYY-MM-DD

## [Day], [Date], [Meal] — $XX.XX planned
- [Brand] — [Item Name] — $XX.XX
- [Brand] — [Item Name] — $XX.XX
Status: planned | ordered ✅ #ORDERNUM | skipped (reason) | modified

## [Day], [Date], [Meal] — $XX.XX planned
...
```

**Rules:**
- Append new planned slots to the file (don't overwrite existing entries)
- After each successful order, update that slot's `Status:` line to `ordered ✅ #ORDERNUM`
- If an item was substituted (e.g., sold out → replacement), update the item line with the actual item ordered
- Prune entries older than `plan_cache_days` (default: 14) at the start of each session

## Step 7: Add Items to Cart

Navigate to the correct date+meal URL before adding items. Each date's cart is separate — switching the date URL resets the cart context.

### Finding and Clicking Items

```javascript
(async () => {
  const targetName = 'ITEM_NAME_HERE'; // partial match, case-insensitive
  const items = [...document.querySelectorAll('app-product-menu-item.menu-section-product-item, .new-menu-product-item')];
  const match = items.find(item => {
    const title = item.querySelector('.product-menu-title');
    return title && title.innerText.toLowerCase().includes(targetName.toLowerCase());
  });
  if (!match) return 'item_not_found';
  // Two button types: .btn.plus-add (most items) or .product-add-wrapper (items with required options)
  const btn = match.querySelector('.btn.plus-add') || match.querySelector('.product-add-wrapper');
  if (!btn) return 'no_button_found';
  btn.click();
  await new Promise(r => setTimeout(r, 1000));
  const modal = document.querySelector('[class*="product-detail-header"]');
  return modal ? 'modal_opened' : 'added_directly';
})()
```

**If `no_button_found`:** Inspect the item's actual button structure:
```javascript
(async () => {
  const items = [...document.querySelectorAll('app-product-menu-item.menu-section-product-item, .new-menu-product-item')];
  const match = items.find(i => i.querySelector('.product-menu-title')?.innerText?.includes('SEARCH_TERM'));
  if (!match) return 'no match';
  return [...match.querySelectorAll('[class*="plus"],[class*="add"],[class*="btn"],[role="button"],button')]
    .map(b => b.tagName + '.' + b.className.slice(0, 60)).join(' | ');
})()
```

### Handling Options Modal

If result is `modal_opened`:

1. Use `find("Add to Cart button")` → get ref
2. `computer scroll_to` + `computer left_click` on the ref
3. The first/default option is pre-selected by WeBox — accept unless preferences require otherwise

**Check `~/.webox-autopilot/items-with-options.md`** before clicking: if the item is cached there, use the noted preferred option instead of the default.

**Complex options (5+ choices, poke bowls, build-your-own):**
- Take a screenshot, use model judgment (computer use) to select reasonable options
- Then click "Add to Cart"

**After encountering a new item with options**, append to `~/.webox-autopilot/items-with-options.md`:
```
- [Brand] [Item Name] — option: "Choose Rice" (single) — default chosen: Purple Rice
```

### If Item Not Found

1. Try navigating to the item's cuisine category URL and re-scraping
2. If still not found, substitute with the next best option from the plan
3. Update the plan-cache entry to reflect the substitution

## Step 8: Checkout

After all items for one date+meal are in the cart:

1. Open cart (click cart icon top-right)
2. Use `find("Quick Checkout button")` → `computer scroll_to` + `computer left_click`
3. Wait for "Thank you for your order" page, note the order number
4. Update that slot's status in `~/.webox-autopilot/plan-cache.md` to `ordered ✅ #ORDERNUM`

```
✅ Order placed! Order #XXXXXXX
   Mon May 25, Lunch — $XX.XX
```

## Step 9: Repeat for Each Day

Repeat Steps 7–8 for each date+meal in the plan. After all orders are complete, print a summary:

```
🎉 All orders placed!

  Mon May 25 Lunch  — $XX.XX  ✅ #XXXXXXX
  Mon May 25 Dinner — $XX.XX  ✅ #XXXXXXX
  Tue May 26 Lunch  — $XX.XX  ✅ #XXXXXXX
  ...
```

## Step 10: Cleanup (Optional)

After all orders succeed, offer to update `~/.webox-autopilot/user-preferences.md` if new preferences were inferred from the order choices.

---

## DOM Reference (Verified 2026-05-20)

| Selector | Purpose |
|----------|---------|
| `app-product-menu-item.menu-section-product-item, .new-menu-product-item` | Product card — works on both Favorites page and main menu |
| `.product-item-content-wrapper` | Content area within product card |
| `.brand-wrapper` | Brand/restaurant name |
| `.product-menu-title` | Item name (clean text). Do NOT use parent wrappers — they include rating text |
| `.product-price` | Price text (e.g., "$17.55") |
| `.product-menu-new-and-rating-wrapper` | Rating (first line is the score) |
| `.product-menu-top-sold-out-wrapper` | Sold-out indicator — **always in DOM**; use `getComputedStyle(el).display !== 'none'`, NOT `!!el` |
| `.btn.plus-add` | Add-to-cart button for most items (DIV element, not `<button>`) |
| `.product-add-wrapper` | Add-to-cart for items with required options (SPAN); always opens modal |
| `[class*="product-detail-header"]` | Modal open indicator |
| `.order-item` | Order history row on `/order/list/normal` |

## Automation vs. Model Judgment

| Action | Method |
|--------|--------|
| Scrape menu items | Pure JS |
| Check existing orders | Pure JS |
| Add item (no options) | JS click `.btn.plus-add` → `added_directly` |
| Add item (simple options e.g. "Choose Rice") | JS click → modal → `find("Add to Cart button")` → click |
| Add item (complex options, 5+ choices) | Screenshot + model judgment + computer use |
| Quick Checkout | `find("Quick Checkout button")` → `computer scroll_to` + `left_click` |

## Error Handling

- **Item not found:** Substitute with next best option from plan, update cache entry
- **Sold out at cart time:** Re-scrape that date's menu, pick substitute, update cache
- **Budget would be exceeded:** Don't add the item; try a cheaper alternative
- **Modal with unexpected options:** Screenshot and use model judgment
- **Network error / page not loading:** Wait 2s, retry once; if still failing, log and skip that slot
- **Outside 7-day window:** Skip silently and note in summary
