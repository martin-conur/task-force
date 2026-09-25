#!/usr/bin/env bats
# Tests for kiro-gh/bin/task-init

bats_load_library bats-support
bats_load_library bats-assert

load helpers/common

TARGET_DIR=""

setup() {
  setup_repo
  TARGET_DIR="$MAIN_REPO"
  cd "$TARGET_DIR"
}

teardown() {
  teardown_all
}

# ---------------------------------------------------------------------------
# File creation
# ---------------------------------------------------------------------------

@test "copies template to .kiro/steering/gh-workflow.md" {
  run "$KIRO_GH_TASK_INIT"
  assert_success
  assert [ -f "$TARGET_DIR/.kiro/steering/gh-workflow.md" ]
}

@test "copied file contains placeholder text when no values provided" {
  run "$KIRO_GH_TASK_INIT"
  assert_success
  run grep -F "{PROJECT}" "$TARGET_DIR/.kiro/steering/gh-workflow.md"
  assert_success
}

# ---------------------------------------------------------------------------
# Flag-based substitution
# ---------------------------------------------------------------------------

@test "all flags: substitutes {OWNER}, {REPO}, {PROJECT}" {
  run "$KIRO_GH_TASK_INIT" --owner myorg --repo myrepo --project 42
  assert_success
  run cat "$TARGET_DIR/.kiro/steering/gh-workflow.md"
  assert_output --partial "myorg"
  assert_output --partial "myrepo"
  assert_output --partial "42"
  refute_output --partial "{OWNER}"
  refute_output --partial "{REPO}"
  refute_output --partial "{PROJECT}"
}

@test "--owner only: {REPO} and {PROJECT} remain as placeholders" {
  run "$KIRO_GH_TASK_INIT" --owner myorg
  assert_success
  run cat "$TARGET_DIR/.kiro/steering/gh-workflow.md"
  assert_output --partial "myorg"
  assert_output --partial "{REPO}"
  assert_output --partial "{PROJECT}"
}

@test "no flags (non-interactive stdin): all {placeholders} preserved" {
  run "$KIRO_GH_TASK_INIT"
  assert_success
  run cat "$TARGET_DIR/.kiro/steering/gh-workflow.md"
  assert_output --partial "{OWNER}"
  assert_output --partial "{REPO}"
  assert_output --partial "{PROJECT}"
}

# ---------------------------------------------------------------------------
# Auto-detection from git remote
# ---------------------------------------------------------------------------

@test "auto-detects owner and repo from HTTPS remote" {
  git -C "$TARGET_DIR" remote add origin "https://github.com/acme/widget.git"
  run "$KIRO_GH_TASK_INIT" --project 1
  assert_success
  run cat "$TARGET_DIR/.kiro/steering/gh-workflow.md"
  assert_output --partial "acme"
  assert_output --partial "widget"
  refute_output --partial "{OWNER}"
  refute_output --partial "{REPO}"
}

@test "auto-detects owner and repo from SSH remote" {
  git -C "$TARGET_DIR" remote add origin "git@github.com:acme/widget.git"
  run "$KIRO_GH_TASK_INIT" --project 1
  assert_success
  run cat "$TARGET_DIR/.kiro/steering/gh-workflow.md"
  assert_output --partial "acme"
  assert_output --partial "widget"
  refute_output --partial "{OWNER}"
  refute_output --partial "{REPO}"
}

@test "--owner flag overrides auto-detected owner" {
  git -C "$TARGET_DIR" remote add origin "https://github.com/acme/widget.git"
  run "$KIRO_GH_TASK_INIT" --owner override-org --project 1
  assert_success
  run cat "$TARGET_DIR/.kiro/steering/gh-workflow.md"
  assert_output --partial "override-org"
  refute_output --partial "acme"
  refute_output --partial "{OWNER}"
}

@test "no remote: {OWNER} and {REPO} stay as placeholders" {
  run "$KIRO_GH_TASK_INIT" --project 5
  assert_success
  run cat "$TARGET_DIR/.kiro/steering/gh-workflow.md"
  assert_output --partial "{OWNER}"
  assert_output --partial "{REPO}"
}

# ---------------------------------------------------------------------------
# Overwrite policy: --force / --restore / default (TTY prompt / non-TTY keep)
# ---------------------------------------------------------------------------

@test "non-TTY default: existing workflow doc is kept silently (exit 0)" {
  run "$KIRO_GH_TASK_INIT" --owner old
  assert_success
  # Sentinel must be a string that cannot occur in the doc's prose: the
  # refute below scans the whole rendered file, so an ordinary English word
  # ("ignored") false-fails the moment the template text happens to use it.
  run "$KIRO_GH_TASK_INIT" --owner sentinel-not-written
  assert_success
  assert_output --partial "kept"
  run cat "$TARGET_DIR/.kiro/steering/gh-workflow.md"
  assert_output --partial "old"
  refute_output --partial "sentinel-not-written"
}

