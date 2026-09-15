#!/usr/bin/env bats
# The task-init managed region (#183).
#
# The workflow doc is the one installed file users are told to edit (#177 puts
# the repo-specific gloss in it) *and* the one a documented upgrade re-renders.
# Three times a `task-init` re-run dropped a hand-authored section from it; the
# third took a red suite onto main. These tests pin the boundary that makes the
# two instructions compatible: task-init owns what is between the markers,
# the user owns everything after the end marker, and a re-run must never cross
# that line.

bats_load_library bats-support
bats_load_library bats-assert

load helpers/common

MANAGED_LIB="$REPO_ROOT_REAL/lib/managed-region.sh"
INSTALL_FILE_LIB="$REPO_ROOT_REAL/lib/install-file.sh"

START='<!-- task-init:managed:start -->'
END='<!-- task-init:managed:end -->'

setup() {
  TMP_DIR=$(mktemp -d)
  SRC="$TMP_DIR/template.md"
  DEST="$TMP_DIR/sub/workflow.md"
  printf '## Template\n\nrendered body v1\n' > "$SRC"
}

teardown() {
  [[ -n "${TMP_DIR:-}" && -d "$TMP_DIR" ]] && rm -rf "$TMP_DIR"
  teardown_all
}

# Run install_managed_file in a subshell so each call gets a fresh policy.
# stdin is /dev/null unless the caller pipes something in.
_run_managed() {
  local policy="$1"; shift
  run env INSTALL_POLICY="$policy" bash -c \
    "source '$INSTALL_FILE_LIB'; source '$MANAGED_LIB'; install_managed_file \"\$@\"" _ "$@"
}

# ---------------------------------------------------------------------------
# Fresh install
# ---------------------------------------------------------------------------

@test "missing dest: writes the template wrapped in managed markers" {
  _run_managed keep "$SRC" "$DEST" "workflow.md" </dev/null
  assert_success
  assert [ -f "$DEST" ]
  run cat "$DEST"
  assert_output --partial "$START"
  assert_output --partial "rendered body v1"
  assert_output --partial "$END"
}

@test "missing dest: start marker is the first line, tail stub comes after the end" {
  _run_managed force "$SRC" "$DEST" "workflow.md" </dev/null
  assert_success
  run head -1 "$DEST"
  assert_output "$START"
  # The tail is the user's: it must sit after the end marker, not before it.
  local end_line tail_line
  end_line=$(grep -nFx "$END" "$DEST" | cut -d: -f1)
  tail_line=$(grep -nFx '## Repo-specific notes' "$DEST" | cut -d: -f1)
  assert [ -n "$end_line" ]
  assert [ "$tail_line" -gt "$end_line" ]
}

@test "missing dest: every policy writes, including restore" {
  for policy in keep force restore prompt; do
    rm -rf "$TMP_DIR/sub"
    _run_managed "$policy" "$SRC" "$DEST" "workflow.md" </dev/null
    assert_success
    assert [ -f "$DEST" ]
  done
}

@test "missing source is an error" {
  _run_managed force "$TMP_DIR/nope.md" "$DEST" "workflow.md" </dev/null
  assert_failure
  assert_output --partial "source not found"
}

@test "unknown policy is an error" {
  _run_managed bogus "$SRC" "$DEST" "workflow.md" </dev/null
  assert_failure
  assert_output --partial "unknown INSTALL_POLICY"
}

# ---------------------------------------------------------------------------
# The load-bearing property: a re-render never touches out-of-region content
# ---------------------------------------------------------------------------

@test "force re-render replaces the region and preserves out-of-region content" {
  _run_managed force "$SRC" "$DEST" "workflow.md" </dev/null
  assert_success
  printf '\n### Pre-PR checklist (this repo)\n\nGreen means ./run_tests.sh here.\n' >> "$DEST"

  printf '## Template\n\nrendered body v2\n' > "$SRC"
  _run_managed force "$SRC" "$DEST" "workflow.md" </dev/null
  assert_success
  assert_output --partial "Refreshed the managed region"

  run cat "$DEST"
  assert_output --partial "rendered body v2"
  refute_output --partial "rendered body v1"
  # The whole point:
  assert_output --partial "### Pre-PR checklist (this repo)"
  assert_output --partial "Green means ./run_tests.sh here."
}

@test "content above the start marker is preserved too" {
  _run_managed force "$SRC" "$DEST" "workflow.md" </dev/null
  assert_success
  printf '%s\n' "PREAMBLE THE USER ADDED" | cat - "$DEST" > "$DEST.new"
  mv "$DEST.new" "$DEST"

  printf '## Template\n\nrendered body v2\n' > "$SRC"
  _run_managed force "$SRC" "$DEST" "workflow.md" </dev/null
  assert_success
  run head -1 "$DEST"
  assert_output "PREAMBLE THE USER ADDED"
  run cat "$DEST"
  assert_output --partial "rendered body v2"
}

