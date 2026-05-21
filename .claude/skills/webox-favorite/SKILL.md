---
name: webox-favorite
description: Order food from WeBox using ONLY the user's hearted favorites for each meal slot. Fast and narrow — picks from items the user has already chosen to like. Use when the user says "order from my usuals", "stick to favorites", "quick order from my hearted list". For broader exploration including the full menu, use webox-order instead.
---

# WeBox Order — Favorites-Only Variant

Thin variant of `webox-order`. **Same API flow**, with one tighter filter in Step 2: only items where `in_favorites: true` are considered for the plan.

For Step 0 (prereq), Step 1 (load state), Step 3 (plan), Step 3b (validate budget), Step 4 (confirm), Step 5 (save planned), Step 6 (Place Order), Step 7 (per-slot loop), Step 8 (post-order feedback) — **follow `~/.claude/skills/webox-order/SKILL.md` exactly.**

The only difference is in Step 2's filter, below.

Also see `~/.claude/skills/webox/SITEMAP.md` for API reference.

---

## Step 2 override: filter the menu to favorites only

After fetching the menu via `GET /api/productSpecials/v8/...` (same as `webox-order` Step 2), apply an additional filter that drops non-favorited items:

```javascript
// items already filtered by hidden + sold-out (same as webox-order Step 2b)
const favItems = items.filter(it => it.in_favorites === true);
```

Save the cache to `~/Documents/WeBox/menu-cache/<DATE>-<MEAL>.json` with a `scope` marker so downstream code knows this is a favorites-only snapshot:

```json
{
  "cached_at": "ISO-8601",
  "date": "2026-05-22",
  "meal": "Lunch",
  "kitchenId": 12838,
  "shippingTimeSectionId": 27274,
  "scope": "favorites-only",
  "items": [ /* favorite items only */ ]
}
```

### If the favorites-only set can't fulfill the slot

If the filtered set is empty, or selection can't reach `budget × 0.4`, or there's no main dish in favorites:

> Your favorites for [date] [meal] can't fulfill the budget (only X items totaling $Y). Want me to switch to `/webox-order` (full menu) instead?

This skill is deliberately narrow — agreeing to switch should require the user's explicit consent.

---

## Everything else: same as webox-order

Selection logic (Step 3), budget validation, confirmation, plan persistence, Place Order via `POST /api/orders`, post-order feedback — all identical to `webox-order`. Refer to `webox-order/SKILL.md` for those steps; don't duplicate the logic here.
