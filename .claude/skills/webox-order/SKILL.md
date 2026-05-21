---
name: webox-order
description: Order food from WeBox autonomously. Default to a curated full-menu scrape (favorites + preferred_cuisines + filler categories like Drink/Side/Snack) so selection sees broad options, then plans within the user's budget, adds to cart via per-item URL search, and checks out. Use for normal ordering requests like "order my lunch for tomorrow", "order lunch and dinner next week", "get me 5 milks across this week". For favorites-only narrow scope, use webox-favorite. For exhaustive every-category scrape, set category_mode=all in preferences.
---

# WeBox Order Skill

The primary ordering skill. Default scope = **curated full menu** (favorites + preferred_cuisines + filler categories). Use `webox-favorite` for favorites-only narrow scope. Set `category_mode: all` in preferences for exhaustive every-category scrape (slow, rarely needed).

Data directory: `~/Documents/WeBox/` (visible in Finder, plain text + JSON).

## JS-First Principle (strict)

EVERY operation has a verified JS or URL-navigation path. Reach for the first that applies:
1. **URL navigation** — change page state by navigating, not clicking (e.g., `?queryText=NAME` for item search)
2. **JS selector + click/scroll** — for DOM interactions (cart, qty, checkout, modal)
3. **`find` tool** — fallback when a JS selector is unknown
4. **Computer use (screenshot + coordinate click)** — last resort only, for visually complex modals with 5+ option groups

Slow image+coordinate operations are bugs to fix in this skill, not workarounds. See `~/.claude/skills/webox/SITEMAP.md` for the full DOM reference and URL catalog.

## Defaults

- **Meal types:** When not specified, order both **Lunch and Dinner** per day.
- **Weekends:** Skip Saturday and Sunday for multi-day ranges unless asked.
- **Confirmation mode:** Default `auto` (order without asking, pause only on errors). Set `confirm_before_order: true` for plan-first mode.

## WeBox Constraints

- **7-day window:** Can only order up to 7 days ahead.
- **Meal cutoffs:** Lunch has a mid-morning cutoff. Skip slots where cutoff has passed.
- **Budget per slot:** Each date+meal is a separate checkout.

---

## Step 0: Prerequisite Check

1. **Chrome connected?** Call `tabs_context_mcp`. If no tabs, stop:
   > Claude in Chrome doesn't seem to be connected. Make sure Chrome is running with the [Claude in Chrome extension](https://code.claude.com/docs/en/chrome) enabled.

2. **Preferences exist?** Check `~/Documents/WeBox/preferences.md`. If missing:
   > You haven't set up WeBox yet. Run `/webox-onboard` first — takes about 2 minutes.

---

## Step 1: Load Local State

### 1a. Preferences
Read `~/Documents/WeBox/preferences.md`. Extract:
- `budget`, `budget_mode`, `validate_budget`
- `confirm_before_order`, `default_meals`, `skip_weekends`
- `avoid_repeat_days` (default 7), `history_window_days` (default 28)
- `allow_repeat_categories`, `allow_repeat_patterns` (fillers exempt from variety rules)
- `category_mode` (curated | whitelist | blacklist | all), `category_list`
- Dietary restrictions, allergens, preferred/avoided cuisines, drinks

### 1b. Item reviews
Read `~/Documents/WeBox/item-reviews.md` if it exists. Used in Step 4 for selection bias.

### 1c. Order history (per-week JSON)
Order history lives in `~/Documents/WeBox/orders/YYYY-Www.json` (one ISO-week file per week). Load only the week files that overlap `history_window_days` (default ~4 weeks back + current/next week). Don't load the entire directory.

Schema per file:
```json
{
  "week": "2026-W21",
  "week_starts": "2026-05-18",
  "synced_at": "2026-05-21T14:30:00Z",
  "orders": [
    {
      "date": "2026-05-18", "day": "Mon", "meal": "Lunch",
      "items": [
        { "name": "Mongolian Beef Bento", "brand": "Xiangchuan Kitchen", "price": 17.45 }
      ]
    }
  ]
}
```