@test "--force overwrites existing gh-workflow.md" {
  run "$KIRO_GH_TASK_INIT" --owner old
  assert_success
  run "$KIRO_GH_TASK_INIT" --owner new --force
  assert_success
  run cat "$TARGET_DIR/.kiro/steering/gh-workflow.md"
  assert_output --partial "new"
  refute_output --partial "**Owner**: \`old\`"
}

@test "--force + --restore is rejected" {
  run "$KIRO_GH_TASK_INIT" --force --restore
  assert_failure
  assert_output --partial "mutually exclusive"
}

# ---------------------------------------------------------------------------
# --restore: fill missing only
# ---------------------------------------------------------------------------

@test "--restore restores a deleted agent without touching workflow" {
  run "$KIRO_GH_TASK_INIT" --owner acme --repo widget --project 7
  assert_success
  cp "$TARGET_DIR/.kiro/steering/gh-workflow.md" "$BATS_TEST_TMPDIR/workflow.before"
  rm "$TARGET_DIR/.kiro/agents/pm.json"
  run "$KIRO_GH_TASK_INIT" --restore
  assert_success
  assert [ -f "$TARGET_DIR/.kiro/agents/pm.json" ]
  run cmp -s "$BATS_TEST_TMPDIR/workflow.before" "$TARGET_DIR/.kiro/steering/gh-workflow.md"
  assert_success
}

# ---------------------------------------------------------------------------
# --workflow / --commands scope flags
# ---------------------------------------------------------------------------

@test "--commands installs agents without writing workflow doc" {
  run "$KIRO_GH_TASK_INIT" --commands
  assert_success
  assert [ ! -f "$TARGET_DIR/.kiro/steering/gh-workflow.md" ]
  for agent in pm planner worker; do
    assert [ -f "$TARGET_DIR/.kiro/agents/$agent.json" ]
  done
}

@test "--workflow installs workflow doc without writing agents" {
  run "$KIRO_GH_TASK_INIT" --workflow
  assert_success
  assert [ -f "$TARGET_DIR/.kiro/steering/gh-workflow.md" ]
  assert [ ! -d "$TARGET_DIR/.kiro/agents" ]
}

# ---------------------------------------------------------------------------
# Placeholder preservation
# ---------------------------------------------------------------------------

@test "--force preserves filled-in {OWNER}/{REPO}/{PROJECT} when no flags passed" {
  run "$KIRO_GH_TASK_INIT" --owner acme --repo widget --project 7
  assert_success
  run "$KIRO_GH_TASK_INIT" --force
  assert_success
  run cat "$TARGET_DIR/.kiro/steering/gh-workflow.md"
  assert_output --partial "acme"
  assert_output --partial "widget"
  assert_output --partial "**Project number**: \`7\`"
  refute_output --partial "{OWNER}"
  refute_output --partial "{REPO}"
  refute_output --partial "{PROJECT}"
}

# ---------------------------------------------------------------------------
# Project-level agents
# ---------------------------------------------------------------------------

@test "installs pm/planner/worker into .kiro/agents/ as real files" {
  run "$KIRO_GH_TASK_INIT"
  assert_success
  for agent in pm planner worker; do
    assert [ -f "$TARGET_DIR/.kiro/agents/$agent.json" ]
    assert [ ! -L "$TARGET_DIR/.kiro/agents/$agent.json" ]
  done
}

@test "project-level agents are copies of kiro-gh/agents/" {
  run "$KIRO_GH_TASK_INIT"
  assert_success
  # Identical to the shipped source *except* for the radio hooks merged in at
  # install time (#218) — the source files deliberately carry no hooks block, so
  # the loadout name and the ${TASK_FORCE_LOADOUT:-…} override live in exactly
  # one place (task-init) rather than being duplicated across ten agent files.
  jq -S 'del(.hooks)' "$TARGET_DIR/.kiro/agents/pm.json" > "$TARGET_DIR/installed.norm"
  jq -S '.'           "$REPO_ROOT_REAL/kiro-gh/agents/pm.json" > "$TARGET_DIR/source.norm"
  run diff -u "$TARGET_DIR/source.norm" "$TARGET_DIR/installed.norm"
  assert_success
}

