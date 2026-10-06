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
# cannot see it. The behavioural halves live in `tests/task_done.bats` (the jira
# PR title, the local board + state.json) and `tests/task_work_impls.bats` (one
# row per impl: its .info key, its agent's launch line, its --help), each an
# impl-distinguishing observable a failed module load could not produce. Both
# halves, or neither means anything.

bats_load_library bats-support
bats_load_library bats-assert

load helpers/common

DETECT="$REPO_ROOT_REAL/lib/detect-impl.sh"

# The hooks a composed loadout must provide, per leaf script. Keep them literals
# here rather than deriving them from the modules, since a list derived from the
# thing under test asserts nothing.
TRACKER_HOOKS_TASK_DONE=(
  aw_tracker_usage_steps
  aw_tracker_pr_section
  aw_tracker_post_cleanup
)
TRACKER_HOOKS_TASK_WORK=(
  aw_tracker_usage_synopsis
  aw_tracker_usage_notes
  aw_tracker_usage_examples
  aw_tracker_is_ref
  aw_tracker_ref_slug
  aw_tracker_parse_ref
  aw_tracker_info_key
  aw_tracker_worker_prompt
  aw_tracker_post_worktree
)
# No _default.sh on the agent axis: every agent module defines every hook, so
# this list is what a new agent module has to implement.
AGENT_HOOKS_TASK_WORK=(
  aw_agent_name
  aw_agent_usage_options
  aw_agent_usage_env
  aw_agent_usage_examples
  aw_agent_init_flags
  aw_agent_parse_flag
  aw_agent_validate_flags
  aw_agent_preflight
  aw_agent_launch_cmd
  aw_agent_started_message
)
# What bin/task-recreate-worker asks of an agent beyond task-work's list (#239).
AGENT_HOOKS_TASK_RECREATE_WORKER=(
  aw_agent_resume_cmd
)

# Compose <impl> the way the leaf scripts do — _default.sh, then the tracker
# module, then the agent module — and run <cmd> in that shell.
_compose() {
  local impl="$1" cmd="$2"
  bash -c "
    set -euo pipefail
    AW_ROOT='$REPO_ROOT_REAL'
    source '$DETECT'
    source \"\$AW_ROOT/lib/trackers/_default.sh\"
    source \"\$(aw_tracker_module \"\$AW_ROOT\" '${impl##*-}')\"
    source \"\$(aw_agent_module   \"\$AW_ROOT\" '${impl%%-*}')\"
    $cmd
  "
}

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

# These two exercise the helper DIRECTLY, and their names say so. The previous
# names claimed the helper stopped `source` from failing, which is a claim about
# the call site and was not what they checked — a green suite would have told the
# next reader something untrue. The call-site behaviour is pinned separately, at
# the bottom of this file, by running the real bin/task-done.
@test "aw_tracker_module itself names the missing file and fails" {
  run bash -c "source '$DETECT'; aw_tracker_module '$REPO_ROOT_REAL' nosuchtracker"
  assert_failure
  assert_output --partial "no tracker module for 'nosuchtracker'"
  assert_output --partial "lib/trackers/nosuchtracker.sh"
}