**Cancelled/refunded orders are filtered at sync time** — they never appear in these files. Anything present = real active or planned order, blocks its slot.

**Planned orders** (written by Step 6 before checkout, not yet placed) — when added to a week file, the agent sets a `planned: true` field on that entry. After checkout the field is removed. This lets downstream skills distinguish "I told the user we'd order this" from "this is in WeBox".

If the latest week file's `synced_at` is more than 1 day old → re-sync in Step 2.

---

## Step 2: Sync Order History (if stale)

*Skip if the most recent week file's `synced_at` is within the last day.*

Navigate to `https://www.webox.com/order/list/normal` and run the scraper below. **Output is compact by design** — only `{name, brand, price}` per item (no item descriptions, allergens, or marketing copy). A typical 40-order history fits comfortably in one tool result, avoiding display truncation.

```javascript
(async () => {
  // Wait for first .order-item to render (up to 10s)
  const SEL = '.order-item';
  let waited = 0;
  while (document.querySelectorAll(SEL).length === 0 && waited < 10000) {
    await new Promise(r => setTimeout(r, 300));
    waited += 300;
  }
  // Helpers
  const now = new Date();
  const toFullDate = (md) => {
    const m = md.match(/(\d{2})\/(\d{2})/); if (!m) return null;
    let d = new Date(now.getFullYear(), +m[1]-1, +m[2]);
    if (d - now > 30*86400000) d = new Date(now.getFullYear()-1, +m[1]-1, +m[2]);
    return d.toISOString().slice(0, 10);
  };
  const isoWeek = (iso) => {
    const d = new Date(iso + 'T00:00:00'); d.setHours(0,0,0,0);
    d.setDate(d.getDate() + 4 - (d.getDay() || 7));
    const ys = new Date(d.getFullYear(), 0, 1);
    return `${d.getFullYear()}-W${String(Math.ceil((((d - ys)/86400000)+1)/7)).padStart(2,'0')}`;
  };
  const weekMonday = (wk) => {
    const [y, w] = wk.split('-W').map(Number);
    const jan4 = new Date(y, 0, 4); const dow = jan4.getDay() || 7;
    const mon = new Date(jan4); mon.setDate(jan4.getDate() - dow + 1 + (w-1)*7);
    return mon.toISOString().slice(0, 10);
  };
  // Harvest-while-scrolling: dedup by orderId so we capture every order even if the
  // page virtualizes (mounts/unmounts items as you scroll). seen set prevents reprocessing.
  const seen = new Set();
  const synced = now.toISOString();
  const weeks = {};
  const harvest = () => {
    for (const o of document.querySelectorAll(SEL)) {
      const orderId = o.querySelector('.order-id')?.innerText?.trim();
      if (!orderId || seen.has(orderId)) continue;
      const orderStatus = o.querySelector('.order-status')?.innerText?.trim() || 'Paid';
      if (/refund|cancel/i.test(orderStatus)) { seen.add(orderId); continue; }
      const lines = o.innerText.split('\n').map(l => l.trim()).filter(Boolean);
      const dateLine = lines.find(l => /^(Mon|Tue|Wed|Thu|Fri|Sat|Sun)\s+\d{2}\/\d{2}$/.test(l));
      const mealLine = lines.find(l => /^(Lunch|Dinner|HappyHour)(\s|\(|$)/.test(l));
      if (!dateLine || !mealLine) return;
      const meal = mealLine.match(/^(Lunch|Dinner|HappyHour)/)[1];
      const items = [...o.querySelectorAll('.product-item')].map(p => {
        const name = p.querySelector('[class*="item-name"]')?.innerText?.trim();
        const txt = p.innerText.split('\n').map(l => l.trim()).filter(Boolean);
        const desc = txt.find(l => l !== name && !/^\$/.test(l) && !/^(Refunded|Paid|Delivered|Request Refund)$/i.test(l));
        const pl = txt.find(l => /^\$[\d.]+/.test(l));
        return { name, brand: desc?.split(',')[0]?.replace(/^Cold\s*·\s*/, '').trim(), price: pl ? parseFloat(pl.slice(1)) : null };
      }).filter(x => x.name);
      if (!items.length) continue;
      const fullDate = toFullDate(dateLine);
      if (!fullDate) continue;
      const day = dateLine.split(/\s+/)[0];
      const wk = isoWeek(fullDate);
      if (!weeks[wk]) weeks[wk] = { week: wk, week_starts: weekMonday(wk), synced_at: synced, orders: [] };
      weeks[wk].orders.push({ date: fullDate, day, meal, items });
      seen.add(orderId);
    }
  };
  harvest();
  // Incremental scroll — ~80% viewport per step so each row passes through view and
  // triggers lazy-load. Jumping to scrollHeight can skip intermediate items entirely.
  const step = Math.max(window.innerHeight * 0.8, 600);
  let y = 0;
  let lastSize = seen.size, stable = 0;
  for (let i = 0; i < 100; i++) {
    y += step;
    window.scrollTo(0, y);
    await new Promise(r => setTimeout(r, 600));
    harvest();
    const atBottom = y >= document.body.scrollHeight - window.innerHeight;
    if (seen.size === lastSize) {
      if (++stable >= 5 && atBottom) break;
    } else { stable = 0; }
    lastSize = seen.size;
  }
  return JSON.stringify(weeks);
})()
```

