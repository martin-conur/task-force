#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "Installing claude-gh scripts..."

# region:install-shared-symlinks
# Shared root scripts. task-init / task-work / task-done are impl-dispatching
# scripts at the repo root (they route per-project based on which workflow doc
# is present); task-pm and radio are canonical single copies (#170). This
# stanza is byte-identical across all seven loadout installers and is
# drift-guarded by tools/check-drift.sh.
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
# endregion:install-shared-symlinks
ln -sf "$SCRIPT_DIR/../bin/task-reviewer" ~/.local/bin/task-reviewer
echo "  ✓ Script: task-reviewer (canonical + kiro routing)"; sleep 0.05

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
echo "  1. Verify the gh CLI is authenticated:"
echo "       gh auth status"
echo "     If not, run: gh auth login   (needs repo + project scopes)"
sleep 0.4
echo ""
echo "  2. In your project root, run:"
echo "       task-init claude-gh"
echo "     (prompts for owner, repo, and project number — auto-detected from git remote)"
sleep 0.4
echo ""
echo "  3. Start Claude and kick off the PM agent:"
echo "       claude"
echo "     then type /pm"
sleep 0.4
echo ""
echo "  Optional: GitHub MCP add-on (for richer Projects v2 mutations)"
echo "       claude mcp add --transport stdio github -- npx -y @github/github-mcp-server"
echo "     (requires GITHUB_PERSONAL_ACCESS_TOKEN in your environment)"
echo ""
