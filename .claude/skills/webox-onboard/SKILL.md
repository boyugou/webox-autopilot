---
name: webox-onboard
description: First-time setup for webox-autopilot. Verifies Chrome + WeBox login, asks one natural-language question to capture food preferences, scrapes favorites and order history in the background, and creates all local data files. Run this once before using webox-order. Also handles skill updates from GitHub.
---

# WeBox Onboard Skill

Run this once when you first install webox-autopilot, or when you want to re-run setup. Also handles updating the skill files from GitHub.

Data directory: `~/Documents/WeBox/`  
All files are plain text — open them in any editor or Finder.

---

## What this skill does

1. Verifies Claude in Chrome is connected and WeBox is logged in
2. Asks one open-ended question about your food preferences
3. After you reply, scrapes your favorites and order history sequentially in one tab (~10-15s total)
4. Writes all data files to `~/Documents/WeBox/`
5. Shows a summary

If you've already run onboarding, it offers to update preferences, re-sync data, or update the skill itself.

---

## Step 1: Check Prerequisites (single batch, fast)

Run all of these in ONE `browser_batch` call to minimize round-trips and permission prompts:

```
browser_batch([
  tabs_context_mcp,                                       # verify Chrome connected
  navigate(main_tab, "https://www.webox.com"),           # also serves as login check
])
```

Then in JavaScript on the main tab, check for login state:
```javascript
({ loggedIn: !!document.querySelector('[class*="user-avatar"], [class*="user-name"], [class*="header-avatar"], a.cart.fr') })
```
`a.cart.fr` is the cart icon — only present when logged in.

If `loggedIn: false`:
> You're not logged into WeBox. Please log in at webox.com in Chrome and try again.

Then create the data directory:
```bash
mkdir -p ~/Documents/WeBox
```

**Permission note:** Claude in Chrome may ask the user for permission to navigate to webox.com on the FIRST navigation. This is normal and only happens once per origin. Don't navigate to webox.com multiple times — one nav is enough.

---

## Step 2: Detect First-Run vs Returning User

A user is considered **already onboarded** if **both** of these are true:
- `~/Documents/WeBox/preferences.md` exists, AND
- `~/Documents/WeBox/orders/` directory exists with at least one `YYYY-Www.json` file (or is documented as empty after a sync that returned no orders)

