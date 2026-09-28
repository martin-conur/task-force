#!/usr/bin/env bats
# A session that never registered (#229). The identity env is a command prefix on
# the `claude` process — `bash -ic "TASK_FORCE_ROLE=… ZELLIJ_TAB=… claude …"`, see
# claude-gh/bin/task-work's radio-env-injection region — so it lives in no shell
# and nothing hands it back. `SessionStart` DOES fire on resume (verified against
# all four sources: startup / resume / compact / clear), but in a new process it
# fires with an empty environment, and every radio beat keyed off the variable
# then degraded silently:
#
#   1. `send` wrote `from: unknown` into the literal `pm` inbox — shared by every
#      repo on the machine and adoptable first-come since #210
#   2. `check` exited 0 with no output while mail sat in the inbox
#   3. the role had no session file, so nothing could wake it
#   4. `register`, the documented way out, no-opped: the dispatcher gated it on
#      the very env var it exists to repair, before argument parsing
#
# The guards here are: 4 is fixed first (it is the precondition for the rest),
# the role is recovered from disk where it is derivable, refusal is LOUD where it
# is not — and #93's silence for hook entrypoints in a plain `claude` session
# survives all of it.

bats_load_library bats-support
bats_load_library bats-assert

load helpers/common

setup() {
  setup_task_force_home
  setup_repo
  unset ZELLIJ ZELLIJ_TAB TASK_FORCE_ROLE
}

teardown() {
  teardown_all
}

_log_content() { cat "$TASK_FORCE_HOME/radio/log" 2>/dev/null; }

# The role name task-work would have built for a worktree slug: the sanitized
# MAIN repo name (mktemp names carry a dot, which the role charset forbids) plus
# the slug. Derived independently of bin/radio so the assertion has teeth.
_expected_worker_role() {
  local slug="$1" rn
  rn=$(printf '%s' "$REPO_NAME" | tr '[:upper:]' '[:lower:]' | tr -d '.')
  printf 'worker-%s-%s' "$rn" "$slug"
}

_expected_pm_role() {
  local rn
  rn=$(printf '%s' "$REPO_NAME" | tr '[:upper:]' '[:lower:]' | tr -d '.')
  printf 'pm-%s' "$rn"
}

# Plant a message in <role>'s inbox without going through cmd_send (which now
# needs an identity of its own).
_put_mail() {
  local role="$1" id="$2" from="${3:-pm-somewhere}" intent="${4:-changes-requested}"
  mkdir -p "$TASK_FORCE_HOME/radio/mailbox/$role/inbox"
  cat > "$TASK_FORCE_HOME/radio/mailbox/$role/inbox/$id.md" <<EOF
---
id: $id
from: $from
to: $role
intent: $intent
created_at: 2026-09-28T12:09:35Z
---
please fix the thing
EOF
}

# ----- symptom 4: register is the precondition for every other repair --------

@test "register: an explicit --role is honoured with no \$TASK_FORCE_ROLE in the environment (#229)" {
  run env -u TASK_FORCE_ROLE "$RADIO" register --role pm-myrepo --tab pm-myrepo \
    --repo "$MAIN_REPO" --agent claude --loadout claude-gh
  assert_success
  assert [ -f "$TASK_FORCE_HOME/radio/sessions/pm-myrepo.info" ]
  run cat "$TASK_FORCE_HOME/radio/sessions/pm-myrepo.info"
  assert_output --partial "ROLE=pm-myrepo"
  assert_output --partial "LOADOUT=claude-gh"
}

@test "register: the explicit repair reports its own outcome, loudly, when TAB_ID came out empty (#229)" {
  # No zellij and no .info file to recover a binding from: the register succeeds
  # but leaves the role unwakeable, which is worse than no session at all — a
  # sender stops getting `WARNING — no session` and starts getting `queued`.
  run env -u TASK_FORCE_ROLE "$RADIO" register --role pm-myrepo --tab pm-myrepo \
    --repo "$MAIN_REPO" --agent claude
  assert_success
  assert_output --partial "EMPTY TAB_ID"
  assert_output --partial "radio unregister --manual"
}

