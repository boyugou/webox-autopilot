---
name: webox-onboard
description: First-time setup for webox-autopilot. Verifies Chrome + WeBox login, asks one natural-language question to capture food preferences, then fetches user profile + addresses + favorites + hidden + order history via API and creates all local data files. Run this once before using webox-order. Also handles skill updates from GitHub.
---

# WeBox Onboard Skill

First-time setup. Populates `~/Documents/WeBox/` with everything subsequent skills need.

**API-first.** All data fetched via WeBox's JSON API (verified, documented in `~/.claude/skills/webox/SITEMAP.md`). No DOM scraping.

## What gets created

- `config.yaml` — schema-locked structured settings (budget, restrictions, cuisines, etc.). Edit values, never add fields.
- `preferences.md` — free-form notes: anything that doesn't fit a structured field
- `user-profile.json` — `{firstName, lastName, phone, email, timezone, id}` (required for Place Order)
- `address-info.json` — `{addressId, userAddressId, kitchenId, timezone, address1, city, ...}` (required for Place Order)
- `shipping-windows.json` — per-meal `{shippingTimeSectionId, extFormCutoff, ...}` derived from past orders (required for Place Order body)
- `favorites.json` — enriched `{products: [{id, name, brand, category}], unresolvedProductIds, brands, synced_at}`
- `hidden.json` — same shape ("Not Interested" items)
- `orders/YYYY-Www.json` — per-ISO-week order history (active orders only)
- `item-reviews.md` — empty stub (`menu-cache/` is populated lazily on first order, not at onboard)

### Different users / addresses

Each WeBox user has their own delivery address (or multiple). The skill is per-user-correct because every value is derived dynamically from the WeBox API — nothing is hardcoded:

- `addressId` (e.g., 240212) is the **physical address record** shared by anyone delivering there. Used by all menu/order/tax APIs.
- `userAddressId` (e.g., 459170) is **your account's link** to that address. Per-user.
- `kitchenId` is **per-address** — different addresses may be served by different WeBox kitchens, each with their own menu and (potentially) their own `shippingTimeSectionId` per meal.
- `shipping-windows.json` is derived from the user's own order history, so it inherently reflects their kitchen's schedule.

When this skill runs for a different user, all values come from their `/api/v2/userAddresses/my` and `/api/orders/list`. The skill makes zero assumptions about specific IDs.

---

## Step 1: Open a Fresh Tab + Verify Login

### 1a. Get a clean tab
```
tabs_context_mcp({ createIfEmpty: true })
```
If an MCP tab group already exists, call `tabs_create_mcp()` to get a brand-new tab anyway. Capture the `tabId` and pass it to every subsequent call explicitly — don't rely on "current tab".

### 1b. Navigate to webox.com and probe login
```
navigate(<tabId>, "https://www.webox.com")
```
Wait ~2s for the page to load, then verify login via JS:
```javascript
({ loggedIn: !!document.querySelector('[class*="user-avatar"], [class*="user-name"], [class*="header-avatar"], a.cart.fr') })
```
If `loggedIn: false`:
> You're not logged into WeBox. Please log in at webox.com in Chrome and try again.

### 1c. Data directories
```bash
mkdir -p ~/Documents/WeBox/orders ~/Documents/WeBox/menu-cache
```

**Permission note:** Claude in Chrome may prompt for permission to navigate to webox.com on the first navigation per origin. This is normal — accept once.

---

## Step 2: Detect First-Run vs Returning User

Already onboarded if all of these exist:
- `~/Documents/WeBox/config.yaml`
- `~/Documents/WeBox/user-profile.json`
- `~/Documents/WeBox/address-info.json`

**If already onboarded:**
> You're already set up. What would you like to do?
> 1. **Update preferences** — I'll ask what's changed
> 2. **Re-sync everything** — hands off to `/webox-sync`
> 3. **Update the skill files** — hands off to `/webox-update`
> 4. **Nothing** — just checking

For option 3, suggest the user run `/webox-update` (separate skill — clean GitHub pull without touching local data).

**If not yet onboarded:** continue to Step 3.

---

## Step 3: Ask the Preferences Question

Say:
> Before your first order, tell me about your food preferences — anything goes: budget, diet, allergens, cuisines you love or avoid, whether you want me to confirm before ordering, drink preferences, etc. Answer however feels natural — one sentence or a full paragraph, in any language.

