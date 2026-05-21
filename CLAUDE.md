# webox-autopilot — Claude Code Guide

This file is for **two audiences**:
1. **Claude Code on a user's machine** following install steps below
2. **Developers / contributors** working on the repo itself

---

## For users / Claude Code on the user side

### What this repo is

A set of five Claude Code skills that autonomously order food from [WeBox](https://webox.com) using the user's logged-in Chrome browser:

- **`webox-onboard`** — first-time setup (run this first)
- **`webox-order`** — order meals (smart default: favorites-first with auto-fallback to categories)
- **`webox-order-all`** — explicit "skip favorites, scrape the full menu" variant
- **`webox-calendar`** — view and sync the order calendar
- **`webox-reset`** — wipe local data and re-onboard

**JS-first principle:** all skills prefer JavaScript over computer use for any operation that can be done in JS. Faster, more reliable, works in background tabs.

### Installation

```bash
git clone https://github.com/boyugou/webox-autopilot.git /tmp/webox-autopilot
bash /tmp/webox-autopilot/install.sh
rm -rf /tmp/webox-autopilot
```

After install, **run `/webox-onboard` first** (or say "set up WeBox"). Onboarding takes ~2 minutes and:
- Verifies Chrome + WeBox login
- Asks one open-ended preferences question
- Scrapes favorites and order history in parallel
- Writes all data files to `~/Documents/WeBox/`

Do not call `webox-order` before onboarding — it will refuse and ask for setup.

### Requirements

- Google Chrome with the **[Claude in Chrome](https://code.claude.com/docs/en/chrome)** extension
- User logged into WeBox in that Chrome session
- Claude Code started with `claude --chrome`

### Usage after onboarding

**Order food:**
```
Order my lunch for tomorrow.
Order lunch and dinner Mon–Fri next week, Chinese and Japanese only.
Get me 5 organic milks across this week.
```

**Order from full menu (explore beyond favorites):**
```
Order something new for lunch tomorrow.
Browse the whole menu for next week.
Ignore my favorites this time and order anything.
```

**View / sync calendar:**
```
Show me my WeBox calendar.
Sync my order history.
```

**Manage reviews and preferences (natural language):**
```
The Mongolian Beef bento was amazing — 5/5.
这个超级咸，别再点了
Update my budget to $25.
I'm vegetarian now.
```

**Reset / start over:**
```
Reset WeBox.
Wipe my WeBox data and start over.
```

### User data

`~/Documents/WeBox/` (visible in Finder):
- `preferences.md` — all settings (budget, diet, cuisines, etc.)
- `item-reviews.md` — personal ratings + free-form comments per dish (any language)
- `order-history.md` — unified record of past + planned orders; variety tracking source
- `menu-cache/YYYY-MM-DD-Meal.json` — per-slot menu snapshot (favorites or full menu) with item-level `in_favorites` flag and `categories[]` source list
- `items-with-options.md` — known dishes with required-options modals + user's chosen options (grows over time)

### Updating

```bash
git clone https://github.com/boyugou/webox-autopilot.git /tmp/webox-autopilot
bash /tmp/webox-autopilot/install.sh
rm -rf /tmp/webox-autopilot
```

Or tell the user: "say 'update webox-autopilot'" — `webox-onboard` handles updates. Files in `~/Documents/WeBox/` are never touched by updates.

---

## For developers

### Repo layout

```
webox-autopilot/
├── .claude/skills/
│   ├── webox-onboard/SKILL.md       # First-time setup + skill updates
│   ├── webox-order/SKILL.md         # Core ordering (~600 lines, the canonical reference)
│   ├── webox-order-all/SKILL.md     # Thin override — Step 3 differs, references webox-order for rest
│   ├── webox-calendar/SKILL.md      # View/sync order calendar
│   └── webox-reset/SKILL.md         # Wipe + re-onboard
├── CLAUDE.md                        # This file
├── README.md                        # User-facing docs
├── LICENSE                          # Apache 2.0
├── install.sh                       # Installer (copies skills to ~/.claude/skills/)
├── preferences.md                   # Canonical preferences template
└── .gitignore
```

### Data flow

```
preferences.md           ←── created by webox-onboard from user reply, edited freely
item-reviews.md          ←── written by webox-order Step 10, edited freely, any language
order-history.md         ←── written by webox-order Step 6/8, synced by webox-calendar
menu-cache/*.json        ←── per-slot, written by either webox-order or webox-order-all,
                              auto-pruned after 24h, TTL 60min
items-with-options.md    ←── grown by webox-order Step 7 (one entry per modal encounter)
```

### Skill contracts

- Every skill checks `tabs_context_mcp` first; halts with clear message if Chrome isn't connected.
- `webox-order` and `webox-order-all` additionally require `~/Documents/WeBox/preferences.md` to exist (direct user to `/webox-onboard` if missing).
- All scrapes use smart-scroll (loop until 2 consecutive scrolls yield no new items; capped at 8–12 iterations).
- Order-history uses structured selectors `.order-id` and `.order-status`; slots with `Refunded`/`Cancelled` are treated as OPEN.
- Menu page URL distinction:
  - Favorites: `/menu/section/My%20Favorites?date=X&shippingTime=Y` (ONLY works for favorites)
  - Cuisine categories: `/?date=X&shippingTime=Y&objType=CUISINE&objId=NAME&objName=NAME` (root URL + query params)
  - Anti-pattern: `/menu/section/CATEGORY` for cuisines silently falls back to favorites

### Testing changes locally

```bash
bash install.sh   # copies your local changes to ~/.claude/skills/
# Restart Claude Code so the new skill files are picked up
```

For full-flow testing without polluting real data:
```bash
mv ~/Documents/WeBox ~/Documents/WeBox.bak.$(date +%s)
# run /webox-onboard with a mock answer, place a test order
# restore:
rm -rf ~/Documents/WeBox && mv ~/Documents/WeBox.bak.<TIMESTAMP> ~/Documents/WeBox
```

### DOM reference (verified 2026-05-20)

Order list (`/order/list/normal`):
- `.order-item` — one per order
- `.order-id` — e.g. "No.3258614"
- `.order-status` — "Refunded" / "Cancelled" / "Paid" / absent
- Active orders show meal text as `"Dinner (Delivered at 5:49 PM)"`; cancelled/refunded show just `"Dinner"`. Meal regex: `/^(Lunch|Dinner|HappyHour)(\s|\(|$)/`

Menu pages (favorites or category):
- `app-product-menu-item.menu-section-product-item, .new-menu-product-item` — product card
- `.product-menu-title` — clean name (don't use parent wrappers)
- `.brand-wrapper` — brand
- `.product-price` — "$17.55"
- `.product-menu-top-sold-out-wrapper` — sold-out flag (use `getComputedStyle(el).display !== 'none'`)
- `.btn.plus-add` — add for most items (DIV)
- `.product-add-wrapper` — add for items with required options (SPAN, opens modal)
- `[class*="product-detail-header"]` — modal-open indicator
- `st-button.add-button` — Add to Cart inside modal
- `.anticon.anticon-close` — modal close (modal does NOT auto-close after Add)

Cart / Checkout (`/checkout`):
- `a.cart.fr` — cart icon (click → navigates to `/checkout`)
- `.input-number-wrapper.isCart` — qty stepper per line item
- `.btn.plus` / `.btn.minus` inside stepper, `.btn.minus.unable` at min
- `.place-btn` — Place Order (DIV)
- After success: URL = `/order/finish/<NUMBER>`

### When DOM changes

WeBox uses Angular with `_ngcontent-*` attributes that rotate between deploys, but human-meaningful class names (`.order-id`, `.product-menu-title`, etc.) have been stable. If something breaks:

1. Inspect via Chrome devtools.
2. Update affected selectors in `webox-order/SKILL.md` (the canonical reference) and re-test.
3. The other skills (webox-order-all, webox-calendar, webox-onboard) repeat critical selectors inline — search-replace across them too.

### When adding a new skill

1. Create `.claude/skills/<name>/SKILL.md` with YAML frontmatter (`name`, `description`).
2. Add to the `for skill in ...` loop in `install.sh`.
3. Reference it in README.md and the user-facing section above.
4. Keep single-responsibility (e.g., `webox-reset` only resets; it doesn't also order).

### When changing the preferences schema

- Update `preferences.md` (canonical template).
- Update `webox-onboard` Step 5a (creates the file from user answers).
- Update `webox-order` Step 1a (extracts fields).
- Update README "Configuration Reference" table.

### Commit conventions

- English only (commits, code, comments — per global CLAUDE.md).
- Use `uv` for any Python (never `python3` / `pip` directly).
- No backwards-compatibility shims for renames — small project, rip-and-replace is preferred.
- Self-contained docstrings: each SKILL.md should be readable as a complete contract.

### Known limitations / future work

- HappyHour / weekend ordering not implemented (only Lunch/Dinner)
- No `webox-cancel` skill (user cancels manually at webox.com)
- No automated tests — manual e2e validation only
- Quantity stepper in modal items uses `/checkout` cart stepper (one extra navigation); could be improved if WeBox adds an inline qty control
