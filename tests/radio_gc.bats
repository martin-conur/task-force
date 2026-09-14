#!/usr/bin/env bats
# Tests for `radio gc` (#169): sweep dead mailboxes, expire old processed
# messages, rotate the log, and reject leading-dash roles. Mailbox rooted at a
# tempdir via $TASK_FORCE_HOME.

bats_load_library bats-support
bats_load_library bats-assert

load helpers/common

setup() {
  setup_task_force_home
  unset ZELLIJ
  export TASK_FORCE_ROLE=test-runner
  MAILBOX="$TASK_FORCE_HOME/radio/mailbox"
  SESSIONS="$TASK_FORCE_HOME/radio/sessions"
  DEADLETTER="$TASK_FORCE_HOME/radio/dead-letter"
  REPORT="$TASK_FORCE_HOME/radio/.dead-letter-report"
  # put_mail stamps `from: pm-task-force`, so its reports route to that PM.
  REPORT_PM="$TASK_FORCE_HOME/radio/.dead-letter-report-pm-task-force"
  LOG="$TASK_FORCE_HOME/radio/log"
  mkdir -p "$MAILBOX" "$SESSIONS"
}

teardown() {
  teardown_all
}

# --- helpers ---------------------------------------------------------------

# A timestamp comfortably older than any sane --max-age-days default.
OLD_TS=202001010000

# Seed a role mailbox dir with inbox + processed subdirs.
seed_mailbox() {
  local role="$1"
  mkdir -p "$MAILBOX/$role/inbox" "$MAILBOX/$role/processed"
}

# Write a session file with a FRESH heartbeat so a role counts as live.
seed_session() {
  local role="$1"
  printf 'ROLE=%s\nSTATE=idle\nLAST_HEARTBEAT=%s\n' \
    "$role" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$SESSIONS/$role.info"
}

# Write a session file whose heartbeat is ancient (>1h stale → dead per _session_dead).
seed_stale_session() {
  local role="$1"
  printf 'ROLE=%s\nSTATE=busy\nLAST_HEARTBEAT=2020-01-01T00:00:00Z\n' \
    "$role" > "$SESSIONS/$role.info"
}

# Drop a message file and age it (default: OLD_TS).
put_msg() {
  local path="$1" ts="${2:-}"
  printf 'body\n' > "$path"
  [[ -n "$ts" ]] && touch -t "$ts" "$path"
  return 0
}

# --- dead-role sweep -------------------------------------------------------

@test "gc removes a dead role's mailbox (no session, old entries)" {
  seed_mailbox deadworker
  put_msg "$MAILBOX/deadworker/processed/old.md" "$OLD_TS"
  run "$RADIO" gc
  assert_success
  assert [ ! -d "$MAILBOX/deadworker" ]
  assert_output --partial "deadworker"
}

@test "gc keeps a live role's mailbox (session file present)" {
  seed_mailbox liveworker
  seed_session liveworker
  put_msg "$MAILBOX/liveworker/processed/old.md" "$OLD_TS"
  run "$RADIO" gc
  assert_success
  assert [ -d "$MAILBOX/liveworker" ]
}

@test "gc keeps a dead role with a fresh inbox message" {
  seed_mailbox freshdead
  put_msg "$MAILBOX/freshdead/inbox/new.md"   # current mtime
  run "$RADIO" gc
  assert_success
  assert [ -d "$MAILBOX/freshdead" ]
}

@test "gc preserves the literal pm role's UNREAD inbox even when aged (the #182 backlog guard)" {
  # No session file, but the inbox still holds undelivered mail (aged). The
  # legacy `pm` backlog is exempt from dead-lettering: it is write-only post-#165
  # and waiting for the first repo-scoped PM to adopt it, so archiving it would
  # short-circuit that migration. Neither the reclaim nor the archive may fire.
  seed_mailbox pm
  put_msg "$MAILBOX/pm/inbox/old.md" "$OLD_TS"
  run "$RADIO" gc
  assert_success
  assert [ -d "$MAILBOX/pm" ]
  assert [ -f "$MAILBOX/pm/inbox/old.md" ]
  assert [ ! -d "$DEADLETTER/pm" ]
}

