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

# Write a dummy session file so a role counts as "live".
seed_session() {
  local role="$1"
  printf 'ROLE=%s\nSTATE=idle\n' "$role" > "$SESSIONS/$role.info"
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
