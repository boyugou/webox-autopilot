# webox-autopilot — Claude Code Install Guide

This file tells Claude Code exactly how to install the webox-autopilot skills and get the user started.

## What this repo is

A set of four Claude Code skills that autonomously order food from [WeBox](https://webox.com) using the user's logged-in Chrome browser:

- **`webox-onboard`** — first-time setup (run this first)
- **`webox-order`** — order meals autonomously
- **`webox-calendar`** — view and sync the order calendar
- **`webox-sync-favorites`** — refresh the favorites cache

## Installation (run these shell commands)

```bash
# 1. Clone the repo
git clone https://github.com/boyugou/webox-autopilot.git /tmp/webox-autopilot

# 2. Run the installer (copies all four skills to ~/.claude/skills/)
bash /tmp/webox-autopilot/install.sh

# 3. Clean up
rm -rf /tmp/webox-autopilot
```

After install completes, **the user must run `/webox-onboard` (or say "set up WeBox") before ordering**. The onboarding skill:
- Verifies Chrome + WeBox login
- Asks one open-ended preferences question
- Scrapes favorites and order history in parallel while the user types
- Writes all data files to `~/Documents/WeBox/`

Do not attempt to call `webox-order` before onboarding has completed — it will refuse with a message asking the user to run `/webox-onboard`.

## Requirements

- Google Chrome with the **[Claude in Chrome](https://code.claude.com/docs/en/chrome)** extension enabled
- User logged into WeBox in that Chrome session
- Claude Code started with `claude --chrome` (or Chrome integration enabled)

## How to use after onboarding

**Order food:**
```
Order my lunch for tomorrow.
Order lunch and dinner Mon–Fri next week, Chinese and Japanese only.
Order dinner tonight — something healthy, under $20.
Get me 5 organic milks across this week.
```

**View / sync the calendar:**
```
Show me my WeBox calendar.
Sync my order history.
```

**Refresh favorites:**
```
Refresh my WeBox favorites.
```

**Manage preferences and reviews (natural language, any time):**
```
Update my budget to $25.
I'm vegetarian now.
The Mongolian Beef bento was amazing — save that as 5/5.
这个超级咸，别再点了
```

## User data

`~/Documents/WeBox/` (visible in Finder):
- `preferences.md` — all settings (budget, diet, cuisines, etc.)
- `item-reviews.md` — personal ratings and free-form comments on dishes
- `order-history.md` — unified record of past + planned orders, used for variety tracking
- `favorites-cache.md` — cached favorites list (refreshed weekly)
- `items-with-options.md` — known dishes with required-options modals + the user's chosen options

## Updating the skill

```bash
git clone https://github.com/boyugou/webox-autopilot.git /tmp/webox-autopilot
bash /tmp/webox-autopilot/install.sh
rm -rf /tmp/webox-autopilot
```

Or tell the user: "say 'update webox-autopilot'" — `webox-onboard` handles updates via the same flow.

Files in `~/Documents/WeBox/` are never overwritten by updates.