@test "gc still reclaims the literal pm mailbox once its inbox is EMPTY (#201 review #1)" {
  # The exemption above covers dead-lettering only. A drained `pm` — which is the
  # state right after #182's adoption runs — is an ordinary dead role with an
  # empty inbox, and reclaiming it was already legal pre-#201. Exempting the whole
  # role would re-create this ticket's bug for one mailbox.
  seed_mailbox pm
  touch -t "$OLD_TS" "$MAILBOX/pm" "$MAILBOX/pm/inbox" "$MAILBOX/pm/processed"
  run "$RADIO" gc
  assert_success
  assert_output --partial "remove dead mailbox: pm"
  assert [ ! -d "$MAILBOX/pm" ]
}

@test "gc reclaims a role whose heartbeat is >1h stale (empty inbox, aged)" {
  seed_mailbox crashed
  seed_stale_session crashed
  put_msg "$MAILBOX/crashed/processed/old.md" "$OLD_TS"
  run "$RADIO" gc
  assert_success
  assert [ ! -d "$MAILBOX/crashed" ]
}

@test "gc dead-letters a stale-heartbeat role's aged unread mail, then reclaims it (#201)" {
  seed_mailbox crashed2
  seed_stale_session crashed2
  put_msg "$MAILBOX/crashed2/inbox/pending.md" "$OLD_TS"   # unread + aged
  run "$RADIO" gc
  assert_success
  assert [ ! -d "$MAILBOX/crashed2" ]
  assert [ -f "$DEADLETTER/crashed2/pending.md" ]
}

@test "gc keeps a role with a fresh heartbeat (not dead), aged mail notwithstanding" {
  seed_mailbox liveworker
  seed_session liveworker   # fresh heartbeat
  put_msg "$MAILBOX/liveworker/inbox/old.md" "$OLD_TS"
  run "$RADIO" gc
  assert_success
  assert [ -d "$MAILBOX/liveworker" ]
}

@test "gc never touches session files (the #127 boundary)" {
  seed_session liveworker
  seed_mailbox liveworker
  seed_stale_session crashed        # gc reclaims its mailbox but not its .info
  seed_mailbox crashed
  put_msg "$MAILBOX/crashed/processed/old.md" "$OLD_TS"
  run "$RADIO" gc
  assert_success
  assert [ -f "$SESSIONS/liveworker.info" ]
  assert [ -f "$SESSIONS/crashed.info" ]
}

@test "gc keeps a freshly-created empty dead dir (dir mtime is recent)" {
  seed_mailbox brandnew   # empty, just mkdir'd -> recent dir mtime
  run "$RADIO" gc
  assert_success
  assert [ -d "$MAILBOX/brandnew" ]
}

@test "gc removes an aged empty dead dir (no entries, old dir mtime)" {
  seed_mailbox stale
  touch -t "$OLD_TS" "$MAILBOX/stale" "$MAILBOX/stale/inbox" "$MAILBOX/stale/processed"
  run "$RADIO" gc
  assert_success
  assert [ ! -d "$MAILBOX/stale" ]
}

# --- processed TTL on live roles ------------------------------------------

@test "gc expires old processed messages but keeps recent ones on a live role" {
  seed_mailbox liveworker
  seed_session liveworker
  put_msg "$MAILBOX/liveworker/processed/old.md" "$OLD_TS"
  put_msg "$MAILBOX/liveworker/processed/new.md"   # current mtime
  run "$RADIO" gc
  assert_success
  assert [ ! -f "$MAILBOX/liveworker/processed/old.md" ]
  assert [ -f "$MAILBOX/liveworker/processed/new.md" ]
}

@test "gc never touches inbox messages (only processed)" {
  seed_mailbox liveworker
  seed_session liveworker
  put_msg "$MAILBOX/liveworker/inbox/old.md" "$OLD_TS"
  run "$RADIO" gc
  assert_success
  assert [ -f "$MAILBOX/liveworker/inbox/old.md" ]
}

# --- sidecar reclaim (#188) ------------------------------------------------