**Output format is directly writable.** The result is an object keyed by ISO week — `{"2026-W21": {week, week_starts, synced_at, orders}, "2026-W22": {...}}`. The agent iterates the keys and writes each week as `~/Documents/WeBox/orders/<key>.json` with the value as the file content. No post-processing needed.

**Trust the tool result.** Claude Code's terminal may visually truncate large tool outputs at ~1 KB with `[TRUNCATED]` — that's display-only; the agent's tool result contains the full string. Pass the full JSON straight to `Write` / `JSON.parse`. Don't waste round-trips on `window.__x.slice(...)` chunked re-reads.

Per-order schema is intentionally minimal — `{date, day, meal, items: [{name, brand, price}]}`. Dropped: `orderId`, `status`, `total`, `isActive`. We only return active orders (cancelled/refunded filtered at scrape time), so `status` and `isActive` are constants. `total` on a subsidized account is always $0. `orderId` isn't needed for variety tracking or slot occupancy; if the agent needs to dedup against an existing local file, use `date+meal+first item name` as the key.

For each scraped order:
1. Convert `"Mon 05/18"` to a full ISO date using the current year (or previous year if the resulting date is in the future).
2. Compute the ISO week → `YYYY-Www`.
3. Read or create `~/Documents/WeBox/orders/<YYYY-Www>.json`.
4. Dedupe by `date+meal+first item name` (orderId is no longer in the output). Preserve any local `planned: true` entries.
5. Update `synced_at` on every touched week file.

---

## Step 3: Build the Menu (curated full menu by default)

For each meal slot needing menu data:

### 3a. Cache check
Read `~/Documents/WeBox/menu-cache/YYYY-MM-DD-Meal.json`. If `cached_at < 60 min ago` AND its `sources` covers what you'd scrape, use it; skip to Step 4.

### 3b. Choose what to scrape based on `category_mode`

| `category_mode` | Behavior |
|---|---|
| `curated` (default) | Scrape favorites + `preferred_cuisines` + filler categories (`Drink, Side, Snack, Dairy & Eggs, Produce`). ~7 scrapes total, ~35s. |
| `whitelist` | Scrape favorites + only categories in `category_list`. |
| `blacklist` | Scrape favorites + all categories EXCEPT those in `category_list`. ~25 scrapes, slow. |
| `all` | Scrape favorites + every category (33 total). ~150s. Only for "show me everything". |

Always include `preferred_cuisines`. Always skip `cuisines_to_avoid`. If user's prompt requests a specific cuisine ("I want Thai today"), add it to the scrape set even if the filter would exclude it.

### 3c. Scrape sequentially in one tab

