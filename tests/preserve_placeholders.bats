#!/usr/bin/env bats
# Unit tests for lib/preserve-placeholders.sh

bats_load_library bats-support
bats_load_library bats-assert

load helpers/common

PRESERVE_LIB="$REPO_ROOT_REAL/lib/preserve-placeholders.sh"

setup() {
  TMP_DIR=$(mktemp -d)
  FILE="$TMP_DIR/workflow.md"
}

teardown() {
  [[ -n "${TMP_DIR:-}" && -d "$TMP_DIR" ]] && rm -rf "$TMP_DIR"
}

# ---------------------------------------------------------------------------
# Generic extractor
# ---------------------------------------------------------------------------

@test "extracts filled value from existing file" {
  cat >"$FILE" <<'EOF'
- **Owner**: `martin-conur` (GitHub user or org name)
EOF
  run bash -c "source '$PRESERVE_LIB'; extract_existing_value '$FILE' '^- \\*\\*Owner\\*\\*: \`([^\`]+)\`.*' '{OWNER}'"
  assert_success
  assert_output "martin-conur"
}

@test "returns empty when placeholder is still raw" {
  cat >"$FILE" <<'EOF'
- **Owner**: `{OWNER}` (GitHub user or org name)
EOF
  run bash -c "source '$PRESERVE_LIB'; extract_existing_value '$FILE' '^- \\*\\*Owner\\*\\*: \`([^\`]+)\`.*' '{OWNER}'"
  assert_success
  assert_output ""
}

@test "returns empty when file does not exist" {
  run bash -c "source '$PRESERVE_LIB'; extract_existing_value '$TMP_DIR/nope.md' '.*' '{OWNER}'"
  assert_success
  assert_output ""
}

@test "returns empty when pattern matches nothing" {
  cat >"$FILE" <<'EOF'
unrelated content
EOF
  run bash -c "source '$PRESERVE_LIB'; extract_existing_value '$FILE' '^- \\*\\*Owner\\*\\*: \`([^\`]+)\`.*' '{OWNER}'"
  assert_success
  assert_output ""
}

@test "takes the first match when several lines match" {
  cat >"$FILE" <<'EOF'
- **Owner**: `first-owner` (...)
- **Owner**: `second-owner` (duplicate)
EOF
  run bash -c "source '$PRESERVE_LIB'; extract_existing_value '$FILE' '^- \\*\\*Owner\\*\\*: \`([^\`]+)\`.*' '{OWNER}'"
  assert_success
  assert_output "first-owner"
}

# ---------------------------------------------------------------------------
# Real-world placeholder shapes
# ---------------------------------------------------------------------------

@test "extracts {REPO} placeholder shape" {
  cat >"$FILE" <<'EOF'
- **Owner**: `martin-conur` (GitHub user or org name)
- **Repo**: `task-force` (repository name)
EOF
  run bash -c "source '$PRESERVE_LIB'; extract_existing_value '$FILE' '^- \\*\\*Repo\\*\\*: \`([^\`]+)\`.*' '{REPO}'"
  assert_success
  assert_output "task-force"
}

@test "extracts {PROJECT} placeholder shape" {
  cat >"$FILE" <<'EOF'
- **Project number**: `7` (from the project URL: ...)
EOF
  run bash -c "source '$PRESERVE_LIB'; extract_existing_value '$FILE' '^- \\*\\*Project number\\*\\*: \`([^\`]+)\`.*' '{PROJECT}'"
  assert_success
  assert_output "7"
}

@test "extracts Jira {SITE} placeholder shape" {
  cat >"$FILE" <<'EOF'
- **Site**: `https://acme.atlassian.net`
EOF
  run bash -c "source '$PRESERVE_LIB'; extract_existing_value '$FILE' '^- \\*\\*Site\\*\\*: \`([^\`]+)\`.*' '{SITE}'"
  assert_success
  assert_output "https://acme.atlassian.net"
}