**Wait for the user's reply** before any further work. No background scraping while they type — surprised tabs are bad UX.

---

## Step 4: Fetch Identity + Address Only

After the user replies, fetch identity. The favorites/hidden enrichment happens in Step 6 (after the menu is fetched, so we can resolve IDs → names).

```javascript
(async () => {
  const [profile, addresses] = await Promise.all([
    fetch('/api/users/my', { credentials: 'include' }).then(r => r.json()),
    fetch('/api/v2/userAddresses/my', { credentials: 'include' }).then(r => r.json())
  ]);
  const addrs = Array.isArray(addresses.data) ? addresses.data : (addresses.data?.list || []);
  const defaultAddr = addrs.find(a => a.isDefault) || addrs[0] || null;
  const ext = defaultAddr?.extAddress || {};
  return JSON.stringify({
    profile: profile.data ? {
      id: profile.data.id,
      firstName: profile.data.firstName,
      lastName: profile.data.lastName,
      phone: profile.data.phone,
      email: profile.data.email,
      timezone: profile.data.timezone || ext.timezone || 'America/Los_Angeles'
    } : null,
    address: defaultAddr ? {
      addressId:      defaultAddr.addressId,   // canonical — used by /api/productSpecials/.../address/<X>/..., POST /api/orders, etc.
      userAddressId:  defaultAddr.id,          // your account's link to the address — used only by address-book mutations
      kitchenId:      ext.kitchenId,
      timezone:       ext.timezone,
      address1:       ext.address1,
      address2:       ext.address2,
      city:           ext.city,
      state:          ext.state,
      postcode:       ext.postcode
    } : null
  });
})()
```

**The two address IDs explained:**

| Field | Example | What it identifies |
|---|---|---|
| `addressId` | 240212 | **The canonical address record.** This is what every WeBox API uses: `/api/productSpecials/v8/address/<addressId>/...`, the menu API, the Place Order body's `order.addressId`, tax-rate, kitchen lookup, etc. |
| `userAddressId` | 459170 | The user-address association — the pointer in your account's address book. Useful only for address-book operations (set default, delete an address). NOT used in ordering. |
| `kitchenId` | 12838 | Which WeBox kitchen serves that address. From `extAddress.kitchenId`. Needed in the Place Order body. |
| `timezone` | "America/Los_Angeles" | The address's local timezone. From `extAddress.timezone`. Needed in the Place Order body. |

Write each field to its own JSON file in `~/Documents/WeBox/`:
- `user-profile.json` ← `profile`
- `address-info.json` ← `address` (now includes both `addressId` and `userAddressId` for completeness)

If `address` is null (no registered delivery address), stop:
> You don't have a delivery address set on WeBox yet. Please add one at webox.com first, then run `/webox-onboard` again.

---

## Step 5: Fetch Order History via Paginated API + Derive Shipping Windows

The full order history for a long-time user can be 400+ orders × multiple items each. Doing the entire fetch + return-all in one JS call could exceed the tool's practical payload size. Instead: run a single JS call that **accumulates into `window.__weboxOrders` and returns ONLY a summary + the small shipping-windows + the most recent few orders** for the agent to verify. The full data stays on the page object.