**Sequential, one tab, foreground.** Parallel multi-tab scrapes return partial results due to lazy-load behavior in background tabs (verified). The wall-time cost is acceptable (~5s per scrape).

For each source (favorites + each category):
1. Navigate the tab to the URL. See `SITEMAP.md` for URL patterns:
   - Favorites: `/menu/section/My%20Favorites?date=X&shippingTime=Y` (only `My%20Favorites` works with `/menu/section/`)
   - Cuisines: `/?date=X&shippingTime=Y&objType=CUISINE&objId=NAME&objName=NAME` (Chinese, Japanese, etc.)
   - Food types: `/?date=X&shippingTime=Y&objType=CATEGORY&objId=<NUM>&objName=NAME` (Drink, Side, etc. — numeric ID; discover via SITEMAP.md snippet if unknown)
2. Run the smart-scroll scrape JS (see SITEMAP.md or below).

⚠️ **Anti-pattern:** `/menu/section/Chinese` silently falls back to favorites. Always use the root URL with query params for non-favorites categories.

### 3d. Menu scrape JS

```javascript
(async () => {
  await new Promise(r => setTimeout(r, 1500));
  // Redirect detection for favorites pages — WeBox redirects favorites→full menu
  // when the target slot's cutoff has passed. Check both URL and the actual
  // rendered "My Favorites" header element (DOM is ground truth).
  const expectFavorites = location.href.includes('menu/section');
  if (expectFavorites) {
    const urlOk = /My%20Favorites|My Favorites/.test(location.href);
    const headerEl = [...document.querySelectorAll('.menu-section-header__title, [class*="section-header__title"]')]
      .find(e => /My Favorites/i.test((e.innerText || '').trim()));
    if (!urlOk || !headerEl) {
      return JSON.stringify({ error: 'redirected_from_favorites', urlOk, headerFound: !!headerEl, url: location.href });
    }
  }
  const SEL = 'app-product-menu-item.menu-section-product-item, .new-menu-product-item';
  // Wait for first render
  let waited = 0;
  while (document.querySelectorAll(SEL).length === 0 && waited < 10000) {
    await new Promise(r => setTimeout(r, 300));
    waited += 300;
  }
  // Harvest-while-scrolling: dedup by (brand, name) so we capture every item across
  // the journey even if the page virtualizes (mounts/unmounts items as you scroll).
  // Jumping to scrollHeight can skip intermediate items entirely on classic UI.
  const collected = new Map();
  const harvest = () => {
    for (const el of document.querySelectorAll(SEL)) {
      const soldOutEl = el.querySelector('.product-menu-top-sold-out-wrapper');
      if (soldOutEl && getComputedStyle(soldOutEl).display !== 'none') continue;
      const w = el.querySelector('.product-item-content-wrapper');
      const name = w?.querySelector('.product-menu-title')?.innerText?.trim();
      if (!name) continue;
      const brand = w?.querySelector('.brand-wrapper')?.innerText?.trim();
      const key = `${brand}|${name}`;
      if (collected.has(key)) continue;
      const rating = parseFloat(w?.querySelector('.product-menu-new-and-rating-wrapper')?.innerText?.trim().split('\n')[0]) || null;
      const price = parseFloat(w?.querySelector('.product-price')?.innerText?.trim().replace('$', '') || '0');
      const item = { name, brand, price };
      if (rating !== null) item.rating = rating;
      collected.set(key, item);
    }
  };
  harvest();
  // Incremental scroll — ~80% viewport per step so each row passes through view
  const step = Math.max(window.innerHeight * 0.8, 600);
  let y = 0;
  let lastSize = collected.size, stable = 0;
  for (let i = 0; i < 80; i++) {
    y += step;
    window.scrollTo(0, y);
    await new Promise(r => setTimeout(r, 600));
    harvest();
    const atBottom = y >= document.body.scrollHeight - window.innerHeight;
    if (collected.size === lastSize) {
      if (++stable >= 5 && atBottom) break;
    } else { stable = 0; }
    lastSize = collected.size;
  }
  const items = [...collected.values()];
  if (expectFavorites && items.length > 250) {
    return JSON.stringify({ error: 'suspect_redirect', count: items.length });
  }
  return JSON.stringify({ items });
})()
```