@test "register: the explicit repair confirms a WAKEABLE role when the binding resolves (#229)" {
  # task-work's own info file is the authoritative binding (#188): with it on
  # disk the repair register recovers TAB_ID even with zellij unreachable.
  setup_worktree fix-thing
  printf 'TAB_ID=7\n' >> "$WORKTREE_BASE/.fix-thing.info"
  run env -u TASK_FORCE_ROLE "$RADIO" register --role "$(_expected_worker_role fix-thing)" \
    --tab fix-thing --repo "$WORKTREE_BASE/fix-thing" --agent claude
  assert_success
  assert_output --partial "tab_id=7"
  assert_output --partial "wakeable again"
  refute_output --partial "EMPTY TAB_ID"
}

@test "register: a plain-claude SessionStart hook is still a silent no-op — now logged (#93, #229)" {
  # The hook command is `radio register --role $TASK_FORCE_ROLE --tab $ZELLIJ_TAB
  # --repo <path> …` UNQUOTED, so with both vars unset the arguments do not go
  # empty, they VANISH: `--role` swallows `--tab`. Both shapes must stay silent.
  run env -u TASK_FORCE_ROLE -u ZELLIJ_TAB bash -c \
    "'$RADIO' register --role \$TASK_FORCE_ROLE --tab \$ZELLIJ_TAB --repo '$MAIN_REPO' --agent claude --loadout claude-gh"
  assert_success
  assert_output ""
  run bash -c "ls '$TASK_FORCE_HOME/radio/sessions/' 2>/dev/null | wc -l | tr -d ' '"
  assert_output "0"
  # ... but no longer traceless: "the hook never fired" and "the hook fired and
  # register no-opped" left identical (empty) logs, which is what cost #229
  # eleven hours of reconstruction.
  run _log_content
  assert_output --partial "register: no-op — no \$TASK_FORCE_ROLE and no valid --role in argv"
}

@test "register: an empty --role stays a silent no-op when the env has no role either (#93)" {
  run env -u TASK_FORCE_ROLE "$RADIO" register --role "" --tab t --agent claude
  assert_success
  assert_output ""
}

@test "register: --tab swallowing the next flag is named, not reported as an unknown flag (#229)" {
  # The mixed shape: $TASK_FORCE_ROLE survived, $ZELLIJ_TAB did not, so the
  # arguments shift by one and tab= the literal string "--repo".
  run env -u ZELLIJ_TAB bash -c \
    "export TASK_FORCE_ROLE=pm-myrepo; '$RADIO' register --role \$TASK_FORCE_ROLE --tab \$ZELLIJ_TAB --repo '$MAIN_REPO' --agent claude"
  assert_failure
  assert_output --partial "--tab took the next flag (--repo) as its value"
  run _log_content
  assert_output --partial "register: rejected --tab"
}

# ----- symptom 2: check must never answer "no mail" without looking ----------

@test "check: a roleless worker worktree recovers its role and finds its mail (#229)" {
  setup_worktree board-test
  local role; role=$(_expected_worker_role board-test)
  _put_mail "$role" 20260928-120935-from-pm-gp7 pm-somewhere changes-requested

  cd "$WORKTREE_BASE/board-test"
  run env -u TASK_FORCE_ROLE "$RADIO" check
  assert_success
  # The message, not just the exit status (#229's verification asks for this).
  assert_output --partial "20260928-120935-from-pm-gp7"
  assert_output --partial "intent=changes-requested"
  # And the recovered identity is named, exactly as task-work would have built it.
  assert_output --partial "Recovered role=$role"
}

@test "check: recovery keys off \$ZELLIJ_TAB when it survived, basename(worktree) when it did not (#229)" {
  setup_worktree board-test
  local role; role=$(_expected_worker_role board-test)
  _put_mail "$role" 20260928-aaa pm-somewhere approved-and-merged

  cd "$WORKTREE_BASE/board-test"
  ZELLIJ_TAB=board-test run env -u TASK_FORCE_ROLE ZELLIJ_TAB=board-test "$RADIO" check
  assert_success
  assert_output --partial "Recovered role=$role"
  assert_output --partial "20260928-aaa"
}

@test "check: a reviewer worktree recovers reviewer-<repo>-pr<N>, not worker-… (#229)" {
  # task-reviewer's slug is review-pr<N> while its role says pr<N>.
  setup_worktree review-pr41
  local rn role
  rn=$(printf '%s' "$REPO_NAME" | tr '[:upper:]' '[:lower:]' | tr -d '.')
  role="reviewer-${rn}-pr41"
  _put_mail "$role" 20260928-bbb pm-somewhere changes-requested

  cd "$WORKTREE_BASE/review-pr41"
  run env -u TASK_FORCE_ROLE "$RADIO" check
  assert_success
  assert_output --partial "Recovered role=$role"
  assert_output --partial "20260928-bbb"
}

