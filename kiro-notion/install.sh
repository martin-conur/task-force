#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "Installing kiro-notion agents..."

# Agents → ~/.kiro/agents/
mkdir -p ~/.kiro/agents
for agent in "$SCRIPT_DIR"/agents/*.json; do
  name=$(basename "$agent")
  ln -sf "$agent" ~/.kiro/agents/"$name"
  echo "  ✓ Agent: $name"
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

# Ensure ~/.local/bin is on PATH
# shellcheck disable=SC2016  # literal string written to shell RC; $HOME must not expand here
PATH_LINE='export PATH="$HOME/.local/bin:$PATH"'
MARKER='# added by kiro-notion install.sh'

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
echo "  1. In your project root, run: task-init kiro-notion"
echo "  2. Fill in your Notion database IDs in .kiro/steering/notion-workflow.md"
echo "  3. Start with: kiro-cli chat --agent pm"
