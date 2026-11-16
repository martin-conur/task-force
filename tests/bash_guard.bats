#!/usr/bin/env bats
# `radio bash-guard` — the PreToolUse hook that refuses prose handed to
# `git commit -m`, `gh … --body` / `-b` or `radio send --body` inside a
# double-quoted string that holds a backtick (#400).
#
# #234 made that a rule in every prompt: inside `"…"` the shell
# command-substitutes each backticked token before the tool sees it, so a
# review quoting `pwd -P` posts the reviewer's working directory and an
# identifier naming no command posts as nothing at all. #400 turns the rule
# into a hook so the prompts can say it in one line. tests/prose_body_file.bats
# keeps the proof of why the shape is broken; this file pins the hook.
#
# Three layers: what the guard blocks and passes (the payload is the one both
# assistants send: `.tool_input.command`), that it fails open on everything it
# cannot read, and that every loadout installs it where task-remove can find it.

bats_require_minimum_version 1.5.0   # run --separate-stderr
bats_load_library bats-support
bats_load_library bats-assert

load helpers/common

setup() {
  setup_task_force_home
  unset ZELLIJ
  unset TASK_FORCE_ROLE            # not role-gated: a plain session is guarded too
}

teardown() {
  teardown_all
}

# Run the guard on <command> as claude's Bash tool would hand it over.
guard() {
  jq -n --arg c "$1" '{hook_event_name: "PreToolUse", tool_name: "Bash", tool_input: {command: $c}}' \
    | "$RADIO" bash-guard
}

# Every <command> in the arguments must be refused with exit 2.
assert_all_blocked() {
  local c bad=0
  for c in "$@"; do
    run --separate-stderr guard "$c"
    if [[ "$status" -ne 2 ]]; then
      echo "not blocked (status $status): $c"
      bad=1
    fi
  done
  [ "$bad" -eq 0 ]
}

# Every <command> in the arguments must pass, silently.
assert_all_pass() {
  local c bad=0
  for c in "$@"; do
    run --separate-stderr guard "$c"
    if [[ "$status" -ne 0 || -n "$stderr" ]]; then
      echo "blocked (status $status, stderr: $stderr): $c"
      bad=1
    fi
  done
  [ "$bad" -eq 0 ]
}

# ----- blocks ------------------------------------------------------------------

@test "blocks git commit -m with a backtick in the double-quoted message, every flag spelling" {
  assert_all_blocked \
    'git commit -m "fix `foo`"' \
    'git commit -am "fix `foo`"' \
    'git commit --message "fix `foo`"' \
    'git commit --message="fix `foo`"' \
    'git commit -m"fix `foo`"' \
    'git -C sub commit -m "fix `foo`"' \
    'git commit -m "subject" -m "body names `_helper()`"' \
    'cd sub && git commit -m "fix `foo`"' \
    $'# a comment with an apostrophe: don\'t\ngit commit -m "fix `foo`"' \
    $'cat <<\'EOF\'\nan apostrophe in a heredoc body: don\'t\nEOF\ngit commit -m "fix `foo`"' \
    'GIT_AUTHOR_NAME=x git commit -m "fix `foo`"'
}

@test "blocks gh --body / -b / --body= with a backtick in the double-quoted body" {
  assert_all_blocked \
    'gh pr comment 4 --body "see `pwd -P`"' \
    'gh pr comment 4 -b "see `pwd -P`"' \
    'gh issue edit 4 --body="see `x`"' \
    'gh issue create --title "t" --body "spec for `$WORKTREE_DIR`"'
}

@test "blocks radio send --body with a backtick in the double-quoted body" {
  assert_all_blocked \
    'radio send --to pm --intent review-requested --pr 4 --body "PR up: `x`"' \
    'radio send --to pm --intent x --body="`y`"'
}

@test "blocks a double-quoted message that spans lines, backtick on a later line" {
  assert_all_blocked $'git commit -m "subject\n\nbody names `_helper()`"'
}

@test "the refusal names the command and the fix, on stderr" {
  run --separate-stderr guard 'git commit -m "fix `foo`"'
  assert_equal "$status" 2
  assert_equal "$output" ""
  [[ "$stderr" == *'git commit -m'* ]] || fail "stderr: $stderr"
  [[ "$stderr" == *"git commit -F - <<'MSG'"* ]] || fail "stderr: $stderr"
  [[ "$stderr" == *'--body-file -'* ]] || fail "stderr: $stderr"
  [[ "$stderr" == *'radio send'*'stdin'* ]] || fail "stderr: $stderr"

  run --separate-stderr guard 'gh pr comment 4 --body "`x`"'
  [[ "$stderr" == *'blocked `gh … --body "…"`'* ]] || fail "stderr: $stderr"
  run --separate-stderr guard 'radio send --to pm --intent x --body "`x`"'
  [[ "$stderr" == *'blocked `radio send --body "…"`'* ]] || fail "stderr: $stderr"
}