@test "check: a recovered role with no session file is told it is unwakeable, with the repair (#229)" {
  setup_worktree board-test
  cd "$WORKTREE_BASE/board-test"
  run env -u TASK_FORCE_ROLE "$RADIO" check
  assert_success
  assert_output --partial "has no session file"
  assert_output --partial "radio register --role"
  assert_output --partial "(no unread messages)"
}

@test "check: refuses loudly — never exit 0 in silence — when no role can be derived (#229)" {
  local outside; outside=$(mktemp -d)
  cd "$outside"
  run env -u TASK_FORCE_ROLE "$RADIO" check
  assert_failure
  assert_output --partial "TASK_FORCE_ROLE"
  assert_output --partial "radio register --role"
  rm -rf "$outside"
}

@test "check: will not claim an identity whose session file is LIVE elsewhere (#229)" {
  setup_worktree board-test
  local role; role=$(_expected_worker_role board-test)
  # A fresh heartbeat can only have been written by a process that HAD the role
  # env — so this session is not that one.
  TASK_FORCE_ROLE="$role" ZELLIJ_TAB=board-test "$RADIO" register --role "$role" \
    --tab board-test --repo "$WORKTREE_BASE/board-test" --agent claude
  _put_mail "$role" 20260928-ccc pm-somewhere changes-requested

  cd "$WORKTREE_BASE/board-test"
  run env -u TASK_FORCE_ROLE "$RADIO" check
  assert_failure
  assert_output --partial "already has a live session"
  # The mail is untouched: nothing was listed, nothing was acked.
  assert [ -f "$TASK_FORCE_HOME/radio/mailbox/$role/inbox/20260928-ccc.md" ]
}

@test "check: a stale-heartbeat session file does NOT block recovery (#229)" {
  setup_worktree board-test
  local role sess; role=$(_expected_worker_role board-test)
  sess="$TASK_FORCE_HOME/radio/sessions/$role.info"
  mkdir -p "$(dirname "$sess")"
  printf 'ROLE=%s\nTAB=board-test\nTAB_ID=3\nSTATE=idle\nLAST_HEARTBEAT=2020-01-01T00:00:00Z\nAGENT=claude\n' \
    "$role" > "$sess"
  _put_mail "$role" 20260928-ddd pm-somewhere changes-requested

  cd "$WORKTREE_BASE/board-test"
  run env -u TASK_FORCE_ROLE "$RADIO" check
  assert_success
  assert_output --partial "Recovered role=$role"
  assert_output --partial "20260928-ddd"
}

@test "read: recovers the same way and still acks (#229)" {
  setup_worktree board-test
  local role; role=$(_expected_worker_role board-test)
  _put_mail "$role" 20260928-eee pm-somewhere changes-requested

  cd "$WORKTREE_BASE/board-test"
  run env -u TASK_FORCE_ROLE "$RADIO" read 20260928-eee
  assert_success
  assert_output --partial "please fix the thing"
  assert [ -f "$TASK_FORCE_HOME/radio/mailbox/$role/processed/20260928-eee.md" ]
}

@test "ack: recovers the same way and still moves the message to processed/ (#229)" {
  # `ack` goes through the identical _require_role_or_recover call site as `read`
  # above, so this is coverage rather than a second mechanism — but a behaviour
  # covered only by inspection reads as uncovered to anyone skimming for `ack`.
  setup_worktree board-test
  local role; role=$(_expected_worker_role board-test)
  _put_mail "$role" 20260928-fff0 pm-somewhere approved-and-merged

  cd "$WORKTREE_BASE/board-test"
  run env -u TASK_FORCE_ROLE "$RADIO" ack 20260928-fff0
  assert_success
  assert_output --partial "Recovered role=$role"
  assert [ -f "$TASK_FORCE_HOME/radio/mailbox/$role/processed/20260928-fff0.md" ]
  assert [ ! -f "$TASK_FORCE_HOME/radio/mailbox/$role/inbox/20260928-fff0.md" ]
}

# ----- symptom 1: never write `from: unknown` into the shared pm inbox -------

