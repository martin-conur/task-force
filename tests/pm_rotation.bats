#!/usr/bin/env bats
# PM rotation (#334): task-watch recycles an autonomous PM at a quiet point.
#   - the caps (context, tickets, age) and the group rule each start one;
#   - tickets of the PM's own group in flight defer it, but for the context cap;
#   - the sequence: handoff-requested, handoff-done plus a fresh note, then
#     `radio clear` types /clear with the rotation marker set; a timeout gives
#     up and never clears without a note;
#   - radio: register records the session and transcript, the marker makes the
#     /clear re-register print the digest and the note once, and `radio clear`
#     refuses what it must not type into.
# Jira is tests/helpers/stubs/acli, zellij the zellij stub, the PM a session
# file and a transcript on disk.

bats_load_library bats-support
bats_load_library bats-assert

load helpers/common

WATCH="$REPO_ROOT_REAL/bin/task-watch"
QUEUE_CMD="$REPO_ROOT_REAL/bin/task-monitor-queue"

setup() {
  setup_repo
  setup_task_force_home
  setup_stubs
  unset TASK_FORCE_ROLE TASK_FORCE_PM_ROLE TASK_FORCE_NO_PM_DIGEST ZELLIJ_TAB ZELLIJ_PANE_ID
  export ZELLIJ=fake ZELLIJ_SESSION_NAME=live-server
  NAME=$(basename "$MAIN_REPO" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]//g')
  PM="pm-$NAME"
  LEDGER="$TASK_FORCE_HOME/watch/$NAME"
  SESS="$TASK_FORCE_HOME/radio/sessions"
  PM_INBOX="$TASK_FORCE_HOME/radio/mailbox/$PM/inbox"
  LOG="$TASK_FORCE_HOME/radio/log"
  # The PM's tab is 7, its agent pane 700.
  seed_zellij_tabs "$PM"
  mkdir -p "$MAIN_REPO/.claude"
  cat >"$MAIN_REPO/.claude/jira-workflow.md" <<'DOC'
<!-- task-init:managed:start -->
- **Site**: `https://acme.atlassian.net`
- **Project key(s)**: `PROJ`
- **Watch max in flight**: `2`
- **Watch rotate context tokens**: `150000`
- **Watch rotate tickets**: `6`
- **Watch rotate age minutes**: `480`
- **Watch handoff timeout minutes**: `15`
- **Watch group labels**: `none`
<!-- task-init:managed:end -->
DOC
  export ACLI_STUB_ISSUES="$BATS_TEST_TMPDIR/issues.json"
  echo '[]' >"$ACLI_STUB_ISSUES"
  export TASK_WATCH_ACLI_CONFIG="$BATS_TEST_TMPDIR/no-acli-config.yaml"
  TRANSCRIPT="$BATS_TEST_TMPDIR/transcript.jsonl"
  : >"$TRANSCRIPT"
  pm_session
  cd "$MAIN_REPO"
}

teardown() {
  teardown_all
}

watch() { /bin/bash "$WATCH" "$@"; }
setting() { printf -- '- **%s**: `%s`\n' "$1" "$2" >>"$MAIN_REPO/.claude/jira-workflow.md"; }

# pm_session [agent] [auto-submit 1|0]: the PM's radio session file.
pm_session() {
  mkdir -p "$SESS"
  {
    printf 'ROLE=%s\nTAB=%s\nTAB_ID=7\nZELLIJ_SESSION=live-server\nREPO=%s\nREPO_NAME=%s\nSTATE=idle\n' \
      "$PM" "$PM" "$MAIN_REPO" "$NAME"
    printf 'LAST_HEARTBEAT=%s\nAGENT=%s\nLOADOUT=claude-jira\nREGISTERED_AT=2026-11-01T00:00:00Z\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${1:-claude}"
    printf 'SESSION_ID=sess-1\nTRANSCRIPT=%s\nPANE_ID=700\n' "$TRANSCRIPT"
    if [[ "${2:-1}" == 1 ]]; then printf 'AUTO_SUBMIT=1\n'; fi
  } >"$SESS/$PM.info"
}
pm_state() { sed -i.bak "s/^STATE=.*/STATE=$1/" "$SESS/$PM.info"; }

