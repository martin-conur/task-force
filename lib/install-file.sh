#!/usr/bin/env bash
# Shared helper for task-init scripts: deciding whether to write a file based
# on an overwrite policy.
#
# Usage:
#   INSTALL_POLICY=<policy> install_file <src> <dest> <label>
#
# Policies:
#   force    - always overwrite (--force flag)
#   restore  - only write when dest is missing; never touch existing (--restore flag)
#   prompt   - interactively ask [k]eep / [o]verwrite / [d]iff (TTY default)
#   keep     - silently skip when dest exists (non-TTY default)
#
# Caller is responsible for choosing the policy based on flags and -t 0.
# The helper trusts the policy as given.
#
# Output goes to stdout (status messages) / stderr (prompts, diffs).

# install_file <src> <dest> <label>
install_file() {
  local src="$1" dest="$2" label="$3"
  local policy="${INSTALL_POLICY:-keep}"

  if [[ ! -f "$src" ]]; then
    echo "Error: source not found: $src" >&2
    return 1
  fi

  # Missing target → always write, regardless of policy.
  if [[ ! -e "$dest" && ! -L "$dest" ]]; then
    _install_file_write "$src" "$dest" "$label"
    return 0
  fi

  case "$policy" in
    force)
      _install_file_write "$src" "$dest" "$label"
      ;;
    restore)
      echo "✓ $label already exists — kept (--restore)"
      ;;
    keep)
      echo "✓ $label already exists — kept (use --force to overwrite)"
      ;;
    prompt)
      _install_file_prompt "$src" "$dest" "$label"
      ;;
    *)
      echo "Error: unknown INSTALL_POLICY: $policy" >&2
      return 1
      ;;
  esac
}

_install_file_write() {
  local src="$1" dest="$2" label="$3"
  mkdir -p "$(dirname "$dest")"
  # Atomic write via mktemp + mv: mv on the same filesystem is a POSIX rename,
  # so the target either still points at the old file or at the new one — never
  # missing if we get Ctrl+C'd between cp and rename.
  local tmp
  tmp=$(mktemp "$dest.XXXXXX")
  if ! cp "$src" "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  mv -f "$tmp" "$dest"
  echo "✓ Wrote $label ($dest)"
}

_install_file_prompt() {
  local src="$1" dest="$2" label="$3"
  local answer
  while true; do
    printf '%s exists at %s. [k]eep / [o]verwrite / [d]iff (default: keep): ' "$label" "$dest" >&2
    if ! IFS= read -r answer; then
      # EOF on stdin — fall back to keep.
      echo "" >&2
      answer="k"
    fi
    answer="${answer:-k}"
    case "$answer" in
      k|K|keep)
        echo "✓ $label kept"
        return 0
        ;;
      o|O|overwrite)
        _install_file_write "$src" "$dest" "$label"
        return 0
        ;;
      d|D|diff)
        echo "--- diff: current → new template ---" >&2
        diff -u "$dest" "$src" >&2 || true
        echo "------------------------------------" >&2
        # loop and re-prompt
        ;;
      *)
        echo "Invalid choice '$answer'. Pick k, o, or d." >&2
        ;;
    esac
  done
}