If the result is `{error: ...}`, the favorites URL got redirected — use the next orderable date+meal. For cart-side scrapes that are already for a future slot, the redirect should not happen.

### 3e. Merge + dedupe + cache

Merge all sources into one array, deduping by `(brand, name)` key. Items present in multiple sources (a Chinese snack in both `Chinese` and `Snack`) collapse into one entry with `categories: ["Chinese", "Snack"]`. Items present in favorites get `in_favorites: true`; others `false`.

Write `~/Documents/WeBox/menu-cache/YYYY-MM-DD-Meal.json`:
```json
{
  "cached_at": "2026-05-20T21:30:00",
  "date": "2026-05-21",
  "meal": "Lunch",
  "sources": ["favorites", "Chinese", "Japanese", "Drink", "Side", "Snack", "Dairy & Eggs", "Produce"],
  "items": [
    {
      "brand": "Xiangchuan Kitchen", "name": "BBQ Teriyaki Chicken Cutlet",
      "price": 14.95, "priceText": "$14.95", "rating": 4.5,
      "in_favorites": true, "categories": ["favorites", "Chinese"]
    }
  ]
}
```

Create `menu-cache/` if missing. Auto-prune cache files older than 24 hours when loading.

### Rate-limit recovery
If a page returns 0 items twice in a row or HTTP fails, wait 30s and retry once. If 3+ pages fail, ask user:
> WeBox seems rate-limiting. Want to wait 60s and retry, or proceed with what I have?

---

## Step 4: Build the Order Plan

Build a complete plan for ALL slots before touching any cart.

### Budget rules
- `spend-up-to` (default): aim to use most of budget per slot, prioritize variety
- `ceiling-only`: pick what looks best without filling
- Cap applies to food item total only (excludes delivery fees / tax)

### Quantities
Represent as `× N`:
```
- Northwest China Cuisine — Tea Egg × 6 — $14.70   ($2.45 × 6)
```
Budget validation: `unit_price × qty`.

### Selection priority

1. **Hard constraints (never violate):**
   - Dietary restrictions, allergens
   - Items rated 1/5 or tagged `never-again` in reviews
   - Strongly-negative review comments ("超级咸", "肉太少", "inedible") → hard exclude
   - Budget cap

2. **Strong preferences:**
   - Items rated 4–5/5 → top candidates
   - User's prompt constraints
   - `preferred_cuisines`

3. **Variety (mains only):**
   - Applies only to main dishes (entrées, bowls, bento, noodles, hot pots)
   - Items matching `allow_repeat_categories` or `allow_repeat_patterns` are EXEMPT — milk, water, tea egg, salad can repeat freely
   - For mains: avoid items in recent week files (within `avoid_repeat_days`)
   - Cross-day variety: don't pick the same main twice in this session

4. **Soft preferences:**
   - Items with `in_favorites: true` get a small bias over non-favorites
   - Fill remaining budget with complementary fillers if `spend-up-to`
   - User's prompt-requested cuisine restricts the MAIN only — fillers can come from any category

### Item reviews — how to read

Reviews mix optional ratings with free-form comments in any language:
- "5/5" / "amazing" / "always order" → top preference
- "4/5" / "good" → preferred
- "2-3/5" / "ok" / "a bit X" → deprioritize
- "1/5" / "never again" / "超级咸" → hard exclude (even without a number)
- Free-text option notes ("always purple rice") → apply when modal opens

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

## Step 4b: Validate Budget (if `validate_budget: true`)

```bash
uv run --no-project python -c "
items = [(17.45, 1), (2.45, 2), (5.95, 1)]  # (unit_price, qty)
budget = 30.0
total = sum(p * q for p, q in items)
assert total <= budget, f'Over budget: \${total:.2f} > \${budget:.2f}'
print(f'OK: \${total:.2f} / \${budget:.2f}')
"
```

