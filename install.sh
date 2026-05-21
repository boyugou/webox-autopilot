#!/usr/bin/env bash
# webox-autopilot installer
# Usage: bash install.sh
set -e

SKILLS_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/.claude/skills"
CLAUDE_SKILLS="$HOME/.claude/skills"
WEBOX_DIR="$HOME/Documents/WeBox"

echo "Installing webox-autopilot skills..."

# Install all four skills
for skill in webox-onboard webox-order webox-calendar webox-sync-favorites; do
  mkdir -p "$CLAUDE_SKILLS/$skill"
  cp "$SKILLS_SRC/$skill/SKILL.md" "$CLAUDE_SKILLS/$skill/"
  echo "  ✓ $skill"
done

# Set up data directory (visible in ~/Documents/, never overwrite existing files)
mkdir -p "$WEBOX_DIR"
if [ ! -f "$WEBOX_DIR/preferences.md" ]; then
  cp "$(dirname "${BASH_SOURCE[0]}")/preferences.md" "$WEBOX_DIR/"
  echo "  ✓ Created $WEBOX_DIR/preferences.md"
  echo "    → Edit this file, or run /webox-onboard to set it up interactively"
else
  echo "  ✓ $WEBOX_DIR/preferences.md already exists (not overwritten)"
fi

echo ""
echo "Done! Your WeBox data lives in: $WEBOX_DIR"
echo ""
echo "Next step — run Claude Code with Chrome integration:"
echo "  claude --chrome"
echo ""
echo "Then run: /webox-onboard"
echo "  (sets up your preferences, syncs favorites and order history)"
