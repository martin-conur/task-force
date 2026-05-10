#!/usr/bin/env bats
# Tests for install.sh: TUI selector (fzf/gum) and numbered menu fallback.

bats_load_library bats-support
bats_load_library bats-assert

load helpers/common

INSTALL_SH="$REPO_ROOT_REAL/install.sh"

setup() {
  STUB_BIN=$(mktemp -d)
  STUB_CALLS_DIR=$(mktemp -d)
  export STUB_BIN STUB_CALLS_DIR
  # Restrict PATH so system-installed fzf/gum don't interfere with fallback tests.
  export PATH="$STUB_BIN:/usr/bin:/bin"

  # Install fzf and gum stubs (both present by default; fallback tests remove them).
  for stub in fzf gum; do
    cp "$REPO_ROOT_REAL/tests/helpers/stubs/$stub" "$STUB_BIN/$stub"
    chmod +x "$STUB_BIN/$stub"
  done

  # Create mock sub-installers so install_impl doesn't try to run real scripts.
  MOCK_IMPL_DIR=$(mktemp -d)
  for impl in claude-gh claude-notion claude-jira kiro-gh kiro-notion; do
    mkdir -p "$MOCK_IMPL_DIR/$impl"
    printf '#!/usr/bin/env bash\necho "mock-installed %s"\n' "$impl" \
      > "$MOCK_IMPL_DIR/$impl/install.sh"
    chmod +x "$MOCK_IMPL_DIR/$impl/install.sh"
  done
  export INSTALL_SH_SCRIPT_DIR="$MOCK_IMPL_DIR"
}

teardown() {
  [[ -z "${MOCK_IMPL_DIR:-}" ]] || rm -rf "$MOCK_IMPL_DIR"
  [[ -z "${STUB_BIN:-}"       ]] || rm -rf "$STUB_BIN"
  [[ -z "${STUB_CALLS_DIR:-}" ]] || rm -rf "$STUB_CALLS_DIR"
}

# ---------------------------------------------------------------------------
# Non-interactive (direct arg)
# ---------------------------------------------------------------------------

@test "direct arg claude-gh installs claude-gh" {
  run "$INSTALL_SH" claude-gh
  assert_success
  assert_output --partial "Installing claude-gh"
}

@test "direct arg kiro-notion installs kiro-notion" {
  run "$INSTALL_SH" kiro-notion
  assert_success
  assert_output --partial "Installing kiro-notion"
}

@test "direct arg all installs all five implementations" {
  run "$INSTALL_SH" all
  assert_success
  assert_output --partial "Installing claude-jira"
  assert_output --partial "Installing claude-notion"
  assert_output --partial "Installing claude-gh"
  assert_output --partial "Installing kiro-notion"
  assert_output --partial "Installing kiro-gh"
}

@test "unknown implementation exits non-zero" {
  run "$INSTALL_SH" bogus
  assert_failure
}

# ---------------------------------------------------------------------------
# fzf TUI path (fzf present, gum present but not reached)
# ---------------------------------------------------------------------------

@test "fzf: selects Claude Code + GitHub Projects → claude-gh" {
  run env FZF_STUB_CHOICE="Claude Code + GitHub Projects" "$INSTALL_SH"
  assert_success
  assert_output --partial "Installing claude-gh"
}

@test "fzf: selects Claude Code + Notion → claude-notion" {
  run env FZF_STUB_CHOICE="Claude Code + Notion" "$INSTALL_SH"
  assert_success
  assert_output --partial "Installing claude-notion"
}

@test "fzf: selects Claude Code + Jira → claude-jira" {
  run env FZF_STUB_CHOICE="Claude Code + Jira" "$INSTALL_SH"
  assert_success
  assert_output --partial "Installing claude-jira"
}

@test "fzf: selects Kiro + GitHub Projects → kiro-gh" {
  run env FZF_STUB_CHOICE="Kiro + GitHub Projects" "$INSTALL_SH"
  assert_success
  assert_output --partial "Installing kiro-gh"
}

