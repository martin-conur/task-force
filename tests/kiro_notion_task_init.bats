#!/usr/bin/env bats
# Tests for kiro-notion/bin/task-init

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

@test "copies template to .kiro/steering/notion-workflow.md" {
  run "$KIRO_TASK_INIT"
  assert_success
  assert [ -f "$TARGET_DIR/.kiro/steering/notion-workflow.md" ]
}

@test "copied file contains placeholder text" {
  run "$KIRO_TASK_INIT"
  assert_success
  run grep -F "YOUR_TASKS_DATA_SOURCE_ID" "$TARGET_DIR/.kiro/steering/notion-workflow.md"
  assert_success
}

# ---------------------------------------------------------------------------
# Post-install guidance
# ---------------------------------------------------------------------------

@test "prints Notion ID discovery guide after setup" {
  run "$KIRO_TASK_INIT"
  assert_success
  assert_output --partial "How to find your Notion database IDs"
  assert_output --partial "kiro"
}

# ---------------------------------------------------------------------------
# --help-ids flag
# ---------------------------------------------------------------------------

@test "--help-ids prints guide without running setup" {
  run "$KIRO_TASK_INIT" --help-ids
  assert_success
  assert_output --partial "How to find your Notion database IDs"
  assert [ ! -f "$TARGET_DIR/.kiro/steering/notion-workflow.md" ]
}

@test "--help-ids works outside a git repo" {
  cd /tmp
  run "$KIRO_TASK_INIT" --help-ids
  assert_success
  assert_output --partial "How to find your Notion database IDs"
}

# ---------------------------------------------------------------------------
# Overwrite policy: --force / --restore / default (TTY prompt / non-TTY keep)
# ---------------------------------------------------------------------------

@test "non-TTY default: existing workflow doc is kept silently (exit 0)" {
  run "$KIRO_TASK_INIT"
  assert_success
  echo "USER EDIT" >> "$TARGET_DIR/.kiro/steering/notion-workflow.md"
  run "$KIRO_TASK_INIT"
  assert_success
  assert_output --partial "kept"
  run cat "$TARGET_DIR/.kiro/steering/notion-workflow.md"
  assert_output --partial "USER EDIT"
}

@test "--force refreshes the template half of notion-workflow.md" {
  # Post-#183 the workflow doc is a managed region: --force rebuilds what is
  # between the markers, so deleting a template heading is repaired…
  run "$KIRO_TASK_INIT"
  assert_success
  local doc="$TARGET_DIR/.kiro/steering/notion-workflow.md"
  grep -v '^### When radio misbehaves$' "$doc" > "$doc.x"
  mv "$doc.x" "$doc"
  run "$KIRO_TASK_INIT" --force
  assert_success
  run cat "$doc"
  assert_output --partial "### When radio misbehaves"
}

@test "--force leaves content below the end marker alone (#183)" {
  # …while an appended line lands below the end marker and must survive. This
  # is the deletion that hit this repo three times: a hand-authored section in
  # the workflow doc, gone on the next documented `task-init` re-run.
  run "$KIRO_TASK_INIT"
  assert_success
  local doc="$TARGET_DIR/.kiro/steering/notion-workflow.md"
  echo "USER EDIT" >> "$doc"
  run "$KIRO_TASK_INIT" --force
  assert_success
  run cat "$doc"
  assert_output --partial "USER EDIT"
}

@test "--force + --restore is rejected" {
  run "$KIRO_TASK_INIT" --force --restore
  assert_failure
  assert_output --partial "mutually exclusive"
}

# ---------------------------------------------------------------------------
# --restore: fill missing only
# ---------------------------------------------------------------------------

@test "--restore restores a deleted agent without touching workflow" {
  run "$KIRO_TASK_INIT"
  assert_success
  cp "$TARGET_DIR/.kiro/steering/notion-workflow.md" "$BATS_TEST_TMPDIR/workflow.before"
  rm "$TARGET_DIR/.kiro/agents/pm.json"
  run "$KIRO_TASK_INIT" --restore
  assert_success
  assert [ -f "$TARGET_DIR/.kiro/agents/pm.json" ]
  run cmp -s "$BATS_TEST_TMPDIR/workflow.before" "$TARGET_DIR/.kiro/steering/notion-workflow.md"
  assert_success
}

