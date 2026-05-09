#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

usage() {
  cat <<'EOF'
Usage: ./install.sh [--help] [impl|all]

Install an agentic-workflow implementation.

Implementations:
  claude-jira    Claude Code + Jira (Atlassian MCP)
  claude-notion  Claude Code + Notion MCP
  claude-gh      Claude Code + GitHub Projects (GitHub MCP)
  kiro-notion    Kiro CLI + Notion MCP
  kiro-gh        Kiro CLI + GitHub Projects (GitHub MCP)
  all            Install all five

With no argument, shows an interactive two-step menu (AI tool → board).

Examples:
  ./install.sh
  ./install.sh claude-gh
  ./install.sh all
EOF
  exit 0
}

install_impl() {
  local name="$1"
  echo ""
  echo "==> Installing $name..."
  bash "$SCRIPT_DIR/$name/install.sh"
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage
fi

TARGET="${1:-}"

if [[ -z "$TARGET" ]]; then
  echo "Which AI tool?"
  echo "  1) Claude Code"
  echo "  2) Kiro"
  read -rp "Choice [1-2]: " tool_choice

  case "$tool_choice" in
    1)
      echo ""
      echo "Which board/tracker?"
      echo "  1) Jira (Atlassian MCP)"
      echo "  2) Notion (Notion MCP)"
      echo "  3) GitHub Projects (GitHub MCP)"
      read -rp "Choice [1-3]: " board_choice
      case "$board_choice" in
        1) TARGET="claude-jira" ;;
        2) TARGET="claude-notion" ;;
        3) TARGET="claude-gh" ;;
        *) echo "Invalid choice: $board_choice" >&2; exit 1 ;;
      esac ;;
    2)
      echo ""
      echo "Which board/tracker?"
      echo "  1) Notion (Notion MCP)"
      echo "  2) GitHub Projects (GitHub MCP)"
      read -rp "Choice [1-2]: " board_choice
      case "$board_choice" in
        1) TARGET="kiro-notion" ;;
        2) TARGET="kiro-gh" ;;
        *) echo "Invalid choice: $board_choice" >&2; exit 1 ;;
      esac ;;
    *) echo "Invalid choice: $tool_choice" >&2; exit 1 ;;
  esac
fi

case "$TARGET" in
  claude-jira|claude-notion|claude-gh|kiro-notion|kiro-gh)
    install_impl "$TARGET" ;;
  all)
    install_impl claude-jira
    install_impl claude-notion
    install_impl claude-gh
    install_impl kiro-notion
    install_impl kiro-gh ;;
  *)
    echo "Unknown implementation: $TARGET" >&2
    usage ;;
esac
