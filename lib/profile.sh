#!/usr/bin/env bash
# shellcheck disable=SC2034  # AW_PROFILE_* are read by the launchers that source this
# Agent profiles (#355): `--profile <name>` on task-work, task-reviewer,
# task-recreate-worker and task-pm. Sourced, not executed.
#
# A profile is a named set of environment for the agent, read from
# $TASK_FORCE_HOME/profiles.toml (default ~/.task-force/profiles.toml):
#
#   [profiles.fireworks-glm]
#   agent   = "claude"
#   model   = "glm-latest"
#   env     = { ANTHROPIC_BASE_URL = "https://api.fireworks.ai/inference", ENABLE_TOOL_SEARCH = "true" }
#   key_env = { ANTHROPIC_API_KEY = "FIREWORKS_API_KEY" }
#   pin     = { sonnet = "…", haiku = "…", opus = "…", subagent = "…" }
#   max_context_tokens = 200000
#
# What a profile must carry comes from the #354 spike (docs/agent-profiles-spike.md):
#
# - The key goes in ANTHROPIC_API_KEY only. With ANTHROPIC_AUTH_TOKEN, Claude
#   Code also sent the machine's saved Anthropic Console key as x-api-key, so
#   the gateway got the user's Anthropic key (section 6). Refused.
# - The key's VALUE is never on a command line, where `ps` shows it, nor in any
#   file. The prefix carries a reference, `ANTHROPIC_API_KEY="${SRC:?…}"`, which
#   the tab's `bash -ic` expands from the user's rc. The launcher only checks
#   that SRC is set in its own environment, so the user hears about a missing
#   key before a tab opens; the `:?` stops the agent from starting keyless in a
#   tab whose rc does not export it, where Claude Code would fall back to the
#   saved Console key against the gateway.
# - Every tier is pinned: each `pin` key falls back to `model`. An unpinned
#   Sonnet tier sends the auto-mode classifier to `claude-sonnet-5` (section 2).
#   CLAUDE_CODE_AUTO_MODE_MODEL is not emitted: alone it does not move it.
# - ANTHROPIC_MODEL is set as well as --model, so the profile's model wins over
#   task-reviewer's Sonnet default.
#
# The file is read with a strict TOML subset parser (no python, no toml tool):
# tables, `key = value` with basic or literal one-line strings, integers,
# booleans and one-line inline tables, comments. Anything else refuses as a
# file that does not parse, naming the line.
#
# Exports:
#   aw_profile_file                       the profiles.toml path
#   aw_profile_parse_flag <args>...       --profile / --no-profile out of argv
#   aw_profile_load <name> <agent>        resolve + validate; sets AW_PROFILE_*
#   aw_profile_env_prefix                 the tab's `VAR=val ` prefix
#   aw_profile_export                     export the same set in this process
#
# The --model half lives with each launch line: lib/agents/claude.sh for
# task-work and task-recreate-worker, task-reviewer and task-pm their own.

# The profile file. Beside radio's state, under the same home.
aw_profile_file() {
  printf '%s/profiles.toml' "${TASK_FORCE_HOME:-$HOME/.task-force}"
}

# aw_profile_parse_flag <args>...
#
# Pull `--profile <name>` / `--profile=<name>` / `--no-profile` out of argv.
# Sets AW_PARSED_PROFILE (the name, or empty), AW_PARSED_NO_PROFILE (1 or
# empty) and AW_PROFILE_REMAINING_ARGS. Returns 1, having said why, on a
# missing value or both flags at once.
aw_profile_parse_flag() {
  AW_PARSED_PROFILE=""
  AW_PARSED_NO_PROFILE=""
  AW_PROFILE_REMAINING_ARGS=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --profile)
        [[ $# -ge 2 && -n "$2" ]] || { echo "Error: --profile needs a profile name" >&2; return 1; }
        AW_PARSED_PROFILE="$2"; shift 2 ;;
      --profile=*)
        AW_PARSED_PROFILE="${1#--profile=}"
        [[ -n "$AW_PARSED_PROFILE" ]] || { echo "Error: --profile needs a profile name" >&2; return 1; }
        shift ;;
      --no-profile) AW_PARSED_NO_PROFILE=1; shift ;;
      --) AW_PROFILE_REMAINING_ARGS+=("$@"); break ;;
      *) AW_PROFILE_REMAINING_ARGS+=("$1"); shift ;;
    esac
  done
  if [[ -n "$AW_PARSED_PROFILE" && -n "$AW_PARSED_NO_PROFILE" ]]; then
    echo "Error: --profile and --no-profile are mutually exclusive" >&2
    return 1
  fi
  return 0
}

