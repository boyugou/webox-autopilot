---
name: webox
description: General WeBox knowledge loader for ad-hoc tasks. Loads the API + URL + DOM reference, then lets the agent improvise. Use for free-form WeBox questions like "what's available for lunch tomorrow", "check my cart", "search for noodles on Friday", "hide all sugary drinks" — anything that doesn't fit the dedicated webox-order / webox-favorite / webox-sync / webox-onboard / webox-reset skills.
---

# WeBox General Skill (Knowledge Loader)

Invoked for ad-hoc WeBox tasks that don't map cleanly to one of the dedicated skills.

> **CRITICAL — about `javascript_tool` return values:**
> The string returned by `javascript_tool` IS the full payload. **Never write to `~/Downloads/`** or use blob/URL-download tricks from JS. Terminal display truncates around ~1KB but the result reaches your tool-result in full. For huge payloads, paginate by stashing on `window.__webox*` and slicing back in smaller calls.

## Step 1: Load Knowledge

Read `~/.claude/skills/webox/SITEMAP.md` (full content). It catalogs:
- **The full API surface** (prefer this over DOM): menu, favorites, hidden, order history, Place Order, "Not Interested", etc.
- URL patterns (favorites, cuisine categories, search via `queryText`, checkout, order history)
- DOM selectors (legacy / fallback)
- Login state probe
- Useful tiny scripts

Also read the four cached identity files if present (the user has presumably run `/webox-onboard`):
- `~/Documents/WeBox/user-profile.json` → `{firstName, lastName, phone, email, timezone}`
- `~/Documents/WeBox/address-info.json` → `{addressId, kitchenId, timezone}`
- `~/Documents/WeBox/favorites.json` → `{products: [{id, name, brand, category}], unresolvedProductIds, brands, synced_at}`
- `~/Documents/WeBox/hidden.json` → same shape

Plus `~/Documents/WeBox/preferences.md` for the user's preferences.

## Step 2: Prerequisite Check

1. Call `tabs_context_mcp({ createIfEmpty: true })`. If a tab group exists, create a fresh tab to avoid stale state.
2. Verify WeBox login by navigating to `https://www.webox.com` and checking for `a.cart.fr`.

If the user has no `address-info.json`, suggest they run `/webox-onboard` first for any ordering-related task. Ad-hoc reads can usually proceed without it.

## Step 3: Use Judgment (API-first patterns)

You now have:
- Full WeBox API knowledge (SITEMAP.md)
- A logged-in Chrome session
- The user's identity caches
- The user's specific request

### Common patterns

| User says | Recommended approach |
|---|---|
| "What's available for dinner Friday?" | `GET /api/productSpecials/v8/address/<A>/date/<D>`, extract `dinnerSpecials`, join with `products`, summarize |
| "Search for noodles on Tuesday" | Same fetch + filter `items` by `name` matching "noodle" |
| "What's in my cart?" | `JSON.parse(localStorage.getItem('CartService_cartItemArrMap'))` — cart is fully client-side |
| "Clear my cart" | `localStorage.removeItem('CartService_cartItemArrMap')` + reload |
| "Show my last 5 orders" | `GET /api/orders/list?pageSize=5&pageIndex=1` |
| "Cancel my order #N" | Try the templated cancel endpoints in SITEMAP; verify with the user before firing |
| "Hide all sugary drinks" | See "Bulk operations" below |
| "What are my favorites?" | `GET /api/fav/my` + join with the next-day's menu for names |

### Bulk operations (API loop)

The user can ask things like "hide all sugary drinks", "favorite every Korean main", "un-hide everything I hid last month". These are scriptable loops:

**Bulk hide ("Not Interested") matching a filter:**
```javascript
(async () => {
  // 1. Fetch menu for any date to get the products catalog
  const addrId = /* from address-info.json */;
  const date = /* tomorrow or any orderable date */;
  const r = await fetch(`/api/productSpecials/v8/address/${addrId}/date/${date}`, { credentials: 'include' });
  const j = await r.json();
  const { products, productBrands } = j.data;
  const brandById = new Map(productBrands.map(b => [b.id, b]));
  // 2. Filter products by your criterion — example: sugary drinks
  const matches = products.filter(p => {
    const name = (p.extName?.enUs || '').toLowerCase();
    return p.category === 'Drink' && /soda|sweet|cola|sugar|boba|bubble|milk tea/.test(name);
  });
  // 3. Loop POST userHide
  const results = [];
  for (const p of matches) {
    const r2 = await fetch('/api/userHide/addHide?client=web', {
      method: 'POST', credentials: 'include',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ hideType: 'Product', hideId: p.id })
    });
    const j2 = await r2.json();
    results.push({ id: p.id, name: p.extName?.enUs, brand: brandById.get(p.brandId)?.extName?.enUs, code: j2.code });
  }
  return JSON.stringify({ matchedCount: matches.length, results });
})()
```

**Reverse (un-hide):** same loop with `POST /api/userHide/removeHide`.

**Bulk favorite/unfavorite:** `POST /api/favProducts/<id>?client=web` / DELETE on same path.

**Always confirm before bulk writes.** Show the user the matched items first ("about to hide 14 sugary drinks: …"), wait for "yes", then loop. Don't auto-execute large mutations without confirmation.

### JS-first principle still applies

Use API + JS selectors over slow image+coordinate clicks. Computer-use is the absolute last resort.

## Step 4: When to Hand Off

If the user's request matches a dedicated skill's job, suggest invoking it explicitly:

- Wants to **place an order** → `/webox-order` (smart default) or `/webox-favorite` (narrow)
- Wants to **view/sync the calendar** → `/webox-sync`
- Wants to **set up or update preferences** → `/webox-onboard`
- Wants to **wipe local data** → `/webox-reset`

For everything else — search, inspect, browse, bulk hide/favorite — handle it inline using SITEMAP.md.

## Step 5: Don't Write to Local Files Without Reason

This skill is read-only by default. Don't modify `~/Documents/WeBox/` files (preferences, profile, orders, reviews, menu-cache) unless the user explicitly asks for it. If they do (e.g., "save this dish as 5/5"), append to `item-reviews.md` carefully.

Mutations on WeBox (`POST /api/userHide/addHide`, `POST /api/favProducts/<id>`, etc.) DO write to WeBox's database — always confirm with the user before firing bulk loops.
