# webox-autopilot — Claude Code Install Guide

This file tells Claude Code exactly how to install the webox-autopilot skills and get started ordering food on WeBox.

## What this repo is

A set of Claude Code skills that autonomously order food from [WeBox](https://webox.com) using the user's logged-in Chrome browser. Skills check order history, scrape menus, pick items within budget and preferences, add to cart, and check out.

## Installation (run these shell commands)

```bash
# 1. Clone the repo
git clone https://github.com/boyugou/webox-autopilot.git /tmp/webox-autopilot

# 2. Run the installer (copies all three skills + preferences template)
bash /tmp/webox-autopilot/install.sh

# 3. Clean up
rm -rf /tmp/webox-autopilot
```

This installs three skills:
- `webox-order` — order meals autonomously
- `webox-calendar` — view and sync the order calendar
- `webox-sync-favorites` — refresh the favorites list

## Requirements before using

- Google Chrome must be running with the **[Claude in Chrome](https://code.claude.com/docs/en/chrome)** extension enabled
- User must be **logged into WeBox** in that Chrome session
- Claude Code must be started with `claude --chrome` (or Chrome integration enabled)

## How to use after installation

**Order food:**
```
Order my lunch for tomorrow.
Order lunch and dinner Mon–Fri next week, Chinese and Japanese only.
Order dinner tonight — something healthy, under $20.
```

**View/sync the order calendar:**
```
Show me my WeBox calendar for this week and next.
Sync my order history.
```

**Refresh favorites:**
```
Refresh my WeBox favorites.
Update my favorites list.
```

**Manage reviews and preferences:**
```
The Mongolian Beef bento was amazing — save that as 5/5.
I'm vegetarian now — update my preferences.
```

## User preferences

`~/Documents/WeBox/preferences.md` controls budget, dietary restrictions, confirmation mode, and more. Created automatically on first run from your onboarding answers. Edit it anytime.

## Updating

```bash
git clone https://github.com/boyugou/webox-autopilot.git /tmp/webox-autopilot
bash /tmp/webox-autopilot/install.sh
rm -rf /tmp/webox-autopilot
```

Your `~/Documents/WeBox/` files (preferences, reviews, caches) are never overwritten by updates.
