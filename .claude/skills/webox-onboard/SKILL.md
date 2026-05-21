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

(The preferences file alone is not enough — `install.sh` may have copied a default template without the user having gone through onboarding.)

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

Navigate to `https://www.webox.com/order/list/normal` (use a fresh tab so the main tab stays available). The page uses infinite scroll — scroll 10 times for first-run to capture as much history as possible:

```javascript
(async () => {
  for (let i = 0; i < 10; i++) {
    window.scrollTo(0, document.body.scrollHeight);
    await new Promise(r => setTimeout(r, 800));
  }
  const orders = [...document.querySelectorAll('.order-item')].map(o => {
    const lines = o.innerText.split('\n').map(l => l.trim()).filter(Boolean);
    const dateLine = lines.find(l => /^(Mon|Tue|Wed|Thu|Fri|Sat|Sun)\s+\d{2}\/\d{2}$/.test(l));
    const mealLine = lines.find(l => /Lunch|Dinner|HappyHour|Breakfast/.test(l));
    const orderNum = lines.find(l => /^#\d+/.test(l) || /Order\s*#\d+/i.test(l));
    const itemLines = lines.filter(l =>
      l !== dateLine && l !== mealLine && l !== orderNum &&
      l.length > 3 && !/^\$/.test(l) && !/^(Cancel|View|Reorder|Track)/i.test(l)
    );
    return { date: dateLine, meal: mealLine, orderNum: orderNum || null, items: itemLines };
  }).filter(o => o.date && o.meal);
  return JSON.stringify(orders);
})()
```

If the scrape returns `[]` (new user, zero orders) → write an empty `order-history.md` placeholder in Step 5b.

#### 4b. Scrape favorites

Use today's date in `YYYY-MM-DD` format (e.g., `2026-05-20`). Navigate to:
```
https://www.webox.com/menu/section/My%20Favorites?date=<TODAY_YYYY-MM-DD>&shippingTime=Lunch
```

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

Note: favorites are scraped without sold-out filtering — the list shows all hearted items regardless of today's availability.

If favorites returns `[]`, write an empty `favorites-cache.md` and note in Step 5b that the user has no favorites yet.

---

## Step 5: Process the User's Reply

When the user responds to the onboarding question:

### 5a. Parse and write preferences

Map the user's natural-language reply to the YAML fields below. Leave defaults for anything not mentioned. Put any free-text observations into the `Notes` section at the bottom.

Write `~/Documents/WeBox/preferences.md`:

```markdown
# WeBox Preferences

This file lives in ~/Documents/WeBox/ — open it in any editor to change your settings.
Claude reads it at the start of every order session.

---

## Budget

```yaml
budget: 30.00
budget_mode: spend-up-to   # spend-up-to | ceiling-only
validate_budget: false
```

## Ordering Behavior

```yaml
confirm_before_order: false
default_meals:
  - Lunch
  - Dinner
skip_weekends: true
```

## Variety

```yaml
avoid_repeat_days: 7
history_window_days: 28

allow_repeat_categories:
  - Drink
  - Side
  - Snack
  - Dairy & Eggs
  - Produce

allow_repeat_patterns:
  - milk
  - water
  - tea egg
  - sparkling
  - coconut
  - juice
  - yogurt
```

## Category Scraping

```yaml
category_mode: blacklist
category_list:
  - Dessert
  - Burger
  - Pizza
```

## Dietary Restrictions

```yaml
restrictions:
  - none
```

## Allergens

```yaml
avoid_allergens:
  - none
```

## Cuisine Preferences

```yaml
preferred_cuisines:
  - Chinese
  - Japanese

cuisines_to_avoid:
  - none
```

## Food Preferences

```yaml
foods_i_like:
  - none

foods_to_avoid:
  - none
```

## Drinks

```yaml
order_drinks: true
avoid_sugary_drinks: false
preferred_drinks:
  - water
  - unsweetened tea
```

## Notes

(free text from the user's onboarding reply that didn't fit a structured field)
```

Adjust YAML values to match what the user actually said.

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