# _aw_profile_parse <file>
#
# The TOML subset, flattened to one `<dotted.path>\t<value>` line per key
# (`profiles.fireworks-glm.env.ANTHROPIC_BASE_URL\thttps://…`). On a line it
# cannot read, prints `ERR\t<line>\t<why>` and exits 1. Keys are bare
# ([A-Za-z0-9_-]) or quoted; a quoted key may not contain a dot, which would be
# ambiguous once flattened, nor may any value carry a tab or a newline.
_aw_profile_parse() {
  awk '
    function fail(msg) { printf "ERR\t%d\t%s\n", NR, msg; failed = 1; exit 1 }
    function skipws() { while (pos <= length(s) && (substr(s, pos, 1) == " " || substr(s, pos, 1) == "\t")) pos++ }
    function at_end() {
      skipws()
      return pos > length(s) || substr(s, pos, 1) == "#"
    }
    # One key segment: bare or quoted.
    function key1(   c, k) {
      skipws()
      c = substr(s, pos, 1)
      if (c == "\"" || c == "\047") {
        k = str()
        if (index(k, ".") > 0) fail("a quoted key may not contain a dot")
        if (k == "") fail("empty key")
        return k
      }
      k = ""
      while (pos <= length(s)) {
        c = substr(s, pos, 1)
        if (c ~ /[A-Za-z0-9_-]/) { k = k c; pos++ } else break
      }
      if (k == "") fail("expected a key")
      return k
    }
    # A dotted key: a.b."c"
    function dkey(   k) {
      k = key1()
      skipws()
      while (substr(s, pos, 1) == ".") { pos++; k = k "." key1(); skipws() }
      return k
    }
    # A one-line string at pos: basic ("…", with escapes) or literal (\047…\047).
    function str(   q, out, c, e) {
      q = substr(s, pos, 1); pos++
      if (substr(s, pos, 2) == q q) fail("multi-line strings are not supported")
      out = ""
      while (1) {
        if (pos > length(s)) fail("unterminated string")
        c = substr(s, pos, 1); pos++
        if (c == q) return out
        if (q == "\"" && c == "\\") {
          e = substr(s, pos, 1); pos++
          if (e == "\"" || e == "\\") out = out e
          else fail("unsupported escape \\" e " (only \\\" and \\\\)")
          continue
        }
        if (c == "\t") fail("a tab inside a string is not supported")
        out = out c
      }
    }
    function scalar(   c, v) {
      skipws()
      c = substr(s, pos, 1)
      if (c == "\"" || c == "\047") return str()
      v = ""
      while (pos <= length(s)) {
        c = substr(s, pos, 1)
        if (c ~ /[A-Za-z0-9_+-]/) { v = v c; pos++ } else break
      }
      if (v == "true" || v == "false") return v
      if (v ~ /^[+-]?[0-9][0-9_]*$/) { gsub(/_/, "", v); sub(/^\+/, "", v); return v }
      if (c == "[") fail("arrays are not supported")
      if (v == "") fail("expected a value")
      fail("unsupported value \"" v "\" (strings, integers, booleans and inline tables only)")
    }
    function emit(path, v) {
      if (path in seen) fail("duplicate key " path)
      if (path in tables) fail("key " path " is already a table")
      seen[path] = 1
      mark_tables(path)
      printf "%s\t%s\n", path, v
    }
    # Every proper prefix of a key path is a table; a later scalar on one is a clash.
    function mark_tables(path,   i, n, parts, p) {
      n = split(path, parts, ".")
      p = parts[1]
      for (i = 1; i < n; i++) {
        if (p in seen) fail("key " p " is not a table")
        tables[p] = 1
        p = p "." parts[i + 1]
      }
    }
    function inline_table(prefix,   k, first) {
      pos++   # past {
      first = 1
      while (1) {
        skipws()
        if (substr(s, pos, 1) == "}") { pos++; return }
        if (!first) {
          if (substr(s, pos, 1) != ",") fail("expected , or } in inline table")
          pos++; skipws()
        }
        first = 0
        k = dkey()
        skipws()
        if (substr(s, pos, 1) != "=") fail("expected = after key " k)
        pos++; skipws()
        if (substr(s, pos, 1) == "{") fail("nested inline tables are not supported")
        if (pos > length(s)) fail("inline tables must close on the line they open")
        emit(prefix "." k, scalar())
      }
    }
    BEGIN { table = "" }
    {
      s = $0; sub(/\r$/, "", s); pos = 1
      if (at_end()) next
      if (substr(s, pos, 1) == "[") {
        pos++
        if (substr(s, pos, 1) == "[") fail("arrays of tables are not supported")
        table = dkey()
        skipws()
        if (substr(s, pos, 1) != "]") fail("expected ] to close the table header")
        pos++
        if (!at_end()) fail("unexpected text after the table header")
        if (table in seen) fail("key " table " is not a table")
        if (table in headers) fail("table [" table "] is defined twice")
        headers[table] = 1
        tables[table] = 1
        mark_tables(table ".x")
        next
      }
      k = dkey()
      skipws()
      if (substr(s, pos, 1) != "=") fail("expected = after key " k)
      pos++; skipws()
      path = (table == "" ? k : table "." k)
      if (substr(s, pos, 1) == "{") {
        if (path in seen || path in tables) fail("duplicate key " path)
        tables[path] = 1
        mark_tables(path ".x")
        inline_table(path)
      } else {
        emit(path, scalar())
      }
      if (!at_end()) fail("unexpected text after the value")
    }
  ' "$1"
}

