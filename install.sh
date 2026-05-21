#!/usr/bin/env bash
# webox-autopilot installer
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

# Install all six skills (and any sibling .md docs like SITEMAP.md)
for skill in webox webox-onboard webox-order webox-favorite webox-sync-calendar webox-reset; do
  mkdir -p "$CLAUDE_SKILLS/$skill"
  cp "$SKILLS_SRC/$skill"/*.md "$CLAUDE_SKILLS/$skill/"
  echo "  ✓ $skill"
done

# Create data directory (do NOT copy a template preferences.md — let webox-onboard create it
# from the user's actual answers. Otherwise webox-onboard would skip onboarding.)
mkdir -p "$WEBOX_DIR"
echo "  ✓ Data directory ready at $WEBOX_DIR"

echo ""
echo "✅ Installed. Next step:"
echo ""
echo "   1. Start Claude Code with Chrome integration:  claude --chrome"
echo "   2. Run:  /webox-onboard  (or say 'set up WeBox')"
echo ""
echo "Onboarding takes ~2 minutes and creates all your files in $WEBOX_DIR"
