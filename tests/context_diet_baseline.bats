#!/usr/bin/env bats
# Tests for tools/context-diet-baseline.sh (#396).
#
# Builds a synthetic repo layout, Claude Code transcripts, a PM mailbox and a
# gh stub, then checks the table's numbers: tokens deduplicated by message id,
# the synthetic entry left out, subagents counted, the planner split from the
# worker, review beats per PR, verdict comments, and only a real `radio send`
# outcome counted as an incident.

bats_load_library bats-support
bats_load_library bats-assert

load helpers/common

BASELINE="$REPO_ROOT_REAL/tools/context-diet-baseline.sh"

setup() {
  TMP_DIR=$(mktemp -d)
  export TMP_DIR
  MAIN="$TMP_DIR/src/demo"
  WT="$TMP_DIR/src/demo-worktrees"
  PROJ="$TMP_DIR/projects"
  FIX="$TMP_DIR/fix"
  TF="$TMP_DIR/tf"
  mkdir -p "$MAIN" "$WT" "$PROJ" "$FIX" "$TMP_DIR/bin" "$TF/radio/mailbox/pm-demo/processed"
  export FIX

  cat >"$TMP_DIR/bin/gh" <<'EOF'
#!/usr/bin/env bash
# gh pr view <n> --repo R --json <fields> [--jq <filter>]
n=$3 json="" q="."
while [[ $# -gt 0 ]]; do
  case $1 in --json) json=$2; shift 2 ;; --jq) q=$2; shift 2 ;; *) shift ;; esac
done
if [[ $json == comments ]]; then jq -r "$q" "$FIX/pr$n-comments.json"; else cat "$FIX/pr$n.json"; fi
EOF
  chmod +x "$TMP_DIR/bin/gh"

  cat >"$FIX/pr7.json" <<'EOF'
{"number":7,"headRefName":"task/feat","createdAt":"2026-01-01T00:00:00Z","mergedAt":"2026-01-02T00:00:00Z","closingIssuesReferences":[{"number":5}]}
EOF
  cat >"$FIX/pr7-comments.json" <<'EOF'
{"comments":[{"body":"**Verdict:** clean — reviewed 0123456789abcdef0123456789abcdef01234567"},{"body":"thanks"}]}
EOF

  pd() { printf '%s/%s' "$PROJ" "$(printf '%s' "$1" | sed 's/[^A-Za-z0-9]/-/g')"; }
  WDIR=$(pd "$WT/feat"); RDIR=$(pd "$WT/review-pr7"); PDIR=$(pd "$MAIN")
  mkdir -p "$WDIR/w1/subagents" "$RDIR" "$PDIR"

  # Worker: msg_a is written twice (one line per content block) and must count
  # once; the synthetic entry comes first and must not be the start context.
  cat >"$WDIR/w1.jsonl" <<'EOF'
{"type":"user","timestamp":"2026-01-01T01:00:00Z","message":{"content":"<command-name>/worker</command-name>"}}
{"type":"assistant","timestamp":"2026-01-01T01:00:00Z","message":{"id":"s1","model":"<synthetic>","usage":{"input_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":0}}}
{"type":"assistant","timestamp":"2026-01-01T01:00:01Z","isSidechain":false,"message":{"id":"msg_a","model":"m","usage":{"input_tokens":10,"cache_creation_input_tokens":1000,"cache_read_input_tokens":0,"output_tokens":5},"content":[{"type":"text","text":"hi"}]}}
{"type":"assistant","timestamp":"2026-01-01T01:00:02Z","isSidechain":false,"message":{"id":"msg_a","model":"m","usage":{"input_tokens":10,"cache_creation_input_tokens":1000,"cache_read_input_tokens":0,"output_tokens":5},"content":[{"type":"tool_use","id":"t2","input":{"command":"grep -n 'radio send' README.md"}}]}}
{"type":"user","timestamp":"2026-01-01T01:00:03Z","message":{"content":[{"type":"tool_result","tool_use_id":"t2","content":"radio: WARNING — quoted, not a send"}]}}
{"type":"assistant","timestamp":"2026-01-01T01:00:04Z","isSidechain":false,"message":{"id":"msg_b","model":"m","usage":{"input_tokens":1,"cache_creation_input_tokens":0,"cache_read_input_tokens":1010,"output_tokens":20},"content":[{"type":"tool_use","id":"t1","input":{"command":"cd /x; radio send --to pm --intent review-requested --pr 7 <<'BODY'\nPR up\nBODY"}}]}}
{"type":"user","timestamp":"2026-01-01T01:00:05Z","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":[{"type":"text","text":"radio: WARNING — no session for pm-demo; message queued"}]}]}}
EOF
  cat >"$WDIR/w1/subagents/agent-x.jsonl" <<'EOF'
{"type":"assistant","timestamp":"2026-01-01T01:00:06Z","isSidechain":true,"message":{"id":"msg_c","model":"m","usage":{"input_tokens":100,"output_tokens":0}}}
EOF
  # Planner: a /planner session in the worker's worktree (task-work --plan).
  cat >"$WDIR/p1.jsonl" <<'EOF'
{"type":"user","timestamp":"2026-01-01T00:30:00Z","message":{"content":"<command-name>/planner</command-name>"}}
{"type":"assistant","timestamp":"2026-01-01T00:30:01Z","message":{"id":"msg_p","model":"m","usage":{"input_tokens":0,"cache_creation_input_tokens":500,"cache_read_input_tokens":0,"output_tokens":0}}}
EOF
  cat >"$RDIR/r1.jsonl" <<'EOF'
{"type":"user","timestamp":"2026-01-01T02:00:00Z","message":{"content":"<command-name>/reviewer</command-name>"}}
{"type":"assistant","timestamp":"2026-01-01T02:00:01Z","message":{"id":"msg_r","model":"m","usage":{"input_tokens":0,"cache_creation_input_tokens":2000,"cache_read_input_tokens":0,"output_tokens":0}}}
EOF
  cat >"$PDIR/pm1.jsonl" <<'EOF'
{"type":"user","timestamp":"2026-01-01T00:10:00Z","message":{"content":"<command-name>/pm</command-name>"}}
{"type":"assistant","timestamp":"2026-01-01T00:10:01Z","message":{"id":"msg_pm","model":"m","usage":{"input_tokens":0,"cache_creation_input_tokens":3000,"cache_read_input_tokens":0,"output_tokens":0}}}
EOF

  local mb="$TF/radio/mailbox/pm-demo/processed"
  printf -- '---\nintent: review-requested\npr: 7\n---\n' >"$mb/1-from-worker-demo-feat-a.md"
  printf -- '---\nintent: re-review-requested\npr: 7\n---\n' >"$mb/2-from-worker-demo-feat-b.md"
  printf -- '---\nintent: re-review-requested\npr: 70\n---\n' >"$mb/3-from-worker-demo-other-c.md"
  printf -- '---\nintent: review-complete-clean\npr: 7\n---\n' >"$mb/4-from-reviewer-demo-pr7-d.md"
  printf '2026-01-03T00:00:00Z send id=x\n' >"$TF/radio/log"
}