# _aw_profile_refuse <why>... — the one shape every refusal takes.
_aw_profile_refuse() {
  {
    echo "Error: profile '$_AW_PROFILE_NAME': $1"
    shift
    local l
    for l in "$@"; do echo "       $l"; done
  } >&2
  return 1
}

_aw_profile_is_env_name() { [[ "$1" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; }

# aw_profile_load <name> <agent>
#
# Read profile <name> and check it against the agent being launched. On
# success sets:
#   AW_PROFILE_NAME    the name
#   AW_PROFILE_MODEL   the model, or empty
#   AW_PROFILE_VARS    one `NAME<TAB>lit<TAB>value` or `NAME<TAB>ref<TAB>SRC`
#                      per variable, in emit order
# On a refusal says why on stderr and returns 1, having set nothing a launch
# could use. The refusals: no file / a file that does not parse, an unknown
# profile, an agent other than the one launched, a key_env source unset or
# empty here, and a schema error (unknown field, a key_env target other than
# ANTHROPIC_API_KEY, a credential put in `env`).
aw_profile_load() {
  local name="$1" agent="$2" file parsed rc line kpath value rest field sub
  _AW_PROFILE_NAME="$name"
  AW_PROFILE_NAME="" AW_PROFILE_MODEL="" AW_PROFILE_VARS=""
  file=$(aw_profile_file)

  [[ "$name" =~ ^[A-Za-z0-9_-]+$ ]] \
    || { _aw_profile_refuse "not a valid profile name (letters, digits, - and _)."; return 1; }
  if [[ ! -f "$file" ]]; then
    _aw_profile_refuse "no profile file at $file." \
      "Define it there as a [profiles.$name] table (see the README's Agent profiles section)."
    return 1
  fi

  rc=0
  parsed=$(_aw_profile_parse "$file") || rc=$?
  if (( rc != 0 )); then
    line=$(grep '^ERR' <<<"$parsed" | head -1)
    if [[ -n "$line" ]]; then
      rest="${line#ERR$'\t'}"
      _aw_profile_refuse "$file does not parse: line ${rest%%$'\t'*}: ${rest#*$'\t'}." \
        "task-force reads a TOML subset: tables, one-line strings, integers, booleans" \
        "and one-line inline tables."
    else
      _aw_profile_refuse "could not read $file."
    fi
    return 1
  fi

  local p_agent="" p_model="" p_ctx="" env_lines="" key_lines="" found=""
  local pin_sonnet="" pin_haiku="" pin_opus="" pin_subagent=""
  while IFS=$'\t' read -r kpath value; do
    [[ -n "$kpath" ]] || continue
    case "$kpath" in
      profiles.*) ;;
      *) _aw_profile_refuse "$file does not parse: '$kpath' is outside a [profiles.<name>] table."; return 1 ;;
    esac
    rest="${kpath#profiles.}"
    [[ "$rest" == "$name."* ]] || continue
    found=1
    rest="${rest#"$name".}"
    field="${rest%%.*}"
    sub=""
    [[ "$rest" == *.* ]] && sub="${rest#*.}"
    case "$field" in
      agent|model|max_context_tokens)
        [[ -z "$sub" ]] || { _aw_profile_refuse "'$field' is a value, not a table."; return 1; }
        case "$field" in
          agent) p_agent="$value" ;;
          model) p_model="$value" ;;
          max_context_tokens) p_ctx="$value" ;;
        esac ;;
      env|key_env|pin)
        [[ -n "$sub" && "$sub" != *.* ]] \
          || { _aw_profile_refuse "'$field' must be a table of NAME = \"value\"."; return 1; }
        case "$field" in
          env) env_lines+="$sub"$'\t'"$value"$'\n' ;;
          key_env) key_lines+="$sub"$'\t'"$value"$'\n' ;;
          pin)
            case "$sub" in
              sonnet) pin_sonnet="$value" ;;
              haiku) pin_haiku="$value" ;;
              opus) pin_opus="$value" ;;
              subagent) pin_subagent="$value" ;;
              *) _aw_profile_refuse "unknown pin '$sub' (sonnet, haiku, opus or subagent)."; return 1 ;;
            esac ;;
        esac ;;
      *)
        _aw_profile_refuse "unknown field '$field'." \
          "A profile takes agent, model, env, key_env, pin and max_context_tokens."
        return 1 ;;
    esac
  done <<<"$parsed"

  if [[ -z "$found" ]]; then
    local known
    known=$(awk -F'\t' '$1 ~ /^profiles\./ { p = substr($1, 10); sub(/\..*/, "", p); if (!(p in s)) { s[p] = 1; o = o (o == "" ? "" : ", ") p } } END { print o }' <<<"$parsed")
    _aw_profile_refuse "no such profile in $file." "Profiles defined there: ${known:-none}."
    return 1
  fi

  if [[ -z "$p_agent" ]]; then
    _aw_profile_refuse "it names no agent." "Add agent = \"claude\" to [profiles.$name]."
    return 1
  fi
  if [[ "$p_agent" != "$agent" ]]; then
    _aw_profile_refuse "it is a $p_agent profile, and this launch is on $agent." \
      "Pass --agent $p_agent to launch on $p_agent, or pick a $agent profile."
    return 1
  fi
  if [[ "$p_agent" != claude ]]; then
    _aw_profile_refuse "profiles are claude-only: the variables a profile sets are Claude Code's" \
      "(docs/agent-profiles-spike.md covers Claude Code alone)."
    return 1
  fi
  if [[ -n "$p_ctx" && ! "$p_ctx" =~ ^[1-9][0-9]*$ ]]; then
    _aw_profile_refuse "max_context_tokens must be a positive integer, not '$p_ctx'."
    return 1
  fi

  local vars="" k v
  # env, as given. A credential does not belong here: its value would sit on
  # the launch line, where `ps` shows it.
  while IFS=$'\t' read -r k v; do
    [[ -n "$k" ]] || continue
    _aw_profile_is_env_name "$k" || { _aw_profile_refuse "env name '$k' is not a valid variable name."; return 1; }
    case "$k" in
      ANTHROPIC_API_KEY|ANTHROPIC_AUTH_TOKEN)
        _aw_profile_refuse "$k is in env, where its value would be on the launch line." \
          "Name the variable that holds it in key_env instead: key_env = { ANTHROPIC_API_KEY = \"<VAR>\" }."
        return 1 ;;
      TASK_FORCE_*|ZELLIJ_TAB)
        _aw_profile_refuse "env may not set $k: task-force's launchers own it."
        return 1 ;;
    esac
    vars+="$k"$'\tlit\t'"$v"$'\n'
  done <<<"$env_lines"

  # key_env: ANTHROPIC_API_KEY only, from a variable set here.
  while IFS=$'\t' read -r k v; do
    [[ -n "$k" ]] || continue
    case "$k" in
      ANTHROPIC_API_KEY) ;;
      ANTHROPIC_AUTH_TOKEN)
        _aw_profile_refuse "key_env may not set ANTHROPIC_AUTH_TOKEN: use ANTHROPIC_API_KEY." \
          "With ANTHROPIC_AUTH_TOKEN, Claude Code also sends the machine's saved Anthropic" \
          "Console key as x-api-key, so the gateway receives your Anthropic key and every" \
          "request fails with 401 (docs/agent-profiles-spike.md, section 6)."
        return 1 ;;
      *)
        _aw_profile_refuse "key_env may set ANTHROPIC_API_KEY only, not '$k'."
        return 1 ;;
    esac
    _aw_profile_is_env_name "$v" \
      || { _aw_profile_refuse "key_env source '$v' is not a valid variable name."; return 1; }
    if [[ -z "${!v:-}" ]]; then
      _aw_profile_refuse "\$$v, which key_env reads $k from, is unset or empty here." \
        "Export it from your shell rc, so the new tab, which sources that rc, has it too."
      return 1
    fi
    vars+="$k"$'\tref\t'"$v"$'\n'
  done <<<"$key_lines"

  # Every tier, falling back to the model (spec amendment 3).
  local tier tv
  for tier in SONNET HAIKU OPUS; do
    case "$tier" in
      SONNET) tv="${pin_sonnet:-$p_model}" ;;
      HAIKU) tv="${pin_haiku:-$p_model}" ;;
      OPUS) tv="${pin_opus:-$p_model}" ;;
    esac
    [[ -n "$tv" ]] && vars+="ANTHROPIC_DEFAULT_${tier}_MODEL"$'\tlit\t'"$tv"$'\n'
  done
  tv="${pin_subagent:-$p_model}"
  [[ -n "$tv" ]] && vars+="CLAUDE_CODE_SUBAGENT_MODEL"$'\tlit\t'"$tv"$'\n'
  [[ -n "$p_model" ]] && vars+="ANTHROPIC_MODEL"$'\tlit\t'"$p_model"$'\n'
  [[ -n "$p_ctx" ]] && vars+="CLAUDE_CODE_MAX_CONTEXT_TOKENS"$'\tlit\t'"$p_ctx"$'\n'
  vars+="TASK_FORCE_PROFILE"$'\tlit\t'"$name"$'\n'

  AW_PROFILE_NAME="$name"
  AW_PROFILE_MODEL="$p_model"
  AW_PROFILE_VARS="$vars"
  return 0
}

# The profile's part of a tab's env prefix, `NAME=value ` per variable, each
# value %q-quoted for the tab's `bash -ic` re-parse. The key is a reference the
# tab expands, never its value: see the file header. Empty with no profile
# loaded.
aw_profile_env_prefix() {
  local k kind v out=""
  while IFS=$'\t' read -r k kind v; do
    [[ -n "$k" ]] || continue
    if [[ "$kind" == ref ]]; then
      out+="$k=\"\${$v:?is unset in this tab, so the profile has no key: export it from your shell rc}\" "
    else
      out+="$k=$(printf %q "$v") "
    fi
  done <<<"${AW_PROFILE_VARS:-}"
  printf '%s' "$out"
}

# Export the loaded profile into this process, for a launcher that execs the
# agent in place (task-pm). The key is copied from its source variable in
# memory; nothing reaches argv or disk.
aw_profile_export() {
  local k kind v
  while IFS=$'\t' read -r k kind v; do
    [[ -n "$k" ]] || continue
    if [[ "$kind" == ref ]]; then
      export "$k=${!v}"
    else
      export "$k=$v"
    fi
  done <<<"${AW_PROFILE_VARS:-}"
}
