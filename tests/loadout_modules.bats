#!/usr/bin/env bats
# Parity for the loadout modules a canonical leaf script composes (#236).
#
# This suite exists because of the failure mode this repo keeps hitting: a
# change that lands in six of seven loadouts and nothing notices. #234 is the
# clearest instance — `grep -rn -- '-b "'` found 20 markdown prompts and missed
# all 10 kiro agent JSONs, because inside JSON the quotes are backslash-escaped.
# Twenty of thirty files fixed, a green-looking sweep, and kiro silently broken.
#
# So every assertion here is DERIVED FROM aw_all_impls rather than listing the
# loadouts again. A suite that hard-codes "gh jira notion local" is satisfied by
# its own copy of the list and tells you nothing when the real list grows. The
# three properties it pins:
#
#   1. every tracker/agent name a loadout can be built from has a module file
#      -> fails on a MISSING file, which is the #234 shape
#   2. module count == distinct axis-name count
#      -> fails on an ORPHAN file too, so a renamed loadout cannot leave a
#         stale module behind that nothing loads and nobody notices
#   3. every required hook resolves for every impl, via `declare -F`
#      -> fails when a module loads but forgot a hook
#
# Property 3 is deliberately not the whole story: a hook that resolves may still
# never be reached. That is the #206 lesson — a region can be byte-identical and
# still inert when a precondition differs per host — and structural parity
# cannot see it. The behavioural half lives in `tests/task_done.bats`, which
# asserts an impl-distinguishing observable a failed module load could not
# produce (the jira PR title, the local board + state.json). Both halves, or
# neither means anything.

bats_load_library bats-support
bats_load_library bats-assert

load helpers/common

DETECT="$REPO_ROOT_REAL/lib/detect-impl.sh"

# The hooks a tracker module must provide for bin/task-done. #237 extends this
# list for task-work; keep it a literal here rather than deriving it from the
# modules, since a list derived from the thing under test asserts nothing.
TRACKER_HOOKS_TASK_DONE=(
  aw_tracker_usage_steps
  aw_tracker_pr_section
  aw_tracker_post_cleanup
)

# ---------------------------------------------------------------------------
# 1. Every axis name has a module file
# ---------------------------------------------------------------------------

@test "every tracker in aw_all_impls has a readable lib/trackers/<name>.sh" {
  run bash -c "source '$DETECT'; aw_all_trackers"
  assert_success
  assert [ -n "$output" ]
  local t
  for t in $output; do
    assert [ -r "$REPO_ROOT_REAL/lib/trackers/$t.sh" ]
  done
}

@test "every agent in aw_all_impls has a readable lib/agents/<name>.sh" {
  run bash -c "source '$DETECT'; aw_all_agents"
  assert_success
  assert [ -n "$output" ]
  local a
  for a in $output; do
    assert [ -r "$REPO_ROOT_REAL/lib/agents/$a.sh" ]
  done
}

@test "aw_tracker_module / aw_agent_module resolve every axis name" {
  run bash -c "
    source '$DETECT'
    for t in \$(aw_all_trackers); do aw_tracker_module '$REPO_ROOT_REAL' \"\$t\" >/dev/null || exit 1; done
    for a in \$(aw_all_agents);   do aw_agent_module   '$REPO_ROOT_REAL' \"\$a\" >/dev/null || exit 1; done
  "
  assert_success
}

@test "aw_tracker_module names the missing file rather than letting source fail" {
  run bash -c "source '$DETECT'; aw_tracker_module '$REPO_ROOT_REAL' nosuchtracker"
  assert_failure
  assert_output --partial "no tracker module for 'nosuchtracker'"
  assert_output --partial "lib/trackers/nosuchtracker.sh"
}

@test "aw_agent_module names the missing file rather than letting source fail" {
  run bash -c "source '$DETECT'; aw_agent_module '$REPO_ROOT_REAL' nosuchagent"
  assert_failure
  assert_output --partial "no agent module for 'nosuchagent'"
  assert_output --partial "lib/agents/nosuchagent.sh"
}

# ---------------------------------------------------------------------------
# 2. No orphans: the module files and the axis names are the same set
# ---------------------------------------------------------------------------
#
# `_default.sh` is excluded by name — it is the shared base every tracker module
# layers on, not a tracker. The underscore prefix is what marks it as such, and
# this is the one place that convention is load-bearing.

