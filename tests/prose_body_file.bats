#!/usr/bin/env bats
# Agent-authored prose must never be interpolated into a double-quoted shell
# string (#234).
#
# Observed on PR #233's review: the reviewer's PR comment was posted with
# `gh pr comment <N> -b "<full analysis>"`, so the shell command-substituted
# every backticked token in the prose before `gh` ever saw it. `pwd -P` posted
# as the reviewer's working directory, `radio orphans` posted as that command's
# tab-separated output, and backticked identifiers naming no command
# (`$WORKTREE_DIR`, `_resume_session_id()`) posted as nothing at all — the
# finding's subject deleted, with nothing to signal a word was gone. The
# reviewer self-destructs by design, so its PR comment is the only surviving
# artifact and a mangled one is an unrecoverable loss of the analysis.
#
# Two layers here. The behavioural tests pin *why* `--body-file -` off a
# quote-delimited heredoc is the fix and the alternatives are not — they would
# have failed against the old pattern. The prompt-contract tests pin that every
# shipped prompt actually says so, in every loadout, since the fix lives in
# prose the model reads rather than in code anyone can call.

bats_load_library bats-support
bats_load_library bats-assert

load helpers/common

# Review prose with one of each hazard: a backticked command that succeeds and
# prints, a backticked identifier that is no command at all (substitutes to
# empty), an apostrophe (which rules out the single-quote "fix"), and `$(…)` /
# `${…}` for good measure.
PROSE='canonicalize with `pwd -P`; `$WORKTREE_DIR` is unset here, and don'\''t trust $(date) or ${HOME}'

setup() {
  setup_task_force_home
  unset ZELLIJ                       # no wakeup attempts in unit tests
  export TASK_FORCE_ROLE=test-runner
  export RADIO

  # A `gh` stand-in that prints the body it was actually handed, so the
  # assertions are on what would have reached GitHub rather than on what the
  # prompt says. Real `gh` is never invoked: these tests are about the shell,
  # not about the forge.
  FAKE_BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$FAKE_BIN"
  cat > "$FAKE_BIN/gh" <<'GH'
#!/usr/bin/env bash
body=''
while [[ $# -gt 0 ]]; do
  case "$1" in
    -b|--body)      body="$2"; shift 2 ;;
    -F|--body-file) if [[ "$2" == - ]]; then body="$(cat)"; else body="$(cat "$2")"; fi; shift 2 ;;
    *)              shift ;;
  esac
done
printf '%s' "$body"
GH
  chmod +x "$FAKE_BIN/gh"
  export FAKE_BIN
}

teardown() {
  teardown_all
}

# Run a snippet the way an agent would: as shell source, so heredocs and
# quoting behave exactly as they do when the model types the command.
run_snippet() {
  printf '%s\n' "PATH=\"\$FAKE_BIN:\$PATH\"" > "$BATS_TEST_TMPDIR/snippet.sh"
  cat >> "$BATS_TEST_TMPDIR/snippet.sh"
  bash "$BATS_TEST_TMPDIR/snippet.sh"
}

# ----- behaviour: what each quoting form actually delivers -------------------

@test "the old -b \"…\" form is the bug: backticked code is substituted before gh sees it" {
  run run_snippet <<'SNIPPET'
gh pr comment 42 -b "canonicalize with `pwd -P`; `$WORKTREE_DIR` is unset here"
SNIPPET
  assert_success
  # The command ran and its output took the code's place…
  refute_output --partial 'pwd -P'
  assert_output --partial "$PWD"
  # …and the identifier that named no command was deleted outright, leaving a
  # sentence with a hole in it and no marker that anything was removed.
  refute_output --partial 'WORKTREE_DIR'
  assert_output --partial 'canonicalize with'
}

@test "--body-file - off a quote-delimited heredoc reaches gh verbatim" {
  run run_snippet <<'SNIPPET'
gh pr comment 42 --body-file - <<'REVIEW'
canonicalize with `pwd -P`; `$WORKTREE_DIR` is unset here, and don't trust $(date) or ${HOME}
REVIEW
SNIPPET
  assert_success
  assert_output "$PROSE"
}