# ---------------------------------------------------------------------------
# --workflow / --commands scope flags
# ---------------------------------------------------------------------------

@test "--commands installs agents without writing workflow doc" {
  run "$KIRO_TASK_INIT" --commands
  assert_success
  assert [ ! -f "$TARGET_DIR/.kiro/steering/notion-workflow.md" ]
  for agent in pm planner worker; do
    assert [ -f "$TARGET_DIR/.kiro/agents/$agent.json" ]
  done
}

@test "--workflow installs workflow doc without writing agents" {
  run "$KIRO_TASK_INIT" --workflow
  assert_success
  assert [ -f "$TARGET_DIR/.kiro/steering/notion-workflow.md" ]
  assert [ ! -d "$TARGET_DIR/.kiro/agents" ]
}

# ---------------------------------------------------------------------------
# Project-level agents
# ---------------------------------------------------------------------------

@test "installs pm/planner/worker into .kiro/agents/ as real files" {
  run "$KIRO_TASK_INIT"
  assert_success
  for agent in pm planner worker; do
    assert [ -f "$TARGET_DIR/.kiro/agents/$agent.json" ]
    assert [ ! -L "$TARGET_DIR/.kiro/agents/$agent.json" ]
  done
}

@test "project-level agents are copies of kiro-notion/agents/" {
  run "$KIRO_TASK_INIT"
  assert_success
  # Identical to the shipped source *except* for the radio hooks merged in at
  # install time (#218) — the source files deliberately carry no hooks block, so
  # the loadout name and the ${TASK_FORCE_LOADOUT:-…} override live in exactly
  # one place (task-init) rather than being duplicated across ten agent files.
  jq -S 'del(.hooks)' "$TARGET_DIR/.kiro/agents/pm.json" > "$TARGET_DIR/installed.norm"
  jq -S '.'           "$REPO_ROOT_REAL/kiro-notion/agents/pm.json" > "$TARGET_DIR/source.norm"
  run diff -u "$TARGET_DIR/source.norm" "$TARGET_DIR/installed.norm"
  assert_success
}

@test "--force overwrites pre-existing project-level agent" {
  mkdir -p "$TARGET_DIR/.kiro/agents"
  echo "stale" > "$TARGET_DIR/.kiro/agents/pm.json"
  run "$KIRO_TASK_INIT" --force
  assert_success
  assert [ ! -L "$TARGET_DIR/.kiro/agents/pm.json" ]
  # Identical to the shipped source *except* for the radio hooks merged in at
  # install time (#218) — the source files deliberately carry no hooks block, so
  # the loadout name and the ${TASK_FORCE_LOADOUT:-…} override live in exactly
  # one place (task-init) rather than being duplicated across ten agent files.
  jq -S 'del(.hooks)' "$TARGET_DIR/.kiro/agents/pm.json" > "$TARGET_DIR/installed.norm"
  jq -S '.'           "$REPO_ROOT_REAL/kiro-notion/agents/pm.json" > "$TARGET_DIR/source.norm"
  run diff -u "$TARGET_DIR/source.norm" "$TARGET_DIR/installed.norm"
  assert_success
}

@test "--force replaces a stale (broken) symlink" {
  mkdir -p "$TARGET_DIR/.kiro/agents"
  ln -sf /nonexistent/path "$TARGET_DIR/.kiro/agents/pm.json"
  run "$KIRO_TASK_INIT" --force
  assert_success
  assert [ ! -L "$TARGET_DIR/.kiro/agents/pm.json" ]
  # Identical to the shipped source *except* for the radio hooks merged in at
  # install time (#218) — the source files deliberately carry no hooks block, so
  # the loadout name and the ${TASK_FORCE_LOADOUT:-…} override live in exactly
  # one place (task-init) rather than being duplicated across ten agent files.
  jq -S 'del(.hooks)' "$TARGET_DIR/.kiro/agents/pm.json" > "$TARGET_DIR/installed.norm"
  jq -S '.'           "$REPO_ROOT_REAL/kiro-notion/agents/pm.json" > "$TARGET_DIR/source.norm"
  run diff -u "$TARGET_DIR/source.norm" "$TARGET_DIR/installed.norm"
  assert_success
}

