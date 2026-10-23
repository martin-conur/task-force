#!/usr/bin/env bats
# PM handoff across assistants (#301):
#   - a fresh PM register prints the board digest beside the backlog summary,
#     and a re-register (/compact, /clear) does not;
#   - the digest is capped, and is built without a forge call;
#   - the handoff note round-trips: written by task-monitor-queue, printed with
#     its age at the next fresh PM start;
#   - task-pm refuses a second live PM and accepts --force.

bats_load_library bats-support
bats_load_library bats-assert

load helpers/common

QUEUE_CMD="$REPO_ROOT_REAL/bin/task-monitor-queue"

setup() {
  setup_repo
  setup_task_force_home
  setup_kiro_agents
  setup_stubs
  cd "$MAIN_REPO"
  unset TASK_FORCE_ROLE TASK_FORCE_NO_PM_DIGEST
  NAME=$(printf '%s' "$REPO_NAME" | tr '[:upper:]' '[:lower:]' | tr ' ' '-' | sed 's/[^a-z0-9-]//g')
  PM="pm-$NAME"
  SESS="$TASK_FORCE_HOME/radio/sessions"
  # A gh loadout, so a queued ref is one the tracker would ask the forge about
  # on a full run: the no-forge test means something.
  mkdir -p "$MAIN_REPO/.claude"
  cat > "$MAIN_REPO/.claude/gh-workflow.md" <<'DOC'
- **Owner**: `acme`
- **Repo**: `widgets`
- **Project number**: `7`
- **Status when starting work**: `In Progress`
- **Status when in review**: `In Review`
- **Status when done**: `Done`
DOC
}

teardown() {
  teardown_all
}

register_pm() {
  "$RADIO" register --role "$PM" --tab "$PM" --repo "$MAIN_REPO" --agent claude --loadout claude-gh
}

# ISO time <secs> seconds ago.
ago() { jq -rn --argjson s "$1" 'now - $s | floor | todate'; }

# ----- the digest --------------------------------------------------------------

@test "a fresh PM register prints the board digest, and a re-register does not (#301)" {
  "$QUEUE_CMD" set 41 42 --note 41="kiro hooks first" >/dev/null
  run register_pm
  assert_success
  assert_line --partial "[board] $NAME:"
  assert_line "Next (PM queue):"
  assert_line --regexp '^  1\. 41 .*: kiro hooks first$'
  assert_line --regexp '^  2\. 42 '
  assert_line "In flight: nothing."
  # /compact and /clear re-register with the session file still there.
  run register_pm
  assert_success
  refute_output --partial "[board]"
}

@test "the digest is for PMs only, and TASK_FORCE_NO_PM_DIGEST=1 turns it off (#301)" {
  "$QUEUE_CMD" set 41 >/dev/null
  run "$RADIO" register --role "worker-$NAME-x" --tab x --repo "$MAIN_REPO" --agent claude
  assert_success
  refute_output --partial "[board]"
  TASK_FORCE_NO_PM_DIGEST=1 run register_pm
  assert_success
  refute_output --partial "[board]"
}

@test "the digest is capped at 40 lines, and says how much it left out (#301)" {
  local refs=() i
  for i in $(seq 1 60); do refs+=("$i"); done
  "$QUEUE_CMD" set "${refs[@]}" >/dev/null
  run register_pm
  assert_success
  local digest
  digest=$(sed -n '/^\[board\]/,$p' <<<"$output")
  assert_equal "$(wc -l <<<"$digest" | tr -d ' ')" 40
  # Header, "In flight: nothing.", "Next (PM queue):", then 36 of the 60 items,
  # then the line saying the other 25 lines (24 items and Done) were cut.
  run tail -1 <<<"$digest"
  assert_output --regexp '^… 25 more line\(s\): run task-monitor-snapshot --local'
  run grep -c '^  [0-9]*\. ' <<<"$digest"
  assert_output 36
}

@test "the digest asks the forge nothing (#301)" {
  "$QUEUE_CMD" set 41 >/dev/null
  rm -f "$STUB_CALLS_DIR/gh.calls"
  run register_pm
  assert_success
  assert_line --partial "[board] $NAME:"
  # A full snapshot of this repo calls gh for the PR lists and for issue 41;
  # the digest's --local run must not reach the binary at all.
  run stub_calls gh
  assert_output ""
}

# ----- the handoff note --------------------------------------------------------

@test "the handoff note round-trips: written, then printed with its age at the next start (#301)" {
  run "$QUEUE_CMD" handoff write <<'NOTE'
Decided: #41 waits for the kiro hook fix.
Asked the user whether #42 ships this week; no answer yet.
NOTE
  assert_success
  assert_output "handoff: 2 line(s) saved; the next PM start prints them"
  local note="$TASK_FORCE_HOME/monitor/$NAME/handoff.md"
  # Two hours old, as if the last PM wrote it before lunch.
  sed -i.bak "s/^written_at: .*/written_at: $(ago 7200)/" "$note"
  run register_pm
  assert_success
  assert_line --regexp '^\[handoff\] Note from the previous PM \(.*\), written 2h ago \('
  assert_line "  Decided: #41 waits for the kiro hook fix."
  assert_line "  Asked the user whether #42 ships this week; no answer yet."
  # Kept until overwritten: the next start (the PM exited, its session file
  # gone) prints it again.
  rm -f "$SESS/$PM.info"
  run register_pm
  assert_line "  Decided: #41 waits for the kiro hook fix."
  # Overwritten by the next write.
  echo "Nothing open." | "$QUEUE_CMD" handoff write >/dev/null
  rm -f "$SESS/$PM.info"
  run register_pm
  assert_line "  Nothing open."
  refute_output --partial "Decided: #41"
}