@test "kiro's payload shape is read the same way (execute_bash, extra tool_input fields)" {
  # The payload kiro-cli 3.3.0 sent its preToolUse hook on a shell call (#400).
  local c='git commit -m "fix `foo`"'
  run --separate-stderr bash -c 'jq -n --arg c "$1" '\''{session_id: "s", hook_event_name: "PreToolUse", cwd: "/tmp", tool_name: "execute_bash", tool_input: {command: $c, description: "d", cwd: null, run_in_background: false, timeout: null}}'\'' | "$2" bash-guard' _ "$c" "$RADIO"
  assert_equal "$status" 2
}

# ----- passes ------------------------------------------------------------------

@test "passes the stdin forms: heredoc, --body-file -, -F -, radio send on stdin" {
  assert_all_pass \
    $'git commit -F - <<\'MSG\'\nfix `foo` in `_helper()`\nMSG' \
    $'gh pr comment 4 --body-file - <<\'REVIEW\'\nsee `pwd -P`; don\'t\nREVIEW' \
    $'radio send --to pm --intent review-requested --pr 4 <<\'BODY\'\nPR up: `x`\nBODY' \
    $'git commit -m "$(cat <<\'EOF\'\nfix `foo`\nEOF\n)"' \
    $'cat <<-\'EOF\' | git commit -F -\n\tfix `foo`\n\tEOF'
}

@test "a heredoc body that quotes the bad shape is not parsed as a command" {
  # A review discussing this very hook quotes the shape it refuses.
  assert_all_pass \
    $'gh pr comment 4 --body-file - <<\'REVIEW\'\nThe hook refuses git commit -m "fix `foo`" and gh pr comment --body "`x`".\nREVIEW\necho done' \
    $'git commit -F - <<\'MSG\'\nmention radio send --body "`y`"\nMSG' \
    $'gh pr comment 4 --body-file - <<\'REVIEW\'\ngit commit -m "fix `foo`"\nREVIEW'
}

@test "passes backtick-free double-quoted literals" {
  assert_all_pass \
    'git commit -m "plain message"' \
    'gh pr merge 4 --squash --body "merged"' \
    'radio send --to pm --intent approved-and-merged --pr 4 --body "merged"' \
    'gh pr comment 4 --body "LGTM, $HOME is fine"'
}

@test "passes backticks in places the shell leaves alone, and in commands it does not guard" {
  assert_all_pass \
    "git commit -m 'single-quoted \`foo\`'" \
    "git commit -m '\"\`foo\`\" in single quotes is how to write it'" \
    'git commit -m "escaped \`foo\`"' \
    '# git commit -m "`foo`" in a comment' \
    'grep -n "gh pr comment --body \"`x`\"" file' \
    'echo "`date`"' \
    'git log -m "x `y`"' \
    'git commit -m "plain" && echo "`date`"' \
    'gh pr view 4 --json body --jq ".body" | grep "`x`"'
}

# ----- fails open --------------------------------------------------------------

@test "fails open on a payload it cannot read: empty, not JSON, no command" {
  local p
  for p in '' 'not json' '{}' '{"tool_input":{}}' '{"tool_name":"Read","tool_input":{"file_path":"x"}}'; do
    run --separate-stderr bash -c 'printf "%s" "$1" | "$2" bash-guard' _ "$p" "$RADIO"
    assert_equal "$status" 0
    assert_equal "$stderr" ""
  done
}

@test "fails open without jq rather than blocking every shell call" {
  local nojq payload
  nojq=$(make_nojq_bin)
  payload=$(jq -n --arg c 'git commit -m "fix `foo`"' '{tool_input: {command: $c}}')
  run --separate-stderr env PATH="$nojq" bash -c 'printf "%s" "$1" | "$2" bash-guard' _ "$payload" "$RADIO"
  rm -rf "$nojq"
  assert_equal "$status" 0
}

@test "touches no radio state: no role needed, nothing created under TASK_FORCE_HOME" {
  local home="$BATS_TEST_TMPDIR/untouched"
  run --separate-stderr env TASK_FORCE_HOME="$home" bash -c \
    'jq -n --arg c "git commit -m \"plain\"" "{tool_input: {command: \$c}}" | "$1" bash-guard' _ "$RADIO"
  assert_equal "$status" 0
  assert [ ! -e "$home" ]
}

