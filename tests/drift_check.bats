#!/usr/bin/env bats
# Tests for tools/check-drift.sh.
#
# Verifies the drift checker passes on a synthetic repo whose regions match,
# and fails (with a readable diff) when one file diverges. Also runs the real
# manifest against the live repo as a regression guard.

bats_load_library bats-support
bats_load_library bats-assert

load helpers/common

CHECK_DRIFT="$REPO_ROOT_REAL/tools/check-drift.sh"

setup() {
  TMP_DIR=$(mktemp -d)
  export TMP_DIR
}

teardown() {
  [[ -n "${TMP_DIR:-}" && -d "$TMP_DIR" ]] && rm -rf "$TMP_DIR"
}

# Build a pair of stub scripts with identical sentinel regions.
make_pair() {
  local a="$1" b="$2" extra_in_b="${3-}"
  cat >"$a" <<'EOF'
#!/usr/bin/env bash
# region:shared
echo "hello"
echo "world"
# endregion:shared
EOF
  if [[ -n "$extra_in_b" ]]; then
    cat >"$b" <<EOF
#!/usr/bin/env bash
# region:shared
echo "hello"
echo "$extra_in_b"
# endregion:shared
EOF
  else
    cp "$a" "$b"
  fi
}

@test "check-drift passes when sentinel regions match" {
  make_pair "$TMP_DIR/a.sh" "$TMP_DIR/b.sh"
  cat >"$TMP_DIR/manifest" <<EOF
demo|shared|$TMP_DIR/a.sh $TMP_DIR/b.sh
EOF
  CHECK_DRIFT_MANIFEST="$TMP_DIR/manifest" run bash "$CHECK_DRIFT"
  assert_success
  assert_output --partial "1 group(s) checked"
}

@test "check-drift fails with a diff when a region diverges" {
  make_pair "$TMP_DIR/a.sh" "$TMP_DIR/b.sh" "DRIFTED"
  cat >"$TMP_DIR/manifest" <<EOF
demo|shared|$TMP_DIR/a.sh $TMP_DIR/b.sh
EOF
  CHECK_DRIFT_MANIFEST="$TMP_DIR/manifest" run bash "$CHECK_DRIFT"
  assert_failure
  assert_output --partial "DRIFT [demo/shared]"
  assert_output --partial "a.sh"
  assert_output --partial "b.sh"
}

@test "check-drift fails when a file is missing the region entirely" {
  cat >"$TMP_DIR/a.sh" <<'EOF'
#!/usr/bin/env bash
# region:shared
echo "hello"
# endregion:shared
EOF
  cat >"$TMP_DIR/b.sh" <<'EOF'
#!/usr/bin/env bash
echo "no region here"
EOF
  cat >"$TMP_DIR/manifest" <<EOF
demo|shared|$TMP_DIR/a.sh $TMP_DIR/b.sh
EOF
  CHECK_DRIFT_MANIFEST="$TMP_DIR/manifest" run bash "$CHECK_DRIFT"
  assert_failure
  assert_output --partial "region missing in"
  assert_output --partial "b.sh"
}

@test "check-drift fails (with a distinct message) when sentinels bracket an empty body" {
  cat >"$TMP_DIR/a.sh" <<'EOF'
#!/usr/bin/env bash
# region:shared
echo "hello"
# endregion:shared
EOF
  cat >"$TMP_DIR/b.sh" <<'EOF'
#!/usr/bin/env bash
# region:shared
# endregion:shared
EOF
  cat >"$TMP_DIR/manifest" <<EOF
demo|shared|$TMP_DIR/a.sh $TMP_DIR/b.sh
EOF
  CHECK_DRIFT_MANIFEST="$TMP_DIR/manifest" run bash "$CHECK_DRIFT"
  assert_failure
  assert_output --partial "region empty in"
  assert_output --partial "b.sh"
  # And it shouldn't be mislabelled as missing.
  refute_output --partial "region missing in: $TMP_DIR/b.sh"
}

@test "check-drift fails when a manifest file does not exist" {
  cat >"$TMP_DIR/manifest" <<EOF
demo|shared|$TMP_DIR/missing.sh $TMP_DIR/also-missing.sh
EOF
  CHECK_DRIFT_MANIFEST="$TMP_DIR/manifest" run bash "$CHECK_DRIFT"
  assert_failure
  assert_output --partial "missing file"
}

@test "check-drift default manifest passes on the live repo" {
  cd "$REPO_ROOT_REAL"
  run bash "$CHECK_DRIFT"
  assert_success
  assert_output --partial "group(s) checked"
}

@test "claude reviewer.md prompts use the right tracker-specific spec-lookup tool (#144)" {
  # Per #144, the 4 reviewer.md files are NO LONGER byte-identical — each
  # loadout's spec-lookup step legitimately differs (gh issue view vs. Jira
  # MCP vs. Notion MCP vs. local file Read). Replace the byte-identical
  # assertion (introduced in #138 by accident — the prompts were never
  # drift-grouped in the check-drift manifest) with per-loadout content
  # assertions: each prompt must reference its tracker's spec-lookup tool.
  run grep -q "gh issue view" "$REPO_ROOT_REAL/claude-gh/commands/reviewer.md"
  assert_success
  run grep -q "mcp__atlassian__getJiraIssue" "$REPO_ROOT_REAL/claude-jira/commands/reviewer.md"
  assert_success
  run grep -q "mcp__notion__notion-fetch" "$REPO_ROOT_REAL/claude-notion/commands/reviewer.md"
  assert_success
  run grep -q "tasks/" "$REPO_ROOT_REAL/claude-local/commands/reviewer.md"
  assert_success
}

@test "claude reviewer.md prompts share the same authority-boundaries spine (#144)" {
  # Shared invariant across all 4 loadouts: the authority boundaries block
  # (no merge, no push, no Status edits, etc.) and the radio handoff intents
  # must stay consistent. Drift here would be a real bug.
  for f in \
      "$REPO_ROOT_REAL/claude-gh/commands/reviewer.md" \
      "$REPO_ROOT_REAL/claude-jira/commands/reviewer.md" \
      "$REPO_ROOT_REAL/claude-notion/commands/reviewer.md" \
      "$REPO_ROOT_REAL/claude-local/commands/reviewer.md"; do
    run grep -q "### Authority boundaries" "$f"
    assert_success
    run grep -q "Merge PRs" "$f"
    assert_success
    run grep -q "review-complete-clean" "$f"
    assert_success
    run grep -q "review-complete-with-findings" "$f"
    assert_success
  done
}
