#!/usr/bin/env bats
# Unit tests for lib/install-file.sh

bats_load_library bats-support
bats_load_library bats-assert

load helpers/common

INSTALL_FILE_LIB="$REPO_ROOT_REAL/lib/install-file.sh"

setup() {
  TMP_DIR=$(mktemp -d)
  SRC="$TMP_DIR/src.md"
  DEST="$TMP_DIR/sub/dest.md"
  printf 'NEW CONTENT\n' > "$SRC"
}

teardown() {
  [[ -n "${TMP_DIR:-}" && -d "$TMP_DIR" ]] && rm -rf "$TMP_DIR"
}

# Run install_file in a subshell so each invocation gets a fresh INSTALL_POLICY.
_run_install() {
  local policy="$1"; shift
  run env INSTALL_POLICY="$policy" bash -c "source '$INSTALL_FILE_LIB'; install_file \"\$@\"" _ "$@"
}

# ---------------------------------------------------------------------------
# Missing target → always write
# ---------------------------------------------------------------------------

@test "missing dest: keep policy writes file" {
  _run_install keep "$SRC" "$DEST" "my-label"
  assert_success
  assert [ -f "$DEST" ]
  run cat "$DEST"
  assert_output "NEW CONTENT"
}

@test "missing dest: force policy writes file" {
  _run_install force "$SRC" "$DEST" "my-label"
  assert_success
  assert [ -f "$DEST" ]
}

@test "missing dest: restore policy writes file" {
  _run_install restore "$SRC" "$DEST" "my-label"
  assert_success
  assert [ -f "$DEST" ]
}

@test "missing dest: prompt policy writes file without prompting" {
  _run_install prompt "$SRC" "$DEST" "my-label"
  assert_success
  assert [ -f "$DEST" ]
  refute_output --partial "keep"
}

@test "missing dest: creates parent directory" {
  _run_install keep "$SRC" "$TMP_DIR/a/b/c/d.md" "deep-label"
  assert_success
  assert [ -f "$TMP_DIR/a/b/c/d.md" ]
}

# ---------------------------------------------------------------------------
# Existing target — each policy
# ---------------------------------------------------------------------------

@test "existing dest + keep: silently skips" {
  mkdir -p "$(dirname "$DEST")"
  printf 'OLD CONTENT\n' > "$DEST"
  _run_install keep "$SRC" "$DEST" "my-label"
  assert_success
  assert_output --partial "kept"
  run cat "$DEST"
  assert_output "OLD CONTENT"
}

@test "existing dest + force: overwrites" {
  mkdir -p "$(dirname "$DEST")"
  printf 'OLD CONTENT\n' > "$DEST"
  _run_install force "$SRC" "$DEST" "my-label"
  assert_success
  run cat "$DEST"
  assert_output "NEW CONTENT"
}

@test "existing dest + restore: skips with restore marker in output" {
  mkdir -p "$(dirname "$DEST")"
  printf 'OLD CONTENT\n' > "$DEST"
  _run_install restore "$SRC" "$DEST" "my-label"
  assert_success
  assert_output --partial "--restore"
  run cat "$DEST"
  assert_output "OLD CONTENT"
}

# ---------------------------------------------------------------------------
# Prompt policy (stdin fed answers)
# ---------------------------------------------------------------------------

@test "prompt: 'k' keeps existing file" {
  mkdir -p "$(dirname "$DEST")"
  printf 'OLD CONTENT\n' > "$DEST"
  run env INSTALL_POLICY=prompt bash -c "
    source '$INSTALL_FILE_LIB'
    install_file '$SRC' '$DEST' 'my-label'
  " <<<"k"
  assert_success
  run cat "$DEST"
  assert_output "OLD CONTENT"
}

@test "prompt: empty answer (default) keeps existing file" {
  mkdir -p "$(dirname "$DEST")"
  printf 'OLD CONTENT\n' > "$DEST"
  run env INSTALL_POLICY=prompt bash -c "
    source '$INSTALL_FILE_LIB'
    install_file '$SRC' '$DEST' 'my-label'
  " <<<""
  assert_success
  run cat "$DEST"
  assert_output "OLD CONTENT"
}

@test "prompt: 'o' overwrites with new content" {
  mkdir -p "$(dirname "$DEST")"
  printf 'OLD CONTENT\n' > "$DEST"
  run env INSTALL_POLICY=prompt bash -c "
    source '$INSTALL_FILE_LIB'
    install_file '$SRC' '$DEST' 'my-label'
  " <<<"o"
  assert_success
  run cat "$DEST"
  assert_output "NEW CONTENT"
}

@test "prompt: 'd' shows diff then re-prompts; final 'k' keeps file" {
  mkdir -p "$(dirname "$DEST")"
  printf 'OLD CONTENT\n' > "$DEST"
  run env INSTALL_POLICY=prompt bash -c "
    source '$INSTALL_FILE_LIB'
    install_file '$SRC' '$DEST' 'my-label'
  " <<<"d
k"
  assert_success
  # Diff output should have appeared
  assert_output --partial "diff:"
  run cat "$DEST"
  assert_output "OLD CONTENT"
}

@test "prompt: invalid answer re-prompts" {
  mkdir -p "$(dirname "$DEST")"
  printf 'OLD CONTENT\n' > "$DEST"
  run env INSTALL_POLICY=prompt bash -c "
    source '$INSTALL_FILE_LIB'
    install_file '$SRC' '$DEST' 'my-label'
  " <<<"x
k"
  assert_success
  assert_output --partial "Invalid choice"
}

# ---------------------------------------------------------------------------
# Error cases
# ---------------------------------------------------------------------------

@test "missing source file is a hard error" {
  _run_install keep "$TMP_DIR/nope.md" "$DEST" "my-label"
  assert_failure
  assert_output --partial "source not found"
}

@test "unknown policy is a hard error (when dest exists)" {
  mkdir -p "$(dirname "$DEST")"
  printf 'OLD CONTENT\n' > "$DEST"
  _run_install bogus "$SRC" "$DEST" "my-label"
  assert_failure
  assert_output --partial "unknown INSTALL_POLICY"
}

# ---------------------------------------------------------------------------
# Default policy when INSTALL_POLICY is unset
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Atomic write (mktemp + mv): no temp-file leftovers
# ---------------------------------------------------------------------------

@test "force overwrite leaves no .XXXXXX temp files alongside dest" {
  mkdir -p "$(dirname "$DEST")"
  printf 'OLD\n' > "$DEST"
  _run_install force "$SRC" "$DEST" "my-label"
  assert_success
  # Glob for any stray temp files in the dest directory.
  run bash -c "shopt -s nullglob; printf '%s\n' '$(dirname "$DEST")'/dest.md.*"
  assert_output ""
}

@test "missing dest write leaves no .XXXXXX temp files alongside dest" {
  _run_install keep "$SRC" "$DEST" "my-label"
  assert_success
  run bash -c "shopt -s nullglob; printf '%s\n' '$(dirname "$DEST")'/dest.md.*"
  assert_output ""
}

@test "unset policy defaults to 'keep'" {
  mkdir -p "$(dirname "$DEST")"
  printf 'OLD CONTENT\n' > "$DEST"
  run bash -c "source '$INSTALL_FILE_LIB'; install_file '$SRC' '$DEST' 'my-label'"
  assert_success
  run cat "$DEST"
  assert_output "OLD CONTENT"
}
