---
name: webox-order-all
description: Order food from WeBox using the FULL menu across all cuisine categories. Strict full-menu — scrapes every category for the meal slot first, then plans from the complete set. Use when the user wants variety, wants to explore beyond favorites, when favorites page is blocked, or when they say "order anything", "browse the menu", "order something new". For favorites-only ordering, use webox-order instead.
---

# WeBox Order — Full Menu Scope (strict)

This skill scrapes **every cuisine category** for the target meal slot first, builds a unified deduped menu, and only then plans the order. The favorites cache (and `item-reviews.md`) is loaded as **guidance for selection** — not as the source of items.

Sister skill: **`webox-order`** is favorites-only (does not scrape categories). Both share identical selection, budget, cart, and checkout logic.

Data directory: `~/Documents/WeBox/`

## JS-First Principle

Always prefer JavaScript over computer use for any operation that can be done in JS. Use computer use only for visually complex modals with 5+ option groups. See `webox-order/SKILL.md` for the full DOM Reference and JS snippets — all checkout/cart/modal code is identical here.

## Defaults

Same as `webox-order`:
- Meal types: both Lunch and Dinner when not specified
- Weekends: skip Sat/Sun
- Confirmation mode: `auto` unless preferences override

---

## Step 0: Prerequisite Check

Same as `webox-order` Step 0 — verify Chrome connected, verify `~/Documents/WeBox/preferences.md` exists (if missing → tell user to run `/webox-onboard`).

## Step 1: Load Preferences, Reviews, History

Same as `webox-order` Step 1, EXCEPT for 1d:

### 1d. Favorites cache (loaded as REFERENCE only, not as source)
Read `~/Documents/WeBox/favorites-cache.md` if it exists. This skill does NOT use it as the item pool — it's loaded purely so the selection logic can prefer hearted items when they appear in the full-menu scrape.

If favorites cache is missing or stale, that's fine — proceed without it.

## Step 2: Sync Order History (if stale)

Same as `webox-order` Step 2.

## Step 3: Scrape the FULL Menu (all categories)

This is the core difference from `webox-order`. **First, scrape all eligible cuisine categories in parallel. Then plan from the merged result.**

### URL — categories only

Use the **root URL with query parameters**:
```
https://www.webox.com/?date=YYYY-MM-DD&shippingTime=Lunch&objType=CUISINE&objId=CATEGORY&objName=CATEGORY
```

⚠️ **CRITICAL — DO NOT use `https://www.webox.com/menu/section/CATEGORY`.** That URL pattern works ONLY for `My%20Favorites`. For any cuisine category, `/menu/section/X` **silently falls back to the favorites list and returns wrong data while appearing to succeed.** If two different category scrapes return identical items, this is the bug.

### Which categories to scrape

Apply `category_mode` from preferences:
- `all` → every category in the table below (default behavior for this skill)
- `whitelist` → only categories in `category_list`
- `blacklist` → all categories EXCEPT those in `category_list`

Always include `preferred_cuisines` even if a filter would exclude them.
Skip everything in `cuisines_to_avoid`.

If the user prompt requests a specific cuisine ("I want Thai today"), restrict to that cuisine for the main dish; still scrape filler-eligible categories (Drink, Side, Snack, Dairy & Eggs, Produce) for budget-filling.

### Full category URL value table

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

### Parallel multi-tab scraping (required)

Scraping 25–33 categories serially is unworkable. **Open in parallel waves of 5 tabs:**

```
For each wave of 5 categories:
  browser_batch([
    tabs_create_mcp(category_url_1),
    tabs_create_mcp(category_url_2),
    tabs_create_mcp(category_url_3),
    tabs_create_mcp(category_url_4),
    tabs_create_mcp(category_url_5),
  ])
  # Then run scraping JS in all 5 tabs:
  browser_batch([
    javascript_tool(scrape_js, tabId_1),
    javascript_tool(scrape_js, tabId_2),
    javascript_tool(scrape_js, tabId_3),
    javascript_tool(scrape_js, tabId_4),
    javascript_tool(scrape_js, tabId_5),
  ])
  # Then close all 5 tabs:
  browser_batch([tabs_close_mcp x5])
```