```javascript
(async () => {
  const params = 'client=web&status=Paid%2CPartialRefunded%2CPlanned%2CUnpaid%2CRefunded%2CCancelled%2COnHold&pageSize=10&type=Individual&orderBy=id&desc=true&referenceTypes=GROUP_ORDER_META';
  const active = [];
  const shippingWindows = {};
  let pageIndex = 1, totalCount = 0;
  while (pageIndex <= 100) {
    const r = await fetch(`/api/orders/list?${params}&pageIndex=${pageIndex}`, { credentials: 'include' });
    const j = await r.json();
    if (j.code !== 1 || !j.data?.result?.length) break;
    totalCount = j.data.totalCount;
    for (const o of j.data.result) {
      for (const pkg of (o.orderPackages || [])) {
        const ts = pkg.timeShipping;
        const ext = pkg.extShippingTimeSection;
        if (ext && !shippingWindows[ts]) {
          shippingWindows[ts] = {
            shippingTimeSectionId: pkg.shippingTimeSectionId,
            extFormCutoff: ext.extFormCutoff,
            daysBefore: ext.daysBefore || 0,
            extFormShippingBegin: ext.extFormShippingBegin,
            extFormShippingEnd: ext.extFormShippingEnd,
            cutoff_local_ms: ext.cutoff,
            shippingBegin_local_ms: ext.shippingBegin,
            shippingEnd_local_ms: ext.shippingEnd
          };
        }
        if (['Refunded', 'Cancelled'].includes(o.order?.status)) continue;  // keep Paid + Planned + PartialRefunded + Unpaid + OnHold
        active.push({
          orderId: 'No.' + o.order.id,
          dateShippingMs: pkg.dateShipping,
          timeShipping: ts,
          total: o.order.totalCharge || 0,
          items: (pkg.extItems || []).map(it => ({
            productId: it.productId,
            productSpecialId: it.productSpecialId,
            portionId: it.portionId,
            quantity: it.quantity,
            price: (it.pricePerUnitCents ?? it.priceCents ?? 0) / 100
          }))
        });
      }
    }
    if (j.data.result.length < 10) break;
    pageIndex++;
  }
  // Stash the FULL active list on the page so a follow-up call can paginate it back.
  window.__weboxOrders = active;
  // Return only a small summary + shipping-windows. The full list is fetched in chunks next.
  return JSON.stringify({
    totalCount,
    activeCount: active.length,
    pagesFetched: pageIndex,
    shippingWindows,
    // Just the latest 20 active orders inline — enough to seed orders/YYYY-Www.json for the current week.
    recentOrders: active.slice(0, 20)
  });
})()
```

