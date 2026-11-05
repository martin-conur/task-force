#!/usr/bin/env bats
# `task-config profile add|list|show|test|remove` (#356): define and verify an
# agent profile (#355) without knowing the variable names.
#
# What these pin: `add` writes only what lib/profile.sh reads back and loads,
# so it cannot write a profile a launcher refuses; `add` and `remove` leave
# every other line of the file alone; no key value is ever printed or written;
# and `test` runs claude with the variables a launch sets, in a throwaway
# directory, with no radio identity.

bats_load_library bats-support
bats_load_library bats-assert

load helpers/common

TC="$REPO_ROOT_REAL/bin/task-config"
SENTINEL="sk-sentinel-356-do-not-print"

setup() {
  setup_stubs
  setup_task_force_home
  PF="$TASK_FORCE_HOME/profiles.toml"
  export FIREWORKS_API_KEY="$SENTINEL"
  unset TASK_FORCE_ROLE TASK_FORCE_PROFILE ANTHROPIC_MODEL ANTHROPIC_AUTH_TOKEN
  # Profiles are the machine's, not a repo's: run from outside any repo.
  OUTSIDE=$(mktemp -d)
  cd "$OUTSIDE"
}

teardown() {
  [[ -z "${OUTSIDE:-}" ]] || rm -rf "$OUTSIDE"
  teardown_all
}

# A claude that answers in stream-json, as `claude -p --output-format
# stream-json --verbose` does. $STUB_PT_MODE: ok (reads probe.txt with Read
# and answers with it), authfail (a synthetic 401), notool (answers without a
# tool), echo-key (an error that quotes the key back).
stub_test_claude() {
  cat > "$STUB_BIN/claude" <<'STUB'
#!/usr/bin/env bash
{
  echo "PWD=$PWD"
  echo "ARGS=$*"
  for v in TASK_FORCE_ROLE TASK_FORCE_PM_ROLE ZELLIJ_TAB ANTHROPIC_AUTH_TOKEN TASK_FORCE_PROFILE \
           ANTHROPIC_BASE_URL ENABLE_TOOL_SEARCH ANTHROPIC_MODEL ANTHROPIC_DEFAULT_SONNET_MODEL \
           ANTHROPIC_DEFAULT_HAIKU_MODEL ANTHROPIC_DEFAULT_OPUS_MODEL CLAUDE_CODE_SUBAGENT_MODEL; do
    echo "$v=${!v-<unset>}"
  done
  [[ "${ANTHROPIC_API_KEY:-}" == "$EXPECT_KEY" ]] && echo "KEY=match" || echo "KEY=mismatch"
} > "$STUB_CALLS_DIR/test-claude.env"
ls -A > "$STUB_CALLS_DIR/test-claude.ls"
case "${STUB_PT_MODE:-ok}" in
  ok)
    n=$(cat probe.txt)
    echo '{"type":"system","subtype":"init","model":"requested"}'
    echo '{"type":"assistant","message":{"model":"gw/glm-5","content":[{"type":"tool_use","name":"Read","input":{"file_path":"probe.txt"}}]}}'
    echo '{"type":"assistant","message":{"model":"gw/glm-5","content":[{"type":"text","text":"'"$n"'"}]}}'
    echo '{"type":"result","subtype":"success","is_error":false,"result":"'"$n"'"}'
    ;;
  authfail)
    echo '{"type":"assistant","message":{"model":"<synthetic>","content":[{"type":"text","text":"API Error: 401 invalid api key"}]}}'
    echo '{"type":"result","subtype":"success","is_error":true,"result":"API Error: 401 invalid api key"}'
    exit 1
    ;;
  notool)
    echo '{"type":"assistant","message":{"model":"gw/glm-5","content":[{"type":"text","text":"I cannot read files"}]}}'
    echo '{"type":"result","subtype":"success","is_error":false,"result":"I cannot read files"}'
    ;;
  echo-key)
    echo "{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":true,\"result\":\"API Error: 401 bad key $ANTHROPIC_API_KEY\"}"
    exit 1
    ;;