@test "fzf: selects Kiro + Notion → kiro-notion" {
  run env FZF_STUB_CHOICE="Kiro + Notion" "$INSTALL_SH"
  assert_success
  assert_output --partial "Installing kiro-notion"
}

@test "fzf: selects Install all → all five installed" {
  run env FZF_STUB_CHOICE="Install all" "$INSTALL_SH"
  assert_success
  assert_output --partial "Installing claude-jira"
  assert_output --partial "Installing kiro-gh"
}

# ---------------------------------------------------------------------------
# gum TUI path (gum present, fzf absent)
# ---------------------------------------------------------------------------

@test "gum: selects Claude Code + GitHub Projects → claude-gh" {
  rm -f "$STUB_BIN/fzf"
  run env GUM_STUB_CHOICE="Claude Code + GitHub Projects" "$INSTALL_SH"
  assert_success
  assert_output --partial "Installing claude-gh"
}

@test "gum: selects Claude Code + Notion → claude-notion" {
  rm -f "$STUB_BIN/fzf"
  run env GUM_STUB_CHOICE="Claude Code + Notion" "$INSTALL_SH"
  assert_success
  assert_output --partial "Installing claude-notion"
}

@test "gum: selects Kiro + Notion → kiro-notion" {
  rm -f "$STUB_BIN/fzf"
  run env GUM_STUB_CHOICE="Kiro + Notion" "$INSTALL_SH"
  assert_success
  assert_output --partial "Installing kiro-notion"
}

@test "gum: selects Install all → all five installed" {
  rm -f "$STUB_BIN/fzf"
  run env GUM_STUB_CHOICE="Install all" "$INSTALL_SH"
  assert_success
  assert_output --partial "Installing claude-jira"
  assert_output --partial "Installing kiro-gh"
}

# ---------------------------------------------------------------------------
# Fallback numbered menu (neither fzf nor gum present)
# ---------------------------------------------------------------------------

@test "fallback: Claude Code + Jira (1 then 1)" {
  rm -f "$STUB_BIN/fzf" "$STUB_BIN/gum"
  run bash -c "printf '1\n1\n' | \"$INSTALL_SH\""
  assert_success
  assert_output --partial "Installing claude-jira"
}

@test "fallback: Claude Code + Notion (1 then 2)" {
  rm -f "$STUB_BIN/fzf" "$STUB_BIN/gum"
  run bash -c "printf '1\n2\n' | \"$INSTALL_SH\""
  assert_success
  assert_output --partial "Installing claude-notion"
}

@test "fallback: Claude Code + GitHub Projects (1 then 3)" {
  rm -f "$STUB_BIN/fzf" "$STUB_BIN/gum"
  run bash -c "printf '1\n3\n' | \"$INSTALL_SH\""
  assert_success
  assert_output --partial "Installing claude-gh"
}

@test "fallback: Kiro + Notion (2 then 1)" {
  rm -f "$STUB_BIN/fzf" "$STUB_BIN/gum"
  run bash -c "printf '2\n1\n' | \"$INSTALL_SH\""
  assert_success
  assert_output --partial "Installing kiro-notion"
}

@test "fallback: Kiro + GitHub Projects (2 then 2)" {
  rm -f "$STUB_BIN/fzf" "$STUB_BIN/gum"
  run bash -c "printf '2\n2\n' | \"$INSTALL_SH\""
  assert_success
  assert_output --partial "Installing kiro-gh"
}

@test "fallback: invalid tool choice exits non-zero" {
  rm -f "$STUB_BIN/fzf" "$STUB_BIN/gum"
  run bash -c "echo 9 | \"$INSTALL_SH\""
  assert_failure
  assert_output --partial "Invalid choice"
}

@test "fallback: invalid board choice exits non-zero" {
  rm -f "$STUB_BIN/fzf" "$STUB_BIN/gum"
  run bash -c "printf '1\n9\n' | \"$INSTALL_SH\""
  assert_failure
  assert_output --partial "Invalid choice"
}
