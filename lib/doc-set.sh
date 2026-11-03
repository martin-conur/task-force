#!/usr/bin/env bash
# `task-init --set "<setting>=<value>"` (#346): write any workflow-doc setting
# bullet from the command line, so a config tool can drive status names and the
# Watch settings the way it already drives --site / --key / --board.
#
# A setting is a bullet of the shape `- **<label>**: `<value>`<rest>` in the
# loadout's template, the same shape lib/doc-setting.sh reads back. The label is
# matched case-insensitively; only the code span is rewritten, the rest of the
# line stays the template's.
#
# Precedence for one bullet, applied to the already-rendered template:
#   1. a --set for it            (an empty value restores the template default)
#   2. the value already in the existing doc's managed region, when the render
#      left the bullet at the template default (the carry-over --site / --key /
#      --board get from lib/tracker-settings.sh, extended to every bullet)
#   3. the rendered value
#
# A --set on a tracker bullet whose template default is a placeholder ({SITE},
# {OWNER}, …) also fills that placeholder elsewhere in the doc, so
# `--set "Site=…"` is what `--site …` is.
#
# Sourced, never executed. Must run on /bin/bash 3.2.
#
# Exports:
#   tf_set_bullets <file>                       -> "label<TAB>value" per setting bullet
#   tf_set_labels <template>                    -> the template's labels, one per line
#   tf_set_validate <template> <spec>...        -> refuses a malformed or unknown spec
#   tf_set_apply <rendered> <template> <doc> <spec>...
#   tf_set_carry_flags <doc> <template>         -> "--set" / "label=value" tokens

_TF_DOC_SET_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/managed-region.sh
[[ -n "${MANAGED_START:-}" ]] || . "$_TF_DOC_SET_DIR/managed-region.sh"
# shellcheck source=lib/tracker-settings.sh
declare -F tf_tracker_table >/dev/null || . "$_TF_DOC_SET_DIR/tracker-settings.sh"

# The awk that splits a bullet into PRE (through the opening backtick), VAL and
# POST (from the closing backtick). Shared by every reader and the writer, so
# what tf_set_labels lists is exactly what tf_set_apply can rewrite.
# shellcheck disable=SC2016  # literal backticks inside the awk program
_TF_SET_AWK_BULLET='
function bullet(line,   i, rest, j) {
  if (line !~ /^- \*\*[^*]+\*\*: `[^`]*`/) return 0
  i = index(line, "**: `")
  LABEL = substr(line, 5, i - 5)
  rest = substr(line, i + 5)
  j = index(rest, "`")
  PRE = substr(line, 1, i + 4)
  VAL = substr(rest, 1, j - 1)
  POST = substr(rest, j)
  return 1
}'

# tf_set_bullets <file>
# "label<TAB>value" for every setting bullet. A doc with managed-region markers
# is read between them only: a bullet below the end marker is the user's own
# override, which task-init neither owns nor carries.
tf_set_bullets() {
  local file="$1" scoped=0
  [[ -f "$file" ]] || return 0
  grep -qxF "$MANAGED_START" "$file" && scoped=1
  awk -v scoped="$scoped" -v s="$MANAGED_START" -v e="$MANAGED_END" "$_TF_SET_AWK_BULLET"'
    scoped && $0 == s { inside = 1; next }
    scoped && $0 == e { inside = 0; next }
    (!scoped || inside) && bullet($0) { print LABEL "\t" VAL }
  ' "$file"
}

# tf_set_labels <template>
tf_set_labels() {
  tf_set_bullets "$1" | cut -f1
}