esac
STUB
  chmod +x "$STUB_BIN/claude"
  export EXPECT_KEY="$SENTINEL"
}

add_fw() { run "$TC" profile add fw --preset fireworks --model glm-latest --key-env FIREWORKS_API_KEY "$@"; }

# --- add ---------------------------------------------------------------------

@test "add --preset fireworks writes the spike's profile, which a launcher loads" {
  add_fw
  assert_success
  assert_output --partial "Added profile fw"
  assert_output --partial "task-config profile test fw"
  run cat "$PF"
  assert_output --partial '[profiles.fw]'
  assert_output --partial 'agent   = "claude"'
  assert_output --partial 'model   = "glm-latest"'
  assert_output --partial 'env     = { ANTHROPIC_BASE_URL = "https://api.fireworks.ai/inference", ENABLE_TOOL_SEARCH = "true" }'
  assert_output --partial 'key_env = { ANTHROPIC_API_KEY = "FIREWORKS_API_KEY" }'
  # Every tier on the model: no pin table.
  refute_output --partial 'pin'
  # The reader the launchers use takes it, every tier pinned to the model.
  run bash -c ". '$REPO_ROOT_REAL/lib/profile.sh' && aw_profile_load fw claude && printf '%s' \"\$AW_PROFILE_VARS\""
  assert_success
  assert_line $'ANTHROPIC_DEFAULT_SONNET_MODEL\tlit\tglm-latest'
  assert_line $'CLAUDE_CODE_SUBAGENT_MODEL\tlit\tglm-latest'
  assert_line $'ANTHROPIC_API_KEY\tref\tFIREWORKS_API_KEY'
}

@test "add: a custom profile with pins, --env, and values the reader must take back whole" {
  run "$TC" profile add local --base-url http://localhost:4000 --model 'm "q" \ x' \
    --key-env FIREWORKS_API_KEY --pin haiku=small --pin=subagent=sub --env FOO='a b' --env=ENABLE_TOOL_SEARCH=false
  assert_success
  run bash -c ". '$REPO_ROOT_REAL/lib/profile.sh' && aw_profile_load local claude && printf '%s' \"\$AW_PROFILE_VARS\""
  assert_success
  assert_line $'ANTHROPIC_BASE_URL\tlit\thttp://localhost:4000'
  assert_line $'FOO\tlit\ta b'
  assert_line $'ENABLE_TOOL_SEARCH\tlit\tfalse'
  assert_line $'ANTHROPIC_DEFAULT_HAIKU_MODEL\tlit\tsmall'
  assert_line $'CLAUDE_CODE_SUBAGENT_MODEL\tlit\tsub'
  assert_line $'ANTHROPIC_MODEL\tlit\tm "q" \\ x'
}

@test "add: --env overrides a preset's variable in place" {
  add_fw --env ENABLE_TOOL_SEARCH=false
  assert_success
  run grep '^env' "$PF"
  assert_output 'env     = { ANTHROPIC_BASE_URL = "https://api.fireworks.ai/inference", ENABLE_TOOL_SEARCH = "false" }'
}

@test "add: the anthropic preset, and an unknown preset lists the ones there are" {
  run "$TC" profile add direct --preset anthropic --model claude-haiku-5-5 --key-env FIREWORKS_API_KEY
  assert_success
  run grep 'ANTHROPIC_BASE_URL' "$PF"
  assert_output --partial '"https://api.anthropic.com"'
  run "$TC" profile add x --preset openrouter --model m --key-env FIREWORKS_API_KEY
  assert_failure
  assert_output --partial "no preset 'openrouter'. Presets: fireworks, anthropic."
}

