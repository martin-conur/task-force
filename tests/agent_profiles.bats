#!/usr/bin/env bats
# Agent profiles (#355): `--profile <name>` on task-work, task-reviewer,
# task-recreate-worker and task-pm, read from $TASK_FORCE_HOME/profiles.toml.
#
# What the #354 spike (docs/agent-profiles-spike.md) says a profile must get
# right is what these pin: the key goes in ANTHROPIC_API_KEY as a reference the
# tab expands, never as a value on the launch line or in a file; every tier is
# pinned to the model unless the profile says otherwise; ANTHROPIC_MODEL rides
# along with --model, so the profile's model beats the reviewer's Sonnet
# default. And each refusal fires before anything is created.

bats_load_library bats-support
bats_load_library bats-assert

load helpers/common

# `run !`, for the tab's `${VAR:?}` abort (exit 127 on some bashes).
bats_require_minimum_version 1.5.0

RADIO="$REPO_ROOT_REAL/bin/radio"
SENTINEL="sk-sentinel-355-do-not-write"

setup() {
  setup_repo
  setup_kiro_agents
  setup_stubs
  setup_task_force_home
  cd "$MAIN_REPO"
  export GH_STUB_PR_URL="https://github.com/owner/repo/pull/42"
  export FIREWORKS_API_KEY="$SENTINEL"
  NAME=$(basename "$MAIN_REPO" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]//g')
  unset TASK_FORCE_ROLE TASK_FORCE_PROFILE ANTHROPIC_MODEL
  cat > "$TASK_FORCE_HOME/profiles.toml" <<'TOML'
# The spike's worked example.
[profiles.fireworks-glm]
agent   = "claude"
model   = "glm-latest"
env     = { ANTHROPIC_BASE_URL = "https://api.fireworks.ai/inference", ENABLE_TOOL_SEARCH = "true" }
key_env = { ANTHROPIC_API_KEY = "FIREWORKS_API_KEY" }

[profiles.pinned]
agent = "claude"
model = "main model"
max_context_tokens = 131_072
pin   = { haiku = "small", subagent = "sub" }

[profiles.pinned.env]
WEIRD = 'a $HOME `pwd` "q" b'

[profiles.kiro-one]
agent = "kiro"
TOML
}

teardown() {
  teardown_all
}

# The variables the claude stub started with, as NAME=value lines.
agent_env() { cat "$STUB_CALLS_DIR/claude.profile-env"; }

# Re-run the tab's payload as the new tab would.
run_tab() { bash -c "$(cat "$STUB_CALLS_DIR/zellij.new-tab-cmd")"; }

# The post-reboot state task-recreate-worker recovers, with extra sidecar lines.
dead_worker() {
  mkdir -p "$WORKTREE_BASE"
  git -C "$MAIN_REPO" worktree add -q "$WORKTREE_BASE/issue-42" -b task/issue-42
  seed_hook_carriers "$WORKTREE_BASE/issue-42"
  { printf 'BASE_BRANCH=main\nSLUG=issue-42\nGH_URL=https://github.com/owner/repo/issues/42\nTAB_ID=999\n'
    local l; for l in "$@"; do printf '%s\n' "$l"; done; } > "$WORKTREE_BASE/.issue-42.info"
}

assert_no_worktree() {
  run git -C "$MAIN_REPO" worktree list
  assert_equal "$(wc -l <<<"$output" | tr -d ' ')" 1
  [[ ! -f "$STUB_CALLS_DIR/zellij.new-tab-cmd" ]]
}

# ----- the prefix -------------------------------------------------------------

