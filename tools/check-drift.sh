#!/usr/bin/env bash
# Check that named sentinel regions are byte-identical across grouped loadout
# files. Catches the "fix lands in 6 of 7 loadouts" failure mode (#32, #38, #40).
#
# Manifest format (one entry per line in $GROUPS, fields | -separated):
#   <group-label>|<region-name>|<file1> <file2> ...
#
# Override the manifest for tests by setting CHECK_DRIFT_MANIFEST to a file path.
#
# A region is the lines between `# region:<name>` and `# endregion:<name>`. In a
# markdown prompt, where a `#` line renders as a heading, the sentinels may be
# written `<!-- region:<name> -->` / `<!-- endregion:<name> -->` instead. A kiro
# agent config (*.json) is checked on its `prompt` string, since its lines exist
# only once the JSON is decoded (#320).

set -euo pipefail

# region:default-manifest
GROUPS_DEFAULT=(
  "radio-install-hooks|radio-hook-cmds|claude-gh/bin/task-init claude-jira/bin/task-init claude-local/bin/task-init claude-notion/bin/task-init"
  "radio-install-hooks|radio-hooks-jq-merge|claude-gh/bin/task-init claude-jira/bin/task-init claude-local/bin/task-init claude-notion/bin/task-init"
  "radio-install-hooks|radio-stray-hook-verify|claude-gh/bin/task-init claude-jira/bin/task-init claude-local/bin/task-init claude-notion/bin/task-init"
  "kiro-radio-install-hooks|kiro-radio-hook-cmds|kiro-gh/bin/task-init kiro-local/bin/task-init kiro-notion/bin/task-init"
  "kiro-radio-install-hooks|kiro-radio-hooks-jq-merge|kiro-gh/bin/task-init kiro-local/bin/task-init kiro-notion/bin/task-init"
  "kiro-radio-install-hooks|kiro-radio-stray-hook-verify|kiro-gh/bin/task-init kiro-local/bin/task-init kiro-notion/bin/task-init"
  "kiro-radio-install-hooks|kiro-radio-legacy-hooks-sweep|kiro-gh/bin/task-init kiro-local/bin/task-init kiro-notion/bin/task-init"
  "radio-legacy-hook-guard|radio-legacy-hook-guard|kiro-gh/bin/task-init kiro-local/bin/task-init kiro-notion/bin/task-init lib/loadout-artifacts.sh"
  "read-only-allow|read-only-allow|claude-gh/bin/task-init claude-jira/bin/task-init claude-local/bin/task-init claude-notion/bin/task-init"
  "managed-region-source|managed-region-source|claude-gh/bin/task-init claude-jira/bin/task-init claude-local/bin/task-init claude-notion/bin/task-init kiro-gh/bin/task-init kiro-local/bin/task-init kiro-notion/bin/task-init"
  "require-jq-source|require-jq-source|claude-gh/bin/task-init claude-jira/bin/task-init claude-local/bin/task-init claude-notion/bin/task-init kiro-gh/bin/task-init kiro-local/bin/task-init kiro-notion/bin/task-init"
  "require-jq-call|require-jq-call|claude-gh/bin/task-init claude-jira/bin/task-init claude-local/bin/task-init claude-notion/bin/task-init kiro-gh/bin/task-init kiro-local/bin/task-init kiro-notion/bin/task-init"
  "tracker-settings|tracker-settings-source|claude-gh/bin/task-init claude-jira/bin/task-init claude-notion/bin/task-init kiro-gh/bin/task-init kiro-notion/bin/task-init"
  "tracker-settings-notion|notion-settings-render|claude-notion/bin/task-init kiro-notion/bin/task-init"
  "tracker-settings-gh|tracker-preserve-gh|claude-gh/bin/task-init kiro-gh/bin/task-init"
  "install-shared-symlinks|install-shared-symlinks|claude-gh/install.sh claude-jira/install.sh claude-local/install.sh claude-notion/install.sh kiro-gh/install.sh kiro-local/install.sh kiro-notion/install.sh"
  "reviewer-contract|reviewer-destruct-summary|.claude/commands/reviewer.md claude-gh/commands/reviewer.md claude-jira/commands/reviewer.md claude-local/commands/reviewer.md claude-notion/commands/reviewer.md kiro-gh/agents/reviewer.json kiro-local/agents/reviewer.json kiro-notion/agents/reviewer.json"
  "reviewer-contract|reviewer-post-radio-destruct|.claude/commands/reviewer.md claude-gh/commands/reviewer.md claude-jira/commands/reviewer.md claude-local/commands/reviewer.md claude-notion/commands/reviewer.md kiro-gh/agents/reviewer.json kiro-local/agents/reviewer.json kiro-notion/agents/reviewer.json"
)
# endregion:default-manifest

# The text a file's sentinels live in: a kiro agent config's decoded prompt,
# otherwise the file itself.
region_source() {
  case "$1" in
    *.json) jq -r '.prompt // empty' "$1" ;;
    *)      cat "$1" ;;
  esac
}

extract_region() {
  local file="$1" region="$2"
  region_source "$file" | awk -v r="$region" '
    $0 == "# region:" r || $0 == "<!-- region:" r " -->" { in_region=1; next }
    $0 == "# endregion:" r || $0 == "<!-- endregion:" r " -->" { in_region=0; next }
    in_region { print }
  '
}

has_region() {
  local file="$1" region="$2"
  # Not a pipe: grep -q exits on the first match, and under pipefail the
  # writer's SIGPIPE would turn a found region into a missing one.
  grep -qFx -e "# region:$region" -e "<!-- region:$region -->" <<<"$(region_source "$file")"
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
    if ! has_region "$file" "$region"; then
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
