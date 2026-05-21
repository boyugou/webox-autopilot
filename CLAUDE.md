# webox-autopilot — Claude Code Guide

This file is for **two audiences**:
1. **Claude Code on a user's machine** following the install steps below to install the skill set
2. **Developers / contributors** working on the repo itself

---

## For users / Claude Code on the user side

### What this repo is

A set of four Claude Code skills that autonomously order food from [WeBox](https://webox.com) using the user's logged-in Chrome browser:

- **`webox-onboard`** — first-time setup (run this first)
- **`webox-order`** — order meals autonomously
- **`webox-calendar`** — view and sync the order calendar
- **`webox-sync-favorites`** — refresh the favorites cache

### Installation

```bash
git clone https://github.com/boyugou/webox-autopilot.git /tmp/webox-autopilot
bash /tmp/webox-autopilot/install.sh
rm -rf /tmp/webox-autopilot
```

After install, **the user must run `/webox-onboard` (or say "set up WeBox") before ordering**. Onboarding takes ~2 minutes and:
- Verifies Chrome + WeBox login
- Asks one open-ended preferences question
- Scrapes favorites and order history in parallel
- Writes all data files to `~/Documents/WeBox/`

Do not call `webox-order` before onboarding — it will refuse and ask for setup.

### Requirements

- Google Chrome with the **[Claude in Chrome](https://code.claude.com/docs/en/chrome)** extension enabled
- User logged into WeBox in that Chrome session
- Claude Code started with `claude --chrome`

### Usage

```
Order my lunch for tomorrow.
Order lunch and dinner Mon–Fri next week, Chinese and Japanese only.
Get me 5 organic milks across this week.
Show me my WeBox calendar.
Refresh my favorites.
The Mongolian Beef bento was amazing — 5/5.
这个超级咸，别再点了
```

### Updating the skill

```bash
git clone https://github.com/boyugou/webox-autopilot.git /tmp/webox-autopilot
bash /tmp/webox-autopilot/install.sh
rm -rf /tmp/webox-autopilot
```

Or say "update webox-autopilot" — `webox-onboard` handles updates via the same flow. Files in `~/Documents/WeBox/` are never touched by updates.

---

## For developers

### Repo layout

```
webox-autopilot/
├── .claude/skills/
│   ├── webox-onboard/SKILL.md      # First-time setup
│   ├── webox-order/SKILL.md        # Core ordering skill (longest, ~600 lines)
│   ├── webox-calendar/SKILL.md     # View/sync order calendar
│   └── webox-sync-favorites/SKILL.md  # Refresh favorites cache
├── CLAUDE.md                       # This file
├── README.md                       # User-facing docs
├── LICENSE                         # Apache 2.0
├── install.sh                      # Installer (copies skills to ~/.claude/skills/)
├── preferences.md                  # Canonical preferences template
└── .gitignore                      # Blocks local cache/data files
```

### Data flow

```
preferences.md (~/Documents/WeBox/)  ←─ created by webox-onboard from user reply
item-reviews.md                       ←─ written by webox-order Step 10, edited by user
order-history.md                      ←─ written by webox-order Step 6/8, synced by webox-calendar
favorites-cache.md                    ←─ written by webox-onboard, webox-sync-favorites,
                                          and webox-order Step 3 (cache miss)
items-with-options.md                 ←─ grown by webox-order Step 7
menu-cache/YYYY-MM-DD-Meal.json       ←─ written by webox-order Step 3 (per-slot, 60-min TTL)
```

### Skill invocation contract

- Every skill checks `tabs_context_mcp` first; halts with a clear message if Chrome isn't connected.
- `webox-order` additionally checks for `~/Documents/WeBox/preferences.md` and halts if missing (directs user to `/webox-onboard`).
- All scraping uses **smart scroll** (loop until 2 consecutive scrolls yield no new items, capped at 10–20 iterations). Verified DOM selectors live in each skill's "DOM Reference" section.
- Order-history scraping uses structured selectors `.order-id` and `.order-status`. Slots with `Refunded` or `Cancelled` status are treated as **open** (can be re-ordered).

### Testing changes locally

After editing skill files in this repo:

```bash
# Install your local changes
bash install.sh

# Restart Claude Code so the new skill files are picked up
# (the in-memory cached version of SKILL.md persists across the same session)
```

For testing the full flow end-to-end without polluting real data:

```bash
# Backup
mv ~/Documents/WeBox ~/Documents/WeBox.bak.$(date +%s)

# Run /webox-onboard with a mock answer ("budget 30, no restrictions"),
# then /webox-order with a test date+meal.
# When done:

# Restore
rm -rf ~/Documents/WeBox
mv ~/Documents/WeBox.bak.<TIMESTAMP> ~/Documents/WeBox
```

### DOM reference (verified 2026-05-20)

Order list (`/order/list/normal`):
- `.order-item` — one per order
- `.order-id` — e.g. "No.3258614"
- `.order-status` — "Refunded", "Cancelled", absent for active
- `.order-type` — usually "Order"

Menu pages:
- `app-product-menu-item.menu-section-product-item, .new-menu-product-item` — product card
- `.product-menu-title` — clean item name
- `.brand-wrapper` — brand
- `.product-price` — "$17.55"
- `.product-menu-top-sold-out-wrapper` — sold-out flag (check `getComputedStyle(el).display !== 'none'`)
- `.btn.plus-add` — add-to-cart for most items (DIV)
- `.product-add-wrapper` — add-to-cart for items with required options (SPAN, opens modal)
- `[class*="product-detail-header"]` — modal-open indicator

### When DOM changes

WeBox is built on Angular with `_ngcontent` attributes that change between deploys, but the human-meaningful class names (`.order-id`, `.product-menu-title`, etc.) have been stable. If something breaks:

1. Inspect the real DOM in Chrome devtools (open a WeBox page, right-click → Inspect).
2. Update the affected selectors in the skill's "DOM Reference" table and the JS snippets.
3. Verify across all four skills — selectors are duplicated for skill independence; keep them consistent.

### When adding a new skill

1. Create `.claude/skills/<skill-name>/SKILL.md` with YAML frontmatter (`name`, `description`).
2. Add it to the `for` loop in `install.sh`.
3. Reference it in `README.md` (Skills table) and this file.
4. Keep skills focused — single responsibility (e.g., `webox-sync-favorites` only refreshes favorites, doesn't order).

### When changing the preferences schema

- Update `preferences.md` (canonical template).
- Update `webox-onboard` Step 5a (which references the template).
- Update `webox-order` Step 1a (where field names are extracted).
- Update `README.md` Configuration Reference table.

### Commit conventions

- English only (commits, code, comments — per global CLAUDE.md).
- Use `uv` for any Python (never `python3` / `pip` directly).
- No backwards-compatibility shims for renames — this is a small project, rip-and-replace is preferred. Stale references in committed files are bugs.
- Self-contained docstrings: each SKILL.md should be readable as a complete contract without cross-referencing other skills.

### Open issues / future work

- HappyHour / weekend ordering not implemented (only Lunch/Dinner)
- No `webox-cancel` skill (user cancels manually at webox.com)
- Quantity stepper in cart for items with required-options modals: currently the skill opens the modal, clicks "Add to Cart" once, then clicks the `+` stepper in cart panel — this could be more robust
- No automated tests; reliance on manual e2e validation with real orders