@test "add refuses an existing name without --force, and replaces it in place with it" {
  cat > "$PF" <<'TOML'
# my profiles
[profiles.before]
agent = "claude"
model = "b"

# the gateway one
[profiles.fw]
agent = "claude"
model = "old"

[profiles.fw.env]
OLD = "1"

# the last one
[profiles.after]
agent = "claude"
model = "a"
TOML
  add_fw
  assert_failure
  assert_output --partial "already exists"
  assert_output --partial "--force"
  run grep -c 'model = "old"' "$PF"
  assert_output 1

  add_fw --force
  assert_success
  assert_output --partial "Replaced profile fw"
  run cat "$PF"
  assert_output - <<'TOML'
# my profiles
[profiles.before]
agent = "claude"
model = "b"

# the gateway one
[profiles.fw]
agent   = "claude"
model   = "glm-latest"
env     = { ANTHROPIC_BASE_URL = "https://api.fireworks.ai/inference", ENABLE_TOOL_SEARCH = "true" }
key_env = { ANTHROPIC_API_KEY = "FIREWORKS_API_KEY" }

# the last one
[profiles.after]
agent = "claude"
model = "a"
TOML
}

@test "add appends after the file's comments and profiles, leaving them as they were" {
  printf '# hand-written\n[profiles.mine]\nagent = "claude"   # mine\nmodel = "x"\n' > "$PF"
  add_fw
  assert_success
  run cat "$PF"
  assert_output - <<'TOML'
# hand-written
[profiles.mine]
agent = "claude"   # mine
model = "x"

[profiles.fw]
agent   = "claude"
model   = "glm-latest"
env     = { ANTHROPIC_BASE_URL = "https://api.fireworks.ai/inference", ENABLE_TOOL_SEARCH = "true" }
key_env = { ANTHROPIC_API_KEY = "FIREWORKS_API_KEY" }
TOML
}

@test "add refuses what a launcher would, and writes nothing" {
  printf '# keep\n' > "$PF"
  run "$TC" profile add x --preset fireworks --key-env FIREWORKS_API_KEY
  assert_failure
  assert_output --partial "needs --model"
  run "$TC" profile add x --preset fireworks --model m
  assert_failure
  assert_output --partial "needs --key-env"
  run "$TC" profile add x --model m --key-env FIREWORKS_API_KEY
  assert_failure
  assert_output --partial "needs --preset <name> or --base-url"
  run "$TC" profile add x --preset fireworks --model m --key-env 'sk-a key'
  assert_failure
  assert_output --partial "takes a variable name"
  run "$TC" profile add x --preset fireworks --model m --key-env FIREWORKS_API_KEY --pin turbo=m
  assert_failure
  assert_output --partial "unknown pin 'turbo'"
  # The validator's own refusals: a credential in env, a launcher-owned name.
  run "$TC" profile add x --preset fireworks --model m --key-env FIREWORKS_API_KEY --env ANTHROPIC_AUTH_TOKEN=t
  assert_failure
  assert_output --partial "ANTHROPIC_AUTH_TOKEN is in env"
  assert_output --partial "Nothing written."
  run "$TC" profile add x --preset fireworks --model m --key-env FIREWORKS_API_KEY --env TASK_FORCE_ROLE=r
  assert_failure
  assert_output --partial "launchers own it"
  run "$TC" profile add 'bad.name' --preset fireworks --model m --key-env FIREWORKS_API_KEY
  assert_failure
  assert_output --partial "not a valid profile name"
  run cat "$PF"
  assert_output '# keep'
}

@test "add refuses --auth, pointing at the spike: x-api-key only" {
  run "$TC" profile add x --base-url http://gw --auth bearer --model m --key-env FIREWORKS_API_KEY
  assert_failure
  assert_output --partial "--auth is not offered"
  assert_output --partial "section 6"
  [[ ! -f "$PF" ]]
}

@test "add refuses on a file that does not parse, naming the line, and leaves it alone" {
  printf '[profiles.a]\nagent = "claude"\nlist = [1, 2]\n' > "$PF"
  run cat "$PF"; local before="$output"
  add_fw
  assert_failure
  assert_output --partial "does not parse: line 3"
  run cat "$PF"
  assert_equal "$output" "$before"
}

