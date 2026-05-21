# webox-autopilot

> Order your WeBox meals autonomously with Claude Code — API-first, budget-aware, variety-conscious, fully transparent.

**webox-autopilot** is a set of six Claude Code skills that order food from [WeBox](https://webox.com) by talking to Claude in plain language. Every read and write goes through WeBox's JSON API — no DOM scraping, no scroll loops. Fetching the entire menu takes ~1 second. Placing an order is one POST.

```
Order lunch and dinner Mon–Fri next week, Chinese and Japanese only.
```

```
Get me 5 organic milks across the week + lunch for Thursday and Friday.
```

```
Hide all sugary drinks.
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

Either option installs six skills: `webox`, `webox-onboard`, `webox-order`, `webox-favorite`, `webox-sync`, `webox-reset`. **After install, run `/webox-onboard` once** (or say "set up WeBox") for the ~30-second setup.

The same one-liner upgrades to the latest version. Your `~/Documents/WeBox/` data is never touched.

**Full reinstall (clean slate — wipe everything + reinstall):**

```bash
rm -rf ~/Documents/WeBox ~/.claude/skills/webox ~/.claude/skills/webox-onboard ~/.claude/skills/webox-order ~/.claude/skills/webox-favorite ~/.claude/skills/webox-sync ~/.claude/skills/webox-reset && git clone https://github.com/boyugou/webox-autopilot.git /tmp/webox-autopilot && bash /tmp/webox-autopilot/install.sh && rm -rf /tmp/webox-autopilot
```

Then restart Claude Code (`claude --chrome`) and run `/webox-onboard`.

⚠️ This is destructive — `~/Documents/WeBox/` (config.yaml, preferences.md, item-reviews.md, etc.) cannot be recovered. To preserve your reviews/notes, back them up first:

```bash
mv ~/Documents/WeBox ~/Documents/WeBox.backup.$(date +%Y%m%d-%H%M%S)
```

Your WeBox account itself (orders, hearts, hidden list) is untouched — it all lives on webox.com and `/webox-onboard` refetches.

## Requirements

- [Claude Code](https://claude.ai/code) (any recent version)
- Google Chrome with the **[Claude in Chrome](https://code.claude.com/docs/en/chrome)** extension
- An active WeBox account, logged in to Chrome
- A direct Anthropic plan (Pro, Max, Team, or Enterprise)

**One-time Chrome setup (recommended — makes onboarding ~3× faster):**

1. Open `chrome://settings/content/automaticDownloads`
2. Under "Allowed to automatically download multiple files", click **Add**
3. Paste `[*.]webox.com` and save

This lets the skill write big data files (favorites, hidden, menu cache, order history) to your `~/Downloads` in one shot, where Claude Code's Bash then moves them into `~/Documents/WeBox/`. Without this permission the skill falls back to streaming data in 5-item chunks (~3× slower but functional).

---

## Skills

| Skill | Trigger | Purpose |
|---|---|---|
| `webox-onboard` | `/webox-onboard` or "set up WeBox" | First-time setup: fetches profile, address, favorites, hidden list, order history via API. **Run this first.** |
| `webox-order` | "Order my lunch for tomorrow" | **Primary ordering.** API menu fetch → plan within budget honoring preferences/dietary/reviews → place via `POST /api/orders`. |
| `webox-favorite` | "Order from my usuals" / "Stick to favorites" | Narrow variant — same flow, filtered to your hearted items. |
| `webox-sync` | "Show my WeBox calendar" / "Sync everything" | Refresh history + favorites/hidden + upcoming-slot menus via API, then display the weekly calendar. |
| `webox-reset` | "Reset WeBox" / "Start over" | Wipe all local data in ~/Documents/WeBox/ and re-onboard. |
| `webox` | "What's available friday?" / "Hide all sugary drinks" / ad-hoc | General API loader for free-form tasks — search, inspect, bulk hide/favorite, browse. |

## Usage

Start Claude Code with Chrome integration:

```bash
claude --chrome
```

### First time
```
/webox-onboard
```
Answer one open-ended question about your food preferences. Claude fetches profile + addresses + favorites + history via API (~15s total).

### Ordering
```
Order my lunch for tomorrow.
Order lunch and dinner Mon–Fri next week.
Order dinner tonight — something healthy, under $20.
Order next week, Chinese and Japanese only, confirm before placing.
Get me 5 milks across this week.
```

### Favorites-only ordering
```
Order from my usuals for tomorrow.
Quick favorite order for Thursday lunch.
```

### Ad-hoc tasks
```
What's available for dinner Friday?
Search for noodles on Tuesday.
Hide all sugary drinks.
Favorite every Korean main dish.
What's in my cart?
```

### Reviewing dishes (any language)
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

Settings live in two files in `~/Documents/WeBox/` (visible in Finder — edit anytime):

- **`config.yaml`** — schema-locked structured fields documented in the tables below. **Edit values; never add new fields** — downstream skills only read the canonical keys.
- **`preferences.md`** — free-form notes. Anything that doesn't fit a structured field above: meal composition rules ("1 main + sides"), portion hints ("not a big eater"), ratios ("5/10 Chinese"), incident notes. Claude reads this as a soft constraint.

### Budget

| Setting | Type | Default | Description |
|---|---|---|---|
| `budget` | number | `30.00` | Hard cap per meal slot (food only, excludes fees/tax) |
| `budget_mode` | string | `spend-up-to` | `spend-up-to`: fill the budget with variety. `ceiling-only`: best picks, no fill-up. |
| `validate_budget` | bool | `false` | If true, runs a Python `sum × qty` check before each order |

### Ordering Behavior

| Setting | Type | Default | Description |
|---|---|---|---|
| `confirm_before_order` | bool | `false` | `false`: auto-order in one shot. `true`: show plan, wait for OK. |
| `default_meals` | list | `[Lunch, Dinner]` | Meal types to order when not specified |
| `skip_weekends` | bool | `true` | Skip Sat/Sun for multi-day ranges |

### Variety

| Setting | Type | Default | Description |
|---|---|---|---|
| `avoid_repeat_days` | int | `7` | Don't re-order the same **main** within this many days |
| `history_window_days` | int | `28` | Days of order-history loaded into context |
| `allow_repeat_categories` | list | `[Beverage, Appetizer, Snacks, Salads]` | Item categories exempt from variety rules (filler items can repeat freely) |

### Dietary

| Setting | Type | Default | Description |
|---|---|---|---|
| `restrictions` | list | `[none]` | `vegetarian`, `vegan`, `gluten-free`, `halal`, `kosher`, ... |
| `avoid_allergens` | list | `[none]` | `nuts`, `shellfish`, `dairy`, `eggs`, `soy`, ... |
| `preferred_cuisines` | list | `[]` | Cuisines to prioritize (empty = no bias) |
| `cuisines_to_avoid` | list | `[none]` | Cuisines to never order |
| `foods_i_like` | list | `[none]` | Free-text patterns |
| `foods_to_avoid` | list | `[none]` | Free-text patterns |

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
| `preferences.md` | Free-form notes (soft constraints — anything that doesn't fit `config.yaml`). Created by onboarding, editable forever. |
| `user-profile.json` | `{firstName, lastName, phone, email, timezone}` — needed for Place Order. |
| `address-info.json` | `{addressId, userAddressId, kitchenId, timezone, ...}` — needed for Place Order. `addressId` is the canonical address record (e.g., 240212); `userAddressId` is your account's link (e.g., 459170). Distinct concepts. |
| `shipping-windows.json` | Per-meal constants (`shippingTimeSectionId`, `extFormCutoff`) derived from past orders. Required for Place Order body assembly. |
| `favorites.json` | Hearted items, enriched: `{products: [{id, name, brand, category}], unresolvedProductIds, brands, synced_at}`. Human-readable in Finder. |
| `hidden.json` | Same shape — "Not Interested" items. |
| `orders/YYYY-Www.json` | Per-ISO-week order history (active orders only). |
| `menu-cache/YYYY-MM-DD-Meal.json` | Per-slot menu snapshot. TTL 60 min, auto-pruned after 24h. |
| `item-reviews.md` | Personal ratings + free-form comments per dish (any language). Comments stack as a timeline. Heavily injected into selection. |

---

## How It Works

```
User prompt
    │
    ▼
0. Prerequisite check (Chrome connected, identity caches exist)
   If anything missing → tell user to run /webox-onboard first
    │
    ▼
1. Load preferences + identity caches + item-reviews + order-history (recent)
    │
    ▼
2. Sync order history if stale (> 1 day) via /api/orders/list paginated
    │
    ▼
3. For each target slot:
   - Check menu-cache (TTL 60 min) → reuse if fresh
   - Else: GET /api/productSpecials/v8/... (~1s) → join lunchSpecials+products+brands,
     filter sold-out, filter hidden, mark in_favorites, write to menu-cache
    │
    ▼
4. Build the plan
   Inject: preferences + reviews (5/5 top, 1/5 exclude, free-text synthesized)
           + variety rules (fillers exempt) + budget + quantity × N
    │
    ▼
4b. Optional Python budget validation (uv run python)
    │
    ▼
5. confirm_before_order = false → place orders
   confirm_before_order = true  → show plan, wait for OK
    │
    ▼
6. Write plan to orders/YYYY-Www.json (planned: true)
    │
    ▼
7. For each slot: POST /api/orders with the assembled body (one slot = one POST, ~1s)
   On success: update entry to active with orderId
   Sequential, never parallel — avoids race conditions
    │
    ▼
8. Final summary + invite free-form feedback
   Reviews appended to item-reviews.md
```

For favorites-only scope, use `webox-favorite` — same flow but Step 3 filters items to `in_favorites: true` only.

## First Session vs Later Sessions

### First session (after `/webox-onboard`, ~30s)
- 1 open-ended preferences question; skill waits for your reply
- After reply: API parallel-fetch of profile + address + favorites + hidden
- Paginated fetch of full order history (~4s for 400 orders)
- Tomorrow's menu warm-cached for instant first order
- All files created in `~/Documents/WeBox/`

### Later sessions
- preferences.md, identity caches → loaded instantly
- orders/YYYY-Www.json → reused if synced within 1 day
- menu-cache/SLOT.json → reused if cached_at < 60 min
- item-reviews.md → loaded instantly; new feedback appended each session

## Automation Breakdown

All operations are pure API or pure JS — no slow image+coordinate clicks.

| Operation | Method | Time |
|---|---|---|
| Menu (cached) | Read local JSON | instant |
| Menu (fresh) | `GET /api/productSpecials/v8/...` (one call, ~2000 items) | ~1s |
| Order history (full) | `GET /api/orders/list` paginated | ~4s for 400 orders |
| Favorites / hidden | `GET /api/fav/my` / `GET /api/hide/my` | ~200ms |
| Budget validation | Python `sum(p × q)` via `uv run` | ✅ 100% |
| Place Order | `POST /api/orders` with assembled body | ~1s per slot |
| Bulk hide / favorite | API loop (one POST per match) | ~200ms × N |

## WeBox Constraints

- **7-day window:** Orders up to 7 days ahead only.
- **Meal cutoffs:** The menu API only returns items for slots whose cutoff hasn't passed.
- **Weekends:** No subsidized Lunch/Dinner; skipped by default.
- **Budget per slot:** Each date+meal is a separate POST.

## FAQ

**Q: Will it double-order a slot I've already ordered?**
A: No — `orders/YYYY-Www.json` is checked first; slots with active or planned entries are skipped.

**Q: What if an item is sold out?**
A: Filtered by the API (`stockStatus`). If something went out of stock between menu fetch and Place Order, the API returns an error and the skill substitutes from the cached menu.

**Q: What if I want 5 bottles of water in one slot?**
A: Just say it: "order 5 waters with Thursday lunch". Quantities are first-class.

**Q: I keep wanting milk every day — won't variety rules block that?**
A: No. Fillers (Beverage, Appetizer, Snacks, etc.) are exempt via `allow_repeat_categories`.

**Q: Can I cancel an order it placed?**
A: Yes — at webox.com/order/list/normal. On next sync, the slot will be marked open again.

**Q: How do I review a dish?**
A: Tell Claude in any form: "the Mongolian beef was too dry", "love this 5/5", "这个超级咸". Stored in `item-reviews.md` verbatim and weighted in future selection.

**Q: Can I bulk-hide ("Not Interested") a bunch of items?**
A: Yes — say "hide all sugary drinks" or "hide everything by Brand X". The `/webox` general skill loops `POST /api/userHide/addHide` over matched items. Confirms with you first.

## Updating

Say "update webox-autopilot" — `/webox-onboard` handles it. Or manually:

```bash
git clone https://github.com/boyugou/webox-autopilot.git /tmp/webox-autopilot && bash /tmp/webox-autopilot/install.sh && rm -rf /tmp/webox-autopilot
```

`~/Documents/WeBox/` is never touched by updates. For a clean-slate wipe + reinstall, see the **Full reinstall** one-liner up in the [Quick Install](#quick-install) section.

### What to do when a new version ships

For most version bumps:

1. Run the update one-liner above. Skill files at `~/.claude/skills/webox-*/` get overwritten in place.
2. **Restart Claude Code** so the new skill files are loaded. (Claude Code reads skills at session start — running skills in an existing session continue with the old version.)
3. Continue using normally. Your `~/Documents/WeBox/` data (preferences, history, identity caches, reviews) is preserved and stays valid.

For version bumps that change the local file schema (rare, but happens when a new field is added or a file format changes), the release notes / commit message will say so explicitly. In that case:

1. Back up your reviews and notes if you want to keep them:
   ```bash
   cp ~/Documents/WeBox/item-reviews.md ~/Documents/WeBox/item-reviews.md.bak
   cp ~/Documents/WeBox/preferences.md  ~/Documents/WeBox/preferences.md.bak
   cp ~/Documents/WeBox/config.yaml     ~/Documents/WeBox/config.yaml.bak
   ```
2. Run the **Full reinstall** one-liner (top of README) to wipe + reinstall.
3. Run `/webox-onboard` — it rebuilds the identity caches and history from the WeBox API (your WeBox account is the source of truth and is never touched).
4. Restore your reviews/notes from the `.bak` files manually, merging any newly-asked-for fields from the fresh config.yaml template.

The Chrome "automatic downloads" permission you set up under [Requirements](#requirements) is **persistent across reinstalls and version updates** — you only have to grant it once.

## Contributing

PRs welcome. Areas for improvement:

- HappyHour / weekend ordering (templated, not yet wrapped)
- `webox-cancel` skill (templated endpoints exist in SITEMAP.md, not yet wrapped)
- Multi-week planning with persistent state across sessions
- Budget tracking across multiple orders
- Smarter sentiment analysis on reviews

## License

Apache 2.0 — see [LICENSE](LICENSE).