@test "re-render with an unchanged template is a byte-for-byte no-op" {
  _run_managed force "$SRC" "$DEST" "workflow.md" </dev/null
  assert_success
  printf '\n## Mine\n\nkeep me\n' >> "$DEST"
  cp "$DEST" "$TMP_DIR/before"

  _run_managed force "$SRC" "$DEST" "workflow.md" </dev/null
  assert_success
  assert_output --partial "already up to date"
  run cmp -s "$TMP_DIR/before" "$DEST"
  assert_success
}

@test "prompt policy refreshes a marker-bearing doc without asking" {
  _run_managed force "$SRC" "$DEST" "workflow.md" </dev/null
  assert_success
  printf '\n## Mine\n\nkeep me\n' >> "$DEST"

  printf '## Template\n\nrendered body v2\n' > "$SRC"
  # Empty stdin: a prompt would read EOF and fall back to keep, leaving v1.
  _run_managed prompt "$SRC" "$DEST" "workflow.md" </dev/null
  assert_success
  refute_output --partial "[k]eep"
  run cat "$DEST"
  assert_output --partial "rendered body v2"
  assert_output --partial "keep me"
}

@test "keep and restore still leave a marker-bearing doc completely alone" {
  _run_managed force "$SRC" "$DEST" "workflow.md" </dev/null
  assert_success
  printf '\n## Mine\n\nkeep me\n' >> "$DEST"
  cp "$DEST" "$TMP_DIR/before"

  printf '## Template\n\nrendered body v2\n' > "$SRC"
  for policy in keep restore; do
    _run_managed "$policy" "$SRC" "$DEST" "workflow.md" </dev/null
    assert_success
    assert_output --partial "kept"
    run cmp -s "$TMP_DIR/before" "$DEST"
    assert_success
  done
}

@test "markers named in prose are not mistaken for the boundary" {
  # The shipped templates cite the marker strings inside backticks. Only a line
  # that *is* the marker counts, or the region would start at the prose line.
  {
    printf 'Wrap it in `%s` / `%s` markers.\n\n' "$START" "$END"
    printf '%s\n' "$START"
    printf 'old body\n'
    printf '%s\n' "$END"
    printf '\n## Mine\n\nkeep me\n'
  } > "$TMP_DIR/doc.md"

  _run_managed force "$SRC" "$TMP_DIR/doc.md" "workflow.md" </dev/null
  assert_success
  run head -1 "$TMP_DIR/doc.md"
  assert_output --partial 'Wrap it in'
  run cat "$TMP_DIR/doc.md"
  assert_output --partial "rendered body v1"
  refute_output --partial "old body"
  assert_output --partial "keep me"
}

@test "an end marker before the start marker is treated as no markers at all" {
  printf '%s\nnot a real region\n%s\ncustom\n' "$END" "$START" > "$TMP_DIR/doc.md"
  _run_managed force "$SRC" "$TMP_DIR/doc.md" "workflow.md" </dev/null
  assert_success
  assert [ -f "$TMP_DIR/doc.md.bak" ]
}

# ---------------------------------------------------------------------------
# Adopting a pre-#183 doc (no markers)
# ---------------------------------------------------------------------------

@test "marker-less doc identical to the template is re-wrapped silently" {
  mkdir -p "$(dirname "$DEST")"
  cp "$SRC" "$DEST"
  _run_managed force "$SRC" "$DEST" "workflow.md" </dev/null
  assert_success
  assert_output --partial "added task-init managed-region markers"
  refute_output --partial ".bak"
  assert [ ! -e "$DEST.bak" ]
  run head -1 "$DEST"
  assert_output "$START"
}

@test "customized marker-less doc is backed up before the markers are added" {
  mkdir -p "$(dirname "$DEST")"
  cat "$SRC" > "$DEST"
  printf '\n### Pre-PR checklist (this repo)\n\nGreen means ./run_tests.sh here.\n' >> "$DEST"

  _run_managed force "$SRC" "$DEST" "workflow.md" </dev/null
  assert_success
  assert_output --partial "predates the managed region"
  assert [ -f "$DEST.bak" ]
  # Nothing is lost: the hand-added section is intact in the backup…
  run cat "$DEST.bak"
  assert_output --partial "Green means ./run_tests.sh here."
  # …and the live file now has the markers, so the NEXT re-run preserves in place.
  run head -1 "$DEST"
  assert_output "$START"
}

@test "a second adoption does not clobber the first backup" {
  mkdir -p "$(dirname "$DEST")"
  printf 'v1 custom\n' > "$DEST"
  _run_managed force "$SRC" "$DEST" "workflow.md" </dev/null
  assert_success
  # Strip the markers back out to force a second adoption.
  printf 'v2 custom\n' > "$DEST"
  _run_managed force "$SRC" "$DEST" "workflow.md" </dev/null
  assert_success
  run cat "$DEST.bak"
  assert_output "v1 custom"
  run cat "$DEST.bak.1"
  assert_output "v2 custom"
}