@test "handoff write names the PM's agent, refuses an empty note, and clear removes it (#301)" {
  mkdir -p "$SESS"
  printf 'ROLE=%s\nAGENT=kiro\nLAST_HEARTBEAT=%s\n' "$PM" "$(ago 60)" > "$SESS/$PM.info"
  echo "One line." | "$QUEUE_CMD" handoff write >/dev/null
  run "$QUEUE_CMD" handoff show
  assert_line "agent: kiro"
  assert_line "role: $PM"
  assert_line "One line."
  run "$QUEUE_CMD" handoff write <<<$'  \n\n'
  assert_failure 2
  assert_output --partial "empty"
  # The empty write did not clobber the note.
  run "$QUEUE_CMD" handoff show
  assert_line "One line."
  run "$QUEUE_CMD" handoff clear
  assert_output "handoff: (none)"
  [[ ! -e "$TASK_FORCE_HOME/monitor/$NAME/handoff.md" ]]
  run "$QUEUE_CMD" handoff bogus
  assert_failure 2
}

# ----- one live PM per repo ----------------------------------------------------

# pm_session <agent> <heartbeat-secs-ago> <tab_id>: a PM session file as radio
# writes it, plus the agent sidecar the refusal reads.
pm_session() {
  mkdir -p "$SESS"
  printf 'ROLE=%s\nTAB=%s\nTAB_ID=%s\nZELLIJ_SESSION=zs\nREPO=%s\nREPO_NAME=%s\nSTATE=idle\nLAST_HEARTBEAT=%s\nAGENT=%s\nLOADOUT=%s-gh\n' \
    "$PM" "$PM" "$3" "$MAIN_REPO" "$NAME" "$(ago "$2")" "$1" "$1" > "$SESS/$PM.info"
  printf '%s\n' "$1" > "$SESS/$PM.agent"
}

# The zellij stub's tabs: tab 3 and tab 5, with tab <active> focused.
tabs_with_active() {
  export ZELLIJ=fake ZELLIJ_SESSION_NAME=zs
  export STUB_ZELLIJ_TABS_JSON="[
    {\"name\": \"$PM\", \"tab_id\": 3, \"position\": 0, \"active\": $([[ $1 == 3 ]] && echo true || echo false)},
    {\"name\": \"other\", \"tab_id\": 5, \"position\": 1, \"active\": $([[ $1 == 5 ]] && echo true || echo false)}
  ]"
}

@test "task-pm refuses while a kiro PM is live in another tab, and names it (#301)" {
  pm_session kiro 60 3
  # The name comes from the <role>.agent sidecar, which outlives the session
  # file's own fields (#188): leave AGENT= out of the file to prove it.
  sed -i.bak '/^AGENT=/d' "$SESS/$PM.info"
  tabs_with_active 5
  AW_IMPL=claude-gh run "$TASK_PM"
  assert_failure
  assert_output --partial "$PM is already live on kiro"
  assert_output --partial "task-pm --force"
  # Refused before anything changed: no launch, no tab rename, session intact.
  run stub_calls claude
  assert_output ""
  run stub_calls zellij
  refute_output --partial "rename-tab"
  run grep -c '^LOADOUT=kiro-gh$' "$SESS/$PM.info"
  assert_output 1
}

@test "task-pm --force takes over a live PM and retires its session for a fresh start (#301)" {
  pm_session kiro 60 3
  tabs_with_active 5
  AW_IMPL=claude-gh run "$TASK_PM" --force
  assert_success
  run stub_calls claude
  assert_output --partial "/pm"
  # Retired, so the new PM's register is fresh: backlog and digest print.
  [[ ! -e "$SESS/$PM.info" ]]
}

@test "task-pm accepts a PM that is live only in this tab, or stale (#301)" {
  # The kiro PM just quit in this tab: kiro has no exit hook, so its session
  # still looks live. This is the handoff itself, not a second PM.
  pm_session kiro 60 3
  tabs_with_active 3
  AW_IMPL=claude-gh run "$TASK_PM"
  assert_success
  [[ ! -e "$SESS/$PM.info" ]]
  # A heartbeat older than an hour is a dead PM wherever its tab was.
  pm_session claude 7200 3
  tabs_with_active 5
  AW_IMPL=kiro-gh run "$TASK_PM"
  assert_success
  run stub_calls kiro-cli
  assert_output --partial "--agent pm"
  [[ ! -e "$SESS/$PM.info" ]]
}

@test "task-pm refuses a live PM in a same-numbered tab of another zellij session (#301)" {
  pm_session claude 60 3
  tabs_with_active 3
  export ZELLIJ_SESSION_NAME=elsewhere
  AW_IMPL=kiro-gh run "$TASK_PM"
  assert_failure
  assert_output --partial "already live on claude"
  assert_output --partial "zellij session zs"
}