Both confirm onboarding actually ran (a stray preferences file alone — manually copied or left from a prior partial setup — wouldn't indicate history was synced).

**If already onboarded:**

> You're already set up! Here's what I found in ~/Documents/WeBox/:
> - preferences.md ✓
> - item-reviews.md (X items reviewed)
> - orders/ (X weeks of history, latest sync DATE, Y total active orders)
> - menu-cache/ (X cached slot snapshots)
>
> What would you like to do?
> 1. **Update preferences** — I'll ask what's changed
> 2. **Re-sync order history** — pull the latest orders from WeBox (hands off to `webox-sync-calendar`)
> 3. **Clear menu caches** — force a fresh menu scrape on your next order
> 4. **Update the skill** — pull the latest version from GitHub
> 5. **Nothing** — just checking

Handle the user's choice. For option 3 — `rm -f ~/Documents/WeBox/menu-cache/*.json`. For option 4, jump to Step 6.

**If not yet onboarded:** continue to Step 3 (ask question, wait for reply), then Step 4 (scrape sequentially after reply).

---

## Step 3: Ask the preferences question

Say:

> Before your first order, tell me about your food preferences — anything goes: budget, diet, allergens, cuisines you love or avoid, whether you want me to confirm before ordering, drink preferences, etc. Answer however feels natural — one sentence or a full paragraph, in any language.

**Then wait for the user's reply. Do not start scraping yet** — scraping in parallel with the question opens multiple tabs the user didn't expect and may produce unreliable results (background-tab lazy load is inconsistent). Scrape AFTER the user replies, in Step 4.

## Step 4: Scrape sequentially (after the user has replied)

Two scrapes, one tab at a time, in the same single tab where possible. Total time ~10–15s.

**4a. Order history first** — navigate the existing main tab to `https://www.webox.com/order/list/normal` and run the smart-scroll scrape from SCRIPT_4A below. Convert each order to per-week JSON and save to `~/Documents/WeBox/orders/YYYY-Www.json` (see schema in Step 5b).

**4b. Then favorites** — use **tomorrow's date** (not today). Today's Lunch cutoff may have passed, which causes WeBox to silently redirect from the favorites URL to the next orderable slot's full-menu view (returns 100+ wrong items, not favorites). Navigate the same tab to `https://www.webox.com/menu/section/My%20Favorites?date=<TOMORROW_YYYY-MM-DD>&shippingTime=Lunch` and run SCRIPT_4B. Save to `~/Documents/WeBox/menu-cache/<TOMORROW>-Lunch.json` as the warm cache.

Reusing the same tab avoids the multi-tab permission prompts and the "what are these tabs" surprise. Each scrape is ~5s, sequential total ~10s.

#### 4a. Order history scrape (SCRIPT_4A)

The order list page is heavier than menu pages. **Keep scrolls fast (300ms) and capped at 8** to avoid CDP timeouts. Smart-scroll terminates as soon as no new items load:

```javascript
(async () => {
  await new Promise(r => setTimeout(r, 1500));
  let lastCount = 0, stable = 0;
  for (let i = 0; i < 8; i++) {
    window.scrollTo(0, document.body.scrollHeight);
    await new Promise(r => setTimeout(r, 350));
    const cnt = document.querySelectorAll('.order-item').length;
    if (cnt === lastCount) { if (++stable >= 2) break; } else { stable = 0; }
    lastCount = cnt;
  }
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
  const synced = now.toISOString();
  const weeks = {};
  for (const o of document.querySelectorAll('.order-item')) {
    const orderStatus = o.querySelector('.order-status')?.innerText?.trim() || 'Paid';
    if (/refund|cancel/i.test(orderStatus)) continue;
    const lines = o.innerText.split('\n').map(l => l.trim()).filter(Boolean);
    const dateLine = lines.find(l => /^(Mon|Tue|Wed|Thu|Fri|Sat|Sun)\s+\d{2}\/\d{2}$/.test(l));
    const mealLine = lines.find(l => /^(Lunch|Dinner|HappyHour)(\s|\(|$)/.test(l));
    if (!dateLine || !mealLine) continue;
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
    const key = `${fullDate}|${meal}|${items[0].name}`;
    if (weeks[wk].orders.some(x => `${x.date}|${x.meal}|${x.items[0].name}` === key)) continue;
    weeks[wk].orders.push({ date: fullDate, day, meal, items });
  }
  return JSON.stringify(weeks);
})()
```

**Output is directly writable** — keyed by ISO week. For each key, write `~/Documents/WeBox/orders/<key>.json` with the value as the file content. No post-processing. If empty (new user), create `~/Documents/WeBox/orders/.empty` marker instead.

Empty result (new user, no orders) → create `~/Documents/WeBox/orders/.empty` marker so the "already onboarded" check in Step 2 succeeds on next run.

**Recovery if CDP times out:** if this script times out, the order list page may be hung. Skip it for first-run (just create the `.empty` marker) — webox-sync-calendar will do the first sync later. Don't retry in onboarding — onboarding shouldn't block on this.

#### 4b. Favorites scrape (SCRIPT_4B)

Use **tomorrow's date** in `YYYY-MM-DD` format when constructing the URL (today's slot may have its cutoff passed, causing WeBox to silently redirect):
```
https://www.webox.com/menu/section/My%20Favorites?date=<TOMORROW_YYYY-MM-DD>&shippingTime=Lunch
```