teardown() {
  [[ -n "${TMP_DIR:-}" && -d "$TMP_DIR" ]] && rm -rf "$TMP_DIR"
}

run_baseline() {
  PATH="$TMP_DIR/bin:$PATH" CLAUDE_PROJECTS="$PROJ" TASK_FORCE_HOME="$TF" \
    run bash "$BASELINE" --prs 7 --repo o/demo --main-root "$MAIN"
}

@test "per-issue row: deduped tokens, subagents, planner split, beats, verdicts, incidents" {
  run_baseline
  assert_success
  # worker 1015 + 1031 + 100 subagent; reviewer 2000; planner 500; total 4646.
  # Starts: worker 1010 (msg_a, not the synthetic entry), reviewer 2000.
  # Beats 1 / 1 (pr 70 and the reviewer's message left out), 1 verdict,
  # 1 incident (a grep for radio send does not count).
  assert_output --partial "| #5 | #7 | 2026-01-02 | 2.1K | 2.0K | 0.5K | 4.6K | 1.0K | 2.0K | 1 / 1 | 1 | 1 |"
}

@test "starting context per role, and the radio log's coverage" {
  run_baseline
  assert_success
  assert_output --partial "| pm | 1 | 3.0K | 3.0K | 3.0K |"
  assert_output --partial "| planner | 1 | 0.5K | 0.5K | 0.5K |"
  assert_output --partial "| worker | 1 | 1.0K | 1.0K | 1.0K |"
  assert_output --partial "| reviewer | 1 | 2.0K | 2.0K | 2.0K |"
  assert_output --partial "naming WARNING, wake failed or looks dead: 1."
  assert_output --partial "after the window closed"
}

@test "a rerun over the same --prs prints the same table" {
  run_baseline
  first=$output
  run_baseline
  assert_equal "$output" "$first"
}