# ----- installed by every loadout, removed by task-remove ----------------------

@test "every claude loadout installs PreToolUse(Bash) -> radio bash-guard, once" {
  local lo args
  for lo in claude-gh claude-jira claude-notion claude-local; do
    setup_repo
    case "$lo" in
      claude-gh)   args=(--owner acme --repo widgets --project 7) ;;
      claude-jira) args=(--site https://acme.atlassian.net --key PROJ --board "My Board") ;;
      *)           args=() ;;
    esac
    (cd "$MAIN_REPO" && "$REPO_ROOT_REAL/$lo/bin/task-init" --force ${args[@]+"${args[@]}"} >/dev/null 2>&1)
    (cd "$MAIN_REPO" && "$REPO_ROOT_REAL/$lo/bin/task-init" --force ${args[@]+"${args[@]}"} >/dev/null 2>&1)
    run jq -r '[.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[].command] | join(",")' \
      "$MAIN_REPO/.claude/settings.json"
    assert_output "radio bash-guard"
    rm -rf "$MAIN_REPO"
  done
}

@test "every kiro loadout installs preToolUse(shell) -> radio bash-guard in each agent config" {
  local lo f args
  for lo in kiro-gh kiro-notion kiro-local; do
    setup_repo
    case "$lo" in
      kiro-gh) args=(--owner acme --repo widgets --project 7) ;;
      *)       args=() ;;
    esac
    (cd "$MAIN_REPO" && "$REPO_ROOT_REAL/$lo/bin/task-init" --force ${args[@]+"${args[@]}"} >/dev/null 2>&1)
    for f in "$MAIN_REPO"/.kiro/agents/*.json; do
      run jq -c '.hooks.preToolUse' "$f"
      assert_output '[{"matcher":"shell","command":"radio bash-guard"}]'
    done
    rm -rf "$MAIN_REPO"
  done
}

@test "the installed claude hook, run as Claude Code runs it, blocks the bad shape" {
  # End to end: read the command back out of settings.json and run it through a
  # shell with radio on PATH, so a typo in the installed string fails here.
  setup_repo
  (cd "$MAIN_REPO" && "$REPO_ROOT_REAL/claude-gh/bin/task-init" --force --owner acme --repo widgets --project 7 >/dev/null 2>&1)
  local hook payload
  hook=$(jq -r '.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[0].command' "$MAIN_REPO/.claude/settings.json")
  payload=$(jq -n --arg c 'gh pr comment 4 --body "see `pwd -P`"' '{tool_name: "Bash", tool_input: {command: $c}}')
  run --separate-stderr env PATH="$REPO_ROOT_REAL/bin:$PATH" bash -c 'printf "%s" "$1" | sh -c "$2"' _ "$payload" "$hook"
  assert_equal "$status" 2
  payload=$(jq -n --arg c 'gh pr comment 4 --body "merged"' '{tool_name: "Bash", tool_input: {command: $c}}')
  run --separate-stderr env PATH="$REPO_ROOT_REAL/bin:$PATH" bash -c 'printf "%s" "$1" | sh -c "$2"' _ "$payload" "$hook"
  assert_equal "$status" 0
}

@test "task-remove takes the guard out and leaves a user's own PreToolUse(Bash) hook" {
  setup_repo
  mkdir -p "$MAIN_REPO/.claude"
  cat > "$MAIN_REPO/.claude/settings.json" <<'JSON'
{ "hooks": { "PreToolUse": [ { "matcher": "Bash", "hooks": [ { "type": "command", "command": "./scripts/my-bash-lint.sh" } ] } ] } }
JSON
  (cd "$MAIN_REPO" && "$REPO_ROOT_REAL/claude-gh/bin/task-init" --force --owner acme --repo widgets --project 7 >/dev/null 2>&1)
  run jq -r '[.. | objects | select(has("command")) | .command] | map(select(. == "radio bash-guard")) | length' \
    "$MAIN_REPO/.claude/settings.json"
  assert_output "1"

  run bash -c 'cd "$1" && "$2" --yes' _ "$MAIN_REPO" "$REPO_ROOT_REAL/bin/task-remove"
  assert_success
  run jq -c '.hooks.PreToolUse' "$MAIN_REPO/.claude/settings.json"
  assert_output '[{"matcher":"Bash","hooks":[{"type":"command","command":"./scripts/my-bash-lint.sh"}]}]'
}
