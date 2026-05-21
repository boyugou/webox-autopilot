# webox-autopilot — Claude Code Guide

This file is for **two audiences**:
1. **Claude Code on a user's machine** following install steps below
2. **Developers / contributors** working on the repo itself

---

## For users / Claude Code on the user side

### What this repo is

A set of six Claude Code skills that autonomously order food from [WeBox](https://webox.com) using the user's logged-in Chrome browser:

- **`webox-onboard`** — first-time setup (run this first)
- **`webox-order`** — primary ordering: API menu fetch, plan within budget, place via `POST /api/orders`
- **`webox-favorite`** — narrow variant: filter the menu to favorites-only
- **`webox-sync`** — pull latest history + favorites/hidden + warm-cache menus; display the calendar
- **`webox-reset`** — wipe local data and re-onboard
- **`webox`** — general knowledge loader for ad-hoc tasks (search, inspect, bulk hide/favorite, browse)

**API-first architecture.** Every read and write goes through WeBox's JSON API (documented in `webox/SITEMAP.md`). No DOM scraping, no scroll loops, no virtualization workarounds. Operations that used to take 30+ seconds now take ~1 second.

### Installation

```bash
git clone https://github.com/boyugou/webox-autopilot.git /tmp/webox-autopilot
bash /tmp/webox-autopilot/install.sh
rm -rf /tmp/webox-autopilot
```

After install, **run `/webox-onboard` first** (or say "set up WeBox"). Onboarding takes ~30 seconds and fetches:
- Your profile (`/api/users/my`) and address (`/api/v2/userAddresses/my`)
- Favorites (`/api/fav/my`) and hidden / Not-Interested (`/api/hide/my`)
- Order history (`/api/orders/list`, paginated)
- Tomorrow's menu warm-cache (`/api/productSpecials/v8/...`)

All written to `~/Documents/WeBox/`.

Don't call `webox-order` before onboarding — it will refuse and ask for setup.

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

**Order from favorites only:**
```
Order from my usuals for tomorrow.
Quick favorite order for Thursday lunch.
```

**View / sync calendar:**
```
Show me my WeBox calendar.
Sync my orders.
Refresh my favorites.
```

**Ad-hoc tasks:**
```
What's available for dinner Friday?
Search for noodles on Tuesday.
Hide all sugary drinks.
Favorite every Korean main dish.
What's in my cart?
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

`~/Documents/WeBox/` (visible in Finder, plain text + JSON, edit freely):
- `preferences.md` — all settings (budget, diet, cuisines, etc.)
- `user-profile.json` — `{firstName, lastName, phone, email, timezone}` (needed for Place Order)
- `address-info.json` — `{addressId, kitchenId, timezone}` (needed for Place Order)
- `favorites.json` — `{productIdList, brandIdList, synced_at}` (hearted items)
- `hidden.json` — same shape ("Not Interested" items)
- `orders/YYYY-Www.json` — per-ISO-week order history (active orders only)
- `menu-cache/YYYY-MM-DD-Meal.json` — per-slot menu snapshot (TTL 60 min)
- `item-reviews.md` — personal ratings + free-form comments per dish

### Updating

```bash
git clone https://github.com/boyugou/webox-autopilot.git /tmp/webox-autopilot
bash /tmp/webox-autopilot/install.sh
rm -rf /tmp/webox-autopilot
```

Or say "update webox-autopilot" — `webox-onboard` handles updates. Files in `~/Documents/WeBox/` are never touched by updates.

---

## For developers

### Repo layout

```
webox-autopilot/
├── .claude/skills/
│   ├── webox/
│   │   ├── SKILL.md                 # General knowledge loader for ad-hoc tasks
│   │   └── SITEMAP.md               # API + URL + DOM reference — single source of truth
│   ├── webox-onboard/SKILL.md       # First-time setup + skill updates (API-based)
│   ├── webox-order/SKILL.md         # Primary ordering (API: menu fetch + Place Order)
│   ├── webox-favorite/SKILL.md      # Thin variant — filter menu to favorites-only
│   ├── webox-sync/SKILL.md          # API-based sync of history/favorites/hidden/menus
│   └── webox-reset/SKILL.md         # Wipe + re-onboard
├── CLAUDE.md                        # This file
├── README.md                        # User-facing docs
├── LICENSE                          # Apache 2.0
├── install.sh                       # Installer (copies all *.md per skill dir to ~/.claude/skills/)
├── preferences.md                   # Canonical preferences template
└── .gitignore
```

`webox/SITEMAP.md` is the **single source of truth** for WeBox endpoints + DOM selectors. When WeBox changes the schema, update SITEMAP.md first.

### Data flow

```
preferences.md           ←── webox-onboard from user reply, edited freely
user-profile.json        ←── webox-onboard via /api/users/my, refreshed by /webox-sync
address-info.json        ←── webox-onboard via /api/v2/userAddresses/my
favorites.json           ←── /api/fav/my (refreshed by /webox-sync)
hidden.json              ←── /api/hide/my (refreshed by /webox-sync)
orders/YYYY-Www.json     ←── webox-order Step 5 (planned: true) and Step 6 (active)
                              + webox-sync via /api/orders/list (active only)
                              + webox-onboard via same on first-run
menu-cache/SLOT.json     ←── per-slot, written by webox-order/webox-favorite/webox-sync
                              via /api/productSpecials/v8/..., TTL 60 min
item-reviews.md          ←── webox-order Step 8 + free-form user feedback, any language
```

### API endpoints (full list in SITEMAP.md)

Reads:
- `GET /api/users/my`
- `GET /api/v2/userAddresses/my`
- `GET /api/productSpecials/v8/address/<A>/date/<D>` — full menu (~2000 items in one call)
- `GET /api/fav/my` — productIdList + brandIdList
- `GET /api/hide/my` — same shape (Not-Interested)
- `GET /api/orders/list?pageSize=10&pageIndex=N&...` — paginated, totalCount in response

Writes:
- `POST /api/orders?client=web` — Place Order
- `POST /api/favProducts/<id>?client=web` — heart
- `POST /api/userHide/addHide` — Not Interested (`{hideType, hideId}`)
- `POST /api/userHide/removeHide` — undo Not Interested

### Skill contracts

- Every skill calls `tabs_context_mcp({createIfEmpty: true})` first and creates a fresh tab to avoid stale session state.
- `webox-order` and `webox-favorite` require the four identity files (`preferences.md`, `user-profile.json`, `address-info.json`, `favorites.json`). Direct user to `/webox-onboard` if any is missing.
- All Place Order calls are **sequential, never parallel** — race conditions could cause duplicate charges.
- The cart (`localStorage.CartService_cartItemArrMap`) is client-side. Ordering via `POST /api/orders` doesn't touch the cart.
- DOM scraping remains in SITEMAP.md as the **last-resort fallback** for cases where the API path is unavailable.

### JS embedded in SKILL.md

Claude Code doesn't execute JavaScript itself — the agent copies the snippet into `mcp__claude-in-chrome__javascript_tool`. Embedded JS in markdown is the simplest pattern.

- Short snippets (<20 lines) — inline in SKILL.md
- Reusable patterns — once in SITEMAP.md, referenced by skill files
- Promote to a sibling `.js` file only if >50 lines and shared across skills

### Testing changes locally

```bash
bash install.sh   # copies your local changes to ~/.claude/skills/ + removes obsolete dirs
# Restart Claude Code so the new skill files are picked up
```

For full-flow testing without polluting real data:
```bash
mv ~/Documents/WeBox ~/Documents/WeBox.bak.$(date +%s)
# run /webox-onboard with a mock answer, place a test order
# restore:
rm -rf ~/Documents/WeBox && mv ~/Documents/WeBox.bak.<TIMESTAMP> ~/Documents/WeBox
```

### When WeBox changes the API or DOM

1. Empirically verify the breakage (one of the SKILL.md scripts started returning errors).
2. Reproduce the change in `~/.claude/skills/webox/SITEMAP.md` (single source of truth).
3. Update inline JS in the SKILL.md files that duplicate the changed shape (a `grep` sweep across `.claude/skills/`).

### When adding a new skill

1. Create `.claude/skills/<name>/SKILL.md` with YAML frontmatter (`name`, `description`).
2. Add to the `for skill in ...` loop in `install.sh`.
3. Reference it in README.md and the "For users" section above.
4. Keep single-responsibility.

### When changing the preferences schema

- Update `preferences.md` (canonical template).
- Update `webox-onboard` Step 7a (creates the file from user answers).
- Update `webox-order` Step 1a (extracts fields).
- Update README's Configuration Reference table.

### Commit conventions

- English only (commits, code, comments — per global CLAUDE.md).
- Use `uv` for any Python (never `python3` / `pip` directly).
- No backwards-compatibility shims — small project, rip-and-replace is preferred.
- Self-contained docstrings: each SKILL.md should be readable as a complete contract.

### Known limitations / future work

- HappyHour / weekend ordering not exercised (only Lunch/Dinner in active use)
- No `webox-cancel` skill (templated endpoints exist in SITEMAP.md, not yet wrapped)
- No automated tests — manual e2e validation only
- Order modification (changeItemQuantity, refund) endpoints discovered but not wrapped
