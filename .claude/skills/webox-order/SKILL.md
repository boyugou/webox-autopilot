---
name: webox-order
description: Order food from WeBox autonomously via the WeBox API. Fetches the full menu in one call, plans within the user's budget honoring preferences/dietary/reviews, then places orders via POST /api/orders. Use for normal ordering — "order my lunch for tomorrow", "order lunch and dinner next week", "get me 5 milks across this week". For favorites-only narrow scope, use webox-favorite.
---

# WeBox Order Skill

**Fully API-based.** Fetches menu via `/api/productSpecials/v8/...`, plans, places via `POST /api/orders`. No DOM scraping, no cart manipulation. See `~/.claude/skills/webox/SITEMAP.md` for the full API reference.

Data directory: `~/Documents/WeBox/`

## Defaults

- **Meal types:** When not specified, order both **Lunch and Dinner** per day.
- **Weekends:** Skip Sat/Sun for multi-day ranges unless asked.
- **Confirmation mode:** `auto` by default. Set `confirm_before_order: true` for plan-first mode.

## WeBox Constraints

- **7-day window:** Orders up to 7 days ahead only.
- **Meal cutoffs:** Slots have order cutoffs; the menu API simply won't return a slot once its cutoff has passed.
- **One slot = one POST:** each date+meal is a separate order.

---

## Step 0: Prerequisite Check

```
tabs_context_mcp({ createIfEmpty: true })
```
Capture the `tabId`. Navigate it to `https://www.webox.com` (login probe). Verify `a.cart.fr` exists.

Check that **all four identity files** exist in `~/Documents/WeBox/`:
- `preferences.md` · `user-profile.json` · `address-info.json` · `favorites.json`

If any is missing:
> You haven't set up WeBox yet. Run `/webox-onboard` first — takes about 2 minutes.

---

## Step 1: Load Local State

### 1a. Preferences (`preferences.md`)
Extract `budget`, `budget_mode`, `validate_budget`, `confirm_before_order`, `default_meals`, `skip_weekends`, `avoid_repeat_days` (default 7), `history_window_days` (default 28), `allow_repeat_categories`, `allow_repeat_patterns`, dietary restrictions, allergens, preferred/avoided cuisines, food likes/dislikes, drink preferences.

### 1b. Identity caches (JSON)
- `user-profile.json` → `{firstName, lastName, phone, email, timezone}` (for Place Order body)
- `address-info.json` → `{addressId, kitchenId, timezone}` (for Place Order body and menu URL)
- `favorites.json` → `productIdList` Set for in-favorites bias
- `hidden.json` → `productIdList` Set to filter out items the user marked "Not Interested"

### 1c. Item reviews (`item-reviews.md`)
Heavily injected into Step 4 selection.

### 1d. Order history (per-week JSON)
Read only week files overlapping `history_window_days` (typically last 4 weeks + current/next). Two purposes:
- **Slot occupancy:** any `✅` (active) or `📝 planned` entry blocks that slot
- **Variety tracking:** productIds in recent entries → avoid repeating (mains only)

If the latest week file's `synced_at` is more than 1 day old → re-sync via `/webox-sync` first (or inline the order-history-fetch JS from webox-sync Step 3).

---

## Step 2: Fetch Menu for Each Target Slot

For each `(date, meal)` the user wants:

### 2a. Menu cache check
Read `~/Documents/WeBox/menu-cache/<DATE>-<MEAL>.json`. If `cached_at < 60 minutes ago`, reuse it.

### 2b. Fresh fetch via API (~1s per slot)

```javascript
(async () => {
  const addrId = /* from address-info.json */;
  const date = '<YYYY-MM-DD>';
  const meal = '<Lunch|Dinner|HappyHour>';
  const r = await fetch(`/api/productSpecials/v8/address/${addrId}/date/${date}`, { credentials: 'include' });
  const j = await r.json();
  if (j.code !== 1) return JSON.stringify({ error: 'menu_fetch_failed', code: j.code, msg: j.msg });
  const specialsKey = meal.toLowerCase() + 'Specials';
  const specials = j.data[specialsKey] || [];
  const { products, productBrands } = j.data;
  const productById = new Map(products.map(p => [p.id, p]));
  const brandById   = new Map(productBrands.map(b => [b.id, b]));
  const favIds  = new Set(/* favorites.json productIdList */);
  const hideIds = new Set(/* hidden.json productIdList */);
  let kitchenId = null, shippingTimeSectionId = null;
  const items = specials
    .filter(s => s.stockStatus !== 'outofstock')
    .map(s => {
      const p = productById.get(s.productId);
      if (!p || hideIds.has(p.id)) return null;
      kitchenId = kitchenId || s.kitchenId;
      shippingTimeSectionId = shippingTimeSectionId || s.shippingTimeSectionId;
      return {
        productSpecialId: s.id, productId: p.id, portionId: s.portionId, cutoffTime: s.cutoffTime,
        name:  p.extName?.enUs,
        brand: brandById.get(p.brandId)?.extName?.enUs,
        price: s.price,
        rating: p.averageRating || null,
        category: p.category,
        in_favorites: favIds.has(p.id),
        dietary: {
          glutenFree: !!p.glutenFree, dairyFree: !!p.dairyFree, halal: !!p.halalCertified,
          nutFree: !!p.nutFree, vegan: p.veggieLevel === 'Vegan', vegetarian: p.veggieLevel === 'Vegetarian'
        }
      };
    })
    .filter(Boolean);
  return JSON.stringify({ date, meal, kitchenId, shippingTimeSectionId, items });
})()
```