```javascript
(async () => {
  await new Promise(r => setTimeout(r, 1500));
  // Redirect detection — WeBox silently redirects favorites→full menu when the
  // target slot's cutoff has passed. Check URL AND the rendered "My Favorites"
  // section header in the DOM (ground truth). If either is off → redirected.
  const urlOk = /My%20Favorites|My Favorites/.test(location.href);
  const headerEl = [...document.querySelectorAll('.menu-section-header__title, [class*="section-header__title"]')]
    .find(e => /My Favorites/i.test((e.innerText || '').trim()));
  if (!urlOk || !headerEl) {
    return JSON.stringify({ error: 'redirected', urlOk, headerFound: !!headerEl, url: location.href, hint: 'Use a later orderable date+meal' });
  }
  const SELECTORS = 'app-product-menu-item.menu-section-product-item, .new-menu-product-item';
  let lastCount = 0, stable = 0;
  for (let i = 0; i < 12; i++) {
    window.scrollTo(0, document.body.scrollHeight);
    await new Promise(r => setTimeout(r, 350));
    const cnt = document.querySelectorAll(SELECTORS).length;
    if (cnt === lastCount) { if (++stable >= 2) break; } else { stable = 0; }
    lastCount = cnt;
  }
  const items = [...document.querySelectorAll(SELECTORS)].map(item => {
    const wrapper = item.querySelector('.product-item-content-wrapper');
    const brand = wrapper?.querySelector('.brand-wrapper')?.innerText?.trim();
    const name = wrapper?.querySelector('.product-menu-title')?.innerText?.trim();
    const priceText = wrapper?.querySelector('.product-price')?.innerText?.trim();
    const price = parseFloat(priceText?.replace('$', '') || '0');
    const rating = parseFloat(wrapper?.querySelector('.product-menu-new-and-rating-wrapper')?.innerText?.trim().split('\n')[0]) || null;
    const soldOutEl = item.querySelector('.product-menu-top-sold-out-wrapper');
    const soldOut = soldOutEl ? getComputedStyle(soldOutEl).display !== 'none' : false;
    return { brand, name, price, priceText, rating, soldOut };
  }).filter(i => i.name);
  // Sanity guard: favorites typically returns 10-200 items. If 200+, redirect probably happened but URL check missed.
  if (items.length > 250) {
    return JSON.stringify({ error: 'suspect_redirect', count: items.length, hint: 'Try a later date' });
  }
  return JSON.stringify({ items });
})()
```

If the result is `{error: "redirected", ...}` or `{error: "suspect_redirect", ...}`, retry with the next orderable date+meal slot. If even tomorrow's Lunch redirects, the user may have no orderable slots in the immediate future — just write `~/Documents/WeBox/menu-cache/<TOMORROW>-Lunch.json` with an empty `items: []` and note in the summary.

Otherwise: result is `{items: [...]}` — write the items array to `~/Documents/WeBox/menu-cache/<TOMORROW>-Lunch.json` wrapped in the standard cache schema (Step 5c).

---

## Step 5: Process the User's Reply

When the user responds to the onboarding question:

### 5a. Parse and write preferences

The canonical preferences template is `preferences.md` in the webox-autopilot repo root — read it (or load the cached copy from the repo clone) and write that exact content to `~/Documents/WeBox/preferences.md`, replacing values **only for fields the user explicitly mentioned**.

#### CRITICAL: defaults are sacred

**For any field the user did not mention, KEEP THE TEMPLATE'S DEFAULT EXACTLY AS-IS.** Do not invent, infer, or "improve" values the user didn't ask for.

- Don't downgrade the default budget because the user "sounds frugal"
- Don't add cuisines to `cuisines_to_avoid` because the user didn't mention them as preferred
- Don't switch `confirm_before_order` to `true` because the user seems cautious
- Don't shrink `history_window_days` because the user didn't ask
- Don't add `vegetarian` because the user mentioned liking vegetables

The user can always edit the file later or tell Claude to update specific fields. Inferring or guessing creates surprise behavior the user can't trace back to anything they said.

Only change a field if the user clearly named it or named a synonym ("budget" / "spend" / "cap" / "上限" → `budget`; "vegetarian" / "vegan" / "no meat" → `restrictions`; etc.).

The template includes inline comments explaining each option (`# spend-up-to | ceiling-only`, the full categories list, etc.). Preserve these — the file is meant to be human-editable in Finder.

Free-text observations the user volunteered that don't map to any structured field go into the `## Notes` section at the bottom (preserve the template's helper comment above it).

Example mappings (only change explicitly stated fields):
- "vegetarian" → `restrictions: [vegetarian]` (other dietary fields untouched)
- "budget around 25" → `budget: 25.00` (budget_mode etc. unchanged)
- "ask me first" / "confirm before ordering" → `confirm_before_order: true`
- "love spicy Thai food" → add `Thai` to `preferred_cuisines` IF the user named it; otherwise just append "loves spicy Thai" to `foods_i_like`
- "no dairy" → `avoid_allergens: [dairy]`
- "5 milks a week" → leave defaults; mention in `## Notes`

#### Summary back to the user

After writing the file, echo only what you CHANGED from defaults — not the whole config. This makes it easy for the user to spot if you misinterpreted anything:

```
✅ Saved preferences. Changed from defaults:
  - budget: 25.00 (was 30.00)
  - restrictions: [vegetarian]
  - confirm_before_order: true
Everything else kept default. Edit ~/Documents/WeBox/preferences.md anytime.
```

If the user didn't mention anything specific, that's fine — say so:
```
✅ Saved preferences using all defaults. Edit ~/Documents/WeBox/preferences.md anytime.
```

### 5b. Write per-week order files from scraped data

For each scraped active order:
1. Convert `"Mon 05/18"` to a full ISO date (use current year; if the resulting date is in the future, use previous year).
2. Compute the ISO week → `YYYY-Www` (e.g. `2026-W21` for Mon 2026-05-18).
3. Read or create `~/Documents/WeBox/orders/<YYYY-Www>.json` and append/merge.

Schema (matches what the scraper returns directly — just iterate the returned object's keys and write each value as the file content):
```json
{
  "week": "2026-W21",
  "week_starts": "2026-05-18",
  "synced_at": "2026-05-21T14:30:00Z",
  "orders": [
    {
      "date": "2026-05-18",
      "day": "Mon",
      "meal": "Lunch",
      "items": [
        { "name": "Mongolian Beef Bento", "brand": "Xiangchuan Kitchen", "price": 17.45 }
      ]
    }
  ]
}
```

The scraper handles dedup internally (date+meal+first item name). If a week file already exists locally with `planned: true` entries from `webox-order`, preserve them — only overwrite entries whose `date+meal` match.

If scrape returned 0 orders (new user), create `~/Documents/WeBox/orders/.empty` as a marker so future runs detect "onboarded" correctly.

### 5c. Write today's menu cache (warm cache for first order)

If the favorites scrape (Step 4b) returned items, write `~/Documents/WeBox/menu-cache/<TODAY>-Lunch.json`:

```json
{
  "cached_at": "ISO-8601",
  "date": "<TODAY>",
  "meal": "Lunch",
  "sources": ["favorites"],
  "items": [
    {
      "brand": "Xiangchuan Kitchen",
      "name": "BBQ Teriyaki Chicken Cutlet",
      "price": 14.95,
      "priceText": "$14.95",
      "rating": 4.5,
      "in_favorites": true,
      "categories": ["favorites"]
    }
  ]
}
```

Create the `menu-cache/` directory if it doesn't exist. If favorites returned empty, skip this step.

### 5d. Create empty item-reviews.md (if missing)

```markdown
# Item Reviews

<!-- Add reviews here, or just tell Claude Code about a dish and it will record them for you. -->
<!-- Examples: -->
<!--   "The Mongolian Beef bento from Xiangchuan Kitchen is amazing, 5/5" -->
<!--   "这个超级咸，别再点了" -->
<!--   "肉太少，分量不够" -->

```

### 5e. Print summary

```
✅ WeBox setup complete! Files in ~/Documents/WeBox/:

  preferences.md            — budget $30, prefer Chinese/Japanese, no mushrooms
  item-reviews.md           — empty (grows as you order and give feedback)
  orders/2026-W21.json, ... — X weeks of history, Y past active orders
  menu-cache/<TODAY>.json   — X favorites scraped as warm cache for first order

You're ready to order! Try:
  "Order my lunch for tomorrow"        (default — curated full menu via webox-order)
  "Order from my favorites tomorrow"   (faster narrow scope via webox-favorite)
  "Show my WeBox calendar"             (via webox-sync-calendar)
```

Tailor the preferences summary line to what the user actually told you.

---

## Step 6: Update the Skill

If the user asked to update the skill (option 4 in Step 2, or says "update webox-autopilot" / "upgrade webox"):

```bash
# Show current version (for comparison)
ls -la ~/.claude/skills/webox-order/SKILL.md 2>/dev/null

# Clone latest and run installer
git clone https://github.com/boyugou/webox-autopilot.git /tmp/webox-autopilot-update
cd /tmp/webox-autopilot-update && git log --oneline -1
bash /tmp/webox-autopilot-update/install.sh
rm -rf /tmp/webox-autopilot-update
```

After update:
- Report which commit was just installed
- Note that the current Claude Code session is still running the old skill files in memory — restart Claude Code for the new version to take effect
- `~/Documents/WeBox/` files (preferences, reviews, history, caches) are never touched