@test "gc sweeps the loadout + agent sidecars of a role whose mailbox it reclaims (#188)" {
  # Sidecars now outlive `unregister` (#188), so gc is the only thing keeping
  # them from accumulating one pair per retired worker slug forever.
  seed_mailbox deadworker
  put_msg "$MAILBOX/deadworker/processed/old.md" "$OLD_TS"
  printf 'claude-gh' > "$SESSIONS/deadworker.loadout"
  printf 'claude'    > "$SESSIONS/deadworker.agent"

  run "$RADIO" gc
  assert_success
  assert [ ! -d "$MAILBOX/deadworker" ]
  assert [ ! -f "$SESSIONS/deadworker.loadout" ]
  assert [ ! -f "$SESSIONS/deadworker.agent" ]
}

@test "gc keeps sidecars for a stale-heartbeat role that still has a session file (#188)" {
  # _session_dead also fires on a >1h-stale heartbeat, but sweeping sidecars on
  # that arm would re-create the exact bug #188 fixes: a live-but-quiet role
  # whose next re-seed then writes LOADOUT=unknown. Sidecars go only when there
  # is no session file at all.
  seed_mailbox staleworker
  seed_stale_session staleworker
  put_msg "$MAILBOX/staleworker/processed/old.md" "$OLD_TS"
  printf 'claude-gh' > "$SESSIONS/staleworker.loadout"
  printf 'claude'    > "$SESSIONS/staleworker.agent"

  run "$RADIO" gc
  assert_success
  assert [ ! -d "$MAILBOX/staleworker" ]   # mailbox reclaim is unchanged
  assert [ -f "$SESSIONS/staleworker.loadout" ]
  assert [ -f "$SESSIONS/staleworker.agent" ]
}

@test "gc --dry-run leaves sidecars alone (#188)" {
  seed_mailbox deadworker
  put_msg "$MAILBOX/deadworker/processed/old.md" "$OLD_TS"
  printf 'claude-gh' > "$SESSIONS/deadworker.loadout"

  run "$RADIO" gc --dry-run
  assert_success
  assert [ -f "$SESSIONS/deadworker.loadout" ]
}

# --- dead-letter (#201) ----------------------------------------------------