@test "the quote on the heredoc delimiter is what does the work, not the heredoc" {
  run run_snippet <<'SNIPPET'
gh pr comment 42 --body-file - <<REVIEW
canonicalize with `pwd -P`; `$WORKTREE_DIR` is unset here
REVIEW
SNIPPET
  assert_success
  refute_output --partial 'pwd -P'      # <<REVIEW substitutes exactly as "…" does
  refute_output --partial 'WORKTREE_DIR'
}

@test "single-quoting -b is not the fix: review prose contains apostrophes" {
  # The apostrophe in "don't" closes the string, so the rest of the review is
  # read as shell and the trailing quote is left unterminated: the snippet does
  # not even parse, let alone post. This is why the fix is `--body-file -` and
  # not `-b '…'`.
  run run_snippet <<'SNIPPET'
gh pr comment 42 -b 'a finding about `pwd -P` that don't get posted'
SNIPPET
  assert_failure
  assert_output --partial 'unexpected EOF'
  refute_output --partial 'a finding about'
}

@test "radio send takes its body from stdin, verbatim (#234)" {
  "$RADIO" register --role pm --tab pm --agent claude
  run run_snippet <<'SNIPPET'
TASK_FORCE_ROLE=reviewer-foo-pr42 "$RADIO" send --to pm --intent review-complete-with-findings --pr 42 <<'SUMMARY'
1 blocker: `_resume_session_id()` never sees `$WORKTREE_DIR`; don't merge
SUMMARY
SNIPPET
  assert_success
  local msg
  msg=$(ls "$TASK_FORCE_HOME/radio/mailbox/pm/inbox/"*.md | head -1)
  run cat "$msg"
  assert_output --partial 'from: reviewer-foo-pr42'
  assert_output --partial '1 blocker: `_resume_session_id()` never sees `$WORKTREE_DIR`; don'"'"'t merge'
}

# ----- prompt contract: every loadout has to say it ------------------------

# Prompt text, whether it lives in a markdown file or a kiro agent's JSON
# "prompt" field. Same accessor shape as tests/worker_checklist.bats.
prompt_text() {
  case "$1" in
    *.json) python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["prompt"])' "$1" ;;
    *)      cat "$1" ;;
  esac
}

ALL_REVIEWER_PROMPTS=(
  "$REPO_ROOT_REAL/.claude/commands/reviewer.md"
  "$REPO_ROOT_REAL/claude-gh/commands/reviewer.md"
  "$REPO_ROOT_REAL/claude-jira/commands/reviewer.md"
  "$REPO_ROOT_REAL/claude-notion/commands/reviewer.md"
  "$REPO_ROOT_REAL/claude-local/commands/reviewer.md"
  "$REPO_ROOT_REAL/kiro-gh/agents/reviewer.json"
)

ALL_PM_PROMPTS=(
  "$REPO_ROOT_REAL/.claude/commands/pm.md"
  "$REPO_ROOT_REAL/claude-gh/commands/pm.md"
  "$REPO_ROOT_REAL/claude-jira/commands/pm.md"
  "$REPO_ROOT_REAL/claude-notion/commands/pm.md"
  "$REPO_ROOT_REAL/claude-local/commands/pm.md"
  "$REPO_ROOT_REAL/kiro-gh/agents/pm.json"
  "$REPO_ROOT_REAL/kiro-local/agents/pm.json"
  "$REPO_ROOT_REAL/kiro-notion/agents/pm.json"
)