Write the result to `~/Documents/WeBox/menu-cache/<DATE>-<MEAL>.json`:
```json
{
  "cached_at": "ISO-8601",
  "date": "2026-05-22",
  "meal": "Lunch",
  "kitchenId": 12838,
  "shippingTimeSectionId": 27274,
  "items": [ ... ]
}
```

**Hidden items and sold-out items are pre-filtered.** The cache is clean and ready for planning.

If `j.code !== 1` or items is empty: cutoff has likely passed. Tell the user; suggest picking a later slot.

---

## Step 3: Build the Order Plan

Build a complete plan for ALL requested slots **before placing anything**.

### Budget
- `spend-up-to` (default): aim to use most of the budget; prioritize variety
- `ceiling-only`: best picks, no fill-up
- Cap is on food item total only (no fees/tax)

### Quantities (× N notation)
Budget validation: `unit_price × qty`.

### Selection priority

1. **Hard constraints (never violate):**
   - `restrictions` (vegetarian/vegan/halal/etc.) — filter via `dietary.*` flags
   - `avoid_allergens` — filter via dietary flags + free-text in review comments
   - Items rated 1/5 or tagged `never-again` in reviews → exclude
   - Strongly-negative review comments ("超级咸", "肉太少", "inedible") → exclude
   - Budget cap

2. **Strong preferences:**
   - Items rated 4–5/5 → top candidates
   - User's prompt constraints (e.g., "Chinese only today")
   - `preferred_cuisines` (match `category`)

3. **Variety (mains only):**
   - ONLY apply to mains (entrées, bowls, bento, noodles, hot pots).
   - Items matching `allow_repeat_categories` (Drink, Side, Snack, Dairy & Eggs, Produce) or `allow_repeat_patterns` (milk, water, tea egg, etc.) are EXEMPT — they can repeat freely; ordering 5 of the same is fine.
   - For mains: avoid productIds in recent `orders/YYYY-Www.json` entries within `avoid_repeat_days`.
   - Cross-day variety in this session: don't pick the same main twice across consecutive days.

4. **Soft preferences:**
   - `in_favorites: true` items get a small bias
   - Fill remaining budget with complementary fillers if `spend-up-to`
   - Prompt-requested cuisine restricts the MAIN only — fillers can come from any category

### Item reviews — how to read

Reviews are free-form prose in any language with optional ratings. Both matter:
- "5/5" / "amazing" / "always order" → top
- "4/5" / "good" → preferred
- "2-3/5" / "ok" → deprioritize
- "1/5" / "never again" / "超级咸" → exclude (even without a number)

If comments diverge across dates, trust the most recent. When a review influences a decision, mention it:
> Skipping Spicy Hot Pot — review notes "too oily, didn't finish" (2026-05-15).

### Plan output

```
📋 Order Plan — Mon May 25 – Fri May 29

📅 Mon May 25, Lunch — $30.00 budget
  - Xiangchuan Kitchen — Mongolian Beef Bento × 1 — $17.45
  - Northwest China Cuisine — Tea Egg × 3 — $7.35   ($2.45 × 3)
  - Mediterranean Grill House — Taboulleh Salad × 1 — $5.95
  Total: $30.75 ❌ → drop one Tea Egg → $28.30 ✓
```

---

## Step 3b: Validate Budget (if `validate_budget: true`)

```bash
uv run --no-project python -c "
items = [(17.45, 1), (2.45, 2), (5.95, 1)]  # (unit_price, qty)
budget = 30.0
total = sum(p * q for p, q in items)
assert total <= budget, f'Over budget: \${total:.2f} > \${budget:.2f}'
print(f'OK: \${total:.2f} / \${budget:.2f}')
"
```

If assertion fails: remove the most expensive non-essential and re-validate.

---

## Step 4: Confirm or Proceed

**Auto mode** (default): print plan, proceed immediately. Pause only for ambiguity, errors, or out-of-window dates.

**Confirm mode** (`confirm_before_order: true`):
```
Does this plan look good? Say "yes" to confirm, or tell me what to change.
```
Wait for reply, apply changes, re-confirm once before proceeding.

---

## Step 5: Save Plan to Order History (planned status)