@test "prefix: env as given, the key as a reference, every tier pinned to the model, --model" {
  AW_IMPL=claude-gh run "$TASK_WORK" "https://github.com/owner/repo/issues/42" --profile fireworks-glm
  assert_success
  local cmd; cmd=$(cat "$STUB_CALLS_DIR/zellij.new-tab-cmd")
  # The reference, unexpanded, and never the value.
  assert_equal "$(grep -c 'ANTHROPIC_API_KEY="${FIREWORKS_API_KEY:?' <<<"$cmd")" 1
  [[ "$cmd" != *"$SENTINEL"* ]]
  [[ "$cmd" == *"claude --model glm-latest --permission-mode"* || "$cmd" == *"claude --model glm-latest \"/worker"* ]]
  run_tab
  run agent_env
  assert_line "TASK_FORCE_PROFILE=fireworks-glm"
  assert_line "ANTHROPIC_BASE_URL=https://api.fireworks.ai/inference"
  assert_line "ENABLE_TOOL_SEARCH=true"
  assert_line "ANTHROPIC_API_KEY=$SENTINEL"
  assert_line "ANTHROPIC_AUTH_TOKEN=<unset>"
  assert_line "ANTHROPIC_MODEL=glm-latest"
  assert_line "ANTHROPIC_DEFAULT_SONNET_MODEL=glm-latest"
  assert_line "ANTHROPIC_DEFAULT_HAIKU_MODEL=glm-latest"
  assert_line "ANTHROPIC_DEFAULT_OPUS_MODEL=glm-latest"
  assert_line "CLAUDE_CODE_SUBAGENT_MODEL=glm-latest"
  assert_line "CLAUDE_CODE_MAX_CONTEXT_TOKENS=<unset>"
  run tail -1 "$STUB_CALLS_DIR/claude.calls"
  assert_output --partial "claude --model glm-latest"
}

@test "prefix: values survive the tab's re-parse whole, pins override the model, max_context_tokens" {
  AW_IMPL=claude-gh run "$TASK_WORK" "https://github.com/owner/repo/issues/42" --profile pinned
  assert_success
  run_tab
  run agent_env
  assert_line "ANTHROPIC_MODEL=main model"
  assert_line "ANTHROPIC_DEFAULT_SONNET_MODEL=main model"
  assert_line "ANTHROPIC_DEFAULT_OPUS_MODEL=main model"
  assert_line "ANTHROPIC_DEFAULT_HAIKU_MODEL=small"
  assert_line "CLAUDE_CODE_SUBAGENT_MODEL=sub"
  assert_line "CLAUDE_CODE_MAX_CONTEXT_TOKENS=131072"
  assert_line "ANTHROPIC_API_KEY=<unset>"
  # --model is %q-quoted too: the stub sees one argument.
  run tail -1 "$STUB_CALLS_DIR/claude.calls"
  assert_output --partial "claude --model main model"
  run bash -c "source '$REPO_ROOT_REAL/lib/profile.sh'; aw_profile_load pinned claude && eval \"\$(aw_profile_env_prefix) env\""
  assert_success
  assert_line 'WEIRD=a $HOME `pwd` "q" b'
}

@test "no --profile: the launch line and the sidecar are as before" {
  AW_IMPL=claude-gh run "$TASK_WORK" "https://github.com/owner/repo/issues/42"
  assert_success
  run grep -E 'TASK_FORCE_PROFILE|ANTHROPIC|--model' "$STUB_CALLS_DIR/zellij.new-tab-cmd"
  assert_failure
  run grep '^PROFILE=' "$WORKTREE_BASE/.issue-42.info"
  assert_failure
}

@test "the tab refuses to start the agent when its rc does not export the key's variable" {
  AW_IMPL=claude-gh run "$TASK_WORK" "https://github.com/owner/repo/issues/42" --profile fireworks-glm
  assert_success
  run ! env -u FIREWORKS_API_KEY bash -c "$(cat "$STUB_CALLS_DIR/zellij.new-tab-cmd")"
  assert_output --partial "FIREWORKS_API_KEY: is unset in this tab"
  [[ ! -f "$STUB_CALLS_DIR/claude.calls" ]]
}

# ----- never written ------------------------------------------------------------

@test "the key's value is in no written file: sidecars, session file, log, launch argv" {
  export STUB_ZELLIJ_NEW_TAB_RUN=1 STUB_CLAUDE_RADIO="$RADIO"
  AW_IMPL=claude-gh run "$TASK_WORK" "https://github.com/owner/repo/issues/42" --profile fireworks-glm
  assert_success
  local role="worker-$NAME-issue-42"
  # The agent really ran with the key, and really registered.
  run grep -Fx "ANTHROPIC_API_KEY=$SENTINEL" "$STUB_CALLS_DIR/claude.profile-env"
  assert_success
  [[ -f "$TASK_FORCE_HOME/radio/sessions/$role.info" ]]
  # The name is recorded everywhere the spec says...
  run grep -Fx "PROFILE=fireworks-glm" "$WORKTREE_BASE/.issue-42.info"
  assert_success
  run grep -Fx "PROFILE=fireworks-glm" "$TASK_FORCE_HOME/radio/sessions/$role.info"
  assert_success
  run cat "$TASK_FORCE_HOME/radio/sessions/$role.profile"
  assert_output fireworks-glm
  [[ -s "$TASK_FORCE_HOME/radio/log" ]]
  # ...and the value nowhere: radio's whole home (sessions, sidecars, log,
  # mailboxes, the queue), task-work's sidecars, and zellij's argv.
  run grep -rlF "$SENTINEL" "$TASK_FORCE_HOME" "$WORKTREE_BASE"/.*.info \
    "$STUB_CALLS_DIR/zellij.calls" "$STUB_CALLS_DIR/zellij.new-tab-cmd"
  assert_failure
  assert_output ""
}

# ----- refusals -----------------------------------------------------------------

@test "refuses an unknown profile, naming the ones there are" {
  AW_IMPL=claude-gh run "$TASK_WORK" "https://github.com/owner/repo/issues/42" --profile nope
  assert_failure
  assert_output --partial "profile 'nope': no such profile"
  assert_output --partial "fireworks-glm, pinned, kiro-one"
  assert_no_worktree
}

@test "refuses a profile whose agent is not the one being launched" {
  AW_IMPL=kiro-gh run "$TASK_WORK" "https://github.com/owner/repo/issues/42" --profile fireworks-glm
  assert_failure
  assert_output --partial "it is a claude profile, and this launch is on kiro"
  assert_output --partial "--agent claude"
  assert_no_worktree
  AW_IMPL=claude-gh run "$TASK_WORK" "https://github.com/owner/repo/issues/42" --profile kiro-one
  assert_failure
  assert_output --partial "it is a kiro profile, and this launch is on claude"
}

@test "refuses a key_env source that is unset or empty" {
  unset FIREWORKS_API_KEY
  AW_IMPL=claude-gh run "$TASK_WORK" "https://github.com/owner/repo/issues/42" --profile fireworks-glm
  assert_failure
  assert_output --partial '$FIREWORKS_API_KEY, which key_env reads ANTHROPIC_API_KEY from, is unset or empty'
  assert_no_worktree
  FIREWORKS_API_KEY="" AW_IMPL=claude-gh run "$TASK_WORK" "https://github.com/owner/repo/issues/42" --profile fireworks-glm
  assert_failure
  assert_output --partial "is unset or empty"
}

@test "refuses a profile file that does not parse, naming the line" {
  printf '[profiles.bad]\nagent = "claude"\nmodel = "unterminated\n' > "$TASK_FORCE_HOME/profiles.toml"
  AW_IMPL=claude-gh run "$TASK_WORK" "https://github.com/owner/repo/issues/42" --profile bad
  assert_failure
  assert_output --partial "profiles.toml does not parse: line 3: unterminated string"
  assert_no_worktree
  printf '[profiles.bad]\nagent = "claude"\nenv = { A = "x",\n  B = "y" }\n' > "$TASK_FORCE_HOME/profiles.toml"
  AW_IMPL=claude-gh run "$TASK_WORK" "https://github.com/owner/repo/issues/42" --profile bad
  assert_failure
  assert_output --partial "does not parse: line 3"
  rm "$TASK_FORCE_HOME/profiles.toml"
  AW_IMPL=claude-gh run "$TASK_WORK" "https://github.com/owner/repo/issues/42" --profile bad
  assert_failure
  assert_output --partial "no profile file at $TASK_FORCE_HOME/profiles.toml"
}

@test "refuses ANTHROPIC_AUTH_TOKEN as a key_env target, pointing at the spike" {
  printf '[profiles.tok]\nagent = "claude"\nkey_env = { ANTHROPIC_AUTH_TOKEN = "FIREWORKS_API_KEY" }\n' \
    > "$TASK_FORCE_HOME/profiles.toml"
  AW_IMPL=claude-gh run "$TASK_WORK" "https://github.com/owner/repo/issues/42" --profile tok
  assert_failure
  assert_output --partial "key_env may not set ANTHROPIC_AUTH_TOKEN"
  assert_output --partial "agent-profiles-spike.md, section 6"
  assert_no_worktree
}

@test "refuses a credential in env, an unknown field and an unknown pin" {
  printf '[profiles.p]\nagent = "claude"\nenv = { ANTHROPIC_API_KEY = "literal" }\n' > "$TASK_FORCE_HOME/profiles.toml"
  AW_IMPL=claude-gh run "$TASK_WORK" "https://github.com/owner/repo/issues/42" --profile p
  assert_failure
  assert_output --partial "ANTHROPIC_API_KEY is in env"
  printf '[profiles.p]\nagent = "claude"\nkey-env = { ANTHROPIC_API_KEY = "X" }\n' > "$TASK_FORCE_HOME/profiles.toml"
  AW_IMPL=claude-gh run "$TASK_WORK" "https://github.com/owner/repo/issues/42" --profile p
  assert_failure
  assert_output --partial "unknown field 'key-env'"
  printf '[profiles.p]\nagent = "claude"\npin = { sonet = "x" }\n' > "$TASK_FORCE_HOME/profiles.toml"
  AW_IMPL=claude-gh run "$TASK_WORK" "https://github.com/owner/repo/issues/42" --profile p
  assert_failure
  assert_output --partial "unknown pin 'sonet'"
  assert_no_worktree
}

# ----- task-reviewer --------------------------------------------------------------

@test "task-reviewer: the profile's model wins over the Sonnet default and ANTHROPIC_MODEL" {
  ANTHROPIC_MODEL=claude-opus-5-5 AW_IMPL=claude-gh run "$TASK_REVIEWER" 42 --profile fireworks-glm
  assert_success
  assert_output --partial "model: glm-latest"
  run grep -E 'claude-sonnet|claude-opus' "$STUB_CALLS_DIR/zellij.new-tab-cmd"
  assert_failure
  run_tab
  run agent_env
  assert_line "ANTHROPIC_MODEL=glm-latest"
  assert_line "ANTHROPIC_DEFAULT_SONNET_MODEL=glm-latest"
  assert_line "ANTHROPIC_API_KEY=$SENTINEL"
  assert_line "TASK_FORCE_PROFILE=fireworks-glm"
  run tail -1 "$STUB_CALLS_DIR/claude.calls"
  assert_output --partial "claude --model glm-latest --permission-mode auto /reviewer"
  run grep -Fx "PROFILE=fireworks-glm" "$WORKTREE_BASE/.review-pr42.info"
  assert_success
}

@test "task-reviewer from a profiled PM does not inherit the profile's model" {
  TASK_FORCE_PROFILE=fireworks-glm ANTHROPIC_MODEL=glm-latest AW_IMPL=claude-gh run "$TASK_REVIEWER" 42
  assert_success
  assert_output --partial "not inheriting ANTHROPIC_MODEL from profile 'fireworks-glm'"
  assert_output --partial "model: claude-sonnet-5-5"
  run grep -F "ANTHROPIC_MODEL=claude-sonnet-5-5" "$STUB_CALLS_DIR/zellij.new-tab-cmd"
  assert_success
  run grep -E 'glm-latest|TASK_FORCE_PROFILE' "$STUB_CALLS_DIR/zellij.new-tab-cmd"
  assert_failure
}

@test "task-reviewer: a refusal leaves no review worktree behind" {
  AW_IMPL=claude-gh run "$TASK_REVIEWER" 42 --profile nope
  assert_failure
  assert_output --partial "no such profile"
  [[ ! -d "$WORKTREE_BASE/review-pr42" ]]
}

# ----- task-recreate-worker --------------------------------------------------------

@test "task-recreate-worker relaunches on the recorded profile" {
  dead_worker PROFILE=fireworks-glm
  AW_IMPL=claude-gh run "$TASK_RECREATE_WORKER" issue-42
  assert_success
  assert_output --partial "Relaunching on profile 'fireworks-glm'"
  assert_output --partial "profile:   fireworks-glm"
  run_tab
  run agent_env
  assert_line "TASK_FORCE_PROFILE=fireworks-glm"
  assert_line "ANTHROPIC_API_KEY=$SENTINEL"
  run tail -1 "$STUB_CALLS_DIR/claude.calls"
  assert_output --partial "claude --model glm-latest"
  # Still recorded, once.
  assert_equal "$(grep -c '^PROFILE=' "$WORKTREE_BASE/.issue-42.info")" 1
  run grep -Fx "PROFILE=fireworks-glm" "$WORKTREE_BASE/.issue-42.info"
  assert_success
}

@test "task-recreate-worker --profile replaces the recorded one, --no-profile drops it" {
  dead_worker PROFILE=fireworks-glm
  AW_IMPL=claude-gh run "$TASK_RECREATE_WORKER" issue-42 --profile pinned
  assert_success
  run grep '^PROFILE=' "$WORKTREE_BASE/.issue-42.info"
  assert_output "PROFILE=pinned"
  run_tab
  run agent_env
  assert_line "TASK_FORCE_PROFILE=pinned"

  AW_IMPL=claude-gh TASK_RECREATE_WORKER_REGISTER_WAIT=0 run "$TASK_RECREATE_WORKER" issue-42 --no-profile --force
  assert_success
  run grep '^PROFILE=' "$WORKTREE_BASE/.issue-42.info"
  assert_failure
  run grep -E 'TASK_FORCE_PROFILE|--model' "$STUB_CALLS_DIR/zellij.new-tab-cmd"
  assert_failure
}

@test "task-recreate-worker refuses when the recorded profile no longer resolves" {
  dead_worker PROFILE=gone
  AW_IMPL=claude-gh run "$TASK_RECREATE_WORKER" issue-42
  assert_failure
  assert_output --partial "profile 'gone': no such profile"
  [[ ! -f "$STUB_CALLS_DIR/zellij.new-tab-cmd" ]]
}

# ----- task-pm ----------------------------------------------------------------------

@test "task-pm --profile exports the profile in place; the key never reaches argv" {
  export ZELLIJ=fake-session STUB_CLAUDE_RADIO="$RADIO"
  AW_IMPL=claude-gh run "$TASK_PM" --profile fireworks-glm
  assert_success
  run agent_env
  assert_line "TASK_FORCE_PROFILE=fireworks-glm"
  assert_line "ANTHROPIC_API_KEY=$SENTINEL"
  assert_line "ANTHROPIC_DEFAULT_HAIKU_MODEL=glm-latest"
  run cat "$STUB_CALLS_DIR/claude.calls"
  assert_output "claude --model glm-latest /pm"
  run cat "$TASK_FORCE_HOME/radio/sessions/pm-$NAME.profile"
  assert_output fireworks-glm
  run grep -rlF "$SENTINEL" "$TASK_FORCE_HOME" "$STUB_CALLS_DIR/claude.calls"
  assert_failure
}

@test "task-pm without --profile drops an inherited TASK_FORCE_PROFILE" {
  export ZELLIJ=fake-session TASK_FORCE_PROFILE=leaked
  AW_IMPL=claude-gh run "$TASK_PM"
  assert_success
  run agent_env
  assert_line "TASK_FORCE_PROFILE=<unset>"
  run cat "$STUB_CALLS_DIR/claude.calls"
  assert_output "claude /pm"
}

@test "task-pm refuses a bad profile before renaming the tab" {
  export ZELLIJ=fake-session
  AW_IMPL=claude-gh run "$TASK_PM" --profile nope
  assert_failure
  assert_output --partial "no such profile"
  [[ ! -f "$STUB_CALLS_DIR/claude.calls" ]]
  run grep rename-tab "$STUB_CALLS_DIR/zellij.calls"
  assert_failure
}

# ----- radio's sidecar ----------------------------------------------------------------

@test "radio: register records TASK_FORCE_PROFILE, clears it on a launch without one, a repair keeps it" {
  local role="worker-x-p" sc="$TASK_FORCE_HOME/radio/sessions/worker-x-p.profile"
  TASK_FORCE_ROLE=$role TASK_FORCE_PROFILE=fw run "$RADIO" register --role "$role" --tab p --agent claude
  assert_success
  run cat "$sc"
  assert_output fw
  # A hand repair has no say: keep it.
  run "$RADIO" register --role "$role" --tab p --agent claude
  assert_success
  run cat "$sc"
  assert_output fw
  run grep -Fx PROFILE=fw "$TASK_FORCE_HOME/radio/sessions/$role.info"
  assert_success
  # A launch without one (same slug, a new worker): gone.
  TASK_FORCE_ROLE=$role run "$RADIO" register --role "$role" --tab p --agent claude
  assert_success
  [[ ! -f "$sc" ]]
  run grep '^PROFILE=' "$TASK_FORCE_HOME/radio/sessions/$role.info"
  assert_failure
}
