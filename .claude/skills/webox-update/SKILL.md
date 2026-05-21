---
name: webox-update
description: Update webox-autopilot to the latest version from GitHub. Pulls fresh skill files into ~/.claude/skills/webox-*/, preserves all user data in ~/Documents/WeBox/. Use when the user says "update webox-autopilot", "pull the latest", "upgrade webox", or after a known new release.
---

# WeBox Update Skill

Pulls the latest skill files from https://github.com/boyugou/webox-autopilot and reinstalls them in `~/.claude/skills/webox-*/`. **User data in `~/Documents/WeBox/` is never touched.**

After updating, the user must restart Claude Code (the current session continues with the old in-memory copy of the skills until a fresh session loads the new files).

---

## Step 1: Confirm with the user

> About to update webox-autopilot to the latest from GitHub.
>
> This will:
>   - Overwrite ~/.claude/skills/webox*/ with the latest skill files
>   - Leave ~/Documents/WeBox/ (your preferences, history, reviews, identity caches) completely untouched
>   - Require a Claude Code restart after to take effect
>
> Proceed?

Wait for "yes" (or equivalent). Anything else aborts.

## Step 2: Show current installed commit (so the user knows what they had)

```bash
# Show the commit currently installed locally if we can — install.sh doesn't write a version marker,
# but we can check the GitHub HEAD to compare.
echo "Latest commit on origin/main:"
curl -s 'https://api.github.com/repos/boyugou/webox-autopilot/commits/main' | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(f'  {d[\"sha\"][:7]} — {d[\"commit\"][\"message\"].splitlines()[0]}')
print(f'  {d[\"commit\"][\"committer\"][\"date\"]}')
"
```

## Step 3: Clone + install

```bash
git clone https://github.com/boyugou/webox-autopilot.git /tmp/webox-autopilot-update \
  && bash /tmp/webox-autopilot-update/install.sh \
  && cd /tmp/webox-autopilot-update && git log --oneline -3 && cd /
rm -rf /tmp/webox-autopilot-update
```

Report which commit was just installed (parse from the `git log --oneline -3` output above).

## Step 4: Detect schema changes

The local data schema (config.yaml keys, file shapes) sometimes changes across versions. If it did, the user needs to re-run `/webox-onboard` to migrate. Check:

```bash
# Compare local config.yaml's top-level keys against the new template
if [ -f ~/Documents/WeBox/config.yaml ] && [ -f ~/.claude/skills/webox-onboard/config.yaml ]; then
  python3 << 'EOF'
import re, pathlib
local = re.findall(r'^([a-z_]+):', pathlib.Path.home().joinpath("Documents/WeBox/config.yaml").read_text(), re.M)
template = re.findall(r'^([a-z_]+):', pathlib.Path.home().joinpath(".claude/skills/webox-onboard/config.yaml").read_text(), re.M)
local_set, template_set = set(local), set(template)
new_in_template = template_set - local_set
removed_in_template = local_set - template_set
if new_in_template or removed_in_template:
    print("⚠ Schema diff between local config.yaml and new template:")
    if new_in_template: print("  + new fields:", sorted(new_in_template))
    if removed_in_template: print("  - removed fields:", sorted(removed_in_template))
    print("  Recommended: back up ~/Documents/WeBox, run /webox-reset, then /webox-onboard.")
else:
    print("✓ Config schema unchanged — no migration needed.")
EOF
fi
```

## Step 5: Suggest stale-data refresh

Even when the schema is unchanged, an older skill version may have left stale data behind (e.g., incomplete `orders/YYYY-Www.json` files from a bug that's now fixed). Suggest a quick re-sync:

> Update installed. To pull any fixes that affect your local data (e.g., bug fixes to history sync), run `/webox-sync` after restarting Claude Code. This refreshes orders, favorites, hidden list, and warm-cache menus from WeBox.

## Step 6: Tell the user to restart

> 🔄 To activate the new skill files, restart Claude Code:
>
>   1. Exit this session (Ctrl-C or close the terminal)
>   2. `claude --chrome`
>   3. Optionally run `/webox-sync` to refresh local caches with the new code's improvements

Until the user restarts, the running session continues with the old in-memory skills. That's normal — Claude Code reads skills at session start.

---

## When NOT to use this skill

- **Schema-breaking version bumps** — for those, the release notes will say "full reinstall recommended". In that case use the full-reinstall one-liner in `README.md`, not this skill.
- **First-time install** — point the user at `README.md`'s Setup section. This skill assumes an existing installation.
- **User wants to clear local data** — that's `/webox-reset`, not this.