5 tabs × 6 waves = 30 categories in roughly the time of 6 sequential scrapes. Rate-limit safe.

### Menu scraping JS (per tab)

```javascript
(async () => {
  await new Promise(r => setTimeout(r, 1500));  // initial paint
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

### Deduplicate across categories

Same dish often appears in multiple categories (a Chinese snack is in both `Chinese` and `Snack`). Dedupe by `(brand, name)` key. Keep one copy per item, but record all source categories in a `categories: []` array on the merged item.

### Cache the merged result

Write `~/Documents/WeBox/menu-cache/YYYY-MM-DD-Meal.json`:

```json
{
  "cached_at": "2026-05-20T21:30:00",
  "date": "2026-05-21",
  "meal": "Lunch",
  "sources": ["Chinese", "Japanese", "Drink", "Side", "..."],
  "items": [
    {
      "brand": "Xiangchuan Kitchen",
      "name": "BBQ Teriyaki Chicken Cutlet",
      "price": 14.95,
      "rating": 4.5,
      "categories": ["Chinese", "Entrée"],
      "in_favorites": true
    }
  ]
}
```

If the favorites cache was loaded in Step 1d, annotate each item with `in_favorites: true/false` for downstream selection bias.

TTL: 60 minutes. Auto-prune cache files older than 24 hours.

### Rate-limit recovery

If a scraped page returns 0 items or hangs:
1. Wait 5 seconds, retry that single category once.
2. If still failing, skip that category and continue with the rest.
3. If 3+ categories fail in a row, WeBox is likely rate-limiting:
   > WeBox seems to be rate-limiting. Want me to wait 60s and retry, or proceed with what I've already scraped?

---

## Step 4: Build the Order Plan (full-menu selection)

Same selection priority as `webox-order` Step 4:

1. **Hard constraints:** dietary restrictions, allergens, items rated 1/5 or "never again" in reviews, budget cap
2. **Strong preferences:** items rated 4–5/5, user's prompt constraints, preferred cuisines
3. **Variety (mains only):** respect `avoid_repeat_days`, fillers exempt via `allow_repeat_categories` and `allow_repeat_patterns`
4. **Soft preferences (this skill specific):** items with `in_favorites: true` from Step 3 get a small bias; otherwise pick from the full set

Quantity handling, item-reviews injection, plan format — identical to `webox-order` Step 4.

## Step 4b: Validate Budget (if `validate_budget: true`)

Same as `webox-order` Step 4b — `uv run python` sum check.

## Step 5: Confirm or Proceed

Same as `webox-order` Step 5 (`confirm_before_order` setting).

## Step 6: Save Plan to Order History

Same as `webox-order` Step 6 — write to `~/Documents/WeBox/order-history.md` with `📝 planned` status.

## Step 7: Add Items to Cart

Same as `webox-order` Step 7 — all JS-first selectors:
- `.btn.plus-add` or `.product-add-wrapper` to open add or modal
- `st-button.add-button` to confirm in modal
- `.anticon.anticon-close` to close modal
- Quantity stepper on `/checkout`: `.input-number-wrapper.isCart` → `.btn.plus` / `.btn.minus`
- Items-with-options cache: `~/Documents/WeBox/items-with-options.md`

## Step 8: Checkout

Same as `webox-order` Step 8 — `a.cart.fr` → `/checkout` → `.place-btn` → `/order/finish/<NUMBER>`.

## Step 9: Repeat for Each Slot

Same as `webox-order` Step 9.

## Step 10: Post-Order Feedback

Same as `webox-order` Step 10 — invite reviews, append to `item-reviews.md`.

---

## DOM Reference, Parallel Execution, Error Handling

See `webox-order/SKILL.md` — identical for both skills.
