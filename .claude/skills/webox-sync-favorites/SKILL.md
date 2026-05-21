---
name: webox-sync-favorites
description: Refresh the local WeBox favorites cache by re-scraping the favorites page. Shows what's new or removed since the last sync. Use when the user asks to update their favorites list, or when favorites-cache.md is stale.
---

# WeBox Sync Favorites Skill

Re-scrapes the WeBox favorites page and updates `~/Documents/WeBox/favorites-cache.md`.

Run this when:
- The user says "refresh my favorites" or "update my favorites list"
- `favorites-cache.md` is older than 7 days (the `webox-order` skill will also trigger this automatically)
- The user thinks their favorites have changed (hearted or un-hearted items)

---

## Step 1: Verify Prerequisites

Call `tabs_context_mcp`. If no tab is available, stop and tell the user to open Chrome with the Claude in Chrome extension.

## Step 2: Load Existing Cache

Read `~/Documents/WeBox/favorites-cache.md` if it exists. Store the current item list — you'll diff against it in Step 4.

## Step 3: Scrape Favorites Page

Navigate to `https://www.webox.com/menu/section/My%20Favorites?date=TODAY&shippingTime=Lunch` (use today's date in YYYY-MM-DD format).

```javascript
(async () => {
  const SELECTORS = 'app-product-menu-item.menu-section-product-item, .new-menu-product-item';
  // Smart scroll: stops early when no new items load
  let lastCount = 0, stable = 0;
  for (let i = 0; i < 15; i++) {
    window.scrollTo(0, document.body.scrollHeight);
    await new Promise(r => setTimeout(r, 600));
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
    return { brand, name, price, priceText, rating };
  }).filter(i => i.name);
})()
```

Note: favorites are scraped without sold-out filtering — the list shows all hearted items regardless of availability on today's date. Availability varies by date and is checked during ordering.

## Step 4: Diff and Report

Compare the new list against the old cache. Identify:
- **New items** (in fresh scrape, not in old cache)
- **Removed items** (in old cache, not in fresh scrape — likely un-hearted)
- **Unchanged items**

Print a summary:

```
🔄 Favorites synced — 47 items total

  ➕ New (3):
    - Ox 9 Lanzhou — Spicy Beef Noodle Soup — $14.95
    - Green Bulgogi — Bibimbap Bowl — $16.50
    - Seto Tempura — Tempura Bento — $18.75

  ➖ Removed (1):
    - Northwest China Cuisine — Spicy Hot Pot — $16.95

  ✅ Unchanged: 43 items
```

If nothing changed:
```
✅ Favorites up to date — 47 items, no changes since [last_updated date].
```

## Step 5: Write Updated Cache

Overwrite `~/Documents/WeBox/favorites-cache.md` with the new list:

```markdown
# Favorites Cache
last_updated: YYYY-MM-DD

- Brand | Item Name | $XX.XX | rating X.X
- Brand | Item Name | $XX.XX | rating X.X
...
```

## Step 6: Surface Relevant Insights (Optional)

After syncing, if `~/Documents/WeBox/item-reviews.md` exists, cross-reference:
- Any newly-hearted items that the user has already reviewed → note their rating/comments
- Any highly-rated items (4–5/5 or with strongly positive comments) that are NOT in favorites → suggest hearting them for better recommendations
- Any items with negative reviews still in favorites → suggest unhearting them on WeBox

Examples:
```
💡 You rated "Ox 9 Lanzhou — Sliced Spicy Beef" 5/5 but it's not in your favorites.
   Consider hearting it on WeBox for better future recommendations.

⚠️ "Spicy Hot Pot" is still in your favorites, but you commented "超级咸，肉太少" last week.
   Consider un-hearting it on WeBox.
```
