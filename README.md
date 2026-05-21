# webox-autopilot

> Order your WeBox meals autonomously with Claude Code — favorites-first, budget-aware, variety-conscious, fully transparent.

**webox-autopilot** is a set of four Claude Code skills that order food from [WeBox](https://webox.com) by simply telling Claude what you want. It uses your existing logged-in Chrome session, scrapes the menu, picks items based on your preferences and past reviews, and checks out — all without leaving your terminal.

```
Order lunch and dinner Mon–Fri next week, Chinese and Japanese only.
```

```
Get me 5 organic milks across the week + lunch for Thursday and Friday.
```

```
这个超级咸，别再点了
```

---

## Quick Install

**Option A — let Claude Code install it:**

```
Install webox-autopilot from https://github.com/boyugou/webox-autopilot, then run /webox-onboard.
```

Claude Code reads `CLAUDE.md` in the repo and follows the install steps automatically.

**Option B — one-liner:**

```bash
git clone https://github.com/boyugou/webox-autopilot.git /tmp/webox-autopilot && bash /tmp/webox-autopilot/install.sh && rm -rf /tmp/webox-autopilot
```

Either option installs four skills: `webox-onboard`, `webox-order`, `webox-calendar`, `webox-sync-favorites`. **After install, run `/webox-onboard` once** (or say "set up WeBox") to do the 2-minute setup.

## Requirements

- [Claude Code](https://claude.ai/code) (any recent version)
- Google Chrome with the **[Claude in Chrome](https://code.claude.com/docs/en/chrome)** extension
- An active WeBox account, logged in to Chrome
- A direct Anthropic plan (Pro, Max, Team, or Enterprise)

---

## Skills

| Skill | Trigger | Purpose |
|-------|---------|---------|
| `webox-onboard` | `/webox-onboard` or "set up WeBox" | First-time setup: preferences, favorites, history. Also handles skill updates. **Run this first.** |
| `webox-order` | "Order my lunch for tomorrow" | Full ordering flow — scrape, select, cart, checkout |
| `webox-calendar` | "Show my WeBox calendar" / "Sync my orders" | View this week + next week, sync from WeBox |
| `webox-sync-favorites` | "Refresh my favorites" | Re-scrape favorites page, diff against cache |

## Usage

Start Claude Code with Chrome integration:

```bash
claude --chrome
```

### First time
```
/webox-onboard
```
Answer one open-ended question about your food preferences (any language). Claude scrapes your favorites and order history in the background while you type.

### Ordering
```
Order my lunch for tomorrow.
Order lunch and dinner Mon–Fri next week.
Order dinner tonight — something healthy, under $20.
Order next week, Chinese and Japanese only, confirm before placing.
Get me 5 milks across this week.
```

### Reviewing dishes (any language, any format)
```
The Mongolian Beef bento is amazing — 5/5.
这个超级咸，肉太少
The poke bowl was overpriced for what you get.
```

### Managing preferences
```
Update my budget to $25.
I'm vegetarian now.
Stop ordering Korean food for a while.
```

---

## Configuration Reference

All settings live in `~/Documents/WeBox/preferences.md` (visible in Finder — edit anytime).

### Budget

| Setting | Type | Default | Description |
|---------|------|---------|-------------|
| `budget` | number | `30.00` | Hard cap per meal slot (food only, excludes fees/tax) |
| `budget_mode` | string | `spend-up-to` | `spend-up-to`: fill the budget with variety. `ceiling-only`: best picks, no fill-up. |
| `validate_budget` | bool | `false` | If true, runs a Python `sum × qty` check before any cart action |

### Ordering Behavior

| Setting | Type | Default | Description |
|---------|------|---------|-------------|
| `confirm_before_order` | bool | `false` | `false`: auto-order in one shot. `true`: show full plan, wait for OK. |
| `default_meals` | list | `[Lunch, Dinner]` | Meal types to order when not specified |
| `skip_weekends` | bool | `true` | Skip Sat/Sun for multi-day ranges |

### Variety

| Setting | Type | Default | Description |
|---------|------|---------|-------------|
| `avoid_repeat_days` | int | `7` | Don't re-order the same **main** within this many days |
| `history_window_days` | int | `28` | How many days of order-history loaded into context (default = ~3 weeks past + 7-day future window) |
| `allow_repeat_categories` | list | `[Drink, Side, Snack, Dairy & Eggs, Produce]` | Categories exempt from variety rules — items here can repeat freely |
| `allow_repeat_patterns` | list | `[milk, water, tea egg, sparkling, coconut, juice, yogurt]` | Name patterns exempt from variety rules |

### Category Scraping (saves time)

| Setting | Type | Default | Description |
|---------|------|---------|-------------|
| `category_mode` | string | `blacklist` | `all`: scrape any category when needed. `whitelist`: only `category_list`. `blacklist`: everything except `category_list`. |
| `category_list` | list | `[Dessert, Burger, Pizza]` | Categories to include/exclude based on `category_mode` |

### Dietary

| Setting | Type | Default | Description |
|---------|------|---------|-------------|
| `restrictions` | list | `[none]` | `vegetarian`, `vegan`, `gluten-free`, `halal`, `kosher`, ... |
| `avoid_allergens` | list | `[none]` | `nuts`, `shellfish`, `dairy`, `eggs`, `soy`, ... |
| `preferred_cuisines` | list | `[Chinese, Japanese]` | Cuisines to prioritize |
| `cuisines_to_avoid` | list | `[none]` | Cuisines to never order |
| `foods_i_like` | list | `[none]` | Free-text patterns ("spicy", "noodles", ...) |
| `foods_to_avoid` | list | `[none]` | Free-text patterns ("mushrooms", "very oily", ...) |

### Drinks

| Setting | Type | Default | Description |
|---------|------|---------|-------------|
| `order_drinks` | bool | `true` | Include drinks in orders |
| `avoid_sugary_drinks` | bool | `false` | Skip sodas and sweetened drinks |
| `preferred_drinks` | list | `[water, unsweetened tea]` | Drink preferences |

---

## Local Files

All in `~/Documents/WeBox/` — plain text, edit freely.

| File | Purpose |
|------|---------|
| `preferences.md` | All settings. Created by onboarding, editable forever. |
| `item-reviews.md` | Your personal ratings and free-form comments on dishes. Multiple comments per dish stack as a timeline. Heavily injected into selection decisions. |
| `order-history.md` | Unified record of all WeBox orders (past, planned, skipped). Long-term storage; only the recent window is loaded for variety tracking. |
| `favorites-cache.md` | Cached WeBox favorites list. Refreshed automatically every 7 days. |
| `items-with-options.md` | Known dishes that open an options modal (e.g., "Choose Rice") with the user's preferred option pre-selected for future orders. |

---

## How It Works

```
User prompt
    │
    ▼
0. Prerequisite check (Chrome connected, preferences.md exists)
   If preferences missing → tell user to run /webox-onboard first
    │
    ▼
1. Load preferences.md + item-reviews.md
   + order-history.md (recent window only)
   + favorites-cache.md (skip scrape if < 7 days)
    │
    ▼
2. Sync order history if stale (> 1 day) → update order-history.md
    │
    ▼
3. Scrape favorites for each needed date (parallel tabs)
   If favorites insufficient: scrape categories (whitelist/blacklist filter)
    │
    ▼
4. Build full multi-day plan
   Injection: preferences + reviews (5/5 → top, 1/5 → exclude,
              free-text comments synthesized) + variety rules
              (fillers exempt) + budget
   Quantities supported: "× N" notation
    │
    ▼
4b. Optional Python budget validation (uv run python)
    │
    ▼
5. confirm_before_order = false → place orders
   confirm_before_order = true  → show plan, wait for OK
    │
    ▼
6. Write plan to order-history.md (status: 📝 planned)
    │
    ▼
7. For each slot: open page, add items (handle quantities + options modals),
   checkout. Update order-history.md status to ✅ #ORDERNUM immediately.
    │
    ▼
8. Final summary + invite feedback
   Free-form reviews appended to item-reviews.md
```

## First Session vs Later Sessions

### First session (after `/webox-onboard`)
- 1 question asked (preferences in natural language)
- Order history scraped (smart scroll, stops when no new items load)
- Favorites scraped (~60s, hidden behind your typing time)
- All files created in `~/Documents/WeBox/`

### Later sessions
- preferences.md → loaded instantly
- item-reviews.md → loaded instantly; new feedback appended each session
- order-history.md → reused if synced within 1 day; full re-sync otherwise
- favorites-cache.md → reused if < 7 days old (the biggest win)
- items-with-options.md → grows over time; known modal items handled automatically

## Automation Breakdown

| Step | Method | Reliability |
|------|--------|-------------|
| Favorites (cached) | Read local file | instant |
| Favorites (scrape) | JS + smart scroll (stops on no new items) | ✅ 100% |
| Order history (cached) | Read local file | instant |
| Order history (scrape) | JS + smart scroll | ✅ 100% |
| Multi-date scraping | Parallel tabs (3–5 concurrent) | ✅ ~Nx speedup |
| Budget validation | Python `sum(p × q)` via `uv run` | ✅ 100% |
| Add item (no options) | JS click `.btn.plus-add` | ✅ 100% |
| Add item (with options) | JS click + `find("Add to Cart")` | ✅ 95% |
| Add item × N | JS click N times | ✅ 100% |
| Complex modal options | Screenshot + model judgment | adaptive |
| Checkout | `find("Quick Checkout button")` + click | ✅ 99% |

## WeBox Constraints

- **7-day window:** Orders up to 7 days ahead only.
- **Meal cutoffs:** Lunch has mid-morning cutoff; skipped if passed.
- **Weekends:** No subsidized Lunch/Dinner; skipped by default.
- **Budget per slot:** Each date+meal is a separate checkout.

## FAQ

**Q: Will it double-order a slot I've already ordered?**
A: No — `order-history.md` is checked first, slots already marked ✅ are skipped.

**Q: What if an item is sold out?**
A: Filtered during scraping. If sold out at cart time, the skill re-scrapes that date and picks a substitute, noting it in `order-history.md`.

**Q: What if the total would exceed my budget?**
A: Items that would push food total over budget aren't added. With `validate_budget: true`, a Python check enforces this strictly.

**Q: Can I see what Claude plans before it orders?**
A: Set `confirm_before_order: true` in preferences. The plan is shown; you can request changes before approval.

**Q: I want 5 bottles of water in one slot. How?**
A: Just say it: "order 5 waters with Thursday lunch". Quantities are supported with `× N` notation and budget-validated.

**Q: I keep wanting milk every day — won't variety rules block that?**
A: No. Fillers (drinks, sides, eggs, milk, water, etc.) are exempt from variety rules via `allow_repeat_categories` and `allow_repeat_patterns`. Customize the lists if needed.

**Q: How do I reset favorites cache?**
A: Say "refresh my favorites" — invokes `webox-sync-favorites`.

**Q: Can I cancel an order it placed?**
A: Yes — `webox.com/order/list/normal` and cancel within the allowed window.

**Q: How do I review a dish?**
A: Tell Claude in any form: "the Mongolian beef was too dry", "love this 5/5", "这个超级咸". Stored verbatim in `item-reviews.md` and weighted in future selection.

## Updating

Say "update webox-autopilot" — `/webox-onboard` handles it. Or manually:

```bash
git clone https://github.com/boyugou/webox-autopilot.git /tmp/webox-autopilot && bash /tmp/webox-autopilot/install.sh && rm -rf /tmp/webox-autopilot
```

`~/Documents/WeBox/` is never touched by updates.

## Contributing

PRs welcome. Areas for improvement:

- HappyHour / weekend ordering
- Cancel-order skill
- Multi-week planning with persistent state
- Budget tracking across multiple orders
- Smarter sentiment analysis on reviews

## License

Apache 2.0 — see [LICENSE](LICENSE).