@test "--force overwrites pre-existing project-level agent" {
  mkdir -p "$TARGET_DIR/.kiro/agents"
  echo "stale" > "$TARGET_DIR/.kiro/agents/pm.json"
  run "$KIRO_GH_TASK_INIT" --force
  assert_success
  assert [ ! -L "$TARGET_DIR/.kiro/agents/pm.json" ]
  # Identical to the shipped source *except* for the radio hooks merged in at
  # install time (#218) — the source files deliberately carry no hooks block, so
  # the loadout name and the ${TASK_FORCE_LOADOUT:-…} override live in exactly
  # one place (task-init) rather than being duplicated across ten agent files.
  jq -S 'del(.hooks)' "$TARGET_DIR/.kiro/agents/pm.json" > "$TARGET_DIR/installed.norm"
  jq -S '.'           "$REPO_ROOT_REAL/kiro-gh/agents/pm.json" > "$TARGET_DIR/source.norm"
  run diff -u "$TARGET_DIR/source.norm" "$TARGET_DIR/installed.norm"
  assert_success
}

@test "--force replaces a stale (broken) symlink" {
  mkdir -p "$TARGET_DIR/.kiro/agents"
  ln -sf /nonexistent/path "$TARGET_DIR/.kiro/agents/pm.json"
  run "$KIRO_GH_TASK_INIT" --force
  assert_success
  assert [ ! -L "$TARGET_DIR/.kiro/agents/pm.json" ]
  # Identical to the shipped source *except* for the radio hooks merged in at
  # install time (#218) — the source files deliberately carry no hooks block, so
  # the loadout name and the ${TASK_FORCE_LOADOUT:-…} override live in exactly
  # one place (task-init) rather than being duplicated across ten agent files.
  jq -S 'del(.hooks)' "$TARGET_DIR/.kiro/agents/pm.json" > "$TARGET_DIR/installed.norm"
  jq -S '.'           "$REPO_ROOT_REAL/kiro-gh/agents/pm.json" > "$TARGET_DIR/source.norm"
  run diff -u "$TARGET_DIR/source.norm" "$TARGET_DIR/installed.norm"
  assert_success
}

@test "without --force, pre-existing project-level agent is preserved" {
  mkdir -p "$TARGET_DIR/.kiro/agents"
  echo "stale content" > "$TARGET_DIR/.kiro/agents/pm.json"
  run "$KIRO_GH_TASK_INIT"
  assert_success
  run cat "$TARGET_DIR/.kiro/agents/pm.json"
  assert_output "stale content"
  assert [ -f "$TARGET_DIR/.kiro/agents/planner.json" ]
  assert [ -f "$TARGET_DIR/.kiro/agents/worker.json" ]
}

# ---------------------------------------------------------------------------
# Error cases
# ---------------------------------------------------------------------------

@test "fails outside a git repo" {
  cd /tmp
  run "$KIRO_GH_TASK_INIT"
  assert_failure
  assert_output --partial "not in a git repo"
}

# ---------------------------------------------------------------------------
# radio hooks: .kiro/hooks/*.json
# ---------------------------------------------------------------------------

@test "merges the 3 radio hooks into every agent config, where kiro-cli reads them (#218)" {
  # NOT .kiro/hooks/*.json: that is the Kiro IDE's directory, which kiro-cli
  # never reads. Writing there is what made radio dead on kiro — the hooks
  # parsed fine and simply never ran.
  run "$KIRO_GH_TASK_INIT"
  assert_success
  assert [ ! -d "$TARGET_DIR/.kiro/hooks" ]
  for agent in pm planner worker reviewer; do
    run jq -r '[.hooks.agentSpawn[0].command, .hooks.userPromptSubmit[0].command, .hooks.stop[0].command] | @tsv' \
      "$TARGET_DIR/.kiro/agents/$agent.json"
    assert_success
    assert_output --partial "radio register"
    assert_output --partial "radio busy"
    assert_output --partial "radio ready"
  done
}

@test "never emits the agentStop trigger, which kiro-cli rejects outright (#218)" {
  # An agent config carrying agentStop fails to load *wholesale*, taking every
  # other hook with it — so this is not cosmetic.
  run "$KIRO_GH_TASK_INIT"
  assert_success
  for agent in pm planner worker reviewer; do
    run jq -e '.hooks | has("agentStop")' "$TARGET_DIR/.kiro/agents/$agent.json"
    assert_failure
  done
}

@test "the merge is idempotent — a second run does not duplicate entries (#218)" {
  run "$KIRO_GH_TASK_INIT"
  assert_success
  run "$KIRO_GH_TASK_INIT"
  assert_success
  run jq -r '[.hooks.agentSpawn, .hooks.userPromptSubmit, .hooks.stop] | map(length) | @tsv' \
    "$TARGET_DIR/.kiro/agents/worker.json"
  assert_output "1	1	1"
}

