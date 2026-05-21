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

## Step 1: Check Prerequisites

### 1a. Claude in Chrome
Call `tabs_context_mcp`. If no tabs or error:
> Claude in Chrome doesn't seem to be connected. Please make sure Chrome is running with the [Claude in Chrome extension](https://code.claude.com/docs/en/chrome) enabled, then try again.

Stop here.

### 1b. WeBox login
Navigate to `https://www.webox.com`. Check for a logged-in state (user avatar/name visible). If not logged in:
> You're not logged into WeBox. Please log in at webox.com in Chrome and try again.

Stop here.

### 1c. Data directory
```bash
mkdir -p ~/Documents/WeBox
```

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

## Step 3 + Step 4: Parallel Onboarding Turn

In a single response, do **both** of these so they happen in parallel from the user's perspective:

### Step 3: Ask the preferences question

Say:

> Before your first order, tell me about your food preferences — anything goes: budget, diet, allergens, cuisines you love or avoid, whether you want me to confirm before ordering, drink preferences, etc. Answer however feels natural — one sentence or a full paragraph, in any language.

### Step 4: While the user is typing — start background data collection

In the same turn, kick off these tool calls. The user reads the question and starts typing; the scrapes run in parallel:

#### 4a. Scrape order history

Navigate to `https://www.webox.com/order/list/normal` (use a fresh tab so the main tab stays available). The page uses infinite scroll — smart-scroll up to 20 times for first-run (stops early when no new items load):

```javascript
(async () => {
  // Smart scroll: up to 20 scrolls for first-run with early termination.
  let lastCount = 0, stable = 0;
  for (let i = 0; i < 20; i++) {
    window.scrollTo(0, document.body.scrollHeight);
    await new Promise(r => setTimeout(r, 700));
    const cnt = document.querySelectorAll('.order-item').length;
    if (cnt === lastCount) { if (++stable >= 2) break; } else { stable = 0; }
    lastCount = cnt;
  }
  const orders = [...document.querySelectorAll('.order-item')].map(o => {
    const orderId = o.querySelector('.order-id')?.innerText?.trim();       // "No.3258614"
    const orderStatus = o.querySelector('.order-status')?.innerText?.trim(); // "Refunded" | "Cancelled" | absent
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

Note: only `isActive: true` entries should be written as `✅ ordered` in `order-history.md`. Refunded/cancelled entries should be marked `🚫 refunded` or `🚫 cancelled` so the slot stays openable. If the scrape returns `[]` (zero orders), write a placeholder.

#### 4b. Scrape favorites

Use today's date in `YYYY-MM-DD` format (e.g., `2026-05-20`). Navigate to:
```
https://www.webox.com/menu/section/My%20Favorites?date=<TODAY_YYYY-MM-DD>&shippingTime=Lunch
```

```javascript
(async () => {
  const SELECTORS = 'app-product-menu-item.menu-section-product-item, .new-menu-product-item';
  let lastCount = 0, stable = 0;
  for (let i = 0; i < 15; i++) {
    window.scrollTo(0, document.body.scrollHeight);
    await new Promise(r => setTimeout(r, 600));
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