@test "add with the key's variable unset writes the profile and warns" {
  unset FIREWORKS_API_KEY
  add_fw
  assert_success
  assert_output --partial 'Warning: $FIREWORKS_API_KEY is unset here'
  run grep -c '^\[profiles.fw\]' "$PF"
  assert_output 1
}

@test "add works with no profile file and no home directory yet" {
  rm -rf "$TASK_FORCE_HOME"
  add_fw
  assert_success
  [[ -f "$PF" ]]
}

# --- list / show -------------------------------------------------------------

@test "list: names, agent, model and base URL; never a key" {
  run "$TC" profile list
  assert_success
  assert_output --partial "No profiles"
  add_fw
  run "$TC" profile add local --base-url http://localhost:4000 --model m --key-env FIREWORKS_API_KEY
  run "$TC" profile list
  assert_success
  assert_line --regexp '^NAME +AGENT +MODEL +BASE URL$'
  assert_line --regexp '^fw +claude +glm-latest +https://api.fireworks.ai/inference$'
  assert_line --regexp '^local +claude +m +http://localhost:4000$'
  refute_output --partial "$SENTINEL"
}

@test "show: the resolved profile, the key's variable as set or unset, never its value" {
  add_fw --pin haiku=small
  run "$TC" profile show fw
  assert_success
  assert_line 'model   : glm-latest'
  assert_line '  ANTHROPIC_BASE_URL=https://api.fireworks.ai/inference'
  assert_line '  ENABLE_TOOL_SEARCH=true'
  assert_line '  ANTHROPIC_API_KEY  from $FIREWORKS_API_KEY (set here)'
  assert_line '  ANTHROPIC_DEFAULT_SONNET_MODEL=glm-latest'
  assert_line '  ANTHROPIC_DEFAULT_HAIKU_MODEL=small'
  assert_line '  ANTHROPIC_MODEL=glm-latest'
  refute_output --partial "$SENTINEL"

  FIREWORKS_API_KEY="" run "$TC" profile show fw
  assert_success
  assert_line '  ANTHROPIC_API_KEY  from $FIREWORKS_API_KEY (unset here)'
  assert_output --partial "a launch on this profile is refused"
}

@test "show refuses an unknown profile, naming the ones there are" {
  add_fw
  run "$TC" profile show nope
  assert_failure
  assert_output --partial "no such profile"
  assert_output --partial "Profiles defined there: fw."
}

# --- remove ------------------------------------------------------------------

@test "remove cuts out one profile and its sub-tables, leaving comments and the rest" {
  cat > "$PF" <<'TOML'
# top
[profiles.a]
agent = "claude"
model = "a"

[profiles.fw]
agent = "claude"
model = "m"
# inside fw
[profiles.fw.env]
X = "1"

# about b
[profiles.b]
agent = "claude"
model = "b"
TOML
  run "$TC" profile remove fw
  assert_success
  assert_output --partial "Removed profile fw"
  run cat "$PF"
  assert_output - <<'TOML'
# top
[profiles.a]
agent = "claude"
model = "a"

# about b
[profiles.b]
agent = "claude"
model = "b"
TOML
  run "$TC" profile remove fw
  assert_failure
  assert_output --partial "no profile 'fw'"
  assert_output --partial "Profiles there: a, b."
}

@test "remove refuses a profile written as dotted keys under another table" {
  printf '[profiles]\nfw.agent = "claude"\nfw.model = "m"\n' > "$PF"
  run cat "$PF"; local before="$output"
  run "$TC" profile remove fw
  assert_failure
  assert_output --partial "Edit it by hand"
  run cat "$PF"
  assert_equal "$output" "$before"
}

# --- test --------------------------------------------------------------------

