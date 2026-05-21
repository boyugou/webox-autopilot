# webox-autopilot — Claude Code Guide

This file is for **two audiences**:
1. **Claude Code on a user's machine** following install steps below
2. **Developers / contributors** working on the repo itself

---

## For users / Claude Code on the user side

### What this repo is

A set of six Claude Code skills that autonomously order food from [WeBox](https://webox.com) using the user's logged-in Chrome browser:

- **`webox-onboard`** — first-time setup (run this first)
- **`webox-order`** — primary ordering. Curated full-menu scrape (favorites + preferred cuisines + filler categories), plan within budget, cart, checkout.
- **`webox-favorite`** — narrow variant: favorites-only scope, faster (~5s/slot) but limited
- **`webox-sync-calendar`** — pull latest order history from WeBox, display this week + next week
- **`webox-reset`** — wipe local data and re-onboard
- **`webox`** — general knowledge loader for ad-hoc tasks (search, inspect, browse) — loads SITEMAP.md and lets the agent improvise

**JS-first principle:** all skills prefer JavaScript / URL navigation over image+coordinate clicks. Faster, more reliable, deterministic.

### Installation

```bash
git clone https://github.com/boyugou/webox-autopilot.git /tmp/webox-autopilot
bash /tmp/webox-autopilot/install.sh
rm -rf /tmp/webox-autopilot
```

After install, **run `/webox-onboard` first** (or say "set up WeBox"). Onboarding takes ~2 minutes and:
- Verifies Chrome + WeBox login
- Asks one open-ended preferences question (waits for your reply)
- Scrapes order history and today's favorites sequentially in one tab (~15s)
- Writes all data files to `~/Documents/WeBox/`

Don't call `webox-order` before onboarding — it will refuse and ask for setup.

### Requirements

- Google Chrome with the **[Claude in Chrome](https://code.claude.com/docs/en/chrome)** extension
- User logged into WeBox in that Chrome session
- Claude Code started with `claude --chrome`

### Usage after onboarding

**Order food (default — curated full menu):**
```
Order my lunch for tomorrow.
Order lunch and dinner Mon–Fri next week, Chinese and Japanese only.
Get me 5 organic milks across this week.
```

**Order from favorites only (faster, narrow scope):**
```
Order from my usuals for tomorrow.
Quick order from my favorites.
Stick to my hearted items.
```

**View / sync calendar:**
```
Show me my WeBox calendar.
Sync my order history.
```

**Ad-hoc WeBox tasks:**
```
What's available for dinner Friday?
Search for noodles on Tuesday.
What's in my cart right now?
Clear my cart.
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
- `orders/YYYY-Www.json` — per-ISO-week order history (one file per week; auto-managed)
- `menu-cache/YYYY-MM-DD-Meal.json` — per-slot menu snapshot (TTL 60 min, auto-pruned after 24h)
- `items-with-options.md` — known dishes with required-options modals + user's chosen options (grows over time)

### Updating

```bash
git clone https://github.com/boyugou/webox-autopilot.git /tmp/webox-autopilot
bash /tmp/webox-autopilot/install.sh
rm -rf /tmp/webox-autopilot
```

Or say "update webox-autopilot" — `webox-onboard` handles updates. Files in `~/Documents/WeBox/` are never touched.

---

## For developers

### Repo layout

```
webox-autopilot/
├── .claude/skills/
│   ├── webox/
│   │   ├── SKILL.md                 # General knowledge loader for ad-hoc tasks
│   │   └── SITEMAP.md               # URL patterns, DOM selectors, anti-patterns — single source of truth
│   ├── webox-onboard/SKILL.md       # First-time setup + skill updates
│   ├── webox-order/SKILL.md         # Primary ordering — curated full menu by default
│   ├── webox-favorite/SKILL.md      # Thin variant — favorites-only narrow scope
│   ├── webox-sync-calendar/SKILL.md # Sync order history from WeBox + display weekly calendar
│   └── webox-reset/SKILL.md         # Wipe + re-onboard
├── CLAUDE.md                        # This file
├── README.md                        # User-facing docs
├── LICENSE                          # Apache 2.0
├── install.sh                       # Installer (copies all *.md per skill dir to ~/.claude/skills/)
├── preferences.md                   # Canonical preferences template (referenced by webox-onboard Step 5a)
└── .gitignore
```

`~/.claude/skills/webox/SITEMAP.md` is the **single source of truth** for WeBox URL patterns and DOM selectors. When the DOM changes, update SITEMAP.md first. Skill files reference it; they also inline the most-used scrape JS for self-containment, so when selectors change a small sync sweep across the SKILL.md files is needed.

### Data flow

```
preferences.md           ←── created by webox-onboard from user reply, edited freely
item-reviews.md          ←── written by webox-order Step 10 + free-form user feedback
orders/YYYY-Www.json     ←── written by webox-order Step 6 (planned) and Step 8 (active);
                              synced by webox-sync-calendar from WeBox order list page
                              (cancelled/refunded filtered out at sync time)
menu-cache/SLOT.json     ←── per-slot, written by webox-order or webox-favorite,
                              auto-pruned after 24h, TTL 60min
items-with-options.md    ←── grown by webox-order Step 7 (one entry per new modal encounter)
```

### Skill contracts

- Every skill calls `tabs_context_mcp` first; halts with clear message if Chrome isn't connected.
- `webox-order` and `webox-favorite` additionally require `~/Documents/WeBox/preferences.md` (direct user to `/webox-onboard` if missing).
- All scrapes use smart-scroll (loop until 2 consecutive scrolls yield no new items; capped at 8–12 iterations).
- Order history: structured selectors (`.order-id`, `.order-status`); cancelled/refunded filtered at scrape time.
- Menu page URL distinctions documented in SITEMAP.md (favorites uses `/menu/section/`, cuisines and food types use root URL with query params).
- **JS-first principle** strictly applied — see SITEMAP.md "useful tiny scripts" for examples.

### About embedding JS in SKILL.md

Claude Code doesn't execute JavaScript itself — the agent copies the snippet into `mcp__claude-in-chrome__javascript_tool`. So embedded JS in markdown is fine and is the simplest pattern:

- Short snippets (<20 lines) — inline in SKILL.md
- Reusable selectors / patterns — once in SITEMAP.md, referenced by skill files
- We don't currently use `.js` files (Claude Code's `@file` import) because the scripts aren't run from disk

If a snippet becomes truly large (50+ lines) and shared across skills, promote it to a sibling `.js` file in the skill dir and reference from SKILL.md.

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

### DOM reference

See `.claude/skills/webox/SITEMAP.md` — single source of truth. Don't duplicate selector docs here (they drift).

### When DOM changes

WeBox uses Angular with rotating `_ngcontent-*` attributes, but human-meaningful class names (`.order-id`, `.product-menu-title`, etc.) have been stable. If something breaks:

1. Inspect via Chrome devtools.
2. Update affected selectors in `webox/SITEMAP.md` first (canonical reference).
3. Update inline scrape JS in any SKILL.md files that duplicate the selector (a small sweep — `grep` for the old selector).

### When adding a new skill

1. Create `.claude/skills/<name>/SKILL.md` with YAML frontmatter (`name`, `description`).
2. Add to the `for skill in ...` loop in `install.sh`.
3. Reference it in README.md and the "For users" section above.
4. Keep single-responsibility — small skills compose better than mega-skills.

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