If assertion fails: remove most expensive non-essential item, re-validate.

---

## Step 5: Confirm or Proceed

**Auto mode** (`confirm_before_order: false`, default): print plan, proceed immediately. Pause only for unresolvable ambiguity, errors, out-of-window dates.

**Confirm mode** (`confirm_before_order: true`):
```
Does this plan look good? Say "yes" to confirm, or tell me what to change.
```
Wait for reply, apply changes, re-confirm once before proceeding.

---

## Step 6: Save Plan to Order History

Before any cart action, write each planned slot to the appropriate per-week file in `~/Documents/WeBox/orders/`. Status `"planned"`. After successful checkout, remove the `planned: true` flag from the entry — that's how downstream code distinguishes active vs not-yet-placed.

Same schema as Step 1c.

---

## Step 7: Add Items to Cart (URL search + per-item)

**Use URL search per item — do NOT navigate to a slot menu and DOM-find each item.** Search is server-side, results are deterministic, and each item is an independent navigation (no cross-item state pollution).

### Per-item add (one item at a time, sequential)

For each item in the plan:

1. **Navigate via URL search:**
   ```
   https://www.webox.com/?date=YYYY-MM-DD&shippingTime=Lunch&queryText=<urlencoded-item-name>
   ```

2. **Click the first result via JS:**
   ```javascript
   (async () => {
     await new Promise(r => setTimeout(r, 2500));  // wait for results to render
     const SEL = 'app-product-menu-item.menu-section-product-item, .new-menu-product-item';
     const items = [...document.querySelectorAll(SEL)];
     if (!items.length) return { status: 'no_results' };
     const target = items[0];
     const name = target.querySelector('.product-menu-title')?.innerText?.trim();
     // Safety: verify the first result matches the intended item by token overlap
     const intended = 'INTENDED_ITEM_NAME';
     const tokens = intended.toLowerCase().split(/\s+/).filter(t => t.length > 3);
     const matchesEnough = tokens.filter(t => name?.toLowerCase().includes(t)).length >= Math.max(1, Math.floor(tokens.length / 2));
     if (!matchesEnough) return { status: 'mismatch', firstResult: name, intended };
     const btn = target.querySelector('.btn.plus-add') || target.querySelector('.product-add-wrapper');
     if (!btn) return { status: 'no_button', name };
     btn.click();
     await new Promise(r => setTimeout(r, 1200));
     const modal = !!document.querySelector('[class*="product-detail-header"]');
     return { status: modal ? 'modal_opened' : 'added_direct', name };
   })()
   ```

3. **If `modal_opened`**, handle the modal (next section). Do NOT chain more clicks in the same JS scope — that breaks if the modal stays open.

4. **Then proceed to the next item** with a fresh navigation.

### Modal handling (pure JS)

```javascript
(async () => {
  // (Optional) Check ~/Documents/WeBox/items-with-options.md for cached options;
  // if cached, find and click the matching radio first:
  //   [...document.querySelectorAll('.option-item, [class*="option"]')]
  //     .find(el => el.innerText.includes('PREFERRED_OPTION'))?.click();
  document.querySelector('st-button.add-button')?.click();
  await new Promise(r => setTimeout(r, 1000));
  document.querySelector('.anticon.anticon-close')?.click();  // modal does NOT auto-close
  await new Promise(r => setTimeout(r, 500));
  return { added: true, modalGone: !document.querySelector('[class*="product-detail-header"]') };
})()
```

After a new options-modal encounter, append to `~/Documents/WeBox/items-with-options.md`:
```
- [Brand] [Item Name] — options: "Choose Rice" (single, default: White Rice) — chosen: Purple Rice — date: YYYY-MM-DD
```

### Quantity > 1

**Item without modal:** the add script can safely loop the click N times:
```javascript
for (let i = 0; i < qty; i++) {
  btn.click();
  await new Promise(r => setTimeout(r, 400));
}
```

**Item with modal:** add once, then navigate to `/checkout` and use the cart qty stepper. See SITEMAP.md for the stepper selectors (`.input-number-wrapper.isCart .btn.plus`).