# Write a realistic message (frontmatter + body) into a role's inbox and age it.
put_mail() {
  local role="$1" id="$2" ts="${3:-$OLD_TS}"
  cat > "$MAILBOX/$role/inbox/$id.md" <<EOF
---
id: $id
from: pm-task-force
to: $role
intent: approved-and-merged
pr: 164
created_at: 2026-07-07T21:53:55Z
---
merged — squashed to main. Run \`task-done --remove-worktree\`.
EOF
  touch -t "$ts" "$MAILBOX/$role/inbox/$id.md"
}

# Same, with an explicit `from:` and an optional `repo:` — the two fields
# _dead_letter_owner routes the report on (#201 review #2).
put_mail_from() {
  local role="$1" id="$2" from="$3" repo="${4:-}"
  {
    printf -- '---\nid: %s\nfrom: %s\nto: %s\nintent: approved-and-merged\n' "$id" "$from" "$role"
    [[ -n "$repo" ]] && printf 'repo: %s\n' "$repo"
    printf -- 'created_at: 2026-07-07T21:53:55Z\n---\nmerged.\n'
  } > "$MAILBOX/$role/inbox/$id.md"
  touch -t "$OLD_TS" "$MAILBOX/$role/inbox/$id.md"
  return 0
}

@test "gc archives a dead role's aged unread mail and then reclaims the mailbox (#201)" {
  # The headline case: mail addressed to a role that has exited was immortal —
  # protected by the very sweep meant to clean it up.
  seed_mailbox worker-gone
  put_mail worker-gone 20260707-215355-from-pm-abc123
  run "$RADIO" gc
  assert_success
  assert_output --partial "dead-letter: worker-gone/20260707-215355-from-pm-abc123.md"
  assert_output --partial "remove dead mailbox: worker-gone"
  assert [ ! -d "$MAILBOX/worker-gone" ]
  assert [ -f "$DEADLETTER/worker-gone/20260707-215355-from-pm-abc123.md" ]
}

@test "an archived message keeps its id and frontmatter (#201)" {
  seed_mailbox worker-gone
  put_mail worker-gone 20260707-215355-from-pm-abc123
  run "$RADIO" gc
  assert_success
  run cat "$DEADLETTER/worker-gone/20260707-215355-from-pm-abc123.md"
  assert_output --partial "id: 20260707-215355-from-pm-abc123"
  assert_output --partial "from: pm-task-force"
  assert_output --partial "intent: approved-and-merged"
  assert_output --partial "pr: 164"
  assert_output --partial 'task-done --remove-worktree'
}

@test "gc never dead-letters a LIVE role's inbox, however aged (#201)" {
  # The guarantee that motivated _inbox_empty in the first place.
  seed_mailbox liveworker
  seed_session liveworker
  put_mail liveworker 20260707-215355-from-pm-abc123
  run "$RADIO" gc
  assert_success
  refute_output --partial "dead-letter:"
  assert [ -f "$MAILBOX/liveworker/inbox/20260707-215355-from-pm-abc123.md" ]
  assert [ ! -d "$DEADLETTER/liveworker" ]
}

@test "gc leaves a dead role's mail alone while it is inside the cutoff (#201)" {
  # It may yet come back — only mail that has aged out is archived.
  seed_mailbox recentdead
  put_mail recentdead 20260914-120000-from-pm-zzz999 "$(date -u +%Y%m%d%H%M)"
  run "$RADIO" gc
  assert_success
  refute_output --partial "dead-letter:"
  assert [ -f "$MAILBOX/recentdead/inbox/20260914-120000-from-pm-zzz999.md" ]
  assert [ ! -d "$DEADLETTER/recentdead" ]
}

@test "gc --dry-run reports the archive and the reclaim without performing either (#201)" {
  seed_mailbox worker-gone
  put_mail worker-gone 20260707-215355-from-pm-abc123
  run "$RADIO" gc --dry-run
  assert_success
  assert_output --partial "[dry-run] dead-letter: worker-gone/20260707-215355-from-pm-abc123.md"
  assert_output --partial "[dry-run] remove dead mailbox: worker-gone"
  assert [ -f "$MAILBOX/worker-gone/inbox/20260707-215355-from-pm-abc123.md" ]
  assert [ ! -d "$DEADLETTER" ]
  assert [ ! -f "$REPORT" ]
}

@test "the gc summary counts dead-lettered messages (#201)" {
  seed_mailbox worker-gone
  put_mail worker-gone 20260707-215355-from-pm-abc123
  put_mail worker-gone 20260707-215356-from-pm-def456
  run "$RADIO" gc
  assert_success
  assert_output --partial "2 dead-lettered message(s)"
}

@test "dead-lettering is collision-safe (#201)" {
  # A name already present in the archive must not strand the message in the
  # inbox — that is the immortal-mailbox state this exists to end.
  seed_mailbox worker-gone
  put_mail worker-gone 20260707-215355-from-pm-abc123
  mkdir -p "$DEADLETTER/worker-gone"
  printf 'pre-existing\n' > "$DEADLETTER/worker-gone/20260707-215355-from-pm-abc123.md"
  run "$RADIO" gc
  assert_success
  assert [ ! -d "$MAILBOX/worker-gone" ]
  run bash -c "ls '$DEADLETTER/worker-gone' | wc -l | tr -d ' '"
  assert_output "2"
  run cat "$DEADLETTER/worker-gone/20260707-215355-from-pm-abc123.md"
  assert_output --partial "pre-existing"
}

@test "gc logs each dead-lettered message (#201)" {
  seed_mailbox worker-gone
  put_mail worker-gone 20260707-215355-from-pm-abc123
  "$RADIO" gc >/dev/null
  run grep -cF 'gc: dead-lettered role=worker-gone msg=20260707-215355-from-pm-abc123.md' "$LOG"
  assert_success
  refute_output "0"
}

# --- surfacing the count to the PM (#201 acceptance 5) ---------------------

@test "a fresh PM register surfaces the dead-letter count and consumes the report (#201)" {
  seed_mailbox worker-gone
  put_mail worker-gone 20260707-215355-from-pm-abc123
  "$RADIO" gc >/dev/null
  assert [ -f "$REPORT_PM" ]

  run "$RADIO" register --role pm-task-force --tab pm --agent claude
  assert_success
  assert_output --partial "1 message(s) addressed to 1 role(s) that had already exited were never delivered"
  assert_output --partial "worker-gone"
  assert_output --partial "dead-letter"
  assert [ ! -f "$REPORT_PM" ]
}

@test "the dead-letter report is surfaced once, not on every boot (#201)" {
  seed_mailbox worker-gone
  put_mail worker-gone 20260707-215355-from-pm-abc123
  "$RADIO" gc >/dev/null
  "$RADIO" register --role pm-task-force --tab pm --agent claude >/dev/null
  # A later fresh register of the same PM finds the report consumed.
  rm -f "$SESSIONS/pm-task-force.info"
  run "$RADIO" register --role pm-task-force --tab pm --agent claude
  assert_success
  refute_output --partial "never delivered"
}

@test "a worker register never consumes the PM's dead-letter report (#201)" {
  seed_mailbox worker-gone
  put_mail worker-gone 20260707-215355-from-pm-abc123
  "$RADIO" gc >/dev/null
  run "$RADIO" register --role worker-repo-slug --tab w --agent claude
  assert_success
  refute_output --partial "never delivered"
  assert [ -f "$REPORT_PM" ]
}

@test "a PM in another repo does not consume this repo's dead-letter report (#201 review #2)" {
  # $RADIO_HOME is shared machine-wide. A global sentinel would let whichever PM
  # registered first eat a report about another repo's roles — the same
  # cross-repo class as #182's adoption bug.
  seed_mailbox worker-task-force-slug
  put_mail_from worker-task-force-slug 20260707-215355-from-pm-abc pm-task-force
  "$RADIO" gc >/dev/null
  assert [ -f "$TASK_FORCE_HOME/radio/.dead-letter-report-pm-task-force" ]

  run "$RADIO" register --role pm-recommender-systems --tab pm2 --agent claude
  assert_success
  refute_output --partial "never delivered"
  assert [ -f "$TASK_FORCE_HOME/radio/.dead-letter-report-pm-task-force" ]

  run "$RADIO" register --role pm-task-force --tab pm --agent claude
  assert_success
  assert_output --partial "never delivered"
  assert_output --partial "worker-task-force-slug"
  assert [ ! -f "$TASK_FORCE_HOME/radio/.dead-letter-report-pm-task-force" ]
}

@test "an explicit repo: field outranks from: when routing the report (#201 review #2)" {
  seed_mailbox worker-gone
  put_mail_from worker-gone 20260707-215355-from-pm-abc pm-task-force /src/recommender-systems
  "$RADIO" gc >/dev/null
  assert [ -f "$TASK_FORCE_HOME/radio/.dead-letter-report-pm-recommender-systems" ]
  assert [ ! -f "$TASK_FORCE_HOME/radio/.dead-letter-report-pm-task-force" ]
}

@test "a dead PM's own inbox reports to that PM (#201 review #2)" {
  # The mirror case: a worker's report to a PM that had already exited. `from:`
  # is not a PM, so the dead role itself is the owner.
  seed_mailbox pm-task-force
  put_mail_from pm-task-force 20260707-215355-from-worker-x worker-task-force-slug
  "$RADIO" gc >/dev/null
  assert [ -f "$TASK_FORCE_HOME/radio/.dead-letter-report-pm-task-force" ]
  run "$RADIO" register --role pm-task-force --tab pm --agent claude
  assert_success
  assert_output --partial "never delivered"
}

@test "an unattributable message lands in the unscoped report any PM may claim (#201 review #2)" {
  seed_mailbox worker-gone
  put_mail_from worker-gone 20260707-215355-from-unknown unknown
  "$RADIO" gc >/dev/null
  assert [ -f "$TASK_FORCE_HOME/radio/.dead-letter-report" ]
  run "$RADIO" register --role pm-anyrepo --tab pm --agent claude
  assert_success
  # Named, so a PM reading someone else's entry can at least tell whose it is.
  assert_output --partial "worker-gone"
}

@test "a PM claims the reports of its --also aliases too (#201 review #2)" {
  # An alias address never fresh-registers, so a report scoped to it would sit
  # unread forever. The primary answers for it, so the primary claims it.
  seed_mailbox worker-other-slug
  put_mail_from worker-other-slug 20260707-215355-from-pm-o pm-otherrepo
  "$RADIO" gc >/dev/null
  assert [ -f "$TASK_FORCE_HOME/radio/.dead-letter-report-pm-otherrepo" ]
  printf 'pm-otherrepo|/src/otherrepo\n' > "$SESSIONS/pm-task-force.aliases"

  run "$RADIO" register --role pm-task-force --tab pm --agent claude
  assert_success
  assert_output --partial "worker-other-slug"
  assert [ ! -f "$TASK_FORCE_HOME/radio/.dead-letter-report-pm-otherrepo" ]
}

@test "a register with nothing dead-lettered prints no report line (#201)" {
  run "$RADIO" register --role pm-thisrepo --tab pm --agent claude
  assert_success
  refute_output --partial "never delivered"
}

# --- dry-run ---------------------------------------------------------------

@test "gc --dry-run reports but does not delete" {
  seed_mailbox deadworker
  put_msg "$MAILBOX/deadworker/processed/old.md" "$OLD_TS"
  seed_mailbox liveworker
  seed_session liveworker
  put_msg "$MAILBOX/liveworker/processed/old.md" "$OLD_TS"
  run "$RADIO" gc --dry-run
  assert_success
  assert_output --partial "dry-run"
  assert [ -d "$MAILBOX/deadworker" ]
  assert [ -f "$MAILBOX/liveworker/processed/old.md" ]
}

# --- --max-age-days --------------------------------------------------------

@test "gc --max-age-days can spare an old file with a huge window" {
  seed_mailbox liveworker
  seed_session liveworker
  put_msg "$MAILBOX/liveworker/processed/old.md" "$OLD_TS"
  run "$RADIO" gc --max-age-days 100000
  assert_success
  assert [ -f "$MAILBOX/liveworker/processed/old.md" ]
}

@test "gc rejects a non-numeric --max-age-days" {
  run "$RADIO" gc --max-age-days abc
  assert_failure
}

# --- log rotation ----------------------------------------------------------

@test "gc rotates the log when it exceeds ~1MB" {
  head -c 1200000 /dev/zero | tr '\0' 'a' > "$LOG"
  run "$RADIO" gc
  assert_success
  local size
  size=$(wc -c < "$LOG")
  [ "$size" -lt 1100000 ]
}

@test "gc leaves a small log untouched" {
  printf 'small log line\n' > "$LOG"
  local before
  before=$(wc -c < "$LOG")
  run "$RADIO" gc
  assert_success
  # gc itself may append its own log lines; assert we didn't truncate.
  local after
  after=$(wc -c < "$LOG")
  [ "$after" -ge "$before" ]
}

# --- leading-dash role rejection (#169 item 3) -----------------------------

@test "send rejects a recipient role with a leading dash" {
  TASK_FORCE_ROLE=worker-foo run "$RADIO" send --to "--tab" --intent ping --body x
  assert_failure
  assert_output --partial "invalid role"
}

@test "register rejects a role with a leading dash" {
  run "$RADIO" register --role "--tab" --tab pm --agent claude
  assert_failure
  assert_output --partial "invalid role"
}

@test "self-identifying commands reject a leading-dash \$TASK_FORCE_ROLE" {
  TASK_FORCE_ROLE="-tab" run "$RADIO" check
  assert_failure
  assert_output --partial "invalid role"
}

# --- register-time piggyback + throttle (#169 item 5 / #184 review #4) -------

@test "a fresh register runs gc and writes the .gc-last sentinel" {
  seed_mailbox deadworker
  put_msg "$MAILBOX/deadworker/processed/old.md" "$OLD_TS"
  run "$RADIO" register --role pm-thisrepo --tab pm --agent claude
  assert_success
  assert [ ! -d "$MAILBOX/deadworker" ]
  assert [ -f "$TASK_FORCE_HOME/radio/.gc-last" ]
}

@test "the register gc piggyback is throttled to once per hour" {
  seed_mailbox dead1
  put_msg "$MAILBOX/dead1/processed/old.md" "$OLD_TS"
  "$RADIO" register --role pm-a --tab a --agent claude >/dev/null
  assert [ ! -d "$MAILBOX/dead1" ]
  assert [ -f "$TASK_FORCE_HOME/radio/.gc-last" ]
  # A second fresh register within the hour must NOT re-sweep (sentinel is fresh).
  seed_mailbox dead2
  put_msg "$MAILBOX/dead2/processed/old.md" "$OLD_TS"
  "$RADIO" register --role pm-b --tab b --agent claude >/dev/null
  assert [ -d "$MAILBOX/dead2" ]
}