# Every shipped prompt, all four roles across all seven loadouts, plus the
# dogfood copies this repo runs on.
all_prompts() {
  printf '%s\n' \
    "$REPO_ROOT_REAL"/.claude/commands/*.md \
    "$REPO_ROOT_REAL"/claude-gh/commands/*.md \
    "$REPO_ROOT_REAL"/claude-jira/commands/*.md \
    "$REPO_ROOT_REAL"/claude-notion/commands/*.md \
    "$REPO_ROOT_REAL"/claude-local/commands/*.md \
    "$REPO_ROOT_REAL"/kiro-gh/agents/*.json \
    "$REPO_ROOT_REAL"/kiro-local/agents/*.json \
    "$REPO_ROOT_REAL"/kiro-notion/agents/*.json
}

@test "the sweep below covers all 30 shipped prompts — 20 markdown + 10 kiro JSON" {
  # Load-bearing: the negative assertions that follow are globs in a loop, so a
  # glob that matched nothing would pass them vacuously. It is also the exact
  # shape of the trap in this bug — `grep -rn -- '-b "'` finds the 20 markdown
  # prompts and MISSES all 10 kiro agent JSONs, because inside a JSON string the
  # quotes are backslash-escaped (`-b \"`). Fix by grep alone and you ship 20 of
  # 30 files fixed with kiro silently still broken.
  local all md json
  all=$(all_prompts | wc -l | tr -d ' ')
  md=$(all_prompts | grep -c '\.md$')
  json=$(all_prompts | grep -c '\.json$')
  assert_equal "$all" 30
  assert_equal "$md" 20
  assert_equal "$json" 10
  # Every path resolved to a real file (an unexpanded glob would count as 1).
  local f
  while read -r f; do assert [ -f "$f" ]; done < <(all_prompts)
}

@test "no shipped prompt hands gh a body through a double-quoted shell string" {
  local f bad=0
  while read -r f; do
    # Anchored on the gh subcommand and stopped at the next backtick, so the
    # rule text that *quotes* `-b "..."` as the thing not to do doesn't match.
    if prompt_text "$f" | grep -nE 'gh (pr comment|pr review|issue create|issue edit|issue comment)[^`]*(-b|--body) "'; then
      echo "^^^ $f passes a body in double quotes (#234)"
      bad=1
    fi
  done < <(all_prompts)
  [ "$bad" -eq 0 ]
}

@test "no shipped prompt puts a model-filled slot inside a quoted --body" {
  # The boundary is *slots*, not trackers. A `<…>` anywhere inside the quoted
  # body is a hole the model fills with text it did not choose the charset of,
  # so it goes on stdin; a body that is literal end to end can stay quoted.
  #
  # Anchoring on the START of the body (`--body "<`) is not enough, and that is
  # the hole this test was widened to close: the notion planners read
  # `--body "spec written for <task name>, …"`, with the slot in the middle.
  # A Notion task titled the way this repo titles its own issues — "a resumed
  # session has no $TASK_FORCE_ROLE", or anything with backticks — would lose
  # the variable name to an empty expansion, or execute.
  local f bad=0
  while read -r f; do
    if prompt_text "$f" | grep -nE -- '--body "[^"]*<[^"]*"'; then
      echo "^^^ $f has a model-filled slot inside a quoted --body (#234)"
      bad=1
    fi
  done < <(all_prompts)
  [ "$bad" -eq 0 ]
}

@test "every reviewer prompt posts its PR comment with --body-file - off a quoted heredoc" {
  for f in "${ALL_REVIEWER_PROMPTS[@]}"; do
    run prompt_text "$f"
    assert_success
    assert_output --partial 'gh pr comment <N> --body-file - '"<<'REVIEW'"
    assert_output --partial 'REVIEW'
  done
}

@test "every reviewer prompt radios its verdict summary on stdin" {
  for f in "${ALL_REVIEWER_PROMPTS[@]}"; do
    run prompt_text "$f"
    assert_success
    assert_output --partial "radio send --to pm --intent review-complete-clean --pr <N> <<'SUMMARY'"
    assert_output --partial "radio send --to pm --intent review-complete-with-findings --pr <N> <<'SUMMARY'"
  done
}

@test "every reviewer prompt explains the substituted-to-empty case, not just the noisy one" {
  # The silent failure is the one worth the words: a noisy substitution is
  # visible in the posted comment, a deleted identifier is not.
  for f in "${ALL_REVIEWER_PROMPTS[@]}"; do
    run prompt_text "$f"
    assert_success
    assert_output --partial 'nothing at all'
    assert_output --partial '_some_helper()'
  done
}

# The posting steps are identical prose in all five claude reviewer prompts —
# keep them that way, or a fix lands in some loadouts and not others (the #32 /
# #38 / #40 failure mode that tools/check-drift.sh guards for shell).
posting_block() {
  awk '/^7\. Post the comment/{p=1} p&&/^9\. /{exit} p{print}' "$1"
}

@test "the reviewer posting block does not drift across the claude loadouts" {
  local ref="" cur
  for f in "$REPO_ROOT_REAL"/.claude/commands/reviewer.md \
           "$REPO_ROOT_REAL"/claude-{gh,jira,notion,local}/commands/reviewer.md; do
    cur=$(posting_block "$f")
    [ -n "$cur" ] || { echo "no posting block in $f"; return 1; }
    if [ -z "$ref" ]; then ref="$cur"; continue; fi
    [ "$cur" = "$ref" ] || { echo "posting block drifted in $f"; diff <(echo "$ref") <(echo "$cur"); return 1; }
  done
}

@test "the PM prose rule is one line of prose, identical in every pm prompt" {
  local ref="" cur
  for f in "${ALL_PM_PROMPTS[@]}"; do
    cur=$(prompt_text "$f" | grep -F 'Prose you author never goes through')
    [ -n "$cur" ] || { echo "no prose rule in $f"; return 1; }
    if [ -z "$ref" ]; then ref="$cur"; continue; fi
    [ "$cur" = "$ref" ] || { echo "prose rule drifted in $f"; diff <(echo "$ref") <(echo "$cur"); return 1; }
  done
}

@test "every workflow doc carries the stdin rule" {
  local f
  for f in "$REPO_ROOT_REAL"/.claude/gh-workflow.md \
           "$REPO_ROOT_REAL"/claude-gh/steering/gh-workflow.example.md \
           "$REPO_ROOT_REAL"/claude-jira/steering/jira-workflow.example.md \
           "$REPO_ROOT_REAL"/claude-notion/steering/notion-workflow.example.md \
           "$REPO_ROOT_REAL"/claude-local/steering/local-workflow.example.md \
           "$REPO_ROOT_REAL"/kiro-gh/steering/gh-workflow.example.md \
           "$REPO_ROOT_REAL"/kiro-notion/steering/notion-workflow.example.md \
           "$REPO_ROOT_REAL"/kiro-local/steering/local-workflow.example.md; do
    run grep -qF 'never through a double-quoted shell' "$f"
    assert_success
  done
}

@test "every worker prompt commits its message on stdin, not through -m \"…\"" {
  # A commit message is prose too, and this repo's commit bodies name files and
  # symbols in backticks by the paragraph. Substituting them there corrupts git
  # history, which is less recoverable than a PR comment.
  local f
  for f in "$REPO_ROOT_REAL"/.claude/commands/worker.md \
           "$REPO_ROOT_REAL"/claude-{gh,jira,notion,local}/commands/worker.md \
           "$REPO_ROOT_REAL"/kiro-{gh,local,notion}/agents/worker.json; do
    run prompt_text "$f"
    assert_success
    assert_output --partial 'git commit -F -'
    assert_output --partial "<<'MSG'"
  done
}

@test "no shipped prompt tells the agent to commit with git commit -m \"…\"" {
  local f bad=0
  while read -r f; do
    if prompt_text "$f" | grep -nE 'git commit[^`]*-m "'; then
      echo "^^^ $f interpolates a commit message into a double-quoted string (#234)"
      bad=1
    fi
  done < <(all_prompts)
  [ "$bad" -eq 0 ]
}

@test "git commit -F - takes the message from stdin verbatim" {
  # The behavioural half of the commit-message rule: same proof as the gh one,
  # against real git rather than a stand-in.
  setup_repo
  cat > "$BATS_TEST_TMPDIR/commit.sh" <<'SCRIPT'
set -e
cd "$MAIN_REPO"
echo change >> README.md
git add README.md
git commit -q --no-verify -F - <<'MSG'
subject: recover `$SOME_VAR` in `_some_helper()`

body: canonicalize with `pwd -P`; don't trust $(date) or ${HOME}
MSG
git log -1 --format=%B
SCRIPT
  run env MAIN_REPO="$MAIN_REPO" bash "$BATS_TEST_TMPDIR/commit.sh"
  assert_success
  assert_output --partial 'subject: recover `$SOME_VAR` in `_some_helper()`'
  assert_output --partial "body: canonicalize with \`pwd -P\`; don't trust \$(date) or \${HOME}"
}
