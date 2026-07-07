#!/usr/bin/env bash
# Check that named sentinel regions are byte-identical across grouped loadout
# files. Catches the "fix lands in 6 of 7 loadouts" failure mode (#32, #38, #40).
#
# Manifest format (one entry per line in $GROUPS, fields | -separated):
#   <group-label>|<region-name>|<file1> <file2> ...
#
# Override the manifest for tests by setting CHECK_DRIFT_MANIFEST to a file path.

set -euo pipefail

# region:default-manifest
GROUPS_DEFAULT=(
  "task-done-std|flag-parsing|claude-gh/bin/task-done claude-jira/bin/task-done claude-notion/bin/task-done kiro-gh/bin/task-done kiro-notion/bin/task-done"
  "task-done-std|worktree-context|claude-gh/bin/task-done claude-jira/bin/task-done claude-notion/bin/task-done kiro-gh/bin/task-done kiro-notion/bin/task-done"
  "task-done-std|diff-summary|claude-gh/bin/task-done claude-jira/bin/task-done claude-notion/bin/task-done kiro-gh/bin/task-done kiro-notion/bin/task-done"
  "task-done-std|confirm-and-cleanup|claude-gh/bin/task-done claude-jira/bin/task-done claude-notion/bin/task-done kiro-gh/bin/task-done kiro-notion/bin/task-done"
  "task-done-local|flag-parsing|claude-local/bin/task-done kiro-local/bin/task-done"
  "task-done-local|worktree-context|claude-local/bin/task-done kiro-local/bin/task-done"
  "task-done-local|diff-summary|claude-local/bin/task-done kiro-local/bin/task-done"
  "task-done-local|confirm-and-cleanup|claude-local/bin/task-done kiro-local/bin/task-done"
  "task-work|lib-source-header|claude-gh/bin/task-work claude-jira/bin/task-work claude-local/bin/task-work claude-notion/bin/task-work kiro-gh/bin/task-work kiro-local/bin/task-work kiro-notion/bin/task-work"
  "task-work|worktree-creation-pre-info|claude-gh/bin/task-work claude-local/bin/task-work claude-notion/bin/task-work kiro-gh/bin/task-work kiro-local/bin/task-work kiro-notion/bin/task-work"
  "task-work-claude|worktree-creation-post-info|claude-gh/bin/task-work claude-local/bin/task-work claude-notion/bin/task-work"
  "task-work-kiro|worktree-creation-post-info|kiro-gh/bin/task-work kiro-local/bin/task-work kiro-notion/bin/task-work"
  "task-work|radio-env-injection|claude-gh/bin/task-work claude-jira/bin/task-work claude-local/bin/task-work claude-notion/bin/task-work kiro-gh/bin/task-work kiro-local/bin/task-work kiro-notion/bin/task-work"
  "task-work|info-tab-id|claude-gh/bin/task-work claude-jira/bin/task-work claude-local/bin/task-work claude-notion/bin/task-work kiro-gh/bin/task-work kiro-local/bin/task-work kiro-notion/bin/task-work"
  "radio-install-hooks|radio-hook-cmds|claude-gh/bin/task-init claude-jira/bin/task-init claude-local/bin/task-init claude-notion/bin/task-init"
  "radio-install-hooks|radio-hooks-jq-merge|claude-gh/bin/task-init claude-jira/bin/task-init claude-local/bin/task-init claude-notion/bin/task-init"
  "radio-install-hooks|radio-stray-hook-verify|claude-gh/bin/task-init claude-jira/bin/task-init claude-local/bin/task-init claude-notion/bin/task-init"
  "read-only-allow|read-only-allow|claude-gh/bin/task-init claude-jira/bin/task-init claude-local/bin/task-init claude-notion/bin/task-init"
  "require-jq-source|require-jq-source|claude-gh/bin/task-init claude-jira/bin/task-init claude-local/bin/task-init claude-notion/bin/task-init"
  "require-jq-call|require-jq-call|claude-gh/bin/task-init claude-jira/bin/task-init claude-local/bin/task-init claude-notion/bin/task-init"
  "install-shared-symlinks|install-shared-symlinks|claude-gh/install.sh claude-jira/install.sh claude-local/install.sh claude-notion/install.sh kiro-gh/install.sh kiro-local/install.sh kiro-notion/install.sh"
)
# endregion:default-manifest

extract_region() {
  local file="$1" region="$2"
  awk -v r="$region" '
    $0 == "# region:" r { in_region=1; next }
    $0 == "# endregion:" r { in_region=0; next }
    in_region { print }
  ' "$file"
}

# Compare a single (group, region, files...) entry. Returns 0 if all files
# share byte-identical content for the named region, 1 otherwise.
check_group() {
  local group="$1" region="$2"
  shift 2
  local files=("$@")
  local ref_file="" ref_content="" failed=0

  for file in "${files[@]}"; do
    if [[ ! -f "$file" ]]; then
      echo "FAIL [$group/$region]: missing file: $file" >&2
      failed=1
      continue
    fi
    # Distinguish "no opening sentinel" from "sentinel pair brackets empty body":
    # both produce empty extract output, but the former is almost always the bug
    # (someone renamed the region or forgot to mark a new file), while the
    # latter is a deliberate placeholder.
    if ! grep -qFx "# region:$region" "$file"; then
      echo "FAIL [$group/$region]: region missing in: $file" >&2
      failed=1
      continue
    fi
    local content
    content=$(extract_region "$file" "$region")
    if [[ -z "$content" ]]; then
      echo "FAIL [$group/$region]: region empty in: $file" >&2
      failed=1
      continue
    fi
    if [[ -z "$ref_file" ]]; then
      ref_file="$file"
      ref_content="$content"
      continue
    fi
    if [[ "$content" != "$ref_content" ]]; then
      echo "DRIFT [$group/$region]: $file diverges from $ref_file" >&2
      diff -u --label "$ref_file" --label "$file" \
        <(printf '%s\n' "$ref_content") \
        <(printf '%s\n' "$content") >&2 || true
      failed=1
    fi
  done

  return "$failed"
}

# Read manifest entries from stdin (one per line). Lines starting with '#' or
# blank lines are skipped.
run_manifest() {
  local fail=0 checked=0
  local line group region files_str
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" || "$line" == \#* ]] && continue
    IFS='|' read -r group region files_str <<<"$line"
    # shellcheck disable=SC2206
    files=($files_str)
    checked=$((checked + 1))
    check_group "$group" "$region" "${files[@]}" || fail=1
  done
  echo "check-drift: $checked group(s) checked"
  return "$fail"
}

main() {
  if [[ -n "${CHECK_DRIFT_MANIFEST:-}" ]]; then
    [[ -f "$CHECK_DRIFT_MANIFEST" ]] || {
      echo "Error: manifest file not found: $CHECK_DRIFT_MANIFEST" >&2
      exit 2
    }
    run_manifest < "$CHECK_DRIFT_MANIFEST"
  else
    printf '%s\n' "${GROUPS_DEFAULT[@]}" | run_manifest
  fi
}

# Only run main when executed directly (so tests can source this script and
# call check_group / extract_region without triggering the manifest run).
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
