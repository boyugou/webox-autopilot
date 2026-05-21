---
name: webox-order-all
description: Order food from WeBox using the FULL menu (all cuisine categories). Use when the user explicitly wants to explore beyond favorites — "order something new", "browse the menu", "ignore my favorites", or when the favorites page is blocked. For normal day-to-day ordering, use webox-order instead (it's smart-default and includes favorites + auto-fallback to categories if needed).
---

# WeBox Order — Full Menu Variant

This is a thin variant of `webox-order` that scrapes the FULL menu (all eligible cuisine categories) instead of favorites-first. Use this only when the user explicitly wants full-menu exploration or when favorites is unavailable.

**For everything except Step 3, follow `~/.claude/skills/webox-order/SKILL.md` exactly.** Read that file first (Read tool, full content), then apply the Step 3 override below.

## Step 3 override: scrape all categories (skip favorites)

Instead of `webox-order`'s "favorites-first with smart fallback", do this:

### 3a. Cache check (same as webox-order)

Check `~/Documents/WeBox/menu-cache/YYYY-MM-DD-Meal.json`. If fresh AND its `sources` array covers what you'd scrape (i.e., it's from a previous webox-order-all run), use it. Otherwise scrape fresh.

### 3b. Determine which categories to scrape

Apply `category_mode` from preferences:
- `all` (default for this skill — overrides preference if absent) → every category in the URL table
- `whitelist` → only categories in `category_list`
- `blacklist` → all categories EXCEPT those in `category_list`

Always include `preferred_cuisines` even if a filter would exclude them. Skip everything in `cuisines_to_avoid`.

If the user prompt requests a specific cuisine ("I want Thai today"), restrict the MAIN to that cuisine. Still scrape filler categories (Drink, Side, Snack, Dairy & Eggs, Produce) for budget-filling.

### 3c. Parallel scraping (waves of 5 tabs)

See `webox-order/SKILL.md` Step 3 "Parallel Multi-Tab Execution" for the exact `browser_batch` pattern. For ~30 categories, that's 6 waves of 5 tabs each. Each wave should complete in ~10s thanks to background-tab JS execution.

Use the URL pattern (NOT `/menu/section/X`):
```
https://www.webox.com/?date=YYYY-MM-DD&shippingTime=Lunch&objType=CUISINE&objId=NAME&objName=NAME
```

Use the URL-encoded category values table from `webox-order/SKILL.md` Step 3.

⚠️ Anti-pattern: `/menu/section/X` silently falls back to favorites for non-favorites categories. If two different category scrapes return the same items, you used the wrong URL.

Use the same menu scraping JS as `webox-order` Step 3b.

### 3d. Optional: also scrape favorites for selection bias

If you want `in_favorites: true/false` to inform Step 4 selection (it's a useful soft preference), add one more tab to the first wave for the favorites URL. Skip this if user said "ignore my favorites this time".

### 3e. Dedupe and cache

Dedupe by `(brand, name)` key. The same dish often appears in multiple categories (e.g., a Chinese snack in both `Chinese` and `Snack`). Keep one merged entry, accumulate sources in `categories: ["Chinese", "Snack"]`.

Write `~/Documents/WeBox/menu-cache/YYYY-MM-DD-Meal.json`:
```json
{
  "cached_at": "ISO-8601",
  "date": "2026-05-21",
  "meal": "Lunch",
  "sources": ["all"],         // or list of scraped categories
  "items": [
    {
      "brand": "...",
      "name": "...",
      "price": 14.95,
      "priceText": "$14.95",
      "rating": 4.5,
      "in_favorites": true,    // or null if favorites not scraped
      "categories": ["Chinese", "Entrée"]
    }
  ]
}
```

### Rate-limit recovery

If a page returns 0 items, retry that single category once after 5s. If 3+ categories fail, ask:
> WeBox seems rate-limiting. Want me to wait 60s and retry, or proceed with what I've scraped?

---

## Everything else: identical to webox-order

Steps 0 (prereq), 1 (load state), 2 (sync history), 4 (build plan), 4b (validate budget), 5 (confirm), 6 (save to history), 7 (add to cart), 8 (checkout), 9 (repeat per slot), 10 (post-order feedback) — all identical. See `~/.claude/skills/webox-order/SKILL.md`.

The DOM Reference and Error Handling tables in `webox-order/SKILL.md` also apply unchanged.
