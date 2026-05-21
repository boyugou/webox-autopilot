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
3. While you type the answer, scrapes your favorites and order history in parallel
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
- `~/Documents/WeBox/order-history.md` exists

Both files together confirm onboarding actually ran (a stray preferences file alone — manually copied or left from a prior partial setup — wouldn't indicate that history was synced).

**If already onboarded:**

> You're already set up! Here's what I found in ~/Documents/WeBox/:
> - preferences.md ✓
> - item-reviews.md (X items reviewed)
> - favorites-cache.md (last updated: DATE, X items)
> - order-history.md (last synced: DATE, X past orders)
>
> What would you like to do?
> 1. **Update preferences** — I'll ask what's changed
> 2. **Re-sync favorites** — re-scrape your WeBox favorites page
> 3. **Re-sync order history** — pull the latest orders from WeBox
> 4. **Update the skill** — pull the latest version from GitHub
> 5. **Nothing** — just checking

Handle the user's choice. For option 4, jump to Step 6.

**If not yet onboarded:** continue to Step 3 and Step 4 (which run in the same turn — see notes).

---

## Step 3 + Step 4: Ask Question + Launch Parallel Scrapes

**CRITICAL: do these as ONE response turn, with TWO new tabs created and BOTH scrapes kicked off in a SINGLE `browser_batch` call.** Do not scrape sequentially. Do not navigate the main tab — leave it alone so the user can see what's happening.

### Step 3: Ask the preferences question

In your response text (BEFORE the tool calls):

> Before your first order, tell me about your food preferences — anything goes: budget, diet, allergens, cuisines you love or avoid, whether you want me to confirm before ordering, drink preferences, etc. Answer however feels natural — one sentence or a full paragraph, in any language.
>
> *(I'm scraping your order history and favorites in the background while you type.)*

### Step 4: Launch both scrapes in a single browser_batch call

Use this exact pattern — create both tabs, navigate both, then JS-execute both, all in ONE `browser_batch`:

```
browser_batch([
  # Create tab 1 — order history
  { name: "tabs_create_mcp", input: { url: "https://www.webox.com/order/list/normal" } },
  # Create tab 2 — favorites (use today's date in YYYY-MM-DD)
  { name: "tabs_create_mcp", input: { url: "https://www.webox.com/menu/section/My%20Favorites?date=<TODAY>&shippingTime=Lunch" } },
])
```

After the batch returns the two tab IDs, IMMEDIATELY issue a SECOND `browser_batch` that runs JS in both tabs in parallel:

```
browser_batch([
  { name: "javascript_tool", input: { action: "javascript_exec", tabId: <HISTORY_TAB_ID>, text: <SCRIPT_4A> } },
  { name: "javascript_tool", input: { action: "javascript_exec", tabId: <FAVORITES_TAB_ID>, text: <SCRIPT_4B> } },
])
```

`browser_batch` items execute sequentially in the same round-trip but each runs to completion in its own tab — meaning **both scrapes overlap in time** because each spends most of its time inside the JS `await sleep()` waiting for the page to lazy-load. Net effect: ~2x faster than serial.

#### 4a. Order history scrape (SCRIPT_4A)

The order list page is heavier than menu pages. **Keep scrolls fast (300ms) and capped at 8** to avoid CDP timeouts. Smart-scroll terminates as soon as no new items load:

```javascript
(async () => {
  await new Promise(r => setTimeout(r, 1500));  // initial paint
  let lastCount = 0, stable = 0;
  for (let i = 0; i < 8; i++) {
    window.scrollTo(0, document.body.scrollHeight);
    await new Promise(r => setTimeout(r, 350));
    const cnt = document.querySelectorAll('.order-item').length;
    if (cnt === lastCount) { if (++stable >= 2) break; } else { stable = 0; }
    lastCount = cnt;
  }
  const orders = [...document.querySelectorAll('.order-item')].map(o => {
    const orderId = o.querySelector('.order-id')?.innerText?.trim();
    const orderStatus = o.querySelector('.order-status')?.innerText?.trim();
    const lines = o.innerText.split('\n').map(l => l.trim()).filter(Boolean);
    const dateLine = lines.find(l => /^(Mon|Tue|Wed|Thu|Fri|Sat|Sun)\s+\d{2}\/\d{2}$/.test(l));
    const mealLine = lines.find(l => /^(Lunch|Dinner|HappyHour)$/.test(l));
    const itemLines = lines.filter(l =>
      l !== dateLine && l !== mealLine && l !== orderId && l !== orderStatus &&
      !/^(Order|Invoice|Details|Reorder|Cancel|View|Track|Total:|Refunded|No\.\d)/i.test(l) &&
      !/^\$/.test(l) && l.length > 3
    );
    const isActive = !orderStatus || !/refund|cancel/i.test(orderStatus);
    return { date: dateLine, meal: mealLine, orderId, orderStatus: orderStatus || 'active', isActive, items: itemLines };
  }).filter(o => o.date && o.meal);
  return JSON.stringify(orders);
})()
```

Mark only `isActive: true` entries as `✅` in `order-history.md`. Refunded/cancelled → `↩️` and slot stays openable. Empty result → write a "no orders yet" placeholder.

**Recovery if CDP times out:** if this script times out, the order list page may be hung. Skip it for first-run (write an empty order-history.md with a comment "first sync deferred — will retry on first webox-order call"). Don't retry in onboarding — onboarding shouldn't block on this.

#### 4b. Favorites scrape (SCRIPT_4B)

Use today's date in `YYYY-MM-DD` format (e.g., `2026-05-20`) when constructing the URL:
```
https://www.webox.com/menu/section/My%20Favorites?date=<TODAY_YYYY-MM-DD>&shippingTime=Lunch
```

```javascript
(async () => {
  await new Promise(r => setTimeout(r, 1500));  // initial paint
  const SELECTORS = 'app-product-menu-item.menu-section-product-item, .new-menu-product-item';
  let lastCount = 0, stable = 0;
  for (let i = 0; i < 12; i++) {
    window.scrollTo(0, document.body.scrollHeight);
    await new Promise(r => setTimeout(r, 350));
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

Note: favorites are scraped without sold-out filtering — the list shows all hearted items regardless of today's availability.

If favorites returns `[]`, write an empty `favorites-cache.md` and note in Step 5b that the user has no favorites yet.

---

## Step 5: Process the User's Reply

When the user responds to the onboarding question:

### 5a. Parse and write preferences

The canonical preferences template is `preferences.md` in the webox-autopilot repo root — read it (or load the cached copy from the repo clone) and write that exact content to `~/Documents/WeBox/preferences.md`, replacing the YAML values with whatever the user actually said in their onboarding reply.

If the user did not mention a field, keep the template's default. Put any free-text observations that don't map to a field into the `## Notes` section at the bottom (preserving the template's helper comment above it).

The template includes inline comments explaining each option (e.g., `# spend-up-to | ceiling-only`, the full list of available categories). Preserve these — the file is meant to be human-editable in Finder.

Example mappings:
- "vegetarian" → `restrictions: [vegetarian]`
- "budget around 25" → `budget: 25.00`
- "ask me first" → `confirm_before_order: true`
- "love spicy Thai food" → `preferred_cuisines: [Thai, ...]` + add a `foods_i_like` entry
- "no dairy" → `avoid_allergens: [dairy]`
- "5 milks a week" → leave defaults; note in `## Notes`

### 5b. Write order-history.md from scraped data

```markdown
# WeBox Order History
last_synced: YYYY-MM-DD

<!-- Long-term record. Recent entries (within history_window_days) are loaded for variety tracking. -->

## YYYY-MM

### Day MM/DD Meal ✅ #ORDERNUM
- Item Line 1
- Item Line 2
...
```

Group by `YYYY-MM` section. If scrape was empty:
```markdown
# WeBox Order History
last_synced: YYYY-MM-DD

<!-- No orders yet. This file will populate as you place orders through webox-order. -->
```

### 5c. Write favorites-cache.md

```markdown
# Favorites Cache
last_updated: YYYY-MM-DD

- Brand | Item Name | $XX.XX | rating X.X
```

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

  preferences.md       — budget $30, prefer Chinese/Japanese, no mushrooms
  item-reviews.md      — empty (grows as you order and give feedback)
  favorites-cache.md   — X favorites scraped
  order-history.md     — X past orders synced (latest: DATE)

You're ready to order! Try:
  "Order my lunch for tomorrow"
  "Show my WeBox calendar"
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