For each slot, write/merge into `~/Documents/WeBox/orders/YYYY-Www.json` with `planned: true`:
```json
{
  "date": "2026-05-25",
  "day": "Mon",
  "meal": "Lunch",
  "planned": true,
  "total": 28.30,
  "items": [
    {
      "productSpecialId": 56813079, "productId": 499852, "portionId": 144251,
      "cutoffTime": 1779462000000, "shippingTimeSectionId": 27274, "kitchenId": 12838,
      "name": "Mongolian Beef Bento", "brand": "Xiangchuan Kitchen", "price": 17.45, "quantity": 1
    }
  ]
}
```

`planned: true` distinguishes "I told the user we'd order this" from "this is in WeBox". After Step 6 success, remove the flag and add the real `orderId`.

---

## Step 6: Place Each Order via API (sequential)

For each slot in the plan, call `POST /api/orders` with the body assembled from the planned items + identity caches.

```javascript
(async (slot, profile, address) => {
  const first = slot.items[0];  // all items in a slot share shippingTimeSectionId and kitchenId
  const dateShipping = new Date(slot.date + 'T00:00:00').getTime();
  const body = {
    order: {
      firstName: profile.firstName,
      lastName:  profile.lastName,
      phone:     profile.phone,
      email:     profile.email,
      timezone:  profile.timezone || address.timezone || 'America/Los_Angeles',
      addressId: address.addressId,
      kitchenId: address.kitchenId,
      currency:  'Dollar',
      autoSelectCoupon: true
    },
    orderPackages: [{
      extItems: slot.items.map(it => ({
        productSpecialId: it.productSpecialId,
        portionId:        it.portionId,
        quantity:         it.quantity,
        cutoffTime:       it.cutoffTime,
        extCartItemId:    `${slot.date}__${first.shippingTimeSectionId}__${it.productSpecialId}__${it.portionId}`,
        extChildren:      []
      })),
      dateShipping,
      timeShipping:           slot.meal,
      shippingTimeSectionId:  first.shippingTimeSectionId,
      kitchenId:              first.kitchenId,
      extCutleryQuantity:     0,
      extBaseCutleryQuantity: 1
    }],
    payType:            'Personal',
    realTips:           0,
    usePersonalWeBucks: true,
    hasAddedWeBucks:    false
  };
  const r = await fetch('/api/orders?client=web', {
    method: 'POST', credentials: 'include',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body)
  });
  const j = await r.json();
  return JSON.stringify({ status: r.status, code: j.code, msg: j.msg || j.message, orderId: j.data?.id });
})(<slot>, <profile>, <address>)
```

**On success** (`code === 1`, `orderId` returned):
- Update the per-week JSON entry: remove `planned: true`, add `"orderId": "No.<id>"`
- Print: `✅ Order placed! Order #<orderId> — <date> <meal> — $<total>`

**On failure** (`code !== 1`):
- Print `msg` to the user
- Keep `planned: true` in the per-week file so the user can retry
- Common cases:
  - `"cutoff passed"` → slot's order window closed; suggest picking a later slot
  - `"item out of stock"` → re-fetch the menu, substitute, retry
  - `"duplicate order"` → slot already has an active order; check `orders/` for an existing entry

**Sequential, never parallel.** Place Order is a real mutation — race conditions could cause duplicate charges. Always one at a time.

---

## Step 7: Repeat per Slot

Loop Step 6 over each slot in the plan. Each is independent; ~1s per slot.

Final summary:
```
🎉 All done!

  Mon May 25 Lunch  $28.30 ✅ #XXXXXXX
  Mon May 25 Dinner $20.25 ✅ #XXXXXXX
  Tue May 26 Lunch  $29.50 ✅ #XXXXXXX
```

---

## Step 8: Post-Order Feedback

If no feedback was given this session, invite it:
> Done! Any feedback on dishes you've tried — good or bad — just tell me. Free-form: "too dry", "loved it", "这个超级咸", etc.

Parse and append to `~/Documents/WeBox/item-reviews.md`. Create the file if missing.

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

Append dated comments rather than overwriting. Only update `Rating:` if the user gives a number explicitly.

---

## Error Handling

| Situation | Response |
|---|---|
| Menu API code != 1 | Print `msg`; ask user to try later or pick different slot |
| 0 items for a slot | Cutoff likely passed; suggest later slot |
| Place Order code != 1 | Print `msg`; leave `planned: true` for retry |
| Budget exceeded mid-plan | Drop most expensive non-essential, re-plan |
| Outside 7-day window | Skip silently, note in summary |
| Identity cache missing | Direct user to `/webox-onboard` |
| User has no address | Tell user to add a delivery address on webox.com first |

---

## DOM Fallback (last resort)

If the API is unavailable (schema change, etc.), see `~/.claude/skills/webox/SITEMAP.md` "DOM patterns" section for the legacy DOM-scraping + cart-clicking + .place-btn flow. Slower (~30s per slot vs ~1s) and more fragile but works.
