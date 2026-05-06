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

# Scripts → ~/.local/bin/
mkdir -p ~/.local/bin
for script in "$SCRIPT_DIR"/bin/*; do
  name=$(basename "$script")
  ln -sf "$script" ~/.local/bin/"$name"
  echo "  ✓ Script: $name"
done

# Ensure ~/.local/bin is on PATH
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
echo "  1. Copy steering/notion-workflow.example.md to your project's .kiro/steering/notion-workflow.md"
echo "  2. Fill in your Notion database IDs"
echo "  3. Start with: kiro-cli chat --agent pm"