@test "aw_agent_module itself names the missing file and fails" {
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

@test "every impl composes a tracker module defining all task-work hooks" {
  local impls impl hook
  impls=$(bash -c "source '$DETECT'; aw_all_impls")
  assert [ -n "$impls" ]
  for impl in $impls; do
    for hook in "${TRACKER_HOOKS_TASK_WORK[@]}"; do
      run _compose "$impl" "declare -F $hook >/dev/null"
      [[ "$status" -eq 0 ]] || { echo "impl=$impl hook=$hook did not resolve" >&2; return 1; }
    done
  done
}

@test "every impl composes an agent module defining all task-work hooks" {
  local impls impl hook
  impls=$(bash -c "source '$DETECT'; aw_all_impls")
  assert [ -n "$impls" ]
  for impl in $impls; do
    for hook in "${AGENT_HOOKS_TASK_WORK[@]}"; do
      run _compose "$impl" "declare -F $hook >/dev/null"
      [[ "$status" -eq 0 ]] || { echo "impl=$impl hook=$hook did not resolve" >&2; return 1; }
    done
  done
}

@test "every impl composes an agent module defining all task-recreate-worker hooks" {
  local impls impl hook
  impls=$(bash -c "source '$DETECT'; aw_all_impls")
  assert [ -n "$impls" ]
  for impl in $impls; do
    for hook in "${AGENT_HOOKS_TASK_RECREATE_WORKER[@]}"; do
      run _compose "$impl" "declare -F $hook >/dev/null"
      [[ "$status" -eq 0 ]] || { echo "impl=$impl hook=$hook did not resolve" >&2; return 1; }
    done
  done
}

# `declare -F` cannot tell a module's own definition from _default.sh's, and the
# info key is the one tracker hook whose default refuses. Every tracker must
# override it, or task-work stops before creating anything.
@test "every tracker names its own .info key" {
  local impl
  for impl in $(bash -c "source '$DETECT'; aw_all_impls"); do
    run _compose "$impl" "aw_tracker_info_key"
    [[ "$status" -eq 0 && "$output" =~ ^[A-Z_]+$ ]] || {
      echo "impl=$impl: aw_tracker_info_key -> status=$status output=$output" >&2; return 1; }
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

# Build a checkout of bin/task-done with one tracker module missing. Prints the
# fake root; the caller runs the script out of it.
_fakeroot_without_tracker() {
  local tracker="$1" fake="$BATS_TEST_TMPDIR/fakeroot-$tracker"
  rm -rf "$fake"
  mkdir -p "$fake/bin" "$fake/lib/trackers" "$fake/lib/agents"
  cp "$REPO_ROOT_REAL/bin/task-done" "$fake/bin/task-done"
  cp "$REPO_ROOT_REAL/lib/detect-impl.sh" "$fake/lib/"
  cp "$REPO_ROOT_REAL/lib/trackers/"*.sh "$fake/lib/trackers/"
  cp "$REPO_ROOT_REAL/lib/agents/"*.sh "$fake/lib/agents/"
  rm -f "$fake/lib/trackers/$tracker.sh"
  printf '%s' "$fake"
}

@test "task-done fails loudly when its tracker module is absent" {
  # A broken checkout must not reach the cleanup code with hooks undefined:
  # under `set -u` an undefined aw_tracker_pr_section would abort mid-run, after
  # the confirmation prompt but before the worktree was removed.
  local fake
  fake=$(_fakeroot_without_tracker gh)
  run env AW_IMPL=claude-gh "$fake/bin/task-done" --force
  assert_failure
  assert_output --partial "no tracker module for 'gh'"
}

@test "task-done's module diagnosis is not buried under shell noise" {
  # The call-site assertion, and the reason it is separate from the two helper
  # tests above. `source "$(aw_tracker_module …)" || exit 1` reads as equivalent
  # to resolve-then-source and is not: the command substitution yields the empty
  # string before `|| exit 1` is reached, so `source ""` runs and bash appends
  # `: No such file or directory` naming a line in task-done. The helper tests
  # pass either way — they never touch the call site — so without this one a
  # green suite would have implied a clean error the user does not actually get.
  #
  # Pin the message bash actually emits. The first draft of this test asserted
  # `source: : not found`, which is what the review described and not what bash
  # says; it therefore passed against the very call site it was written to
  # reject. Verified by hand against both call-site forms before landing.
  local fake
  fake=$(_fakeroot_without_tracker gh)
  run env AW_IMPL=claude-gh "$fake/bin/task-done" --force
  assert_failure
  assert_output --partial "no tracker module for 'gh'"
  refute_output --partial "No such file or directory"
}

@test "every tracker is resolved before it is sourced, for every loadout" {
  # Same property as above, swept across all four trackers rather than just gh,
  # so a future call site added for one tracker cannot regress unnoticed.
  local t fake
  for t in $(bash -c "source '$DETECT'; aw_all_trackers"); do
    fake=$(_fakeroot_without_tracker "$t")
    run env AW_IMPL="claude-$t" "$fake/bin/task-done" --force
    assert_failure
    assert_output --partial "no tracker module for '$t'"
    refute_output --partial "No such file or directory"
  done
}

# ---------------------------------------------------------------------------
# 6. task-work refuses rather than running half-composed (#237)
# ---------------------------------------------------------------------------

# A checkout of bin/task-work (and the libs it sources) with one module removed.
# <kind> is trackers or agents. [<script>] picks another composing leaf script.
_tw_fakeroot_without() {
  local kind="$1" name="$2" script="${3:-task-work}"
  local fake="$BATS_TEST_TMPDIR/fakeroot-$script-$1-$2"
  rm -rf "$fake"
  mkdir -p "$fake/bin" "$fake/lib"
  cp "$REPO_ROOT_REAL/bin/$script" "$fake/bin/$script"
  cp "$REPO_ROOT_REAL/lib/"*.sh "$fake/lib/"
  cp -R "$REPO_ROOT_REAL/lib/trackers" "$REPO_ROOT_REAL/lib/agents" "$fake/lib/"
  rm -f "$fake/lib/$kind/$name.sh"
  printf '%s' "$fake"
}

_tw_repo() {
  local repo="$BATS_TEST_TMPDIR/$1"
  git init -q -b main "$repo"
  git -C "$repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  printf '%s' "$repo"
}

# The floor that makes the dropped task-work test count honest: deleting a
# module must fail a run of the real script, cleanly and before any worktree
# exists. Swept over every axis value, so it covers at least one tracker and one
# agent module as #237 asks, and every other one with them.
@test "task-work fails cleanly, creating nothing, when any tracker module is absent" {
  local t fake repo
  for t in $(bash -c "source '$DETECT'; aw_all_trackers"); do
    fake=$(_tw_fakeroot_without trackers "$t")
    repo=$(_tw_repo "repo-t-$t")
    run bash -c "cd '$repo' && AW_IMPL=claude-$t '$fake/bin/task-work' some-slug"
    assert_failure
    assert_output --partial "no tracker module for '$t'"
    refute_output --partial "No such file or directory"
    assert [ ! -e "$repo-worktrees" ]
  done
}

@test "task-work fails cleanly, creating nothing, when any agent module is absent" {
  local a fake repo
  for a in $(bash -c "source '$DETECT'; aw_all_agents"); do
    fake=$(_tw_fakeroot_without agents "$a")
    repo=$(_tw_repo "repo-a-$a")
    run bash -c "cd '$repo' && AW_IMPL=$a-gh '$fake/bin/task-work' some-slug"
    assert_failure
    assert_output --partial "no agent module for '$a'"
    refute_output --partial "No such file or directory"
    assert [ ! -e "$repo-worktrees" ]
  done
}

@test "task-work refuses before creating anything when a tracker names no .info key" {
  local fake repo
  fake=$(_tw_fakeroot_without trackers none)
  # Strip gh's key override so the refusing default in _default.sh shows through.
  sed -i.bak '/^aw_tracker_info_key()/d' "$fake/lib/trackers/gh.sh"
  repo=$(_tw_repo repo-nokey)
  run bash -c "cd '$repo' && AW_IMPL=claude-gh '$fake/bin/task-work' some-slug"
  assert_failure
  assert_output --partial "defines no .info key"
  assert [ ! -e "$repo-worktrees" ]
}

# ---------------------------------------------------------------------------
# 7. task-recreate-worker composes the same modules (#239)
# ---------------------------------------------------------------------------

# Its module resolution runs before the worktree lookup, so the slug here need
# not exist: the absent module must be named, not "no worktree for slug".
@test "task-recreate-worker fails on the module, not on shell noise, when any module is absent" {
  local kind name names fake repo
  for kind in trackers agents; do
    if [[ "$kind" == trackers ]]; then
      names=$(bash -c "source '$DETECT'; aw_all_trackers")
    else
      names=$(bash -c "source '$DETECT'; aw_all_agents")
    fi
    for name in $names; do
      fake=$(_tw_fakeroot_without "$kind" "$name" task-recreate-worker)
      repo=$(_tw_repo "repo-rw-$kind-$name")
      local impl="claude-$name"
      [[ "$kind" == agents ]] && impl="$name-gh"
      run bash -c "cd '$repo' && AW_IMPL=$impl '$fake/bin/task-recreate-worker' some-slug"
      assert_failure
      assert_output --partial "no ${kind%s} module for '$name'"
      refute_output --partial "No such file or directory"
      refute_output --partial "no worktree for slug"
    done
  done
}
