---
name: webox-order
description: Autonomously order food from WeBox (webox.com) using the user's logged-in Chrome session. Scrapes menus, checks existing orders, selects items within budget based on user preferences, adds to cart, and checks out. Use when the user asks to order food on WeBox for specific dates/meals.
---

# WeBox Order Skill

You are ordering food from WeBox on behalf of the user. Use the `mcp__claude-in-chrome__*` tools to control their Chrome browser (already logged in).

## Step 1: Load User Preferences

Read the user preferences file at `~/.webox-autopilot/user-preferences.md` (or `./user-preferences.md` if in the repo).
If it doesn't exist, proceed without it and note you'll infer preferences from order history.

## Defaults

- **Meal types:** When not specified, order both **Lunch and Dinner** for each day (each is a separate cart/checkout).
- **Weekends:** When ordering "next week" or a multi-day range, **skip Saturday and Sunday** unless the user explicitly requests them. Weekends typically only offer HappyHour (Self Pay), not subsidized Lunch/Dinner.

## Known WeBox Constraints

- **7-day ordering window:** WeBox only allows ordering up to 7 days in advance. If today is Wednesday May 20, the latest orderable date is Wednesday May 27. Do not attempt to order beyond this window — dates further out won't appear on the menu.
- **Weekend availability:** Saturday and Sunday typically only have HappyHour (Self Pay), not subsidized Lunch/Dinner.
- **Meal cutoff times:** Orders for a given meal must be placed before the cutoff (usually mid-morning for Lunch). If the meal time has passed, skip that slot.
- **Budget applies per meal slot** (one checkout per day/meal). Each date+mealtime is a separate cart and checkout.

## Step 2: Check Existing Orders (Avoid Double-Ordering)

Navigate to the order history page and extract already-ordered dates:

```javascript
// Run via javascript_tool
const orders = [...document.querySelectorAll('.order-item')].map(o => {
  const lines = o.innerText.split('\n').map(l => l.trim()).filter(Boolean);
  const dateLine = lines.find(l => /^(Mon|Tue|Wed|Thu|Fri|Sat|Sun)\s+\d{2}\/\d{2}$/.test(l));
  const mealLine = lines.find(l => /Lunch|Dinner|HappyHour|Breakfast/.test(l));
  return { date: dateLine, meal: mealLine };
}).filter(o => o.date);
JSON.stringify(orders.slice(0, 20))
```

URL: `https://www.webox.com/order/list/normal`

Skip any target date+meal that already appears in this list.

## Step 3: Scrape Menu for Each Target Date/Meal

For each date/meal that needs ordering, navigate and scrape the menu.

### URL Format
- **Main menu (all items):** `https://www.webox.com/?date=YYYY-MM-DD&shippingTime=Lunch`
  - shippingTime: `Lunch` or `Dinner`
- **Favorites:** `https://www.webox.com/menu/section/My%20Favorites?date=YYYY-MM-DD&shippingTime=Lunch`
- **By cuisine:** `https://www.webox.com/?date=YYYY-MM-DD&shippingTime=Lunch&objType=CUISINE&objId=Chinese&objName=Chinese`

### Scraping Function (run via javascript_tool)

```javascript
(async () => {
  // Scroll 10 times to trigger lazy loading
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
  }).filter(i => i.name && !i.soldOut); // Only return available items
})()
```

### What to Scrape