# _tf_set_trim <s>
_tf_set_trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# tf_set_validate <template> <spec>...
# Every spec must be "<label>=<value>" with a label the template carries. On
# the first bad one: stderr names it, lists the valid labels, return 2. Never
# lets a stray bullet be written.
tf_set_validate() {
  local template="$1" spec label lc labels known=0 l
  shift
  (($#)) || return 0
  labels=$(tf_set_labels "$template")
  for spec in "$@"; do
    if [[ "$spec" != *=* ]]; then
      echo "Error: --set needs \"<setting>=<value>\", got '$spec'" >&2
      return 2
    fi
    label=$(_tf_set_trim "${spec%%=*}")
    lc=$(printf '%s' "$label" | tr '[:upper:]' '[:lower:]')
    known=0
    while IFS= read -r l; do
      [[ "$(printf '%s' "$l" | tr '[:upper:]' '[:lower:]')" == "$lc" ]] && { known=1; break; }
    done <<<"$labels"
    if ((known == 0)); then
      {
        echo "Error: --set: unknown setting '$label'. Valid settings for this loadout:"
        while IFS= read -r l; do [[ -n "$l" ]] && echo "         $l"; done <<<"$labels"
      } >&2
      return 2
    fi
  done
  return 0
}

# tf_set_apply <rendered> <template> <existing-doc> <spec>...
# Rewrites <rendered> in place by the precedence in the header. Specs are
# assumed validated. INSTALL_POLICY, when keep or restore, means the existing
# doc will not be rewritten at all, so a --set would be silently dropped: say so.
tf_set_apply() {
  local rendered="$1" template="$2" doc="$3" spec label t
  shift 3
  if (($#)) && [[ -e "$doc" ]]; then
    case "${INSTALL_POLICY:-}" in
      keep|restore)
        echo "NOTE: --set is not applied: $doc already exists and is kept. Re-run with --force." >&2 ;;
    esac
  fi

  local sets tmpl old phs out
  sets=$(mktemp); tmpl=$(mktemp); old=$(mktemp); phs=$(mktemp); out=$(mktemp)
  for spec in "$@"; do
    label=$(_tf_set_trim "${spec%%=*}")
    printf '%s\t%s\n' "$label" "${spec#*=}" >>"$sets"
  done
  tf_set_bullets "$template" >"$tmpl"
  tf_set_bullets "$doc" >"$old"
  for t in gh jira notion; do
    tf_tracker_table "$t" | cut -d'|' -f2
  done >"$phs"

  awk -v SETS="$sets" -v TMPL="$tmpl" -v OLD="$old" -v PHS="$phs" "$_TF_SET_AWK_BULLET"'
    function load(file, arr,   line, k) {
      while ((getline line < file) > 0) {
        k = index(line, "\t")
        arr[tolower(substr(line, 1, k - 1))] = substr(line, k + 1)
      }
      close(file)
    }
    function replace_all(s, from, to,   i, r) {
      r = ""
      while ((i = index(s, from)) > 0) {
        r = r substr(s, 1, i - 1) to
        s = substr(s, i + length(from))
      }
      return r s
    }
    BEGIN {
      load(SETS, set); load(TMPL, dflt); load(OLD, old)
      while ((getline line < PHS) > 0) if (line != "") isph[line] = 1
      close(PHS)
    }
    {
      if (bullet($0)) {
        k = tolower(LABEL)
        v = VAL
        if (k in set) {
          v = (set[k] == "") ? dflt[k] : set[k]
          if ((dflt[k] in isph) && v != dflt[k]) fill[dflt[k]] = v
        } else if (VAL == dflt[k] && (k in old) && old[k] != "") {
          v = old[k]
        }
        lines[++n] = PRE v POST
      } else {
        lines[++n] = $0
      }
    }
    END {
      for (i = 1; i <= n; i++) {
        s = lines[i]
        for (p in fill) s = replace_all(s, p, fill[p])
        print s
      }
    }
  ' "$rendered" >"$out" && cat "$out" >"$rendered"
  local rc=$?
  rm -f "$sets" "$tmpl" "$old" "$phs" "$out"
  return "$rc"
}

# tf_set_carry_flags <existing-doc> <template>
# The --set tokens that carry <existing-doc>'s settings into a fresh install
# from <template> (task-config set / add assistant / sync), one token per line
# so a value with spaces survives `read`. Only bullets whose value differs from
# the template default, and none still on a tracker placeholder: those travel
# as --site / --owner / … via tf_tracker_init_flags.
tf_set_carry_flags() {
  local doc="$1" template="$2" label val d t phs defaults
  [[ -f "$doc" && -f "$template" ]] || return 0
  phs=$(for t in gh jira notion; do tf_tracker_table "$t" | cut -d'|' -f2; done)
  defaults=$(tf_set_bullets "$template")
  while IFS=$'\t' read -r label val; do
    [[ -n "$label" ]] || continue
    # A label the template does not carry would be refused by tf_set_validate.
    d=$(awk -F'\t' -v l="$label" 'tolower($1) == tolower(l) { print "=" $2; exit }' <<<"$defaults")
    [[ -n "$d" ]] || continue
    d="${d#=}"
    [[ "$val" != "$d" ]] || continue
    grep -qxF -- "$d" <<<"$phs" && continue
    printf '%s\n%s\n' --set "$label=$val"
  done < <(tf_set_bullets "$doc")
  return 0
}
