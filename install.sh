#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

usage() {
  cat <<'EOF'
Usage: ./install.sh [--help] [impl]

Install one or all agentic-workflow implementations.

Arguments:
  claude-jira    Claude Code + Jira (Atlassian MCP)
  kiro-notion    Kiro CLI + Notion MCP
  claude-notion  Claude Code + Notion MCP
  all            Install all three

With no argument, shows an interactive menu.

Examples:
  ./install.sh
  ./install.sh claude-notion
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
  echo "Which implementation would you like to install?"
  echo "  1) claude-jira"
  echo "  2) kiro-notion"
  echo "  3) claude-notion"
  echo "  4) all"
  read -rp "Choice [1-4]: " choice
  case "$choice" in
    1) TARGET="claude-jira" ;;
    2) TARGET="kiro-notion" ;;
    3) TARGET="claude-notion" ;;
    4) TARGET="all" ;;
    *) echo "Invalid choice: $choice" >&2; exit 1 ;;
  esac
fi

case "$TARGET" in
  claude-jira|kiro-notion|claude-notion)
    install_impl "$TARGET" ;;
  all)
    install_impl claude-jira
    install_impl kiro-notion
    install_impl claude-notion ;;
  *)
    echo "Unknown implementation: $TARGET" >&2
    usage ;;
esac
