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

## Step 0: Prerequisite Check

### 0a. Claude in Chrome connected?
Call `tabs_context_mcp`. If it returns no tabs or an error, stop:
> Claude in Chrome doesn't seem to be connected. Make sure Chrome is running with the [Claude in Chrome extension](https://code.claude.com/docs/en/chrome) enabled, then try again.

### 0b. First-run check
If `~/Documents/WeBox/preferences.md` does **not** exist, stop and say:
> It looks like you haven't set up WeBox yet. Run `/webox-onboard` first — it takes about 2 minutes and sets up your preferences, favorites, and order history.

If the file exists, continue to Step 1.

---

## Step 1: Load User Preferences and Caches

### 1a. Read preferences
Read `~/Documents/WeBox/preferences.md`.

Key settings to extract:
- `budget` and `budget_mode` (spend-up-to vs ceiling-only)
- `confirm_before_order` (auto vs confirm)
- `validate_budget` (Python price check)
- `plan_cache_days` (default: 14)
- `avoid_repeat_days` (default: 3)
- Dietary restrictions, preferred cuisines, drink policy

### 1b. Load item reviews
Read `~/Documents/WeBox/item-reviews.md` if it exists. This file contains the user's personal ratings and notes on specific dishes. Keep this loaded — it will be injected into selection decisions in Step 4.

### 1c. Prune stale plan cache entries
Read `~/Documents/WeBox/plan-cache.md` and drop any entries older than `plan_cache_days`. Use remaining entries for variety tracking (avoid items ordered in the past `avoid_repeat_days` days).

### 1d. Load favorites cache
Check `~/Documents/WeBox/favorites-cache.md`:
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

### 1e. Load order history cache
Check `~/Documents/WeBox/order-history-cache.json`:
- If it exists and `cached_at` is within **1 hour**: use it, skip navigating to `/order/list/normal`.
- Otherwise: scrape order history (Step 2), then write to the cache file.

**Cache format:** `{"cached_at": "2026-05-20T14:30:00", "orders": [...]}`

## Step 2: Check Existing Orders (Avoid Double-Ordering)

Use this decision tree:

1. **Read `~/Documents/WeBox/order-calendar.md`** — if it exists and `last_synced` is within 1 day, use it as the authoritative source of already-ordered slots. No network request needed.

2. **Otherwise**, scrape `/order/list/normal` once and update both `order-calendar.md` and `order-history-cache.json`:

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

After any successful checkout, **immediately append** the new slot to `order-calendar.md` — don't wait for the next sync.

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

After a fresh scrape, update `~/Documents/WeBox/favorites-cache.md`.

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

Apply these in order — higher rules take precedence:

1. **Hard constraints (never violate):**
   - Dietary restrictions (vegetarian, vegan, etc.)
   - Allergens to avoid
   - Items the user has explicitly rated 1/5 or marked "never order again" in item-reviews.md
   - Budget cap

2. **Strong preferences:**
   - Items rated 4–5/5 in item-reviews.md → strongly prefer these
   - Items rated 2–3/5 → deprioritize but don't exclude
   - Preferred cuisines from preferences file
   - User's prompt constraints (e.g., "healthy", "Chinese only", "something light")

3. **Variety and recency:**
   - Avoid items ordered within `avoid_repeat_days` days (check plan-cache.md)
   - Cross-day variety within the same ordering session — don't repeat across days

4. **Soft preferences:**
   - Prioritize WeBox favorites (hearted items)
   - Preferred cuisines
   - Budget mode (spend-up-to: fill the budget with variety; ceiling-only: pick best regardless of total)

### Item Reviews Injection

When item-reviews.md is loaded, treat the review notes as direct signals:

- **"amazing", "love this", 5/5** → bump this item to the top of candidates
- **"too salty", "portion too small", 2/5** → deprioritize; mention the note if you still pick it due to no better options
- **"never order again", "disliked", 1/5** → treat as a hard exclude (same as allergen)
- **Free-text notes** (e.g., "always get extra sauce", "prefer the spicy version") → use as context for option selection when a modal opens

Include the item review in your reasoning when it influences a decision, e.g.:
> Picking Mongolian Beef bento (rated 5/5: "always order this") over Spicy Hot Pot (rated 2/5: "too oily").

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

Before placing any orders, write the plan to `~/Documents/WeBox/plan-cache.md`.

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

**Check `~/Documents/WeBox/items-with-options.md`** before clicking: if the item is cached there, use the noted preferred option instead of the default.

**Complex options (5+ choices, poke bowls, build-your-own):**
- Take a screenshot, use model judgment (computer use) to select reasonable options
- Then click "Add to Cart"

**After encountering a new item with options**, append to `~/Documents/WeBox/items-with-options.md`:
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
4. Update that slot's status in `~/Documents/WeBox/plan-cache.md` to `ordered ✅ #ORDERNUM`

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

## Step 10: Post-Order Feedback (Optional)

After all orders succeed:

1. **Invite reviews** (only if the user hasn't already given feedback in this session):
   > Orders placed! If you have any feedback on items you've tried recently — ratings, things you loved or want to avoid — just tell me and I'll save them for next time.

   If the user responds with feedback, parse it and append to `~/Documents/WeBox/item-reviews.md`.

2. **Update preferences** if new dietary or cuisine preferences were inferred from the conversation.

### Item Review File Format

`~/Documents/WeBox/item-reviews.md`:

```markdown
# Item Reviews

## [Brand] — [Item Name]
Rating: X/5
Tags: favorite | avoid | never-again | love-the-sauce | portion-small | ...
Notes: [free-text — anything the user said about this item]
Last ordered: YYYY-MM-DD

## [Brand] — [Item Name]
Rating: X/5
Notes: ...
```

**Writing reviews:** Users can say anything — Claude parses it:
- "The Mongolian Beef bento is amazing, always order it" → rating 5/5, tag favorite
- "The poke bowl was too salty and overpriced, don't order again" → rating 1/5, tag never-again
- "I liked the Lanzhou noodles but the portion felt small" → rating 3/5, tag portion-small
- "For the bento with rice, I always prefer purple rice" → option preference note

Append new reviews; update existing entries if the same item is reviewed again (keep last rating, append notes with date).

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
