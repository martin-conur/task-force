#!/usr/bin/env bash
# Shared helper for installing the workflow doc as a *managed region* (#183).
#
# The workflow doc is the one installed file users are actively told to edit:
# #177 puts the repo-specific gloss ("in this repo, Green means …") in it, while
# the CHANGELOG tells people to re-run `task-init <loadout>` to pull template
# updates. Those two instructions collide — install_file's policies are
# whole-file, so a re-run could only keep the user's edits or clobber them.
# Three separate incidents dropped a hand-authored section that way.
#
# The fix is a boundary inside the file:
#
#   <!-- task-init:managed:start -->
#   …rendered template — task-init owns this and replaces it on every re-run…
#   <!-- task-init:managed:end -->
#
#   ## Repo-specific notes      ← yours; task-init never rewrites below the end marker
#
# Usage (the caller sources lib/install-file.sh first — the prompt loop and the
# atomic writer are shared from there):
#
#   INSTALL_POLICY=<policy> install_managed_file <rendered-src> <dest> <label>
#
# Policies behave as they do in install_file, with one change: when the target
# already carries the markers, `force` and `prompt` refresh the managed region
# in place instead of rewriting the whole file, so there is nothing destructive
# left to prompt about. `keep` and `restore` still leave the file alone.
#
# A pre-#183 target has no markers. Rather than guess where the user's content
# starts, a write-policy run adopts it: the old file is copied to <dest>.bak and
# the new file is written with markers, unless the old file is byte-identical to
# what would be rendered (nothing to preserve), in which case it is re-wrapped
# silently.

MANAGED_START='<!-- task-init:managed:start -->'
MANAGED_END='<!-- task-init:managed:end -->'

# Line number of the first exact-match marker line, or empty. Full-line match
# only: the markers are also named in the templates' own prose (inside
# backticks), and that must never be mistaken for a boundary.
_managed_marker_line() {
  local file="$1" marker="$2"
  awk -v m="$marker" '$0 == m { print NR; exit }' "$file"
}

# True when <file> carries a usable start/end pair (start strictly before end).
managed_markers_present() {
  local file="$1" s e
  [[ -f "$file" ]] || return 1
  s=$(_managed_marker_line "$file" "$MANAGED_START")
  e=$(_managed_marker_line "$file" "$MANAGED_END")
  [[ -n "$s" && -n "$e" && "$s" -lt "$e" ]]
}

# The bytes that live *between* the markers, for a given rendered template.
# Both the fresh-install wrap and the re-run replace go through this, so a
# re-render of an untouched file is a no-op diff.
# Backticks inside the single-quoted markdown below are literal, not command
# substitution — shellcheck would otherwise warn SC2016 on every such line.
# shellcheck disable=SC2016
_managed_region_body() {
  local src="$1"
  printf '%s\n' '<!-- Managed by `task-init`: everything between these markers is replaced on'
  printf '%s\n' '     every re-run. Put repo-specific notes below the end marker. -->'
  printf '\n'
  cat "$src"
  printf '\n'
}

# shellcheck disable=SC2016  # literal backticks in markdown, see above
_managed_tail_stub() {
  printf '%s\n' '## Repo-specific notes'
  printf '\n'
  printf '%s\n' '<!-- Everything below the end marker above is yours — `task-init` never'
  printf '%s\n' '     rewrites it. Repo-specific guidance belongs here: what "Green" means in'
  printf '%s\n' '     this repo, the pre-PR checklist it resolves to, local conventions. -->'
}

# Fresh install: markers around the rendered template, then an empty tail.
_managed_wrap() {
  local src="$1" out="$2"
  {
    printf '%s\n' "$MANAGED_START"
    _managed_region_body "$src"
    printf '%s\n' "$MANAGED_END"
    printf '\n'
    _managed_tail_stub
  } >"$out"
}