**Then write `shipping-windows.json` immediately** (it's small — just two-three meal entries — no download needed; use Write tool directly).

**Then retrieve the full orders list — preferred path: download bypass (one JS call + one Bash mv).** This needs Chrome's automatic-downloads permission to be granted for `[*.]webox.com` (see "First-run permission" earlier in this skill).

```javascript
(async () => {
  const orders = window.__weboxOrders || [];
  const json = JSON.stringify({ count: orders.length, orders }, null, 2);
  const blob = new Blob([json], { type: 'application/json' });
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url;
  a.download = `webox-orders-${Date.now()}.json`;
  document.body.appendChild(a); a.click(); document.body.removeChild(a);
  setTimeout(() => URL.revokeObjectURL(url), 2000);
  return JSON.stringify({ downloadedAs: a.download, bytes: json.length, count: orders.length });
})()
```

Bash:
```bash
sleep 1.5
F="$HOME/Downloads/<downloadedAs from JS>"
if [ -f "$F" ]; then
  # Read all orders at once; group by ISO week; write per-week files.
  uv run --no-project python3 << 'EOF'
import json, os, datetime
src = json.load(open(os.path.expanduser("$F")))
weeks = {}
for o in src["orders"]:
    d = datetime.datetime.fromtimestamp(o["dateShippingMs"] / 1000, tz=datetime.timezone.utc).date()
    iy, iw, _ = d.isocalendar()
    key = f"{iy}-W{iw:02d}"
    weeks.setdefault(key, []).append({
        "date": d.isoformat(),
        "day": d.strftime("%a"),
        "meal": o["timeShipping"],
        "orderId": o["orderId"],
        "total": o["total"],
        "items": o["items"],
    })
out_dir = os.path.expanduser("~/Documents/WeBox/orders")
os.makedirs(out_dir, exist_ok=True)
for week, entries in weeks.items():
    week_start = datetime.date.fromisocalendar(int(week[:4]), int(week[6:]), 1).isoformat()
    with open(f"{out_dir}/{week}.json", "w") as fp:
        json.dump({"week": week, "week_starts": week_start,
                   "synced_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
                   "orders": entries}, fp, indent=2)
print(f"✓ wrote {len(weeks)} per-week files, {sum(len(v) for v in weeks.values())} orders total")
EOF
  rm "$F"
else
  echo "Download didn't land — falling back to chunked retrieval."
  # See "fallback" below
fi
```

**Fallback (when download bypass fails — permission not granted):**

```javascript
// Loop offset = 0, 3, 6, ... until count: 0
(async (offset) => {
  const chunk = (window.__weboxOrders || []).slice(offset, offset + 3);
  return JSON.stringify({ offset, count: chunk.length, orders: chunk });
})(/* offset */)
```

For a user with 400 active orders that's ~135 small round-trips. Process each chunk into per-week JSON in your own state, then write at the end. Much slower (~3 minutes) but always works.

**Write `~/Documents/WeBox/shipping-windows.json`** with the `shippingWindows` field:
```json
{
  "synced_at": "2026-05-21T14:30:00Z",
  "windows": {
    "Lunch": {
      "shippingTimeSectionId": 27274,
      "extFormCutoff": "08:00",
      "extFormShippingBegin": "11:00",
      "extFormShippingEnd": "12:30",
      "cutoff_local_ms": 28800000,
      "shippingBegin_local_ms": 39600000,
      "shippingEnd_local_ms": 45000000
    },
    "Dinner": {
      "shippingTimeSectionId": 27275,
      "extFormCutoff": "14:30",
      "extFormShippingBegin": "17:00",
      "extFormShippingEnd": "18:30",
      "cutoff_local_ms": 52200000,
      "shippingBegin_local_ms": 61200000,
      "shippingEnd_local_ms": 66600000
    }
  }
}
```

**Brand-new users (zero past orders):** `shipping-windows.json` will be empty. The first time the user places an order, `webox-order` will detect the missing entry, fall back to the DOM-driven path for ONE order to capture the shippingTimeSection, then save it. After that first order, future orders use the API path. (Most users have order history, so this fallback rarely triggers.)

Convert each entry to a per-week JSON file. ISO-week computation:

```javascript
// Pseudocode for the agent: convert dateShippingMs → YYYY-MM-DD → "YYYY-Www" → week file
```

For each active order, group by `isoWeek(dateShipping)` and write to `~/Documents/WeBox/orders/YYYY-Www.json`:

```json
{
  "week": "2026-W21",
  "week_starts": "2026-05-18",
  "synced_at": "2026-05-21T14:30:00Z",
  "orders": [
    {
      "date": "2026-05-21",
      "day": "Thu",
      "meal": "Lunch",
      "orderId": "No.3259401",
      "total": 21.95,
      "items": [
        { "productId": 499852, "name": "Mongolian Beef Bento", "brand": "Xiangchuan Kitchen", "price": 17.45, "quantity": 1 }
      ]
    }
  ]
}
```

**Resolving product names**: the orders API returns `productId` but not the human-readable name. Two options:
- (Recommended) Fetch the menu API once for **tomorrow's date** (Step 6 anyway) and use its `products` array as a lookup for orders that contain those products. For older orders with productIds no longer in the current menu, omit the name (use `"<unknown>"` placeholder) — the `productId` alone is enough for variety tracking.
- Or call `POST /api/products` with the list of unique productIds for full name resolution.

**Edge case:** if `activeCount === 0` (brand-new user), create `~/Documents/WeBox/orders/.empty` as a marker so Step 2 detection succeeds next time.

---

## Step 6: Fetch Menu + Enrich Favorites/Hidden + Build Warm Cache

This step enriches favorites + hidden ID lists into human-readable `{id, name, brand, category}` objects using the menu API's `products` array as a lookup.

> **Two retrieval paths, fall back if the first fails:**
>
> 1. **Download-bypass (fast):** JS builds the file content, triggers a browser download via `<a download>` Blob click. The file lands in `~/Downloads`, Bash moves it to `~/Documents/WeBox/`. One JS call + one Bash call per file.
> 2. **Chunked retrieval (slow but always works):** if the download didn't land in `~/Downloads` within ~2 seconds, fall back to slicing data off `window.__favPayload` / `window.__hidePayload` in chunks of 5.
>
> Tool-result truncation is REAL — at ~1000 characters, the model context (not just display) is cut. Anything after `[TRUNCATED]` is lost. So inline-returning a 10KB favorites payload doesn't work; you NEED one of the two paths above.
>
> Download-bypass needs Chrome's "automatic downloads" permission for webox.com (one-time grant — see "First-run permission" below). When granted, every download flows freely. Without it, only the first download per page-load succeeds; subsequent ones silently drop.

### First-run permission (do this ONCE before anything else)

Tell the user (only the first time onboarding runs):

> Quick one-time setup: open Chrome → `chrome://settings/content/automaticDownloads` → under "Allowed to automatically download multiple files" click **Add**, paste `[*.]webox.com`, save. This lets the skill write data files in one shot instead of streaming them piece-by-piece. Without it, onboarding still works but takes ~3× longer.

Detect whether the permission is granted by trying a download and checking if it lands (Step 6a does this). If the first 6a download succeeds but a follow-up doesn't, you know permission is denied.

### Step 6a — Fetch + enrich + trigger download for favorites.json

This single JS call: fetches the three APIs, enriches IDs → names, builds the full `favorites.json` content, triggers a download, stashes data on `window.*` for fallback. Returns a small summary.

```javascript
(async () => {
  const tmr = new Date(Date.now() + 86400000).toISOString().slice(0, 10);
  const addrId = /* paste integer from address-info.json's addressId */;
  const [menuR, favR, hideR] = await Promise.all([
    fetch(`/api/productSpecials/v8/address/${addrId}/date/${tmr}`, { credentials: 'include' }).then(r => r.json()),
    fetch('/api/fav/my', { credentials: 'include' }).then(r => r.json()),
    fetch('/api/hide/my', { credentials: 'include' }).then(r => r.json())
  ]);
  if (menuR.code !== 1) return JSON.stringify({ error: 'menu fetch failed', code: menuR.code, msg: menuR.msg });
  const { products, productBrands } = menuR.data;
  const productById = new Map(products.map(p => [p.id, p]));
  const brandById   = new Map(productBrands.map(b => [b.id, b]));
  const enrichProducts = (idList) => {
    const out = [], unresolved = [];
    for (const id of idList || []) {
      const p = productById.get(id);
      if (!p) { unresolved.push(id); continue; }
      out.push({ id, name: p.extName?.enUs, brand: brandById.get(p.brandId)?.extName?.enUs, category: p.category });
    }
    return { products: out, unresolved };
  };
  const enrichBrands = (idList) => (idList || []).map(id => {
    const b = brandById.get(id);
    return b ? { id, name: b.extName?.enUs } : { id, name: null };
  });
  const favE  = enrichProducts(favR.data?.productIdList);
  const hideE = enrichProducts(hideR.data?.productIdList);
  const now = new Date().toISOString();
  // Build complete payloads
  const favPayload  = { synced_at: now, products: favE.products,  unresolvedProductIds: favE.unresolved,  brands: enrichBrands(favR.data?.brandIdList) };
  const hidePayload = { synced_at: now, products: hideE.products, unresolvedProductIds: hideE.unresolved, brands: enrichBrands(hideR.data?.brandIdList) };
  // Stash for fallback chunked retrieval
  window.__favPayload   = favPayload;
  window.__hidePayload  = hidePayload;
  window.__weboxMenuRaw = menuR.data;
  // Trigger download for favorites.json (the larger of the two)
  const favJson = JSON.stringify(favPayload, null, 2);
  const blob = new Blob([favJson], { type: 'application/json' });
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url;
  a.download = `webox-favorites-${Date.now()}.json`;
  document.body.appendChild(a);
  a.click();
  document.body.removeChild(a);
  setTimeout(() => URL.revokeObjectURL(url), 2000);
  return JSON.stringify({
    downloadedAs: a.download,
    favBytes: favJson.length,
    favCount: favE.products.length,
    favUnresolved: favE.unresolved.length,
    hideCount: hideE.products.length,
    hideUnresolved: hideE.unresolved.length,
    synced_at: now
  });
})()
```

**Then Bash — wait, verify, move:**
```bash
sleep 1.5
F="$HOME/Downloads/<downloadedAs from JS>"
if [ -f "$F" ]; then
  mv "$F" ~/Documents/WeBox/favorites.json
  python3 -c "import json; d=json.load(open('$HOME/Documents/WeBox/favorites.json')); print('✓ favorites.json written:', len(d['products']), 'products')"
else
  echo "Download didn't land — Chrome permission likely not granted. Falling back to chunked retrieval (see 6a-fallback)."
fi
```

### Step 6b — Same pattern for hidden.json

Trigger a separate download (this is the SECOND download — needs Chrome permission to be granted; if not, this will silently drop):

```javascript
(async () => {
  const hideJson = JSON.stringify(window.__hidePayload, null, 2);
  const blob = new Blob([hideJson], { type: 'application/json' });
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url;
  a.download = `webox-hidden-${Date.now()}.json`;
  document.body.appendChild(a);
  a.click();
  document.body.removeChild(a);
  setTimeout(() => URL.revokeObjectURL(url), 2000);
  return JSON.stringify({ downloadedAs: a.download, bytes: hideJson.length, hideCount: window.__hidePayload.products.length });
})()
```

**Then run Bash immediately** — same pattern as 6a:

```bash
sleep 1.5
F="$HOME/Downloads/<downloadedAs from JS>"
if [ -f "$F" ]; then
  mv "$F" ~/Documents/WeBox/hidden.json
  python3 -c "import json; d=json.load(open('$HOME/Documents/WeBox/hidden.json')); print('✓ hidden.json written:', len(d['products']), 'products')"
else
  echo "Download didn't land — falling back to chunked retrieval."
fi
```

**~/Downloads is intermediate only.** Every webox-*.json file you trigger in JS MUST be moved into `~/Documents/WeBox/` by a Bash `mv` step. Leaving the file in `~/Downloads` is broken — downstream skills only read from `~/Documents/WeBox/`.

### Step 6a-fallback / 6b-fallback — Chunked retrieval (when download silently drops)

If the file didn't land in `~/Downloads`, the user hasn't granted Chrome's "automatic downloads" permission and the second+ downloads were silently blocked. Switch to chunked:

```javascript
// Loop offset = 0, 5, 10, ... until done: true
(async (offset) => {
  const products = window.__favPayload?.products || [];  // or __hidePayload
  const chunk = products.slice(offset, offset + 5);
  return JSON.stringify({ offset, total: products.length, chunkCount: chunk.length, done: offset + chunk.length >= products.length, products: chunk });
})(/* offset */)
```

Then a tail call for `brands` + `unresolvedProductIds`:
```javascript
JSON.stringify({
  synced_at: window.__favPayload.synced_at,
  brands: window.__favPayload.brands,
  unresolvedProductIds: window.__favPayload.unresolvedProductIds
})
```

Assemble the JSON object in your own state, write with the `Write` tool. Same for hidden.

### Why two paths

Empirically verified 2026-05-21:
- `javascript_tool` return values truncate at ~1000 chars in the model context, not just display. A 7438-byte single string arrives with only ~870 chars and the end-marker lost.
- Chrome's `<a download>` Blob click DOES write to `~/Downloads` reliably — BUT only the first programmatic download per origin per page-load succeeds, unless "Allow automatic downloads" is explicitly enabled. Subsequent downloads silently drop.

So:
- **Permission granted** (one-time setup) → use the download path. ~2 round trips for favorites + hidden.
- **Permission not granted** → falls back to chunked. ~40 round trips total. Still works.

### Verification

After writing, sanity-check the files:
```bash
python3 -c "import json; d = json.load(open('$HOME/Documents/WeBox/favorites.json')); print('favorites:', len(d['products']), 'products,', len(d['unresolvedProductIds']), 'unresolved')"
python3 -c "import json; d = json.load(open('$HOME/Documents/WeBox/hidden.json'));    print('hidden:',    len(d['products']), 'products,', len(d['unresolvedProductIds']), 'unresolved')"
```

The counts must match what Step 6a reported. If they don't, something was lost mid-chunk — re-run Step 6b/6c from where the count diverged.

### Schemas

**`~/Documents/WeBox/favorites.json`**:
```json
{
  "synced_at": "2026-05-21T14:30:00Z",
  "products": [
    { "id": 500874, "name": "Mongolian Beef Bento", "brand": "Xiangchuan Kitchen", "category": "Chinese" },
    { "id": 496445, "name": "Tea Egg", "brand": "Lee&Bai Chinese Bao Shop", "category": "Chinese" }
  ],
  "unresolvedProductIds": [202759, 183709],
  "brands": []
}
```

**`~/Documents/WeBox/hidden.json`** — same shape.

**Skip the warm menu-cache.** The first `/webox-order` call fetches the menu on demand (~1 second). Not worth shipping a ~400KB payload at onboard.

### Why this is human-readable

Open `favorites.json` in Finder and see "Mongolian Beef Bento — Xiangchuan Kitchen", not "500874". The bare ID Set used by selection logic is derivable in JS:
```js
const favIds = new Set(favorites.products.map(p => p.id).concat(favorites.unresolvedProductIds));
```

### About `unresolvedProductIds`

Items the user hearted (or hid) in the past but that no longer appear in the current menu — brand rotated out, item discontinued, etc. We keep their IDs so the data isn't lost; if you need their names later, `POST /api/products` with the ID list resolves them.

---

## Step 7: Write Preferences + Reviews Stub, Print Summary

### 7a. Write two files: `config.yaml` (schema-locked) + `preferences.md` (free-form)

WeBox settings live in TWO files. This separation is deliberate:

- **`~/Documents/WeBox/config.yaml`** — structured fields with a fixed schema. Downstream skills (`webox-order` etc.) only read these specific keys. **You may NOT invent new keys here.** Edit values; never rename or add fields.
- **`~/Documents/WeBox/preferences.md`** — free-form markdown. Anything goes — meal composition rules, "5/10 Chinese", "prefer purple rice", incident notes. Downstream skills read this as a soft hint and apply it on a best-effort basis.

This gives you safety (config can't drift off-schema) and freedom (notes can capture anything).

#### Procedure

1. Read the canonical templates:
   - `~/.claude/skills/webox-onboard/config.yaml` → the locked schema
   - `~/.claude/skills/webox-onboard/preferences.md` → the free-form starter

2. Write `~/Documents/WeBox/config.yaml` as a **verbatim copy** of the template, then modify ONLY the values of existing keys per the user's onboarding reply. No new keys. No renames.

3. Write `~/Documents/WeBox/preferences.md` starting from the template, then add the user's free-text intent as bullets. Anything that doesn't map cleanly to a structured `config.yaml` field belongs here.

#### CRITICAL: config.yaml schema is fixed

**Bad agent behavior we have seen and must not repeat:** earlier runs produced a preferences file with fabricated keys like `target_per_meal`, `soft_cap`, `strictly_avoid`, `prefer_instead`, `chinese_target_per_week`, `per_meal_structure`. **None of these exist in the schema.** They break every downstream skill that reads the canonical keys.

The complete set of allowed top-level keys in `config.yaml` (from the template — no others):
`budget`, `budget_mode`, `validate_budget`, `confirm_before_order`, `default_meals`, `skip_weekends`, `avoid_repeat_days`, `history_window_days`, `allow_repeat_categories`, `restrictions`, `avoid_allergens`, `preferred_cuisines`, `cuisines_to_avoid`, `foods_i_like`, `foods_to_avoid`, `order_drinks`, `avoid_sugary_drinks`, `preferred_drinks`.

#### Defaults are sacred

For any field the user did not mention, keep the template default exactly as-is. Don't infer or "improve":
- Don't downgrade `budget` because the user "sounds frugal"
- Don't switch `confirm_before_order: true` because they seem cautious
- Don't add `vegetarian` because they mentioned liking salad
- Don't shorten `history_window_days`

Only change a value if the user clearly named it or a synonym.

#### Field-mapping cheat sheet (intent → config.yaml field OR preferences.md note)

| User says (any language) | Where to encode |
|---|---|
| budget / spend / 上限 / 预算 | `config.yaml`: `budget` (numeric). Cap is always hard — planner never exceeds. |
| "use the full budget" / 尽可能用到满 / "fill up to budget" | `config.yaml`: `budget_mode: spend-up-to` (already default; this is what means "fill the budget"). The alternative `ceiling-only` means best picks without filling. |
| sugary drinks / sodas / 含糖饮料 / 汽水 / 奶茶 / boba | `config.yaml`: `avoid_sugary_drinks: true` + add patterns ("soda", "boba", "milk tea") to `foods_to_avoid`. |
| yogurt no | `config.yaml`: add `yogurt` to `foods_to_avoid`. |
| raw fish / sashimi / 生鱼 / 生食 | `config.yaml`: add `sashimi`, `raw fish`, `ceviche`, `tartare`, `salmon raw`, `tuna raw` to `foods_to_avoid`. |
| 健康 / healthy / lean / 少油 | `config.yaml`: add `fried`, `deep-fried`, `heavily oily` to `foods_to_avoid`. |
| 中餐 / Chinese | `config.yaml`: `preferred_cuisines: [Chinese, ...]`. |
| "at least N Chinese meals per week" | `preferences.md`: free-text bullet — no structured field for ratios. |
| fresh fruit / milk preferred for filling | `config.yaml`: add `fresh fruit`, `milk` to `foods_i_like`. |
| vegetarian / vegan / halal / kosher / gluten-free | `config.yaml`: `restrictions: [...]`. |
| nut / shellfish / dairy / eggs allergy | `config.yaml`: `avoid_allergens: [...]`. |
| "don't ask, just order" / 不用问 | `config.yaml`: `confirm_before_order: false` (already default). |
| "show me the plan first" / 让我确认 | `config.yaml`: `confirm_before_order: true`. |
| "skip weekends" / 不要周末 | `config.yaml`: `skip_weekends: true` (already default). |
| "include weekends" / 要周末 | `config.yaml`: `skip_weekends: false`. |
| meal composition (1 main + sides vs big bowl) | `preferences.md`: free-text — no structured field. |
| portion size hints / "not a big eater" | `preferences.md`: free-text. |
| anything not covered above | `preferences.md`. |

#### Verification before declaring done

After writing `~/Documents/WeBox/config.yaml`, run this schema-check:
```bash
python3 -c "
import re
with open('$HOME/Documents/WeBox/config.yaml') as f: text = f.read()
allowed = {'budget','budget_mode','validate_budget','confirm_before_order','default_meals','skip_weekends',
           'avoid_repeat_days','history_window_days','allow_repeat_categories',
           'restrictions','avoid_allergens','preferred_cuisines','cuisines_to_avoid',
           'foods_i_like','foods_to_avoid','order_drinks','avoid_sugary_drinks','preferred_drinks'}
keys = set(re.findall(r'^(\w+):', text, re.M))
extra = keys - allowed
print('UNKNOWN KEYS — REWRITE FROM TEMPLATE:' if extra else 'OK: all keys canonical.', sorted(extra) if extra else '')
"
```

If anything is reported UNKNOWN, the file is off-schema — rewrite it from the template before finishing the onboarding.

### 7b. Create empty item-reviews.md (if missing)

```markdown
# Item Reviews

<!-- Add reviews here, or just tell Claude Code about a dish and it will record them for you. -->
<!-- Examples: -->
<!--   "The Mongolian Beef bento from Xiangchuan Kitchen is amazing, 5/5" -->
<!--   "这个超级咸，别再点了" -->
```

### 7c. Cleanup any orphan files left in ~/Downloads

Belt-and-suspenders: occasionally a `mv` in an earlier step might fail silently (disk-full, weird permissions, user already moved the file). Sweep `~/Downloads` for any leftover `webox-*.json` files from this onboard session and delete them — they're already either successfully copied into `~/Documents/WeBox/` or stale.

```bash
# Any webox-*.json files older than ~5 minutes are stale by now (onboard has finished its writes)
find ~/Downloads -maxdepth 1 -name "webox-*.json" -print -delete 2>/dev/null
```

If any were deleted, log them — that's a signal that a previous step's `mv` didn't run cleanly. Compare counts in `~/Documents/WeBox/favorites.json` etc. against what was reported in earlier steps; if mismatched, the user should re-run `/webox-sync` or `/webox-onboard`.

### 7d. Summary

Echo only what CHANGED from defaults — and confirm the per-file counts:

```
✅ WeBox setup complete.

Changed from defaults:
  - budget: 25.00 (was 30.00)
  - restrictions: [vegetarian]
Everything else kept default.

Files in ~/Documents/WeBox/:
  config.yaml              — structured settings (budget, restrictions, drinks, ...)
  preferences.md           — free-form notes (edit in Finder anytime)
  user-profile.json        — Boyu Gou, boyu.gou@..., 6145568304
  address-info.json        — 1881 Page Mill Rd (kitchen 12838)
  shipping-windows.json    — Lunch + Dinner cutoff windows (from your past orders)
  favorites.json           — 131 hearted products
  hidden.json              — 180 "Not Interested" products
  orders/                  — 407 past active orders across N weeks
  item-reviews.md          — empty (grows as you order)

You're ready to order. Try:
  "Order my lunch for tomorrow"        (full menu via webox-order)
  "Order from my favorites tomorrow"   (narrow scope via webox-favorite)
  "Show my WeBox calendar"             (via webox-sync)
```

If the user said nothing specific:
```
✅ WeBox setup complete using all default preferences.
```

---

## Step 8: Update Skill (if user picked Option 3 in Step 2)

This is now a dedicated skill — hand off:

> To update the skill files, run `/webox-update`. It pulls the latest from GitHub, diffs the schema against your local config.yaml, and tells you whether you need to re-onboard. Your data in `~/Documents/WeBox/` is preserved.

Don't reimplement the update flow here — `/webox-update` is the single source of truth for that workflow.