### Search returns `no_results` / `mismatch`

- `no_results`: try shorter query. If still nothing, item may be sold out — substitute from the cached menu, note in the per-week order file.
- `mismatch`: first result doesn't contain enough name tokens. Try a more specific query (include brand) or substitute.

### Complex options (5+ option groups)

Last-resort fallback to computer use. Screenshot + judgment to pick options, then run the modal-add JS above. Document chosen options in `items-with-options.md` so future runs use pure JS.

---

## Step 8: Checkout (pure JS, 2 clicks)

```javascript
(async () => {
  document.querySelector('a.cart.fr')?.click();  // navigates to /checkout
  await new Promise(r => setTimeout(r, 2500));
  if (location.pathname !== '/checkout') return { status: 'failed_to_reach_checkout' };
  // Cart-vs-plan verification — list line items for comparison
  const lineItems = [...document.querySelectorAll('.input-number-wrapper.isCart')].map(s => {
    const card = s.closest('[class*="cart-item"], [class*="cart-product"]') || s.parentElement?.parentElement;
    return { name: card?.querySelector('[class*="name"], [class*="title"]')?.innerText?.trim(), qty: s.querySelector('input')?.value };
  });
  return { status: 'at_checkout', lineItems };
})()
```

**Cart drift check:** compare `lineItems` against the planned items for this slot. If they don't match (different items, qtys, or unexpected modal-default additions), STOP and report to the user. Don't blindly Place Order.

If everything matches:
```javascript
(async () => {
  document.querySelector('.place-btn')?.click();
  await new Promise(r => setTimeout(r, 3000));
  const success = /\/order\/finish\/\d+/.test(location.pathname);
  const orderNumber = location.pathname.match(/\/order\/finish\/(\d+)/)?.[1];
  return { success, orderNumber };
})()
```

After success, immediately update the per-week order file:
- Remove `planned: true` from the entry
- Update `total` if it differs

```
✅ Order placed! Order #XXXXXXX
   Mon May 25, Lunch — $28.30
```

---

## Step 9: Repeat for Each Slot

Repeat Steps 7–8 per date+meal sequentially. Slots are independent — different carts — but multi-tab parallelism is not recommended (untested for cart/checkout). Each slot takes ~20-30s.

Final summary:
```
🎉 All done!

  Mon May 25 Lunch  $28.30 ✅ #XXXXXXX
  Mon May 25 Dinner $20.25 ✅ #XXXXXXX
  Tue May 26 Lunch  $29.50 ✅ #XXXXXXX
```

---

## Step 10: Post-Order Feedback

If the user hasn't given feedback this session, invite it:
> Done! Any feedback on dishes you've tried — good or bad — just tell me. Free-form is fine: "too dry", "loved it", "这个超级咸", etc.

Parse feedback and append to `~/Documents/WeBox/item-reviews.md`. Create the file if missing.

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

Append dated comments rather than overwriting. Only update Rating if the user gives a number explicitly.

---

## DOM Reference + URL Catalog

See `~/.claude/skills/webox/SITEMAP.md`. Don't duplicate selector docs here — they drift.

## Error Handling

| Situation | Response |
|---|---|
| Item not found in DOM | Re-scrape, then substitute from cached menu |
| Sold out at cart time | Re-scrape slot, pick substitute, note inline in order file |
| Budget exceeded mid-plan | Drop most expensive non-essential, re-plan |
| Cart drift at checkout | STOP, report to user, don't auto-place |
| Modal with 5+ option groups | Screenshot + judgment + run modal-add JS |
| Page hangs / CDP timeout | Wait 3s, retry once; skip slot if still failing |
| Outside 7-day window | Skip silently, note in summary |
| Favorites blocked / rate-limited | Hand off to `webox-favorite` (favorites-only) or wait + retry |
| 3+ scrapes fail in a row | Ask user to wait 60s |
| Cache file malformed | Treat as missing, re-scrape |
| New user, no order history | Continue with empty variety state |