@test "send: a roleless worktree recovers its identity instead of writing from: unknown (#229)" {
  setup_worktree board-test
  local role; role=$(_expected_worker_role board-test)
  # A PM to reach, so the --to pm shim has somewhere to resolve to.
  local pm; pm=$(_expected_pm_role)
  TASK_FORCE_ROLE="$pm" "$RADIO" register --role "$pm" --tab "$pm" --repo "$MAIN_REPO" --agent claude

  cd "$WORKTREE_BASE/board-test"
  run env -u TASK_FORCE_ROLE -u TASK_FORCE_PM_ROLE "$RADIO" send --to pm \
    --intent review-requested --pr 42 --body "PR up"
  assert_success
  # Attributed, and routed to THIS repo's PM ...
  run grep -h '^from: ' "$TASK_FORCE_HOME/radio/mailbox/$pm/inbox"/*.md
  assert_output "from: $role"
  # ... with nothing left in the machine-wide literal-`pm` inbox that #210 makes
  # adoptable by whichever PM boots first, in whichever repo.
  assert [ ! -d "$TASK_FORCE_HOME/radio/mailbox/pm" ]
}

@test "send: refuses rather than send anonymously when no role can be derived (#229)" {
  local outside; outside=$(mktemp -d)
  cd "$outside"
  run env -u TASK_FORCE_ROLE -u TASK_FORCE_PM_ROLE "$RADIO" send --to pm \
    --intent review-requested --pr 42 --body "PR up"
  assert_failure
  assert_output --partial "TASK_FORCE_ROLE"
  assert [ ! -d "$TASK_FORCE_HOME/radio/mailbox/pm" ]
  rm -rf "$outside"
}

# ----- the PM arm: derivable everywhere, so corroboration-gated --------------

@test "check: a main checkout recovers pm-<reponame> when that role has radio state (#229)" {
  local pm; pm=$(_expected_pm_role)
  # A role that has ever registered leaves sidecars behind — they outlive
  # unregister by design (#188) — and that is the corroboration.
  mkdir -p "$TASK_FORCE_HOME/radio/sessions"
  printf 'claude-gh' > "$TASK_FORCE_HOME/radio/sessions/$pm.loadout"
  _put_mail "$pm" 20260928-fff worker-somewhere review-requested

  cd "$MAIN_REPO"
  run env -u TASK_FORCE_ROLE "$RADIO" check
  assert_success
  assert_output --partial "Recovered role=$pm"
  assert_output --partial "20260928-fff"
}

@test "check: a plain claude in a main checkout with no PM history claims nothing (#229)" {
  # pm-<reponame> is derivable in ANY checkout, so an uncorroborated guess would
  # let a plain `claude` session start acking a PM's mail.
  cd "$MAIN_REPO"
  run env -u TASK_FORCE_ROLE "$RADIO" check
  assert_failure
  assert_output --partial "TASK_FORCE_ROLE"
}

# ----- #93 regression guard: hook entrypoints stay silent even when a role
# ----- COULD have been derived from this very directory ----------------------

@test "hook entrypoints stay silent no-ops in a roleless worktree — recovery must not leak (#93, #229)" {
  setup_worktree board-test
  local role; role=$(_expected_worker_role board-test)
  _put_mail "$role" 20260928-ggg pm-somewhere changes-requested
  cd "$WORKTREE_BASE/board-test"

  run env -u TASK_FORCE_ROLE "$RADIO" busy
  assert_success
  assert_output ""
  run env -u TASK_FORCE_ROLE "$RADIO" ready
  assert_success
  assert_output ""
  run env -u TASK_FORCE_ROLE "$RADIO" awaiting
  assert_success
  assert_output ""
  run bash -c "echo '{}' | env -u TASK_FORCE_ROLE '$RADIO' prompt-hook"
  assert_success
  assert_output ""
  run bash -c "echo '{}' | env -u TASK_FORCE_ROLE '$RADIO' stop-hook"
  assert_success
  assert_output ""
  run env -u TASK_FORCE_ROLE "$RADIO" unregister
  assert_success
  assert_output ""

  # No session file was invented, and the mail is exactly where it was.
  assert [ ! -f "$TASK_FORCE_HOME/radio/sessions/$role.info" ]
  assert [ -f "$TASK_FORCE_HOME/radio/mailbox/$role/inbox/20260928-ggg.md" ]
}
