---
name: webox-order-all
description: Order food from WeBox using the FULL menu (multiple cuisine + food-type categories). Use when the user explicitly wants to explore beyond favorites — "order something new", "browse the menu", "ignore my favorites", or when the favorites page is blocked. For normal day-to-day ordering, use webox-order instead (smart-default: favorites + auto-fallback).
---

# WeBox Order — Full Menu Variant

Thin variant of `webox-order`. Same flow for everything except Step 3.

For everything except Step 3, follow `~/.claude/skills/webox-order/SKILL.md` exactly. Read it first (the full content), then apply the Step 3 override below.

Also read `~/.claude/skills/webox-order/SITEMAP.md` for URL patterns and DOM reference.

---

## Step 3 override: scrape categories (skip favorites)

Instead of `webox-order`'s "favorites-first with smart fallback", scrape across cuisine + food-type categories.

### Cache check (same as webox-order)

Check `~/Documents/WeBox/menu-cache/YYYY-MM-DD-Meal.json`. If fresh AND its `sources` includes the categories you intended to scrape, use it.

### Choose which categories to scrape

Apply `category_mode` from preferences:
- `all` (default for this skill) → scrape every category in SITEMAP.md tables
- `whitelist` → only categories in `category_list`
- `blacklist` → all categories EXCEPT those in `category_list`

Always include `preferred_cuisines`. Skip `cuisines_to_avoid`. If user prompt requests a specific cuisine, scrape that one for the main and filler categories (Drink, Side, Snack, Produce, Dairy & Eggs) for budget-filling.

### Scrape sequentially (NOT parallel)

**One tab, one category at a time, foreground.** Parallel tabs may return partial lazy-load results.

Per category, ~5s. 30 categories sequential = ~150s (~2.5 min). For most use cases, scrape only the curated set described above (~7 categories, ~35s).

If the user genuinely wants the full menu, just be patient — set expectation up front:
> Scraping the full menu — about 2-3 minutes. I'll show progress as each category completes.

For each category:
1. Navigate to the URL (see SITEMAP.md "Category URLs"):
   - Cuisines: `?date=X&shippingTime=Y&objType=CUISINE&objId=NAME&objName=NAME`
   - Food types: `?date=X&shippingTime=Y&objType=CATEGORY&objId=<NUM>&objName=NAME`
2. Run the menu scrape JS (same as `webox-order` Step 3b)
3. Accumulate results
4. Move to next category

⚠️ **Don't use `/menu/section/CATEGORY`** — it silently returns favorites instead of the requested category. Always use the root URL with query params (see SITEMAP.md).

### Discover unknown numeric IDs at runtime

If a food-type category's numeric `objId` isn't in SITEMAP.md, discover it on the first category page:
```javascript
(async () => {
  const target = [...document.querySelectorAll('.category-item-name')].find(e => /^DRINK$/i.test(e.innerText.trim()));
  target?.click();
  await new Promise(r => setTimeout(r, 1300));
  const params = new URLSearchParams((location.href.split('?')[1] || ''));
  return { objType: params.get('objType'), objId: params.get('objId'), objName: params.get('objName') };
})()
```

### Optionally enrich with favorites

If you want `in_favorites: true/false` to inform Step 4 selection (useful soft preference), scrape favorites for this slot too (one more URL). Skip if user said "ignore my favorites".

### Deduplicate

Dedupe by `(brand, name)` key. Same dish often appears in multiple categories (a Chinese snack is in both `Chinese` and `Snack`). Keep one merged entry, accumulate sources in `categories: ["Chinese", "Snack"]`.

### Write the menu cache

```json
{
  "cached_at": "ISO-8601",
  "date": "2026-05-21",
  "meal": "Lunch",
  "sources": ["Chinese", "Japanese", "Drink", "Side", "favorites"],
  "items": [
    {
      "brand": "...",
      "name": "...",
      "price": 14.95,
      "priceText": "$14.95",
      "rating": 4.5,
      "in_favorites": true,
      "categories": ["Chinese", "Entrée"]
    }
  ]
}
```

TTL: 60 minutes. Auto-prune cache files older than 24 hours.

### Rate-limit recovery

If a page returns 0 items or hangs:
1. Wait 5s, retry once.
2. If still 0, skip that category.
3. If 3+ skips in a row, ask the user:
   > WeBox seems rate-limiting. Want me to wait 60s and retry, or proceed with what I have?

---

## Everything else: identical to webox-order

Steps 0 (prereq), 1 (load state), 2 (sync history), 4 (build plan), 4b (validate budget), 5 (confirm), 6 (save to history), 7 (URL-search-based add to cart), 8 (checkout), 9 (per-slot loop), 10 (post-order feedback) — all identical.

The DOM Reference (SITEMAP.md), Error Handling, and JS-First Principle from `webox-order/SKILL.md` apply unchanged.