Always scrape **Favorites** first (these are the user's preferred items). Then if needed for variety or budget filling, scrape relevant cuisine categories.

**Strategy for context efficiency:** The favorites list is the primary source. Only scrape additional categories if:
- No favorites are available for that date
- The user's prompt requests a specific cuisine not in favorites
- Budget can accommodate more items after favorites

## Step 4: Select Items

Based on the scraped menu data, user preferences file, order history, and user's prompt, select items.

### Budget Rules
- **Default budget:** $30.00 (strict — never exceed)
- Check the user's preferences file for custom budget
- **Mode 1 (default — "spend up to budget with variety"):** Aim to use most of the budget but prioritize variety and user preferences over maximizing dollar value. Don't optimize like a knapsack problem.
- **Mode 2 ("relaxed" — budget is ceiling only):** Pick what seems best without trying to fill the budget.

### Selection Heuristics
1. **Prioritize favorites** (items the user has hearted)
2. **Consider recent order history** — avoid repeating the same items ordered in the past 3 days
3. **Apply user preferences** from the preferences file (dietary restrictions, liked/disliked cuisines, etc.)
4. **Apply user's prompt** — e.g., "healthy", "Chinese food", "something light"
5. **Variety** — if ordering multiple days, don't pick identical items across days
6. **Budget constraint** — total must not exceed budget (strict)

### Output Format

Before adding to cart, announce your selections clearly:
```
📅 Thu May 21, Lunch — $30.00 budget
Selected:
  - [Item Name] from [Brand] — $XX.XX
  - [Item Name] from [Brand] — $XX.XX
Total: $XX.XX / $30.00
```

## Step 5: Add Items to Cart

Navigate to the correct date+meal menu page before adding items.

### Finding and Clicking Items

For each selected item:

```javascript
(async () => {
  const targetName = 'ITEM_NAME_HERE'; // Replace with actual item name (partial match ok)
  const items = [...document.querySelectorAll('app-product-menu-item.menu-section-product-item, .new-menu-product-item')];
  const match = items.find(item => {
    const title = item.querySelector('.product-menu-title');
    return title && title.innerText.toLowerCase().includes(targetName.toLowerCase());
  });
  if (!match) return 'item_not_found';
  // Two button types exist: .btn.plus-add (most items) or .product-add-wrapper (bento/items with required options)
  const btn = match.querySelector('.btn.plus-add') || match.querySelector('.product-add-wrapper');
  if (!btn) return 'no_button_found';
  btn.click();
  await new Promise(r => setTimeout(r, 1000));
  const modal = document.querySelector('[class*="product-detail-header"]');
  return modal ? 'modal_opened' : 'added_directly';
})()
```

**If `no_button_found`:** Run the debug snippet to inspect the item's actual button structure:
```javascript
(async () => {
  const items = [...document.querySelectorAll('app-product-menu-item.menu-section-product-item, .new-menu-product-item')];
  const match = items.find(i => i.querySelector('.product-menu-title')?.innerText?.includes('SEARCH_TERM'));
  if (!match) return 'no match';
  return [...match.querySelectorAll('[class*="plus"],[class*="add"],[class*="btn"],[role="button"],button')]
    .map(b => b.tagName + '.' + b.className.slice(0,60)).join(' | ');
})()
```

### Handling Options Modal

If the result is `'modal_opened'` (item has required options like "Choose Rice"):

1. Use `find` tool to locate "Add to Cart" button: `find("Add to Cart button")`
2. Use `computer scroll_to` + `computer left_click` with the ref to click it
3. The first/default option is pre-selected by WeBox — accept it unless user preferences require otherwise

**Complex options (poke bowls, build-your-own items with 5+ choices):**
- Take a screenshot first
- Use model judgment (computer use) to select reasonable options based on user preferences
- Then click "Add to Cart"

**Known items with options:** Check `~/.webox-autopilot/items-with-options.md` if it exists — it caches previously-encountered items with their option types. If an item is in the cache, pre-select the noted option rather than always defaulting.

**After encountering a new item with options:** Append it to `~/.webox-autopilot/items-with-options.md`:
```
- [Brand] [Item Name] — option type: "Choose Rice" (single choice) — default chosen: Purple Rice
```

### If Item Not Found on Current Page

The item might be sold out for this date or may require navigating to a specific cuisine category. Try:
1. Navigate to the item's cuisine category URL
2. Re-scrape and search
3. If still not found, skip and select the next best option from your list

## Step 6: Checkout

After all items for a date are added:

1. Open cart (click cart icon, or use `find("shopping cart")`)
2. Use `find("Quick Checkout button")` to find the checkout button
3. Click it using `computer scroll_to` + `computer left_click` with the ref
4. Wait 2 seconds and screenshot to confirm "Thank you for your order" page
5. Note the order number

```
✅ Order placed! Order #XXXXXXX
   Thu May 21, Lunch — $XX.XX
```

## Step 7: Repeat for Each Day

If ordering multiple days, repeat Steps 5–6 for each date. Each day requires navigating to that date's menu URL before adding items.

**Important:** Each date's cart is separate. Switching the date in the URL resets the cart context.

## Step 8: Update User Preferences (Optional)

After successful ordering, if you inferred new preferences from the order choices, offer to update the user preferences file.

---

## DOM Reference (Verified 2026-05-20)

| Selector | Purpose |
|----------|---------|
| `app-product-menu-item.menu-section-product-item, .new-menu-product-item` | Product card (works on both favorites and main menu) |
| `.product-item-content-wrapper` | Content area within product card |
| `.brand-wrapper` | Brand/restaurant name |
| `.product-menu-title` | Item name (clean, no rating noise). Do NOT use parent wrappers — they include rating text |
| `.product-price` | Price text (e.g., "$17.55") |
| `.product-menu-new-and-rating-wrapper` | Rating (first line is the score) |
| `.product-menu-top-sold-out-wrapper` | Sold out indicator — **always present in DOM**; use `getComputedStyle(el).display !== 'none'`, NOT `!!el` |
| `.btn.plus-add` | Add-to-cart for most items (DIV, not `<button>`) |
| `.product-add-wrapper` | Add-to-cart for items with required options (SPAN); always opens a modal |
| `[class*="product-detail-header"]` | Modal open indicator — check after clicking add button |
| `.order-item` | Order history item on `/order/list/normal` |

## Automation vs. Model Judgment

| Action | Method |
|--------|--------|
| Scrape all menu items | Pure JS (100% automated) |
| Check existing orders | Pure JS (100% automated) |
| Add item (no options) | JS click `.btn.plus-add` → `added_directly` |
| Add item (simple options like "Choose Rice") | JS click (either button) → modal opens → `find("Add to Cart button")` → click |
| Add item (complex options, 5+ choices) | Screenshot + model judgment + computer use |
| Quick Checkout | `find("Quick Checkout button")` → `computer scroll_to` + `computer left_click` |

## Error Handling

- **Item not found:** Skip it, pick next best, log the skip
- **Sold out:** Already filtered during scraping (soldOut check)
- **Budget exceeded:** Remove the last added item, try a cheaper alternative
- **Modal with unexpected options:** Screenshot and use model judgment
- **Network error / page not loading:** Wait 2s and retry once