@test "prompt policy on a marker-less doc still offers keep / overwrite" {
  mkdir -p "$(dirname "$DEST")"
  printf 'custom content\n' > "$DEST"
  _run_managed prompt "$SRC" "$DEST" "workflow.md" <<<"k"
  assert_success
  assert_output --partial "kept"
  run cat "$DEST"
  assert_output "custom content"
}

@test "prompt policy overwrite on a marker-less doc adopts (backup + markers)" {
  mkdir -p "$(dirname "$DEST")"
  printf 'custom content\n' > "$DEST"
  _run_managed prompt "$SRC" "$DEST" "workflow.md" <<<"o"
  assert_success
  assert [ -f "$DEST.bak" ]
  run head -1 "$DEST"
  assert_output "$START"
  run cat "$DEST.bak"
  assert_output "custom content"
}

# ---------------------------------------------------------------------------
# End-to-end, through every loadout's task-init (the ticket applies to all 7)
# ---------------------------------------------------------------------------

# <task-init> <installed workflow doc path, relative to the repo root>
LOADOUTS=(
  "claude-gh/bin/task-init|.claude/gh-workflow.md"
  "claude-jira/bin/task-init|.claude/jira-workflow.md"
  "claude-local/bin/task-init|.claude/local-workflow.md"
  "claude-notion/bin/task-init|.claude/notion-workflow.md"
  "kiro-gh/bin/task-init|.kiro/steering/gh-workflow.md"
  "kiro-local/bin/task-init|.kiro/steering/local-workflow.md"
  "kiro-notion/bin/task-init|.kiro/steering/notion-workflow.md"
)

@test "every loadout writes the workflow doc with managed markers" {
  for entry in "${LOADOUTS[@]}"; do
    local init="${entry%%|*}" doc="${entry##*|}"
    setup_repo
    cd "$MAIN_REPO"
    run "$REPO_ROOT_REAL/$init" --workflow </dev/null
    assert_success
    assert [ -f "$MAIN_REPO/$doc" ]
    run head -1 "$MAIN_REPO/$doc"
    assert_output "$START"
    run grep -qFx "$END" "$MAIN_REPO/$doc"
    assert_success
    cd "$REPO_ROOT_REAL"
    teardown_all
  done
}

@test "every loadout's --force re-run preserves a hand-added section" {
  for entry in "${LOADOUTS[@]}"; do
    local init="${entry%%|*}" doc="${entry##*|}"
    setup_repo
    cd "$MAIN_REPO"
    run "$REPO_ROOT_REAL/$init" --workflow </dev/null
    assert_success
    printf '\n### Pre-PR checklist (this repo)\n\nGreen means ./run_tests.sh here.\n' \
      >> "$MAIN_REPO/$doc"

    run "$REPO_ROOT_REAL/$init" --workflow --force </dev/null
    assert_success
    run cat "$MAIN_REPO/$doc"
    assert_output --partial "### Pre-PR checklist (this repo)"
    assert_output --partial "Green means ./run_tests.sh here."
    # And the template half is still all there.
    assert_output --partial "$START"
    assert_output --partial "$END"
    cd "$REPO_ROOT_REAL"
    teardown_all
  done
}

# ---------------------------------------------------------------------------
# The dogfood copy — this repo's own file is the one that got clobbered
# ---------------------------------------------------------------------------

@test "this repo's .claude/gh-workflow.md carries the markers" {
  run head -1 "$REPO_ROOT_REAL/.claude/gh-workflow.md"
  assert_output "$START"
  run grep -qFx "$END" "$REPO_ROOT_REAL/.claude/gh-workflow.md"
  assert_success
}

@test "this repo's repo-specific checklist lives below the end marker" {
  local f="$REPO_ROOT_REAL/.claude/gh-workflow.md"
  local end_line section_line
  end_line=$(grep -nFx "$END" "$f" | cut -d: -f1)
  section_line=$(grep -nF '### Pre-PR checklist (this repo)' "$f" | cut -d: -f1)
  assert [ -n "$end_line" ]
  assert [ -n "$section_line" ]
  # Inside the region it would be deleted by the next re-run — the exact bug.
  assert [ "$section_line" -gt "$end_line" ]
}

@test "the shipped templates carry no markers of their own" {
  # The markers are added at install time. A template that shipped with them
  # would nest a region inside a region on the next re-render.
  for f in "$REPO_ROOT_REAL"/*/steering/*.example.md; do
    run grep -cFx "$START" "$f"
    assert_output "0"
    run grep -cFx "$END" "$f"
    assert_output "0"
  done
}