@test "without --force, pre-existing project-level agent is preserved" {
  mkdir -p "$TARGET_DIR/.kiro/agents"
  echo "stale content" > "$TARGET_DIR/.kiro/agents/pm.json"
  run "$KIRO_TASK_INIT"
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
  run "$KIRO_TASK_INIT"
  assert_failure
  assert_output --partial "not in a git repo"
}

# ---------------------------------------------------------------------------
# Radio hooks (#218) — these three loadouts had no hook coverage at all before,
# which is how the register command drifted between them unnoticed.
# ---------------------------------------------------------------------------

@test "merges the 3 radio hooks into every agent config, where kiro-cli reads them (#218)" {
  run "$KIRO_TASK_INIT"
  assert_success
  assert [ ! -d "$TARGET_DIR/.kiro/hooks" ]
  for agent in pm planner worker; do
    run jq -r '[.hooks.agentSpawn[0].command, .hooks.userPromptSubmit[0].command, .hooks.stop[0].command] | @tsv' \
      "$TARGET_DIR/.kiro/agents/$agent.json"
    assert_success
    assert_output --partial "radio register"
    assert_output --partial "radio busy"
    assert_output --partial "radio ready"
  done
}

@test "radio-register embeds the loadout name env-overridably (#218)" {
  # kiro-notion hard-coded its loadout where kiro-gh used the override form. The three
  # copies were never drift-guarded, so nothing caught it; they are now.
  run "$KIRO_TASK_INIT"
  assert_success
  run jq -r '.hooks.agentSpawn[0].command' "$TARGET_DIR/.kiro/agents/worker.json"
  assert_output --partial "--loadout \${TASK_FORCE_LOADOUT:-kiro-notion}"
  assert_output --partial "--agent kiro"
}

@test "never emits the agentStop trigger, which kiro-cli rejects outright (#218)" {
  run "$KIRO_TASK_INIT"
  assert_success
  run jq -e '.hooks | has("agentStop")' "$TARGET_DIR/.kiro/agents/worker.json"
  assert_failure
}

@test "hooks are merged even when the policy KEEPS a customized agent config (#218)" {
  run "$KIRO_TASK_INIT"
  assert_success
  jq '.prompt = "CUSTOMIZED" | del(.hooks)' "$TARGET_DIR/.kiro/agents/worker.json" > "$TARGET_DIR/w.tmp"
  mv "$TARGET_DIR/w.tmp" "$TARGET_DIR/.kiro/agents/worker.json"
  run "$KIRO_TASK_INIT"
  assert_success
  run jq -r '.prompt' "$TARGET_DIR/.kiro/agents/worker.json"
  assert_output "CUSTOMIZED"
  run jq -r '.hooks.agentSpawn[0].command' "$TARGET_DIR/.kiro/agents/worker.json"
  assert_output --partial "radio register"
}

@test "sweeps the inert .kiro/hooks/radio-*.json a previous task-init wrote (#218)" {
  mkdir -p "$TARGET_DIR/.kiro/hooks"
  for name in radio-register radio-busy radio-ready; do
    printf '{"version":"1.0","name":"%s","trigger":{"type":"agentSpawn"},"action":{"type":"shellCommand","command":"radio busy"},"enabled":true}\n' \
      "$name" > "$TARGET_DIR/.kiro/hooks/${name}.json"
  done
  run "$KIRO_TASK_INIT"
  assert_success
  assert [ ! -d "$TARGET_DIR/.kiro/hooks" ]
}
