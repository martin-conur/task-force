#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "Installing claude-jira commands and scripts..."

# Slash commands → ~/.claude/commands/
mkdir -p ~/.claude/commands
for cmd in "$SCRIPT_DIR"/commands/*.md; do
  name=$(basename "$cmd")
  ln -sf "$cmd" ~/.claude/commands/"$name"
  echo "  ✓ Slash command: /$(basename "$name" .md)"
done

# Scripts → ~/.local/bin/ (task-init handled separately via unified root script)
mkdir -p ~/.local/bin
for script in "$SCRIPT_DIR"/bin/*; do
  name=$(basename "$script")
  [[ "$name" == "task-init" ]] && continue
  ln -sf "$script" ~/.local/bin/"$name"
  echo "  ✓ Script: $name"
done

# Unified task-init (always points to repo-root task-init regardless of which impl was installed last)
ln -sf "$SCRIPT_DIR/../task-init" ~/.local/bin/task-init
echo "  ✓ Script: task-init (unified)"

# shellcheck disable=SC2016  # literal string written to shell RC; $HOME must not expand here
PATH_LINE='export PATH="$HOME/.local/bin:$PATH"'
MARKER='# added by claude-jira install.sh'

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
echo "Done. Next steps:"
echo "  1. Verify the Atlassian MCP is configured: claude mcp list"
echo "  2. In your project root, run: task-init claude-jira --site https://... --key PROJ"
echo "  3. Fill in any remaining details in .claude/jira-workflow.md"
echo "  4. Start with: claude   (then type /pm)"
