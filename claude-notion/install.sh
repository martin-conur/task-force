#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "Installing claude-notion scripts..."

# region:install-shared-symlinks
# Shared root scripts. task-init / task-work / task-done / task-board are
# impl-dispatching scripts at the repo root (they route per-project based on
# which workflow doc is present); task-pm, radio and task-config are canonical
# single copies (#170, #219 — task-config acts *across* loadouts, so a
# per-loadout copy would make no sense).
# Every loadout links task-board even though only the two *-local
# loadouts implement it: the dispatcher's job on the others is to refuse with a
# message naming the detected loadout, rather than the command being absent
# (#215). This stanza is byte-identical across all seven loadout installers and
# is drift-guarded by tools/check-drift.sh.
mkdir -p ~/.local/bin
ln -sf "$SCRIPT_DIR/../task-init" ~/.local/bin/task-init
echo "  ✓ Script: task-init (shared dispatcher)"; sleep 0.05
ln -sf "$SCRIPT_DIR/../bin/task-work" ~/.local/bin/task-work
echo "  ✓ Script: task-work (shared dispatcher)"; sleep 0.05
ln -sf "$SCRIPT_DIR/../bin/task-done" ~/.local/bin/task-done
echo "  ✓ Script: task-done (shared dispatcher)"; sleep 0.05
ln -sf "$SCRIPT_DIR/../bin/task-pm" ~/.local/bin/task-pm
echo "  ✓ Script: task-pm (canonical)"; sleep 0.05
ln -sf "$SCRIPT_DIR/../bin/radio" ~/.local/bin/radio
echo "  ✓ Script: radio (PM↔worker mailbox CLI)"; sleep 0.05
ln -sf "$SCRIPT_DIR/../bin/ci-guard" ~/.local/bin/ci-guard
echo "  ✓ Script: ci-guard (commit-msg CI-skip-marker guard)"; sleep 0.05
ln -sf "$SCRIPT_DIR/../bin/task-board" ~/.local/bin/task-board
echo "  ✓ Script: task-board (shared dispatcher)"; sleep 0.05
ln -sf "$SCRIPT_DIR/../bin/task-config" ~/.local/bin/task-config
echo "  ✓ Script: task-config (canonical)"; sleep 0.05
# endregion:install-shared-symlinks
ln -sf "$SCRIPT_DIR/../bin/task-reviewer" ~/.local/bin/task-reviewer
echo "  ✓ Script: task-reviewer (canonical + kiro routing)"; sleep 0.05

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
