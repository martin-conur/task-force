#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "Installing claude-notion scripts..."

# Shared root scripts — task-init, task-work, task-done are all impl-dispatching
# scripts at the repo root. No matter which impl was installed last, these
# point at the dispatchers and route per-project based on which workflow doc
# is present.
mkdir -p ~/.local/bin
ln -sf "$SCRIPT_DIR/../task-init" ~/.local/bin/task-init
echo "  ✓ Script: task-init (shared dispatcher)"; sleep 0.05
ln -sf "$SCRIPT_DIR/../bin/task-work" ~/.local/bin/task-work
echo "  ✓ Script: task-work (shared dispatcher)"; sleep 0.05
ln -sf "$SCRIPT_DIR/../bin/task-done" ~/.local/bin/task-done
echo "  ✓ Script: task-done (shared dispatcher)"; sleep 0.05

# Ensure ~/.local/bin is on PATH
# shellcheck disable=SC2016  # literal string written to shell RC; $HOME must not expand here
PATH_LINE='export PATH="$HOME/.local/bin:$PATH"'
MARKER='# added by claude-notion install.sh'

if [[ ":$PATH:" == *":$HOME/.local/bin:"* ]]; then
  echo "  ✓ ~/.local/bin already on PATH"
else
  case "${SHELL:-}" in
    */zsh)  rc="$HOME/.zshrc" ;;
    */bash) rc="$HOME/.bashrc" ;;
    *)      rc="$HOME/.profile" ;;
  esac
  if [[ -f "$rc" ]] && grep -qF "$MARKER" "$rc"; then
    echo "  ✓ PATH already configured in $rc"
  else
    printf '\n%s\n%s\n' "$MARKER" "$PATH_LINE" >> "$rc"
    echo "  ✓ Added ~/.local/bin to PATH in $rc"
    echo "    Run: source $rc   (or open a new terminal)"
  fi
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
sleep 0.3
echo ""
echo "Done. Next steps:"
echo ""
sleep 0.4
echo "  1. Verify the Notion MCP is configured:"
echo "       claude mcp list"
echo "     If missing:"
echo "       claude mcp add --transport http notion https://mcp.notion.com/mcp"
sleep 0.4
echo ""
echo "  2. In your project root, run:"
echo "       task-init claude-notion"
sleep 0.4
echo ""
echo "  3. Fill in your Notion database IDs in .claude/notion-workflow.md"
echo "     (open your Notion board in Claude Code to find the collection:// IDs)"
sleep 0.4
echo ""
echo "  4. Start Claude and kick off the PM agent:"
echo "       claude"
echo "     then type /pm"
echo ""