@test "test: success reports auth, the model that answered, the tool, the time" {
  stub_test_claude
  add_fw --pin sonnet=big
  run "$TC" profile test fw
  assert_success
  assert_line '  auth      : ok'
  assert_line '  answered  : gw/glm-5'
  assert_line '  tool use  : ok (Read)'
  assert_line --regexp '^  elapsed   : [0-9]+s$'
  assert_line 'OK'
  refute_output --partial "$SENTINEL"
}

@test "test runs with the launch's variables, in a throwaway directory, with no radio identity" {
  stub_test_claude
  add_fw --pin sonnet=big
  export TASK_FORCE_ROLE=worker-x-y TASK_FORCE_PM_ROLE=pm-x ZELLIJ_TAB=y ANTHROPIC_AUTH_TOKEN=leak
  run "$TC" profile test fw
  assert_success
  run cat "$STUB_CALLS_DIR/test-claude.env"
  assert_line 'KEY=match'
  assert_line 'ANTHROPIC_BASE_URL=https://api.fireworks.ai/inference'
  assert_line 'ENABLE_TOOL_SEARCH=true'
  assert_line 'ANTHROPIC_MODEL=glm-latest'
  assert_line 'ANTHROPIC_DEFAULT_SONNET_MODEL=big'
  assert_line 'ANTHROPIC_DEFAULT_HAIKU_MODEL=glm-latest'
  assert_line 'ANTHROPIC_DEFAULT_OPUS_MODEL=glm-latest'
  assert_line 'CLAUDE_CODE_SUBAGENT_MODEL=glm-latest'
  assert_line 'TASK_FORCE_PROFILE=fw'
  assert_line 'TASK_FORCE_ROLE=<unset>'
  assert_line 'TASK_FORCE_PM_ROLE=<unset>'
  assert_line 'ZELLIJ_TAB=<unset>'
  assert_line 'ANTHROPIC_AUTH_TOKEN=<unset>'
  assert_line --partial 'ARGS=-p '
  assert_line --partial '--model glm-latest'
  # The key is in the environment only, never in argv.
  refute_output --partial "$SENTINEL"
  local dir
  dir=$(sed -n 's/^PWD=//p' "$STUB_CALLS_DIR/test-claude.env")
  [[ "$dir" != "$OUTSIDE" ]]
  [[ ! -e "$dir" ]]
  # Nothing registered: no radio state under the home.
  [[ ! -e "$TASK_FORCE_HOME/radio" ]]
}

@test "test: an auth failure exits non-zero with the gateway's error" {
  stub_test_claude
  add_fw
  STUB_PT_MODE=authfail run "$TC" profile test fw
  assert_failure
  assert_line '  auth      : FAILED'
  assert_line '  error     : API Error: 401 invalid api key'
  assert_line 'FAILED'
}

@test "test: an answer without the tool call is a failure" {
  stub_test_claude
  add_fw
  STUB_PT_MODE=notool run "$TC" profile test fw
  assert_failure
  assert_line '  auth      : ok'
  assert_line '  tool use  : FAILED (no tool call)'
}

@test "test never prints the key, even when the gateway echoes it back" {
  stub_test_claude
  add_fw
  STUB_PT_MODE=echo-key run "$TC" profile test fw
  assert_failure
  refute_output --partial "$SENTINEL"
  assert_output --partial "bad key <key>"
}

@test "test refuses, as a launch would, when the key's variable is unset; claude never runs" {
  stub_test_claude
  add_fw
  FIREWORKS_API_KEY="" run "$TC" profile test fw
  assert_failure
  assert_output --partial "unset or empty here"
  [[ ! -f "$STUB_CALLS_DIR/test-claude.env" ]]
}

@test "profile with no subcommand prints its usage with the presets" {
  run "$TC" profile
  assert_success
  assert_output --partial "task-config profile add <name> --preset"
  assert_output --partial "fireworks"
  run "$TC" profile frob
  assert_failure
  assert_output --partial "unknown profile subcommand 'frob'"
}
