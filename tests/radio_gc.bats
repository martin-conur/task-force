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

@test "gc preserves a dead role's UNREAD inbox even when aged (the #182 backlog guard)" {
  # No session file, but the inbox still holds undelivered mail (aged). The
  # whole-dir reclaim must NOT fire — this is exactly the legacy pm backlog case.
  seed_mailbox legacypm
  put_msg "$MAILBOX/legacypm/inbox/old.md" "$OLD_TS"
  run "$RADIO" gc
  assert_success
  assert [ -d "$MAILBOX/legacypm" ]
  assert [ -f "$MAILBOX/legacypm/inbox/old.md" ]
}

@test "gc reclaims a role whose heartbeat is >1h stale (empty inbox, aged)" {
  seed_mailbox crashed
  seed_stale_session crashed
  put_msg "$MAILBOX/crashed/processed/old.md" "$OLD_TS"
  run "$RADIO" gc
  assert_success
  assert [ ! -d "$MAILBOX/crashed" ]
}

@test "gc preserves a stale-heartbeat role that still holds unread mail" {
  seed_mailbox crashed2
  seed_stale_session crashed2
  put_msg "$MAILBOX/crashed2/inbox/pending.md" "$OLD_TS"   # unread + aged
  run "$RADIO" gc
  assert_success
  assert [ -d "$MAILBOX/crashed2" ]
  assert [ -f "$MAILBOX/crashed2/inbox/pending.md" ]
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
