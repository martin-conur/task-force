#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "Installing kiro-agents..."

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

# Check PATH
if [[ ":$PATH:" != *":$HOME/.local/bin:"* ]]; then
  echo ""
  echo "⚠ ~/.local/bin is not in your PATH. Add to your shell rc:"
  echo "  export PATH=\"\$HOME/.local/bin:\$PATH\""
fi

echo ""
echo "Done. Next steps:"
echo "  1. Copy steering/notion-workflow.example.md to your project's .kiro/steering/notion-workflow.md"
echo "  2. Fill in your Notion database IDs"
echo "  3. Start with: kiro-cli chat --agent pm"