# context <tokens>: the PM's last main-thread turn used this many, split over
# the three fields that count. A sidechain turn after it must not be read.
context() {
  local third=$(( $1 / 3 ))
  printf '%s\n' '{"type":"user","message":{"role":"user","content":"hi"}}' >>"$TRANSCRIPT"
  printf '{"type":"assistant","message":{"usage":{"input_tokens":%s,"cache_read_input_tokens":%s,"cache_creation_input_tokens":%s,"output_tokens":99999}}}\n' \
    "$third" "$third" "$(( $1 - 2 * third ))" >>"$TRANSCRIPT"
  printf '%s\n' '{"type":"assistant","isSidechain":true,"message":{"usage":{"input_tokens":1}}}' >>"$TRANSCRIPT"
}

# issue <key> [parent] [label...]: a ticket on the queue, optionally under an epic.
issue() {
  local key="$1" parent="${2:-}" labels
  shift; [[ $# -gt 0 ]] && shift
  labels=$(printf '%s\n' ai-auto "$@" | jq -R . | jq -s -c .)
  jq --arg k "$key" --arg p "$parent" --argjson l "$labels" \
    '. + [{key: $k, fields: ({labels: $l, summary: ("summary of " + $k), status: {name: "To Do", statusCategory: {key: "new"}}}
      + (if $p == "" then {} else {parent: {key: $p}} end))}]' \
    "$ACLI_STUB_ISSUES" >"$ACLI_STUB_ISSUES.tmp"
  mv "$ACLI_STUB_ISSUES.tmp" "$ACLI_STUB_ISSUES"
}
set_done() {
  jq --arg k "$1" 'map(if .key == $k then .fields.status = {name: "Done", statusCategory: {key: "done"}} else . end)' \
    "$ACLI_STUB_ISSUES" >"$ACLI_STUB_ISSUES.tmp"
  mv "$ACLI_STUB_ISSUES.tmp" "$ACLI_STUB_ISSUES"
}
labels_of() { jq -r --arg k "$1" '.[] | select(.key == $k) | .fields.labels | join(",")' "$ACLI_STUB_ISSUES"; }