@test "lib/trackers holds exactly the trackers aw_all_impls names (no orphans)" {
  local expected actual
  expected=$(bash -c "source '$DETECT'; aw_all_trackers" | sort)
  actual=$(cd "$REPO_ROOT_REAL/lib/trackers" && ls ./*.sh \
    | sed -e 's|^\./||' -e 's|\.sh$||' \
    | command grep -v '^_' | sort)
  assert_equal "$actual" "$expected"
}

@test "lib/agents holds exactly the agents aw_all_impls names (no orphans)" {
  local expected actual
  expected=$(bash -c "source '$DETECT'; aw_all_agents" | sort)
  actual=$(cd "$REPO_ROOT_REAL/lib/agents" && ls ./*.sh \
    | sed -e 's|^\./||' -e 's|\.sh$||' \
    | command grep -v '^_' | sort)
  assert_equal "$actual" "$expected"
}

# ---------------------------------------------------------------------------
# 3. Every required hook resolves, for every impl
# ---------------------------------------------------------------------------

@test "every impl composes a tracker module defining all task-done hooks" {
  local impls impl hook
  impls=$(bash -c "source '$DETECT'; aw_all_impls")
  assert [ -n "$impls" ]
  for impl in $impls; do
    for hook in "${TRACKER_HOOKS_TASK_DONE[@]}"; do
      # Composed the same way bin/task-done composes it: _default.sh first,
      # then the tracker module over the top.
      run bash -c "
        set -euo pipefail
        AW_ROOT='$REPO_ROOT_REAL'
        source '$DETECT'
        source \"\$AW_ROOT/lib/trackers/_default.sh\"
        source \"\$(aw_tracker_module \"\$AW_ROOT\" '${impl##*-}')\"
        declare -F $hook >/dev/null
      "
      # The impl and the hook are both in the message, so a failure says which
      # of the 21 combinations broke instead of just "a hook is missing".
      assert_success
      [[ "$status" -eq 0 ]] || echo "impl=$impl hook=$hook did not resolve" >&2
    done
  done
}

@test "every impl composes an agent module that loads cleanly" {
  # task-done has no agent hooks — see lib/agents/claude.sh for why — so the
  # assertion is that the module sources without error under `set -euo
  # pipefail`, not that it defines anything. #237 adds the hook list.
  local impls impl
  impls=$(bash -c "source '$DETECT'; aw_all_impls")
  for impl in $impls; do
    run bash -c "
      set -euo pipefail
      AW_ROOT='$REPO_ROOT_REAL'
      source '$DETECT'
      source \"\$(aw_agent_module \"\$AW_ROOT\" '${impl%%-*}')\"
    "
    assert_success
  done
}

# ---------------------------------------------------------------------------
# 4. The floor that makes a dropping test count trustworthy
# ---------------------------------------------------------------------------
#
# #236 deletes duplicated tests along with the duplicated code, so the suite
# total falls. That is only honest if removing a module is still caught, so:
# every module file must be load-bearing for at least one assertion. Proven by
# composing against a directory where one module has been removed and checking
# that it fails — the same thing a real deletion would do, without touching the
# checkout.

@test "removing any tracker module breaks composition for its loadouts" {
  local scratch t
  scratch="$BATS_TEST_TMPDIR/trackers"
  for t in $(bash -c "source '$DETECT'; aw_all_trackers"); do
    rm -rf "$scratch"
    mkdir -p "$scratch/lib/trackers" "$scratch/lib/agents"
    cp "$REPO_ROOT_REAL"/lib/trackers/*.sh "$scratch/lib/trackers/"
    cp "$REPO_ROOT_REAL"/lib/agents/*.sh "$scratch/lib/agents/"
    rm -f "$scratch/lib/trackers/$t.sh"
    run bash -c "source '$DETECT'; aw_tracker_module '$scratch' '$t'"
    assert_failure
    assert_output --partial "no tracker module for '$t'"
  done
}

@test "removing any agent module breaks composition for its loadouts" {
  local scratch a
  scratch="$BATS_TEST_TMPDIR/agents"
  for a in $(bash -c "source '$DETECT'; aw_all_agents"); do
    rm -rf "$scratch"
    mkdir -p "$scratch/lib/trackers" "$scratch/lib/agents"
    cp "$REPO_ROOT_REAL"/lib/trackers/*.sh "$scratch/lib/trackers/"
    cp "$REPO_ROOT_REAL"/lib/agents/*.sh "$scratch/lib/agents/"
    rm -f "$scratch/lib/agents/$a.sh"
    run bash -c "source '$DETECT'; aw_agent_module '$scratch' '$a'"
    assert_failure
    assert_output --partial "no agent module for '$a'"
  done
}

# ---------------------------------------------------------------------------
# 5. task-done refuses rather than running half-composed
# ---------------------------------------------------------------------------

@test "task-done fails loudly when its tracker module is absent" {
  # A broken checkout must not reach the cleanup code with hooks undefined:
  # under `set -u` an undefined aw_tracker_pr_section would abort mid-run, after
  # the confirmation prompt but before the worktree was removed.
  local fake="$BATS_TEST_TMPDIR/fakeroot"
  mkdir -p "$fake/bin" "$fake/lib/trackers" "$fake/lib/agents"
  cp "$REPO_ROOT_REAL/bin/task-done" "$fake/bin/task-done"
  cp "$REPO_ROOT_REAL/lib/detect-impl.sh" "$fake/lib/"
  cp "$REPO_ROOT_REAL/lib/trackers/_default.sh" "$fake/lib/trackers/"
  # gh.sh deliberately absent.
  run env AW_IMPL=claude-gh "$fake/bin/task-done" --force
  assert_failure
  assert_output --partial "no tracker module for 'gh'"
}
