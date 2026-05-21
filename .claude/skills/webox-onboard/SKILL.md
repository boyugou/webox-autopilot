---
name: webox-onboard
description: First-time setup for webox-autopilot. Verifies Chrome + WeBox login, asks one natural-language question to capture food preferences, scrapes favorites and order history in the background, and creates all local data files. Run this once before using webox-order. Also handles skill updates.
---

# WeBox Onboard Skill

Run this skill once when you first install webox-autopilot, or when you want to re-run setup. It also handles updating the skill files from GitHub.

Data directory: `~/Documents/WeBox/`  
All files are plain text — open them in any editor or Finder anytime.

---

## What this skill does

1. Verifies Claude in Chrome is connected and WeBox is logged in
2. Scrapes your favorites list and order history (in the background while you answer the setup question)
3. Asks one open-ended question about your food preferences
4. Writes all data files to `~/Documents/WeBox/`
5. Shows a summary of what was set up

If you've already run onboarding, it offers to update your preferences or re-sync your data instead.

---

## Step 1: Check Prerequisites

### 1a. Claude in Chrome
Call `tabs_context_mcp`. If it returns no tabs or an error:

> Claude in Chrome doesn't seem to be connected. Please make sure Chrome is running with the [Claude in Chrome extension](https://code.claude.com/docs/en/chrome) enabled, then try again.

Stop here.

### 1b. WeBox login
Navigate to `https://www.webox.com`. Check for a logged-in state (user avatar or name visible). If not logged in:

> You're not logged into WeBox in Chrome. Please log in at webox.com and try again.

Stop here.

### 1c. Data directory
Create `~/Documents/WeBox/` if it doesn't exist.

```bash
mkdir -p ~/Documents/WeBox
```

---

## Step 2: Check if Already Onboarded

Check whether `~/Documents/WeBox/preferences.md` exists.

**If it exists** — this is a returning user. Say:

> You're already set up! Here's what I found in ~/Documents/WeBox/:
> - preferences.md ✓
> - item-reviews.md (X items reviewed)
> - favorites-cache.md (last updated: DATE, X items)
> - order-calendar.md (last synced: DATE)
>
> What would you like to do?
> - **Update preferences** — I'll ask what's changed
> - **Re-sync favorites** — re-scrape your WeBox favorites page
> - **Re-sync order history** — pull the latest orders from WeBox
> - **Update the skill** — pull the latest version from GitHub
> - **Nothing** — I'm just checking

Wait for the user's choice and handle it. For "Update the skill", jump to Step 6.

**If it doesn't exist** — continue with onboarding.

---

## Step 3: Background Data Collection

Ask the preferences question (Step 4) immediately, then while the user is typing their reply, run these in the same turn:

### 3a. Scrape order history
Navigate to `https://www.webox.com/order/list/normal`:

```javascript
(async () => {
  const orders = [...document.querySelectorAll('.order-item')].map(o => {
    const lines = o.innerText.split('\n').map(l => l.trim()).filter(Boolean);
    const dateLine = lines.find(l => /^(Mon|Tue|Wed|Thu|Fri|Sat|Sun)\s+\d{2}\/\d{2}$/.test(l));
    const mealLine = lines.find(l => /Lunch|Dinner|HappyHour|Breakfast/.test(l));
    const orderNum = lines.find(l => /^#\d+/.test(l));
    return { date: dateLine, meal: mealLine, orderNum: orderNum || null };
  }).filter(o => o.date && o.meal);
  return JSON.stringify(orders);
})()
```

Write to `~/Documents/WeBox/order-calendar.md`:

```markdown
# WeBox Order Calendar
last_synced: YYYY-MM-DD

## YYYY-MM
- Day MM/DD Meal ✅ #ORDERNUM
- Day MM/DD Meal ✅ #ORDERNUM
...
```

Write to `~/Documents/WeBox/order-history-cache.json`:
```json
{"cached_at": "YYYY-MM-DDTHH:MM:SS", "orders": [...]}
```

### 3b. Scrape favorites
Navigate to `https://www.webox.com/menu/section/My%20Favorites?date=TODAY&shippingTime=Lunch`:

```javascript
(async () => {
  for (let i = 0; i < 10; i++) {
    window.scrollTo(0, document.body.scrollHeight);
    await new Promise(r => setTimeout(r, 600));
  }
  const SELECTORS = 'app-product-menu-item.menu-section-product-item, .new-menu-product-item';
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

Write to `~/Documents/WeBox/favorites-cache.md`:

```markdown
# Favorites Cache
last_updated: YYYY-MM-DD

- Brand | Item Name | $XX.XX | rating X.X
- Brand | Item Name | $XX.XX | rating X.X
```

---

## Step 4: Preferences Question

While kicking off the background scraping above, ask:

> Before your first order, tell me about your food preferences — anything goes: budget, diet, allergens, cuisines you love or avoid, whether you want me to confirm before ordering, drink preferences, etc. Answer however feels natural — one sentence or a full paragraph, any language.

Wait for the reply.

---

## Step 5: Write Preferences

Parse the user's reply and write `~/Documents/WeBox/preferences.md`:

```markdown
# WeBox Preferences
last_updated: YYYY-MM-DD

## Budget
budget: 30.00
budget_mode: spend-up-to   # spend-up-to | ceiling-only
validate_budget: false      # true: Python sum check before ordering

## Ordering Behavior
confirm_before_order: false  # false: auto-order | true: show plan first, wait for OK
default_meals:
  - Lunch
  - Dinner
skip_weekends: true

## Variety
avoid_repeat_days: 3
plan_cache_days: 14

## Dietary Restrictions
restrictions:
  - none

## Allergens
avoid_allergens:
  - none

## Cuisine Preferences
preferred_cuisines:
  - Chinese
  - Japanese

cuisines_to_avoid:
  - none

## Food Preferences
foods_i_like:
  - none

foods_to_avoid:
  - none

## Drinks
order_drinks: true
avoid_sugary_drinks: false
preferred_drinks:
  - water
  - unsweetened tea

## Notes
# (anything that didn't fit above)
```

Also create an empty `~/Documents/WeBox/item-reviews.md` if it doesn't exist:

```markdown
# Item Reviews

<!-- Add reviews here, or just tell Claude Code about a dish and it will record them for you. -->
<!-- Example: "The Mongolian Beef bento from Xiangchuan Kitchen is amazing, 5/5" -->

```

---

## Step 5b: Summary

After writing all files, print:

```
✅ WeBox setup complete! Files created in ~/Documents/WeBox/:

  preferences.md       — your budget, cuisines, dietary settings
  item-reviews.md      — your dish ratings (empty for now — grows as you order)
  favorites-cache.md   — X favorites scraped
  order-calendar.md    — order history synced (last order: DATE)

You're ready to order! Try:
  "Order my lunch for tomorrow"
  "Show my WeBox calendar for this week"
```

---

## Step 6: Update the Skill

If the user asked to update the skill (or says "update webox" / "upgrade webox-autopilot"):

```bash
git clone https://github.com/boyugou/webox-autopilot.git /tmp/webox-autopilot-update && bash /tmp/webox-autopilot-update/install.sh && rm -rf /tmp/webox-autopilot-update
```

This overwrites the skill files in `~/.claude/skills/` but never touches `~/Documents/WeBox/` (your preferences, reviews, and caches are safe).

After updating, report what version (latest commit) was installed.
