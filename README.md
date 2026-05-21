# webox-autopilot

> Order your WeBox meals autonomously with Claude Code — JS-first, budget-aware, variety-conscious, fully transparent.

**webox-autopilot** is a set of six Claude Code skills that order food from [WeBox](https://webox.com) by simply telling Claude what you want. It uses your existing logged-in Chrome session, scrapes the menu, picks items based on your preferences and past reviews, and checks out — all without leaving your terminal. Every operation is pure JavaScript or URL navigation; no slow image+coordinate clicks.

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

Claude Code reads `CLAUDE.md` and follows the install steps automatically.

**Option B — one-liner (also works for updates):**

```bash
git clone https://github.com/boyugou/webox-autopilot.git /tmp/webox-autopilot && bash /tmp/webox-autopilot/install.sh && rm -rf /tmp/webox-autopilot
```

Either option installs six skills: `webox`, `webox-onboard`, `webox-order`, `webox-favorite`, `webox-sync`, `webox-reset`. **After install, run `/webox-onboard` once** (or say "set up WeBox") to do the 2-minute setup.

The same one-liner upgrades to the latest version. Your `~/Documents/WeBox/` data is never touched by install or update.

## Requirements

- [Claude Code](https://claude.ai/code) (any recent version)
- Google Chrome with the **[Claude in Chrome](https://code.claude.com/docs/en/chrome)** extension
- An active WeBox account, logged in to Chrome
- A direct Anthropic plan (Pro, Max, Team, or Enterprise)

---

## Skills

| Skill | Trigger | Purpose |
|---|---|---|
| `webox-onboard` | `/webox-onboard` or "set up WeBox" | First-time setup: preferences, favorites, history. Also handles skill updates. **Run this first.** |
| `webox-order` | "Order my lunch for tomorrow" | **Primary ordering.** Curated full-menu scrape (favorites + preferred cuisines + filler categories), plan within budget, cart, checkout. |
| `webox-favorite` | "Order from my usuals" / "Stick to favorites" | Narrow variant — favorites-only scope, faster (~5s/slot). |
| `webox-sync` | "Show my WeBox calendar" / "Sync everything" | Pull latest history from WeBox, display this week + next week. |
| `webox-reset` | "Reset WeBox" / "Start over" | Wipe all local data in ~/Documents/WeBox/ and re-onboard. |
| `webox` | "What's available on WeBox for Friday?" / ad-hoc | General knowledge loader for free-form WeBox tasks — search, inspect, browse. Loads URL/DOM reference and lets the agent improvise. |

## Usage

Start Claude Code with Chrome integration:

```bash
claude --chrome
```

### First time
```
/webox-onboard
```
Answer one open-ended question about your food preferences (any language). After you reply, Claude scrapes your order history and today's favorites sequentially in one tab (~15s).

### Ordering (default = curated full menu)
```
Order my lunch for tomorrow.
Order lunch and dinner Mon–Fri next week.
Order dinner tonight — something healthy, under $20.
Order next week, Chinese and Japanese only, confirm before placing.
Get me 5 milks across this week.
```

### Favorites-only ordering (faster, narrow)
```
Order from my usuals for tomorrow.
Quick favorite order for Thursday lunch.
```

### Ad-hoc WeBox queries
```
What's available for dinner Friday?
Search for noodles on Tuesday.
What's in my cart?
Clear my cart.
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
|---|---|---|---|
| `budget` | number | `30.00` | Hard cap per meal slot (food only, excludes fees/tax) |
| `budget_mode` | string | `spend-up-to` | `spend-up-to`: fill the budget with variety. `ceiling-only`: best picks, no fill-up. |
| `validate_budget` | bool | `false` | If true, runs a Python `sum × qty` check before any cart action |

### Ordering Behavior

| Setting | Type | Default | Description |
|---|---|---|---|
| `confirm_before_order` | bool | `false` | `false`: auto-order in one shot. `true`: show full plan, wait for OK. |
| `default_meals` | list | `[Lunch, Dinner]` | Meal types to order when not specified |
| `skip_weekends` | bool | `true` | Skip Sat/Sun for multi-day ranges |

### Variety

| Setting | Type | Default | Description |
|---|---|---|---|
| `avoid_repeat_days` | int | `7` | Don't re-order the same **main** within this many days |
| `history_window_days` | int | `28` | Days of order-history loaded into context (default = ~3 weeks past + 7-day future window) |
| `allow_repeat_categories` | list | `[Drink, Side, Snack, Dairy & Eggs, Produce]` | Categories exempt from variety rules |
| `allow_repeat_patterns` | list | `[milk, water, tea egg, sparkling, coconut, juice, yogurt]` | Name patterns exempt from variety rules |

### Category Scraping (saves time)

| Setting | Type | Default | Description |
|---|---|---|---|
| `category_mode` | string | `curated` | `curated`: favorites + preferred_cuisines + fillers (~7 scrapes, ~35s). `whitelist`: only `category_list`. `blacklist`: all except `category_list`. `all`: every category (~150s). |
| `category_list` | list | `[Dessert, Snack]` | Used only by `whitelist`/`blacklist` modes. Default is a minimal exclusion (just Dessert and Snack — categories most users don't want as a meal). Customize freely; set to empty list for no exclusions. |

### Dietary

| Setting | Type | Default | Description |
|---|---|---|---|
| `restrictions` | list | `[none]` | `vegetarian`, `vegan`, `gluten-free`, `halal`, `kosher`, ... |
| `avoid_allergens` | list | `[none]` | `nuts`, `shellfish`, `dairy`, `eggs`, `soy`, ... |
| `preferred_cuisines` | list | `[Chinese, Japanese]` | Cuisines to prioritize |
| `cuisines_to_avoid` | list | `[none]` | Cuisines to never order |
| `foods_i_like` | list | `[none]` | Free-text patterns ("spicy", "noodles", ...) |
| `foods_to_avoid` | list | `[none]` | Free-text patterns ("mushrooms", "very oily", ...) |

### Drinks

| Setting | Type | Default | Description |
|---|---|---|---|
| `order_drinks` | bool | `true` | Include drinks in orders |
| `avoid_sugary_drinks` | bool | `false` | Skip sodas and sweetened drinks |
| `preferred_drinks` | list | `[water, unsweetened tea]` | Drink preferences |

---

## Local Files

All in `~/Documents/WeBox/` — plain text + JSON, edit freely.

| File | Purpose |
|---|---|
| `preferences.md` | All settings. Created by onboarding from your reply, editable forever. |
| `item-reviews.md` | Personal ratings + free-form comments per dish (any language). Comments stack as a timeline. Heavily injected into selection. |
| `orders/YYYY-Www.json` | Per-ISO-week order history (cancelled/refunded filtered out at sync time). Kept long-term; only `history_window_days` worth loaded into context per session. |
| `menu-cache/YYYY-MM-DD-Meal.json` | Per-slot menu snapshot with `in_favorites` flag and `categories[]` sources. TTL 60 min, auto-pruned after 24h. |
| `items-with-options.md` | Known dishes with required-options modals + your chosen options. Grows over time so future modals are auto-handled. |

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
1. Load preferences.md + item-reviews.md + orders/recent-weeks/*.json
    │
    ▼
2. If latest order week file is stale (> 1 day), sync from WeBox
   (filter cancelled/refunded out at scrape time)
    │
    ▼
3. For each slot:
   - Check menu-cache/SLOT.json (TTL 60 min) → reuse if fresh
   - Else: per category_mode (default `curated` = favorites + preferred_cuisines
     + filler categories), scrape sequentially in one tab
   - Dedupe by (brand, name); merge with in_favorites flag
   - Write merged menu to menu-cache/SLOT.json
    │
    ▼
4. Build full multi-day plan from cached menus
   Inject: preferences + reviews (5/5 → top, 1/5 → exclude, free-text
           comments synthesized) + variety rules (fillers exempt) +
           budget + quantity × N
    │
    ▼
4b. Optional Python budget validation (uv run python)
    │
    ▼
5. confirm_before_order = false → place orders
   confirm_before_order = true  → show plan, wait for OK
    │
    ▼
6. Write plan to orders/YYYY-Www.json (status: planned)
    │
    ▼
7. For each slot, for each item: URL search (?queryText=NAME),
   click add (or modal → Add to Cart → close), all pure JS.
   Then a.cart.fr → /checkout → .place-btn → /order/finish/<NUMBER>.
   Update orders/YYYY-Www.json entry to status: active.
    │
    ▼
8. Final summary + invite free-form feedback
   Reviews appended to item-reviews.md
```

For favorites-only scope (faster), use `webox-favorite` — same flow but Step 3 scrapes only the favorites page.

## First Session vs Later Sessions

### First session (after `/webox-onboard`)
- 1 open-ended question asked; skill waits for your reply
- After reply: order history scraped (~5s), then today's favorites (~5s), sequentially in one tab
- Today's favorites become the warm `menu-cache/<TODAY>-Lunch.json` for your first order
- All files created in `~/Documents/WeBox/`

### Later sessions
- preferences.md, item-reviews.md → loaded instantly
- orders/YYYY-Www.json → reused if synced within 1 day; otherwise re-sync
- menu-cache/SLOT.json → reused if cached_at < 60 min for the slot you're ordering
- items-with-options.md → known modals handled automatically without prompts

## Automation Breakdown

| Step | Method | Reliability |
|---|---|---|
| Menu (cached) | Read local JSON | instant |
| Menu (scrape favorites or category) | URL navigate + JS smart-scroll | ~5s per scrape |
| Menu (multi-category, e.g. `curated`) | Sequential per-category scrapes | ~35s for 7 categories |
| Order history (scrape) | JS + smart scroll | ✅ 100% |
| Budget validation | Python `sum(p × q)` via `uv run` | ✅ 100% |
| Add item (no options) | URL search `?queryText=NAME` + JS click `.btn.plus-add` | ✅ 100% |
| Add item (with options) | URL search → modal → JS `st-button.add-button` → close | ✅ pure JS |
| Add item × N | JS click N times (no modal) or cart stepper on `/checkout` | ✅ 100% |
| Complex modal options (5+ groups) | Screenshot + model judgment + JS Add-to-Cart | adaptive |
| Open cart | JS click `a.cart.fr` → navigates to `/checkout` | ✅ 100% |
| Place Order | JS click `.place-btn` → URL becomes `/order/finish/<NUMBER>` | ✅ 100% |

## WeBox Constraints

- **7-day window:** Orders up to 7 days ahead only.
- **Meal cutoffs:** Lunch has mid-morning cutoff; skipped if passed.
- **Weekends:** No subsidized Lunch/Dinner; skipped by default.
- **Budget per slot:** Each date+meal is a separate checkout.

## FAQ

**Q: Will it double-order a slot I've already ordered?**
A: No — the per-week order files (`orders/YYYY-Www.json`) are checked first; slots marked `active` or `planned` are skipped.

**Q: What if an item is sold out?**
A: Filtered during scraping. If sold out at cart time, the skill re-scrapes that date and picks a substitute, noting it inline.

**Q: What if the total would exceed my budget?**
A: Items that would push the food total over budget aren't added. With `validate_budget: true`, a Python check enforces strictly.

**Q: Can I see what Claude plans before it orders?**
A: Set `confirm_before_order: true` in preferences. The plan is shown; you can request changes before approval.

**Q: I want 5 bottles of water in one slot.**
A: Just say it: "order 5 waters with Thursday lunch". Quantities supported via `× N` notation.

**Q: I keep wanting milk every day — won't variety rules block that?**
A: No. Fillers (drinks, sides, eggs, milk, water) are exempt via `allow_repeat_categories` and `allow_repeat_patterns`. Customize if needed.

**Q: How do I force a fresh menu scrape?**
A: Just place an order — menu-cache TTL is 60 minutes. Or delete `~/Documents/WeBox/menu-cache/*.json` to force re-scrape on next order.

**Q: Can I cancel an order it placed?**
A: Yes — `webox.com/order/list/normal` and cancel within the allowed window. The cancellation is filtered out on the next sync, so the slot becomes openable again.

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
