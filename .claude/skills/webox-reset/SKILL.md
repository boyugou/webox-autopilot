---
name: webox-reset
description: Reset webox-autopilot back to a clean state — delete all local data files in ~/Documents/WeBox/ and re-run onboarding. Use when the user says "reset webox", "clear my WeBox data", "start over", or wants to wipe preferences and start fresh.
---

# WeBox Reset Skill

Clears all local webox-autopilot data and re-runs onboarding.

Files in `~/Documents/WeBox/` that get deleted:
- `preferences.md`
- `item-reviews.md`
- `order-history.md`
- `items-with-options.md`
- `menu-cache/` (entire directory)

Does NOT touch:
- The installed skills at `~/.claude/skills/webox-*` (use `/webox-onboard` → "Update the skill" for that)
- Anything outside `~/Documents/WeBox/`

---

## Step 1: Confirm with the user

Reset is destructive. Show what will be deleted:

```bash
ls -la ~/Documents/WeBox/
```

Then ask:

> About to wipe these files in ~/Documents/WeBox/:
>   - preferences.md
>   - item-reviews.md (X items reviewed)
>   - order-history.md (X past orders, history will resync from WeBox)
>   - items-with-options.md
>   - menu-cache/ (X cached menus)
>
> Your WeBox account itself is untouched — only the local files Claude uses.
> Type "yes reset" to confirm.

Wait for explicit "yes" or "yes reset" confirmation. Any other reply aborts.

## Step 2: Wipe

```bash
rm -rf ~/Documents/WeBox
mkdir -p ~/Documents/WeBox
```

## Step 3: Trigger onboarding

Hand off to `webox-onboard`:

> Done. Running onboarding now…

Then invoke the `webox-onboard` skill (or instruct: "Now run `/webox-onboard`").
