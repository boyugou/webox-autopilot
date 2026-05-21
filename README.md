# webox-autopilot

> Order your WeBox meals autonomously with Claude Code — favorites-first, budget-aware, variety-conscious.

**webox-autopilot** is a Claude Code skill that lets you order food from [WeBox](https://webox.com) by simply telling Claude what you want. It uses your existing logged-in Chrome session, scrapes the menu, picks items based on your preferences, and checks out — all without leaving your terminal.

```
Order lunch and dinner Mon–Fri next week, Chinese and Japanese only.
```

## Quick Install

**Option A — tell Claude Code to install it:**

```
Install the webox-order skill from https://github.com/boyugou/webox-autopilot, then order my lunch for tomorrow.
```

Claude Code reads `CLAUDE.md` in this repo and handles the rest automatically.

**Option B — one-liner:**

```bash
git clone https://github.com/boyugou/webox-autopilot.git /tmp/webox-autopilot && bash /tmp/webox-autopilot/install.sh && rm -rf /tmp/webox-autopilot
```

## Requirements

- [Claude Code](https://claude.ai/code) (any recent version)
- Google Chrome with the **[Claude in Chrome](https://claude.ai/docs/claude-code/chrome-extension)** extension
- An active WeBox account, logged in to Chrome
- A direct Anthropic plan (Pro, Max, Team, or Enterprise)

## Usage

Start Claude Code with Chrome integration:

```bash
claude --chrome
```

Then tell Claude what you want:

```
Order my lunch for tomorrow.
Order lunch and dinner Mon–Fri next week.
Order dinner tonight — something healthy, under $20.
Order next week, Chinese and Japanese only, confirm before placing.
Refresh my favorites and reorder what I usually get.
```

---

## Configuration Reference

All settings live in `~/.webox-autopilot/user-preferences.md`. Claude reads this file at the start of every session. Edit it anytime — the next order picks up your changes.

### Budget

| Setting | Type | Default | Description |
|---------|------|---------|-------------|
| `budget` | number | `30.00` | Hard cap per meal slot (food items only, not delivery fees or tax) |
| `budget_mode` | string | `spend-up-to` | `spend-up-to`: aim to use most of the budget with variety. `ceiling-only`: pick the best items without trying to fill the budget. |
| `validate_budget` | bool | `false` | If `true`, runs a Python script to strictly verify `sum(prices) <= budget` before touching the cart. Catches arithmetic errors. If it fails, Claude removes the most expensive non-essential item and retries. |

### Ordering Behavior

| Setting | Type | Default | Description |
|---------|------|---------|-------------|
| `confirm_before_order` | bool | `false` | `false` (auto mode): Claude builds the full plan and places all orders in one shot. Only pauses on errors or genuine ambiguity. `true` (confirm mode): Claude presents the full multi-day plan and waits for your approval before placing any orders. You can request changes before confirming. |
| `default_meals` | list | `[Lunch, Dinner]` | Meal types to order when not specified in the prompt. Set to `[Lunch]` if you only want lunch. |
| `skip_weekends` | bool | `true` | Skip Saturday and Sunday when ordering a multi-day range. WeBox typically has no subsidized Lunch/Dinner on weekends. |

### Variety and History

| Setting | Type | Default | Description |
|---------|------|---------|-------------|
| `avoid_repeat_days` | int | `3` | Avoid re-ordering the same item if it was ordered within this many days. Checked against the local plan cache. |
| `plan_cache_days` | int | `14` | Keep plan history for this many days. Older entries are pruned at session start. Set to `0` to disable. |

### Dietary

| Setting | Type | Default | Description |
|---------|------|---------|-------------|
| `restrictions` | list | `[none]` | Dietary restrictions always enforced: `vegetarian`, `vegan`, `gluten-free`, `halal`, `kosher`, etc. |
| `avoid_allergens` | list | `[none]` | Allergens to avoid: `nuts`, `shellfish`, `dairy`, `eggs`, `soy`, `wheat`, `sesame`, etc. |
| `preferred_cuisines` | list | `[Chinese, Japanese]` | Cuisines to prioritize when selecting from the menu. |
| `cuisines_to_avoid` | list | `[none]` | Cuisines to never order from. |
| `foods_i_like` | list | `[none]` | Free-text food preferences (e.g., "spicy food", "rice-based dishes"). |
| `foods_to_avoid` | list | `[none]` | Foods to never order (e.g., "mushrooms", "very spicy dishes"). |

### Drinks

| Setting | Type | Default | Description |
|---------|------|---------|-------------|
| `order_drinks` | bool | `true` | Include drinks in orders. |
| `avoid_sugary_drinks` | bool | `false` | Skip sodas, sweetened teas, etc. |
| `preferred_drinks` | list | `[water, unsweetened tea]` | Preferred drink types. |

---

## Local Cache Files

The skill maintains several cache files in `~/.webox-autopilot/` to avoid redundant scraping and improve variety tracking. All are plain-text and human-readable — edit or delete them anytime.

| File | TTL | Purpose |
|------|-----|---------|
| `favorites-cache.md` | 7 days | Cached favorites list. Re-scraped automatically when stale. Say "refresh my favorites" to force an update. |
| `order-history-cache.json` | 1 hour | Cached order history. Avoids re-scraping `/order/list/normal` if you run multiple sessions close together. |
| `plan-cache.md` | `plan_cache_days` | Full record of planned and actual orders. Used for variety tracking (avoid_repeat_days) and as a human-readable order log. |
| `items-with-options.md` | permanent | Items that open an options modal when added to cart, with the option type and chosen value. Grows over time — future sessions pre-select known choices automatically. |

---

## How It Works

```
User prompt
    │
    ▼
1. Read ~/.webox-autopilot/user-preferences.md
   + Load favorites cache (skip scraping if fresh)
   + Load order history cache (skip scraping if < 1 hour old)
   + Prune stale plan cache entries
    │
    ▼
2. Check /order/list/normal → skip already-ordered date+meal slots
    │
    ▼
3. Scrape favorites page for each needed date
   (once per date, reused for both Lunch and Dinner on that day)
    │
    ▼
4. Build full multi-day order plan
   + validate_budget: run Python sum check if enabled
    │
    ▼
5. confirm_before_order = false → proceed immediately
   confirm_before_order = true  → show plan, wait for approval
    │
    ▼
6. For each date+meal: add items to cart, checkout
   • No options  → JS click (instant)
   • Simple options (e.g. "Choose Rice") → accept default or cached preference
   • Complex options (poke bowls) → Claude uses judgment
    │
    ▼
7. Update plan cache with actual ordered items + order numbers
```

## Automation Breakdown

| Step | Method | Reliability |
|------|--------|-------------|
| Load favorites (cached) | Read local file | ✅ instant |
| Scrape favorites | Pure JS + scroll | ✅ 100% |
| Check order history (cached) | Read local file | ✅ instant |
| Scrape order history | Pure JS | ✅ 100% |
| Budget validation | Python `sum()` check | ✅ 100% |
| Add to cart (no options) | JS click | ✅ 100% |
| Add to cart (simple options) | JS click + find "Add to Cart" | ✅ 95% |
| Add to cart (complex options) | Claude model judgment | Adaptive |
| Checkout | find "Quick Checkout" + click | ✅ 99% |

## WeBox Constraints

- **7-day ordering window:** Can only order up to 7 days ahead. The skill skips out-of-window dates automatically.
- **Meal cutoffs:** Lunch orders must be placed before mid-morning cutoff. If the cutoff has passed, the slot is skipped.
- **Weekends:** Typically no subsidized Lunch/Dinner. `skip_weekends: true` by default.
- **Budget is per slot:** Each date+meal is a separate checkout. Budget is not shared across slots.

## FAQ

**Q: Will it double-order a day I've already ordered?**  
A: No — it checks your order history (and the local cache) first and skips any already-ordered date+meal slot.

**Q: What if an item is sold out?**  
A: Sold-out items are filtered during scraping. Claude picks the next best available option and notes the substitution in the plan cache.

**Q: What if the total would exceed my budget?**  
A: Claude won't add an item that would push the food total over budget. With `validate_budget: true`, a Python script double-checks before cart operations begin.

**Q: Can I see what Claude plans to order before it orders?**  
A: Set `confirm_before_order: true` in your preferences. Claude will show the full plan and wait for your OK.

**Q: Can I cancel an order it placed?**  
A: Yes — go to `webox.com/order/list/normal` and cancel within the allowed window.

**Q: Does it work for Dinner and HappyHour?**  
A: Dinner yes — specify it in your prompt or set it in `default_meals`. HappyHour (Self Pay, weekends) is possible but not the default target.

**Q: How far in advance can it order?**  
A: WeBox allows up to 7 days ahead. The skill won't attempt dates outside this window.

**Q: How do I reset the favorites cache?**  
A: Tell Claude "refresh my favorites" and it will re-scrape and overwrite the cache.

## Updating

```bash
git clone https://github.com/boyugou/webox-autopilot.git /tmp/webox-autopilot && bash /tmp/webox-autopilot/install.sh && rm -rf /tmp/webox-autopilot
```

Your `~/.webox-autopilot/` directory is never touched by updates — preferences and cache files are safe.

## Contributing

PRs welcome. Key areas:

- HappyHour / weekend ordering support
- Cancel-order functionality
- Multi-week planning with persistent state
- Budget tracking across multiple orders
- Smarter item selection heuristics

## License

Apache 2.0 — see [LICENSE](LICENSE).
