#!/usr/bin/env bash
# webox-autopilot installer
# Usage: bash install.sh
set -e

SKILL_DIR="$HOME/.claude/skills/webox-order"
PREFS_DIR="$HOME/.webox-autopilot"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "Installing webox-order skill..."

mkdir -p "$SKILL_DIR"
cp "$SCRIPT_DIR/.claude/skills/webox-order/SKILL.md" "$SKILL_DIR/"
echo "  ✓ Skill installed to $SKILL_DIR"

mkdir -p "$PREFS_DIR"
if [ ! -f "$PREFS_DIR/user-preferences.md" ]; then
  cp "$SCRIPT_DIR/user-preferences.md" "$PREFS_DIR/"
  echo "  ✓ Preferences template created at $PREFS_DIR/user-preferences.md"
  echo "    → Edit this file to set your budget, cuisines, dietary restrictions, etc."
else
  echo "  ✓ Preferences file already exists at $PREFS_DIR/user-preferences.md (not overwritten)"
fi

echo ""
echo "Done! Start Claude Code with Chrome integration:"
echo "  claude --chrome"
echo ""
echo "Then tell Claude: \"Order my lunch for tomorrow.\""