@test "hooks are merged even when the policy KEEPS a customized agent config (#218)" {
  # The upgrade path that matters: every existing kiro repo has agent files
  # already, so a merge gated behind install_file's overwrite policy would
  # leave them hookless forever — radio would stay dead for exactly the users
  # who already had it broken.
  run "$KIRO_GH_TASK_INIT"
  assert_success
  jq '.prompt = "CUSTOMIZED" | del(.hooks)' "$TARGET_DIR/.kiro/agents/worker.json" > "$TARGET_DIR/w.tmp"
  mv "$TARGET_DIR/w.tmp" "$TARGET_DIR/.kiro/agents/worker.json"

  run "$KIRO_GH_TASK_INIT"   # non-TTY => keep existing files
  assert_success
  run jq -r '.prompt' "$TARGET_DIR/.kiro/agents/worker.json"
  assert_output "CUSTOMIZED"
  run jq -r '.hooks.agentSpawn[0].command' "$TARGET_DIR/.kiro/agents/worker.json"
  assert_output --partial "radio register"
}

@test "a pre-existing non-radio hook on the same trigger is preserved (#218)" {
  run "$KIRO_GH_TASK_INIT"
  assert_success
  jq '.hooks.agentSpawn = [{"command":"./my-own.sh"}]' "$TARGET_DIR/.kiro/agents/pm.json" > "$TARGET_DIR/p.tmp"
  mv "$TARGET_DIR/p.tmp" "$TARGET_DIR/.kiro/agents/pm.json"

  run "$KIRO_GH_TASK_INIT"
  assert_success
  run jq -r '.hooks.agentSpawn | map(.command) | @tsv' "$TARGET_DIR/.kiro/agents/pm.json"
  assert_output --partial "./my-own.sh"
  assert_output --partial "radio register"
}

@test "sweeps the inert .kiro/hooks/radio-*.json a previous task-init wrote, keeping foreign hooks (#218)" {
  mkdir -p "$TARGET_DIR/.kiro/hooks"
  for name in radio-register radio-busy radio-ready; do
    printf '{"version":"1.0","name":"%s","trigger":{"type":"agentSpawn"},"action":{"type":"shellCommand","command":"radio busy"},"enabled":true}\n' \
      "$name" > "$TARGET_DIR/.kiro/hooks/${name}.json"
  done
  printf '{"version":"1.0","name":"mine","trigger":{"type":"agentSpawn"},"action":{"type":"shellCommand","command":"./lint.sh"},"enabled":true}\n' \
    > "$TARGET_DIR/.kiro/hooks/mine.json"

  run "$KIRO_GH_TASK_INIT"
  assert_success
  for name in radio-register radio-busy radio-ready; do
    assert [ ! -f "$TARGET_DIR/.kiro/hooks/${name}.json" ]
  done
  # Not ours, not deleted — and the directory survives because it is non-empty.
  assert [ -f "$TARGET_DIR/.kiro/hooks/mine.json" ]
}

@test "radio-register hook embeds the loadout name (env-overridable) on agentSpawn" {
  run "$KIRO_GH_TASK_INIT"
  assert_success
  run jq -r '.hooks.agentSpawn[0].command' "$TARGET_DIR/.kiro/agents/worker.json"
  assert_success
  # The hook uses ${TASK_FORCE_LOADOUT:-kiro-gh} so per-role launchers like
  # task-reviewer can override LOADOUT= without re-running task-init.
  assert_output --partial "--loadout \${TASK_FORCE_LOADOUT:-kiro-gh}"
  assert_output --partial "--agent kiro"
}

@test "radio-ready is a bare radio-ready on the per-turn stop trigger (#218)" {
  # `radio check` is gone from this hook: it was paired here only because the
  # old wiring had no other way to look at the inbox, and its listing is not
  # something a hook should print unprompted every turn. `stop` fires once per
  # turn (verified against kiro-cli 2.24.0), which is what makes `radio ready`
  # here enough to return the role to idle.
  run "$KIRO_GH_TASK_INIT"
  assert_success
  run jq -r '.hooks.stop[0].command' "$TARGET_DIR/.kiro/agents/worker.json"
  assert_success
  assert_output "radio ready"
}

# ---------------------------------------------------------------------------
# gh-CLI standardization regression guard
# ---------------------------------------------------------------------------

@test "installed kiro-gh agents do not declare GitHub MCP" {
  run "$KIRO_GH_TASK_INIT"
  assert_success
  for agent in pm planner worker; do
    local f="$TARGET_DIR/.kiro/agents/$agent.json"
    # jq must parse — guards against any malformed JSON from edits.
    run jq . "$f"
    assert_success
    # No mcpServers block, no @github tool.
    run jq -e '.mcpServers // empty' "$f"
    assert_failure
    run grep -F '@github' "$f"
    assert_failure
  done
}