# Re-run: prefix (through the start marker) + fresh body + suffix (from the end
# marker to EOF). Everything outside the markers is copied verbatim.
_managed_replace() {
  local dest="$1" src="$2" out="$3"
  {
    awk -v s="$MANAGED_START" '{ print } $0 == s { exit }' "$dest"
    _managed_region_body "$src"
    awk -v e="$MANAGED_END" '$0 == e { f = 1 } f { print }' "$dest"
  } >"$out"
}

# Atomic install of an already-built file (same rename trick as install_file:
# the target points at the old bytes or the new ones, never at nothing).
_managed_commit() {
  local built="$1" dest="$2"
  mkdir -p "$(dirname "$dest")"
  local tmp
  tmp=$(mktemp "$dest.XXXXXX")
  if ! cp "$built" "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  mv -f "$tmp" "$dest"
}

# Pick an unused <dest>.bak / <dest>.bak.N so a second adoption never
# overwrites the backup the first one made.
_managed_backup_path() {
  local dest="$1"
  local candidate="$dest.bak" n=1
  while [[ -e "$candidate" ]]; do
    candidate="$dest.bak.$n"
    n=$((n + 1))
  done
  printf '%s' "$candidate"
}

# Write path for a marker-less target under a write policy.
_managed_adopt_write() {
  local src="$1" dest="$2" label="$3"
  local built backup
  built=$(mktemp)
  _managed_wrap "$src" "$built"

  if cmp -s "$src" "$dest"; then
    # Nothing but the template in there — re-wrap silently.
    _managed_commit "$built" "$dest" || { rm -f "$built"; return 1; }
    rm -f "$built"
    echo "✓ Wrote $label ($dest) — added task-init managed-region markers"
    return 0
  fi

  backup=$(_managed_backup_path "$dest")
  cp "$dest" "$backup"
  _managed_commit "$built" "$dest" || { rm -f "$built"; return 1; }
  rm -f "$built"
  echo "✓ Wrote $label ($dest) — added task-init managed-region markers"
  {
    echo "NOTE: $dest predates the managed region, so task-init could not tell your"
    echo "      edits from the template. The previous file was saved to:"
    echo "        $backup"
    echo "      Move anything you want to keep below the $MANAGED_END"
    echo "      marker — task-init will never touch it again — then delete the backup."
  } >&2
  return 0
}

# install_managed_file <rendered-src> <dest> <label>
install_managed_file() {
  local src="$1" dest="$2" label="$3"
  local policy="${INSTALL_POLICY:-keep}"
  local built

  if [[ ! -f "$src" ]]; then
    echo "Error: source not found: $src" >&2
    return 1
  fi

  case "$policy" in
    force|restore|prompt|keep) ;;
    *)
      echo "Error: unknown INSTALL_POLICY: $policy" >&2
      return 1
      ;;
  esac

  # Missing target → always write, regardless of policy.
  if [[ ! -e "$dest" && ! -L "$dest" ]]; then
    built=$(mktemp)
    _managed_wrap "$src" "$built"
    _managed_commit "$built" "$dest" || { rm -f "$built"; return 1; }
    rm -f "$built"
    echo "✓ Wrote $label ($dest)"
    return 0
  fi

  case "$policy" in
    restore)
      echo "✓ $label already exists — kept (--restore)"
      return 0
      ;;
    keep)
      echo "✓ $label already exists — kept (use --force to overwrite)"
      return 0
      ;;
  esac

  # force / prompt, target exists.
  if managed_markers_present "$dest"; then
    built=$(mktemp)
    _managed_replace "$dest" "$src" "$built"
    if cmp -s "$built" "$dest"; then
      rm -f "$built"
      echo "✓ $label already up to date — your own sections untouched"
      return 0
    fi
    _managed_commit "$built" "$dest" || { rm -f "$built"; return 1; }
    rm -f "$built"
    echo "✓ Refreshed the managed region of $label ($dest) — your own sections untouched"
    return 0
  fi

  # Marker-less (pre-#183) target.
  if [[ "$policy" == "force" ]]; then
    _managed_adopt_write "$src" "$dest" "$label"
  else
    _install_file_prompt "$src" "$dest" "$label" _managed_adopt_write
  fi
}
