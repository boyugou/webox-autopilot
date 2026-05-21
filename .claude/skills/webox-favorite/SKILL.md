---
name: webox-favorite
description: Order food from WeBox using ONLY the user's hearted favorites for each meal slot. Fast (~5s per slot) but narrow — skips all category scrapes. Use when the user says "order from my usuals", "stick to favorites", "quick order from my hearted list", or wants a fast lightweight order from known dishes. For broader exploration including the full curated menu, use webox-order instead (the default).
---

# WeBox Favorite-Only Order

Thin variant of `webox-order`. Same flow for everything except Step 3 (menu scrape).

For Step 0 (prereq), Step 1 (load state), Step 2 (sync history), Step 4 (plan), Step 4b (validate), Step 5 (confirm), Step 6 (save plan), Step 7 (cart-add), Step 8 (checkout), Step 9 (per-slot loop), Step 10 (post-order feedback) — follow `~/.claude/skills/webox-order/SKILL.md` exactly. Read it first, then apply the Step 3 override below.

Also read `~/.claude/skills/webox/SITEMAP.md` for URL patterns and DOM selectors.

---

## Step 3 override: favorites-only scrape

Skip all category scraping. Only scrape the favorites page for each slot.

### 3a. Cache check
Read `~/Documents/WeBox/menu-cache/YYYY-MM-DD-Meal.json` if it exists and is fresh (cached_at < 60 min). If the cache `sources` includes `"favorites"`, use it. Skip to Step 4.

### 3b. Scrape favorites
Navigate to:
```
https://www.webox.com/menu/section/My%20Favorites?date=YYYY-MM-DD&shippingTime=Lunch
```
Replace `Lunch` with `Dinner` for dinner slots. (Favorites are date-bound — items vary by date.)

Run the menu-scrape JS from `webox-order/SKILL.md` Step 3b — same code, same DOM selectors.

Tag every returned item with `in_favorites: true`, `categories: ["favorites"]`.

### 3c. If favorites is empty or insufficient

Unlike `webox-order`, this skill does NOT auto-augment with categories. If favorites can't fulfill the slot (empty page, all sold out, can't reach `budget × 0.4` with a main), STOP and ask:

> Your favorites page is empty / can't fulfill the budget for [date]. Want me to switch to `/webox-order` (which adds curated categories) instead?

This skill is deliberately narrow — agreeing to switch should require the user's explicit consent.

### 3d. Cache the result

Write `~/Documents/WeBox/menu-cache/YYYY-MM-DD-Meal.json`:
```json
{
  "cached_at": "ISO-8601",
  "date": "2026-05-21",
  "meal": "Lunch",
  "sources": ["favorites"],
  "items": [
    { "brand": "...", "name": "...", "price": 14.95, "rating": 4.5, "in_favorites": true, "categories": ["favorites"] }
  ]
}
```

---

## Everything else: identical to webox-order

Selection (Step 4), budget validation (4b), confirmation (5), plan persistence (6), URL-search-based cart-add (7), JS checkout (8), per-slot loop (9), post-order feedback (10) — all identical. The DOM Reference, Error Handling, and JS-First Principle from `webox-order/SKILL.md` and `webox/SITEMAP.md` apply unchanged.
