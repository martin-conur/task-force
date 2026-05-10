#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "Installing claude-gh commands and scripts..."

# Slash commands → ~/.claude/commands/
mkdir -p ~/.claude/commands
for cmd in "$SCRIPT_DIR"/commands/*.md; do
  name=$(basename "$cmd")
  ln -sf "$cmd" ~/.claude/commands/"$name"
  echo "  ✓ Slash command: /$(basename "$name" .md)"; sleep 0.05
done

# Scripts → ~/.local/bin/ (task-init handled separately via unified root script)
mkdir -p ~/.local/bin
for script in "$SCRIPT_DIR"/bin/*; do
  name=$(basename "$script")
  [[ "$name" == "task-init" ]] && continue
  ln -sf "$script" ~/.local/bin/"$name"
  echo "  ✓ Script: $name"; sleep 0.05
done

# Unified task-init (always points to repo-root task-init regardless of which impl was installed last)
ln -sf "$SCRIPT_DIR/../task-init" ~/.local/bin/task-init
echo "  ✓ Script: task-init (unified)"; sleep 0.05

# Ensure ~/.local/bin is on PATH
# shellcheck disable=SC2016  # literal string written to shell RC; $HOME must not expand here
PATH_LINE='export PATH="$HOME/.local/bin:$PATH"'
MARKER='# added by claude-gh install.sh'

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
echo "  1. Set GITHUB_PERSONAL_ACCESS_TOKEN in your environment"
echo "     (needs repo + project scopes)"
sleep 0.4
echo ""
echo "  2. Verify the GitHub MCP is configured:"
echo "       claude mcp list"
echo "     If missing:"
echo "       claude mcp add --transport stdio github -- npx -y @github/github-mcp-server"
sleep 0.4
echo ""
echo "  3. In your project root, run:"
echo "       task-init claude-gh"
echo "     (prompts for owner, repo, and project number — auto-detected from git remote)"
sleep 0.4
echo ""
echo "  4. Start Claude and kick off the PM agent:"
echo "       claude"
echo "     then type /pm"
echo ""