# The PM's inbox messages of <intent>, as issue keys (or one line each).
mail() {
  local f
  for f in "$PM_INBOX"/*.md "$PM_INBOX/../processed"/*.md; do
    [[ -f "$f" ]] || continue
    grep -qx "intent: $1" "$f" && { sed -n 's/^issue: //p' "$f"; grep -q '^issue: ' "$f" || echo "$1"; }
  done | sort
  return 0
}
# The PM drains its inbox, as it does when a wake lands.
pm_reads() {
  mkdir -p "$PM_INBOX/../processed"
  local f
  for f in "$PM_INBOX"/*.md; do [[ -f "$f" ]] && mv "$f" "$PM_INBOX/../processed/"; done
  return 0
}
# The PM answers handoff-requested: the note, then handoff-done to the watcher.
pm_hands_off() {
  pm_reads
  echo "Decided: PROJ-1 waits for the reporter." | "$QUEUE_CMD" handoff write >/dev/null
  TASK_FORCE_ROLE="$PM" "$RADIO" send --to "watch-$NAME" --intent handoff-done --body "note written" >/dev/null
}
pm_get() { sed -n "s/^$1=//p" "$LEDGER/.pm"; }
pm_set() { sed -i.bak "s/^$1=.*/$1=$2/" "$LEDGER/.pm"; }
cleared() { stub_calls zellij | grep -c 'write-chars --pane-id 700 /clear' || true; }

# ----- the caps --------------------------------------------------------------

@test "the context cap: past it, the PM is asked for a handoff, then cleared with the marker set (#334)" {
  context 160000
  run watch --once
  assert_success
  assert_output --partial "rotation of $PM requested reason=context (160000 tokens, cap 150000)"
  assert_output --partial "queue held while $PM hands off"
  assert_equal "$(mail handoff-requested)" "handoff-requested"
  run cat "$PM_INBOX"/*.md
  assert_output --partial "from: watch-$NAME"
  assert_output --partial "radio send --to watch-$NAME --intent handoff-done"
  assert_equal "$(cleared)" 0
  # No reply yet: still waiting, nothing typed.
  pm_reads
  run watch --once
  assert_output --partial "queue held"
  assert_equal "$(cleared)" 0
  pm_hands_off
  run watch --once
  assert_success
  assert_output --partial "rotate $PM reason=context (160000 tokens, cap 150000)"
  assert_equal "$(cleared)" 1
  [[ -f "$SESS/$PM.rotate" ]]
  run grep -E '^EXPIRES=[0-9]+$' "$SESS/$PM.rotate"
  assert_success
  run grep "watch: rotate $PM reason=context" "$LOG"
  assert_success
  # A new generation, counters from zero; the handoff-done was consumed.
  assert_equal "$(pm_get GEN)" 2
  assert_equal "$(pm_get TICKETS)" 0
  assert_equal "$(pm_get PHASE)" ""
  run ls "$TASK_FORCE_HOME/radio/mailbox/watch-$NAME/inbox"
  assert_output ""
}

@test "the tickets cap fires once the PM's tickets are done (#334)" {
  setting "Watch rotate tickets" 2
  issue PROJ-1; issue PROJ-2
  watch --once >/dev/null
  assert_equal "$(pm_get TICKETS)" 2
  pm_reads
  set_done PROJ-1; set_done PROJ-2
  run watch --once
  assert_output --partial "rotation of $PM requested reason=tickets (2 ticket(s), cap 2)"
}

@test "the age cap fires (#334)" {
  watch --once >/dev/null
  pm_set STARTED 1
  run watch --once
  assert_output --regexp "rotation of $PM requested reason=age \([0-9]+m, cap 480m\)"
}

@test "a cap of 0 is off, and a context under the cap rotates nothing (#334)" {
  setting "Watch rotate age minutes" 0
  context 1000
  watch --once >/dev/null
  pm_set STARTED 1
  run watch --once
  refute_output --partial "rotation"
  assert_equal "$(mail handoff-requested)" ""
}

# ----- deferral ----------------------------------------------------------------

@test "tickets of the PM's group in flight defer a cap rotation (#334)" {
  setting "Watch rotate tickets" 1
  issue PROJ-1
  watch --once >/dev/null
  pm_reads
  run watch --once
  assert_output --partial "rotation deferred (tickets: 1 ticket(s) handed to $PM still in flight)"
  assert_equal "$(mail handoff-requested)" ""
  # Logged once, not every poll.
  watch --once >/dev/null
  assert_equal "$(grep -c 'rotation deferred (tickets' "$LOG")" 1
}

@test "an ungrouped ticket still in flight defers, after the PM took a grouped one (#334)" {
  setting "Watch rotate tickets" 2
  issue PROJ-1
  watch --once >/dev/null
  pm_reads
  issue PROJ-2 EPIC-1
  watch --once >/dev/null
  assert_equal "$(pm_get GROUP)" EPIC-1
  pm_reads
  set_done PROJ-2
  run watch --once
  assert_output --partial "rotation deferred (tickets: 1 ticket(s) handed to $PM still in flight)"
  assert_equal "$(mail handoff-requested)" ""
}

@test "the context cap overrides that deferral (#334)" {
  setting "Watch rotate tickets" 1
  issue PROJ-1
  watch --once >/dev/null
  pm_reads
  context 200000
  run watch --once
  assert_output --partial "rotation of $PM requested reason=context"
}

@test "only a quiet point: a busy PM, unread mail or a running review defer even the context cap (#334)" {
  context 200000
  pm_state busy
  run watch --once
  assert_output --partial "rotation deferred ($PM is busy)"
  pm_state idle
  mkdir -p "$PM_INBOX"
  printf -- '---\nintent: review-requested\n---\n' >"$PM_INBOX/x.md"
  run watch --once
  assert_output --partial "rotation deferred ($PM has 1 unread message(s))"
  rm -f "$PM_INBOX/x.md"
  printf 'ROLE=reviewer-%s-pr9\n' "$NAME" >"$SESS/reviewer-$NAME-pr9.info"
  run watch --once
  assert_output --partial "rotation deferred (merge gate pending: reviewer-$NAME-pr9 is still reviewing)"
  assert_equal "$(mail handoff-requested)" ""
}

# ----- the handoff ------------------------------------------------------------

@test "a handoff that never comes times out, is never cleared, and is retried at the next quiet point (#334)" {
  context 160000
  watch --once >/dev/null
  pm_reads
  pm_set REQUESTED_AT 1
  run watch --once
  assert_output --partial "rotation of $PM timed out: no handoff-done with a fresh note after 15m"
  assert_equal "$(cleared)" 0
  assert_equal "$(pm_get PHASE)" ""
  run watch --once
  assert_output --partial "rotation of $PM requested reason=context"
  assert_equal "$(mail handoff-requested | wc -l | tr -d ' ')" 2
}

@test "handoff-done without a fresh note does not clear (#334)" {
  echo "An old note." | "$QUEUE_CMD" handoff write >/dev/null
  touch -t 202001010000 "$TASK_FORCE_HOME/monitor/$NAME/handoff.md"
  context 160000
  watch --once >/dev/null
  pm_reads
  TASK_FORCE_ROLE="$PM" "$RADIO" send --to "watch-$NAME" --intent handoff-done --body x >/dev/null
  run watch --once
  assert_output --partial "rotation deferred ($PM said handoff-done, but wrote no handoff note since the request)"
  assert_equal "$(cleared)" 0
  # The note arrives later: the earlier handoff-done still counts.
  echo "Now written." | "$QUEUE_CMD" handoff write >/dev/null
  run watch --once
  assert_output --partial "rotate $PM reason=context"
  assert_equal "$(cleared)" 1
}

@test "a PM busy after its handoff is cleared only once it is idle (#334)" {
  context 160000
  watch --once >/dev/null
  pm_hands_off
  pm_state busy
  run watch --once
  assert_output --partial "/clear waits for idle"
  assert_equal "$(cleared)" 0
  pm_state idle
  run watch --once
  assert_equal "$(cleared)" 1
}

@test "a kiro PM, or one not auto-submitting, is never rotated, and says so once (#334)" {
  pm_session kiro
  context 160000
  run watch --once
  assert_output --partial "rotation refused: $PM runs on kiro"
  run watch --once
  refute_output --partial "rotation refused"
  assert_equal "$(mail handoff-requested)" ""
  # A new PM (a fresh register) on claude, but without auto-submit.
  pm_session claude 0
  sed -i.bak 's/^REGISTERED_AT=.*/REGISTERED_AT=2026-11-02T00:00:00Z/' "$SESS/$PM.info"
  run watch --once
  assert_output --partial "rotation refused: $PM is not auto-submitting"
  assert_equal "$(mail handoff-requested)" ""
}

@test "right after a rotation the old transcript is not read, so the fresh PM is not rotated again (#334)" {
  context 160000
  watch --once >/dev/null
  pm_hands_off
  run watch --once
  assert_output --partial "rotate $PM reason=context"
  # The /clear re-register has not landed: same session, the old transcript.
  touch -t 202001010000 "$TRANSCRIPT"
  run watch --once
  refute_output --partial "rotation"
  assert_equal "$(mail handoff-requested | wc -l | tr -d ' ')" 1
  # It lands: a new session and its own, small transcript.
  local fresh="$BATS_TEST_TMPDIR/fresh.jsonl"
  TRANSCRIPT="$fresh" context 2000
  sed -i.bak -e 's/^SESSION_ID=.*/SESSION_ID=sess-2/' -e "s|^TRANSCRIPT=.*|TRANSCRIPT=$fresh|" "$SESS/$PM.info"
  run watch --once
  refute_output --partial "rotation"
  assert_equal "$(pm_get ROTATED_SID)" ""
  # From here the new transcript counts as usual.
  TRANSCRIPT="$fresh" context 170000
  run watch --once
  assert_output --partial "rotation of $PM requested reason=context (170000 tokens"
}

@test "a PM registered before REGISTERED_AT existed is adopted at its first re-register, counters kept (#334)" {
  sed -i.bak '/^REGISTERED_AT=/d' "$SESS/$PM.info"
  setting "Watch rotate tickets" 9
  issue PROJ-1
  watch --once >/dev/null
  assert_equal "$(pm_get TICKETS)" 1
  printf 'REGISTERED_AT=2026-11-03T00:00:00Z\n' >>"$SESS/$PM.info"
  watch --once >/dev/null
  assert_equal "$(pm_get GEN)" 1
  assert_equal "$(pm_get TICKETS)" 1
  assert_equal "$(pm_get PM_ID)" 2026-11-03T00:00:00Z
  # A later change is a new PM again.
  sed -i.bak 's/^REGISTERED_AT=.*/REGISTERED_AT=2026-11-04T00:00:00Z/' "$SESS/$PM.info"
  watch --once >/dev/null
  assert_equal "$(pm_get GEN)" 2
}

@test "a PM restarted by hand starts a new generation; its own /clear does not (#334)" {
  setting "Watch rotate tickets" 9
  issue PROJ-1
  watch --once >/dev/null
  assert_equal "$(pm_get GEN)" 1
  assert_equal "$(pm_get TICKETS)" 1
  # A /clear or /compact: same REGISTERED_AT, new session id.
  sed -i.bak 's/^SESSION_ID=.*/SESSION_ID=sess-2/' "$SESS/$PM.info"
  watch --once >/dev/null
  assert_equal "$(pm_get GEN)" 1
  sed -i.bak 's/^REGISTERED_AT=.*/REGISTERED_AT=2026-11-02T00:00:00Z/' "$SESS/$PM.info"
  watch --once >/dev/null
  assert_equal "$(pm_get GEN)" 2
  assert_equal "$(pm_get TICKETS)" 0
}

# ----- groups ----------------------------------------------------------------

@test "group: tickets of one epic stay with one PM, no rotation (#334)" {
  issue PROJ-1 EPIC-1; issue PROJ-2 EPIC-1
  run watch --once
  assert_output --partial "claimed 2"
  assert_equal "$(pm_get GROUP)" EPIC-1
  assert_equal "$(sed -n 's/^GROUP=//p' "$LEDGER/PROJ-2")" EPIC-1
  assert_equal "$(mail handoff-requested)" ""
  # acli's search refuses `parent` (#351): the epic is read through view.
  assert_stub_called acli "--fields key,labels,status,summary --paginate"
  run grep -F "summary,parent" "$STUB_CALLS_DIR/acli.calls"
  assert_failure
  assert_stub_called acli "jira workitem view PROJ-2 --fields parent --json"
  assert_equal "$(sed -n 's/^PARENT=//p' "$LEDGER/PROJ-2")" EPIC-1
}

@test "group: the epic is read once per ticket, then from the ledger (#351)" {
  issue PROJ-1 EPIC-1; issue PROJ-2 EPIC-2; issue PROJ-3
  run watch --once
  assert_success
  # PROJ-2 waits for EPIC-1; PROJ-3 has no epic. Each was viewed once.
  run grep -c 'workitem view PROJ-2 --fields parent' "$STUB_CALLS_DIR/acli.calls"
  assert_output 1
  run watch --once
  assert_success
  run grep -c 'workitem view PROJ-2 --fields parent' "$STUB_CALLS_DIR/acli.calls"
  assert_output 1
  run grep -c 'workitem view PROJ-3 --fields parent' "$STUB_CALLS_DIR/acli.calls"
  assert_output 1
  assert_equal "$(sed -n 's/^PARENT=//p' "$LEDGER/PROJ-3")" ""
}

@test "group: another epic waits while the PM's epic is in flight (#334)" {
  issue PROJ-1 EPIC-1
  watch --once >/dev/null
  pm_reads
  issue PROJ-2 EPIC-2
  run watch --once
  assert_output --partial "rotation deferred (group: 1 ticket(s) handed to $PM still in flight)"
  assert_output --partial "1 waiting for group EPIC-1 to finish"
  assert_equal "$(labels_of PROJ-2)" "ai-auto"
  assert_equal "$(mail ticket-filed)" "PROJ-1"
  assert_equal "$(mail handoff-requested)" ""
}

@test "group: once the PM's epic is idle, another epic rotates the PM before its ticket-filed (#334)" {
  issue PROJ-1 EPIC-1
  watch --once >/dev/null
  pm_reads
  set_done PROJ-1
  issue PROJ-2 EPIC-2
  run watch --once
  assert_output --partial "rotation of $PM requested reason=group (EPIC-1 -> EPIC-2)"
  assert_equal "$(labels_of PROJ-2)" "ai-auto"
  assert_equal "$(mail ticket-filed)" "PROJ-1"
  pm_hands_off
  run watch --once
  assert_output --partial "rotate $PM reason=group (EPIC-1 -> EPIC-2)"
  assert_equal "$(mail ticket-filed)" "PROJ-1"
  run grep "watch: rotate $PM reason=group (EPIC-1 -> EPIC-2)" "$LOG"
  assert_success
  # The next poll files it to the fresh PM, whose group it becomes.
  run watch --once
  assert_output --partial "ticket-filed PROJ-2"
  assert_equal "$(pm_get GROUP)" EPIC-2
  assert_equal "$(pm_get TICKETS)" 1
}

@test "group: an ungrouped ticket never rotates, and does not set the PM's group (#334)" {
  issue PROJ-1
  watch --once >/dev/null
  assert_equal "$(pm_get GROUP)" ""
  pm_reads
  issue PROJ-2 EPIC-1
  watch --once >/dev/null
  assert_equal "$(pm_get GROUP)" EPIC-1
  pm_reads
  set_done PROJ-1
  issue PROJ-3
  run watch --once
  assert_output --partial "ticket-filed PROJ-3"
  assert_equal "$(mail handoff-requested)" ""
}

@test "group: with no epic, a Watch group labels match groups the ticket (#334)" {
  setting "Watch group labels" "team-*, payments"
  issue PROJ-1 "" ui team-a
  watch --once >/dev/null
  assert_equal "$(pm_get GROUP)" team-a
  pm_reads
  set_done PROJ-1
  issue PROJ-2 "" payments
  run watch --once
  assert_output --partial "reason=group (team-a -> payments)"
}

# ----- radio --------------------------------------------------------------------

register_pm() {
  TASK_FORCE_ROLE="$PM" "$RADIO" register --role "$PM" --tab "$PM" --repo "$MAIN_REPO" --agent claude --loadout claude-jira
}

@test "radio register records the session id and transcript from the payload, and keeps them without one (#334)" {
  rm -f "$SESS/$PM.info"
  run register_pm <<<'{"session_id":"s-1","transcript_path":"/t/s-1.jsonl","source":"startup"}'
  assert_success
  run grep -E '^(SESSION_ID|TRANSCRIPT|REGISTERED_AT)=' "$SESS/$PM.info"
  assert_line "SESSION_ID=s-1"
  assert_line "TRANSCRIPT=/t/s-1.jsonl"
  local reg
  reg=$(sed -n 's/^REGISTERED_AT=//p' "$SESS/$PM.info")
  [[ -n "$reg" ]]
  run grep 'register role=.*session_id=s-1' "$LOG"
  assert_success
  # A hand repair with no payload keeps them.
  register_pm </dev/null >/dev/null
  run grep '^SESSION_ID=' "$SESS/$PM.info"
  assert_output "SESSION_ID=s-1"
  # A /clear: a new session, the same REGISTERED_AT.
  sleep 1
  register_pm <<<'{"session_id":"s-2","transcript_path":"/t/s-2.jsonl","source":"clear"}' >/dev/null
  run grep -E '^(SESSION_ID|REGISTERED_AT)=' "$SESS/$PM.info"
  assert_line "SESSION_ID=s-2"
  assert_line "REGISTERED_AT=$reg"
}

@test "the rotation marker makes the /clear re-register print the digest and the handoff note, once (#334)" {
  rm -f "$SESS/$PM.info"
  ZELLIJ_PANE_ID=700 TASK_FORCE_AUTO_SUBMIT=1 register_pm </dev/null >/dev/null
  echo "Decided: EPIC-1 is closed." | "$QUEUE_CMD" handoff write >/dev/null
  # Without the marker a re-register prints neither.
  run register_pm </dev/null
  refute_output --partial "[board]"
  refute_output --partial "[handoff]"
  run "$RADIO" clear --to "$PM"
  assert_success
  assert_output --partial "radio: cleared $PM (tab_id=7)"
  assert_stub_called zellij "action write-chars --pane-id 700 /clear"
  [[ -f "$SESS/$PM.rotate" ]]
  run register_pm <<<'{"session_id":"s-3","source":"clear"}'
  assert_success
  assert_line --partial "[board] $NAME:"
  assert_line --partial "[handoff] Note from the previous PM"
  assert_line "  Decided: EPIC-1 is closed."
  [[ ! -e "$SESS/$PM.rotate" ]]
  run register_pm </dev/null
  refute_output --partial "[board]"
  refute_output --partial "[handoff]"
}

@test "an expired rotation marker is dropped and logged, never printed (#334)" {
  rm -f "$SESS/$PM.info"
  register_pm </dev/null >/dev/null
  echo "A note." | "$QUEUE_CMD" handoff write >/dev/null
  # A /clear that never re-registered, its marker long expired.
  printf 'CREATED=2026-01-01T00:00:00Z\nEXPIRES=1\n' >"$SESS/$PM.rotate"
  run register_pm </dev/null
  assert_success
  refute_output --partial "[board]"
  refute_output --partial "[handoff]"
  [[ ! -e "$SESS/$PM.rotate" ]]
  run grep "watch: stale rotation marker dropped role=$PM" "$LOG"
  assert_success
  # The TTL comes from --ttl-minutes.
  pm_session
  run "$RADIO" clear --to "$PM" --ttl-minutes 7
  assert_success
  local exp
  exp=$(sed -n 's/^EXPIRES=//p' "$SESS/$PM.rotate")
  (( exp - $(date -u +%s) > 6 * 60 && exp - $(date -u +%s) <= 7 * 60 ))
}

@test "radio clear refuses a busy, kiro or not auto-submitting role, and sets no marker (#334)" {
  pm_state busy
  run "$RADIO" clear --to "$PM"
  assert_failure
  assert_output --partial "not clearing $PM: not idle (state=busy)"
  pm_session kiro
  run "$RADIO" clear --to "$PM"
  assert_output --partial "agent is kiro, not claude"
  pm_session claude 0
  run "$RADIO" clear --to "$PM"
  assert_output --partial "not auto-submitting"
  run "$RADIO" clear --to pm-nobody
  assert_output --partial "no session"
  [[ ! -e "$SESS/$PM.rotate" ]]
  assert_equal "$(cleared)" 0
}
