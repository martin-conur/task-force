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

# ---------------------------------------------------------------------------
# Prompt regions (#320): markdown comment sentinels and kiro agent JSON
# ---------------------------------------------------------------------------

# A markdown prompt and a kiro agent config carrying the same region.
make_prompt_pair() {
  local md="$1" json="$2" json_line="${3:-shared line}"
  printf '%s\n' intro '<!-- region:shared -->' 'shared line' '<!-- endregion:shared -->' outro >"$md"
  jq -n --arg l "$json_line" \
    '{name: "reviewer", prompt: ("kiro intro\n<!-- region:shared -->\n" + $l + "\n<!-- endregion:shared -->\nkiro outro")}' >"$json"
}

@test "check-drift reads a kiro agent's decoded prompt and the HTML-comment sentinel form" {
  make_prompt_pair "$TMP_DIR/reviewer.md" "$TMP_DIR/reviewer.json"
  echo "demo|shared|$TMP_DIR/reviewer.md $TMP_DIR/reviewer.json" >"$TMP_DIR/manifest"
  CHECK_DRIFT_MANIFEST="$TMP_DIR/manifest" run bash "$CHECK_DRIFT"
  assert_success
  assert_output --partial "1 group(s) checked"
}

@test "check-drift catches a drifted region inside a kiro agent's prompt" {
  make_prompt_pair "$TMP_DIR/reviewer.md" "$TMP_DIR/reviewer.json" "DRIFTED line"
  echo "demo|shared|$TMP_DIR/reviewer.md $TMP_DIR/reviewer.json" >"$TMP_DIR/manifest"
  CHECK_DRIFT_MANIFEST="$TMP_DIR/manifest" run bash "$CHECK_DRIFT"
  assert_failure
  assert_output --partial "DRIFT [demo/shared]"
  assert_output --partial "DRIFTED line"
}

@test "check-drift reports a kiro agent prompt without the region as missing" {
  make_prompt_pair "$TMP_DIR/reviewer.md" "$TMP_DIR/reviewer.json"
  jq -n '{name: "reviewer", prompt: "no region here"}' >"$TMP_DIR/reviewer.json"
  echo "demo|shared|$TMP_DIR/reviewer.md $TMP_DIR/reviewer.json" >"$TMP_DIR/manifest"
  CHECK_DRIFT_MANIFEST="$TMP_DIR/manifest" run bash "$CHECK_DRIFT"
  assert_failure
  assert_output --partial "region missing in: $TMP_DIR/reviewer.json"
}

@test "the reviewer contract is drift-guarded across all 8 reviewer prompts (#320)" {
  # Post on stdin, radio the verdict, self-destruct, hold the tab open only
  # when the verdict never reached PM: one copy, in every claude and kiro
  # reviewer. kiro's reviewer once idled with the tab open while claude's
  # self-destructed, because nothing tied the two together.
  local rel=(.claude/commands/reviewer.md claude-gh/commands/reviewer.md
    claude-jira/commands/reviewer.md claude-local/commands/reviewer.md
    claude-notion/commands/reviewer.md kiro-gh/agents/reviewer.json
    kiro-local/agents/reviewer.json kiro-notion/agents/reviewer.json)
  local f real="" broken=""
  for f in "${rel[@]}"; do
    real+=" $REPO_ROOT_REAL/$f"
    if [[ "$f" == kiro-local/* ]]; then broken+=" $TMP_DIR/$f"; else broken+=" $REPO_ROOT_REAL/$f"; fi
  done
  # Both regions are in the default manifest, over exactly these files.
  local listed="${real//$REPO_ROOT_REAL\//}"; listed="${listed# }"
  run grep -cF "\"reviewer-contract|reviewer-post-radio-destruct|$listed\"" "$CHECK_DRIFT"
  assert_output 1
  run grep -cF "\"reviewer-contract|reviewer-destruct-summary|$listed\"" "$CHECK_DRIFT"
  assert_output 1
  # The real copies agree.
  printf 'reviewer-contract|%s|%s\n' reviewer-post-radio-destruct "$real" reviewer-destruct-summary "$real" >"$TMP_DIR/manifest"
  CHECK_DRIFT_MANIFEST="$TMP_DIR/manifest" run bash "$CHECK_DRIFT"
  assert_success
  assert_output --partial "2 group(s) checked"
  # Break one kiro copy's region and watch the group go red.
  mkdir -p "$TMP_DIR/kiro-local/agents"
  jq '.prompt |= sub("Otherwise, destruct\\."; "Otherwise, idle.")' \
    "$REPO_ROOT_REAL/kiro-local/agents/reviewer.json" >"$TMP_DIR/kiro-local/agents/reviewer.json"
  run diff -q "$REPO_ROOT_REAL/kiro-local/agents/reviewer.json" "$TMP_DIR/kiro-local/agents/reviewer.json"
  assert_failure
  echo "reviewer-contract|reviewer-post-radio-destruct|$broken" >"$TMP_DIR/manifest"
  CHECK_DRIFT_MANIFEST="$TMP_DIR/manifest" run bash "$CHECK_DRIFT"
  assert_failure
  assert_output --partial "DRIFT [reviewer-contract/reviewer-post-radio-destruct]"
  assert_output --partial "Otherwise, idle."
}
