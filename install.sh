#!/usr/bin/env bash
# webox-autopilot installer / updater
# Usage: bash install.sh
set -e

# Sanity check — must run from a cloned repo
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILLS_SRC="$SCRIPT_DIR/.claude/skills"
if [ ! -d "$SKILLS_SRC" ]; then
  echo "Error: skills directory not found at $SKILLS_SRC"
  echo "Run install.sh from inside the cloned webox-autopilot repo."
  exit 1
fi

CLAUDE_SKILLS="$HOME/.claude/skills"
WEBOX_DIR="$HOME/Documents/WeBox"

echo "Installing webox-autopilot skills..."

# Skills we currently ship
CURRENT_SKILLS=(webox webox-onboard webox-order webox-favorite webox-sync webox-reset)

# Skills we used to ship but no longer do — remove them so the user's
# skill picker isn't polluted with stale entries.
OBSOLETE_SKILLS=(webox-calendar webox-sync-calendar webox-sync-favorites webox-order-all)

# Remove obsolete skill dirs (no-op if they don't exist)
for old in "${OBSOLETE_SKILLS[@]}"; do
  if [ -d "$CLAUDE_SKILLS/$old" ]; then
    rm -rf "$CLAUDE_SKILLS/$old"
    echo "  − removed obsolete: $old"
  fi
done

# Install current skills (and any sibling .md docs like SITEMAP.md)
for skill in "${CURRENT_SKILLS[@]}"; do
  if [ ! -d "$SKILLS_SRC/$skill" ]; then
    echo "  ⚠ source missing: $SKILLS_SRC/$skill — skipping"
    continue
  fi
  mkdir -p "$CLAUDE_SKILLS/$skill"
  # Clear stale files in the target dir, then copy fresh
  rm -f "$CLAUDE_SKILLS/$skill"/*.md
  cp "$SKILLS_SRC/$skill"/*.md "$CLAUDE_SKILLS/$skill/"
  echo "  ✓ $skill"
done

# Place both canonical templates inside webox-onboard's skill dir so the agent can read
# them locally at onboarding time (instead of refetching from GitHub).
for tpl in config.yaml preferences.md; do
  if [ -f "$SCRIPT_DIR/$tpl" ]; then
    cp "$SCRIPT_DIR/$tpl" "$CLAUDE_SKILLS/webox-onboard/$tpl"
    echo "  ✓ $tpl template → webox-onboard/"
  fi
done

# Create data directory (do NOT copy a template preferences.md — let webox-onboard create it
# from the user's actual answers. Otherwise webox-onboard would skip onboarding.)
mkdir -p "$WEBOX_DIR"
echo "  ✓ Data directory ready at $WEBOX_DIR"

echo ""
echo "✅ Installed/updated. Next step:"
echo ""
echo "   1. Start Claude Code with Chrome integration:  claude --chrome"
echo "   2. Run:  /webox-onboard  (or say 'set up WeBox')"
echo ""
echo "Re-run this same script anytime to upgrade — your $WEBOX_DIR data is untouched."
