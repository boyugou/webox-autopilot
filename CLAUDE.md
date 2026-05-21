# webox-autopilot — Claude Code Install Guide

This file tells Claude Code exactly how to install the `webox-order` skill and get started ordering food on WeBox.

## What this repo is

A Claude Code skill that autonomously orders food from [WeBox](https://webox.com) using the user's logged-in Chrome browser. It checks your order history, scrapes the menu, picks items within your budget and preferences, adds to cart, and checks out.

## Installation (run these shell commands)

```bash
# 1. Clone the repo
git clone https://github.com/boyugou/webox-autopilot.git /tmp/webox-autopilot

# 2. Install the skill
mkdir -p ~/.claude/skills/webox-order
cp /tmp/webox-autopilot/.claude/skills/webox-order/SKILL.md ~/.claude/skills/webox-order/

# 3. Set up user preferences (skip if already exists)
mkdir -p ~/.webox-autopilot
[ ! -f ~/.webox-autopilot/user-preferences.md ] && cp /tmp/webox-autopilot/user-preferences.md ~/.webox-autopilot/

# 4. Clean up
rm -rf /tmp/webox-autopilot
```

After running those commands, the `webox-order` skill is installed and ready.

## Requirements before ordering

- Google Chrome must be running with the **Claude in Chrome** extension enabled
- User must be **logged into WeBox** in that Chrome session
- Claude Code must be started with `claude --chrome` (or chrome integration enabled)

## How to order after installation

Just tell Claude Code what you want:

```
Order my lunch for tomorrow.
```

```
Order lunch and dinner Mon–Fri next week. Prefer Chinese and Japanese food.
```

```
Order dinner for tonight, something healthy, under $20.
```

Claude Code will invoke the `webox-order` skill automatically.

## User preferences

Edit `~/.webox-autopilot/user-preferences.md` to set budget, dietary restrictions, preferred cuisines, drink policy, etc. Claude reads this at the start of every order session.

## Updating the skill

```bash
git clone https://github.com/boyugou/webox-autopilot.git /tmp/webox-autopilot
cp /tmp/webox-autopilot/.claude/skills/webox-order/SKILL.md ~/.claude/skills/webox-order/
rm -rf /tmp/webox-autopilot
```
