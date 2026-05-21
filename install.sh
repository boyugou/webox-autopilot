#!/usr/bin/env bash
# webox-autopilot installer
# Usage: bash install.sh
set -e

SKILLS_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/.claude/skills"
CLAUDE_SKILLS="$HOME/.claude/skills"
PREFS_DIR="$HOME/.webox-autopilot"

echo "Installing webox-autopilot skills..."

# Install all three skills
for skill in webox-order webox-calendar webox-sync-favorites; do
  mkdir -p "$CLAUDE_SKILLS/$skill"
  cp "$SKILLS_SRC/$skill/SKILL.md" "$CLAUDE_SKILLS/$skill/"
  echo "  ✓ $skill → $CLAUDE_SKILLS/$skill/"
done

# Set up preferences directory and template (never overwrite existing)
mkdir -p "$PREFS_DIR"
if [ ! -f "$PREFS_DIR/user-preferences.md" ]; then
  cp "$(dirname "${BASH_SOURCE[0]}")/user-preferences.md" "$PREFS_DIR/"
  echo "  ✓ Preferences template → $PREFS_DIR/user-preferences.md"
  echo "    (Edit this file to set your budget, cuisines, dietary restrictions, etc.)"
else
  echo "  ✓ Preferences already exist at $PREFS_DIR/user-preferences.md (not overwritten)"
fi

echo ""
echo "Done! Skills installed:"
echo "  webox-order          — order meals autonomously"
echo "  webox-calendar       — view and sync your order calendar"
echo "  webox-sync-favorites — refresh your favorites list"
echo ""
echo "Start Claude Code with Chrome integration:"
echo "  claude --chrome"
echo ""
echo "Then tell Claude: \"Order my lunch for tomorrow.\""
