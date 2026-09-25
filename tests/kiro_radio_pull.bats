#!/usr/bin/env bats
# kiro loadouts lead with the agent's own inbox poll (#190 option B, as amended
# by #218).
#
# kiro has one of claude's three pull paths: the register backlog report (#168),
# whose stdout does reach the model. It lacks the Stop-hook block-and-drain
# (#163) and the prompt-hook inbox injection (#164) — both because it is wired
# with plain `radio busy` / `radio ready`, which is an un-taken decision (#221)
# rather than a platform limit. The original reason given here — that kiro
# discards hook stdout — was false: it injects it. Nobody had observed injection
# because the hooks were written to `.kiro/hooks/`, which kiro-cli never reads,
# so none of them had ever run (#218).
#
# What covers the remaining gap is a standing instruction in every kiro agent
# prompt to poll its own inbox, plus docs that say so instead of implying
# parity. These tests pin both halves — they are the thing that would silently
# rot, as the injection claim itself did.

bats_load_library bats-support
bats_load_library bats-assert

load helpers/common

KIRO_AGENTS=(
  "$REPO_ROOT_REAL/kiro-gh/agents/planner.json"
  "$REPO_ROOT_REAL/kiro-gh/agents/pm.json"
  "$REPO_ROOT_REAL/kiro-gh/agents/reviewer.json"
  "$REPO_ROOT_REAL/kiro-gh/agents/worker.json"
  "$REPO_ROOT_REAL/kiro-local/agents/planner.json"
  "$REPO_ROOT_REAL/kiro-local/agents/pm.json"
  "$REPO_ROOT_REAL/kiro-local/agents/worker.json"
  "$REPO_ROOT_REAL/kiro-notion/agents/planner.json"
  "$REPO_ROOT_REAL/kiro-notion/agents/pm.json"
  "$REPO_ROOT_REAL/kiro-notion/agents/worker.json"
)

KIRO_TEMPLATES=(
  "$REPO_ROOT_REAL/kiro-gh/steering/gh-workflow.example.md"
  "$REPO_ROOT_REAL/kiro-local/steering/local-workflow.example.md"
  "$REPO_ROOT_REAL/kiro-notion/steering/notion-workflow.example.md"
)

# Print the leading inbox-poll block of an agent prompt: everything up to (and
# not including) the blank line that ends it. Requires jq, like task-init does.
poll_block() {
  jq -r '.prompt' "$1" | awk 'NF==0 && seen {exit} {print; if (NF) seen=1}'
}

@test "every kiro agent prompt opens with the standing radio-check instruction" {
  for f in "${KIRO_AGENTS[@]}"; do
    assert [ -f "$f" ]
    run jq -r '.prompt' "$f"
    assert_success
    assert_output --partial "## Radio inbox — poll it yourself, every turn"
    assert_output --partial 'run `radio check` at the start of every turn'
    assert_output --partial '`radio read <id>`'
    # The instruction has to be the first thing the agent reads, not buried
    # after a workflow it may never finish.
    run bash -c "jq -r '.prompt' '$f' | head -1"
    assert_output "## Radio inbox — poll it yourself, every turn"
  done
}

@test "the poll instruction is byte-identical across all 10 kiro agents (#177 loadout-neutral)" {
  local ref
  ref=$(poll_block "${KIRO_AGENTS[0]}")
  assert [ -n "$ref" ]
  for f in "${KIRO_AGENTS[@]}"; do
    run poll_block "$f"
    assert_success
    assert_output "$ref"
  done
}

@test "the poll instruction names no loadout-specific tool (#177)" {
  # It ships verbatim into gh / local / notion agents, so it must not mention
  # GitHub, Notion, or the local board.
  local block
  block=$(poll_block "${KIRO_AGENTS[0]}")
  run grep -icE 'github|notion|gh cli|`gh `|task-board' <<<"$block"
  assert_output "0"
}

@test "every kiro agent JSON stays parseable after the prompt edit" {
  for f in "${KIRO_AGENTS[@]}"; do
    run jq -e 'has("name") and has("prompt") and has("tools")' "$f"
    assert_success
  done
}

@test "each kiro steering template documents best-effort delivery and the orphans cleanup step" {
  for f in "${KIRO_TEMPLATES[@]}"; do
    assert [ -f "$f" ]
    run cat "$f"
    assert_success
    assert_output --partial "Delivery here is pull-first"
    assert_output --partial "no block-and-drain"
    assert_output --partial "no session-end trigger"
    assert_output --partial "radio orphans"
  done
}

@test "no kiro steering template carries claude's delivery promises" {
  # Guards against the failure mode #190 set out to fix: claude wording copied
  # verbatim into a kiro doc. Matches the promise phrasings specifically, so a
  # future sentence that *denies* one of these mechanisms still passes.
  for f in "${KIRO_TEMPLATES[@]}"; do
    run grep -cE 'drain on its next Stop|surface via prompt-hook|injects (a summary|the inbox)' "$f"
    assert_output "0"
  done
}

@test "the README documents the kiro asymmetry rather than implying parity" {
  run cat "$REPO_ROOT_REAL/README.md"
  assert_success
  assert_output --partial "### kiro delivery: pull-first, with one backstop"
  assert_output --partial "**kiro does inject hook stdout into the model's context.**"
  assert_output --partial "**Kiro agents still pull.**"
}
