#!/usr/bin/env bash
# `task-config profile add|list|show|test|remove` (#356): define and verify an
# agent profile (#355) without knowing the variable names. Sourced by
# bin/task-config, after lib/profile.sh; not executed.
#
# Reading and validating are lib/profile.sh's: `add` runs the profile it is
# about to write through aw_profile_load before writing anything, so it cannot
# write a profile a launcher would refuse, and `test` exports the profile with
# aw_profile_export, the set task-pm exports, so it tests what a launch sends.
#
# The file stays hand-edited. `add` appends one table and `remove` cuts one
# out, leaving every other line as it was: other profiles, comments, and the
# comments just above the profile's own header. A profile that is not written
# as [profiles.<name>] / [profiles.<name>.*] tables (a dotted key under some
# other table) is refused rather than half-removed.
#
# No key value is ever printed or written. The profile names the variable
# that holds the key; `show` says whether it is set, and `test` takes the
# value out of anything it echoes back from the gateway.
#
# Exports:
#   aw_profile_cmd <subcommand> [args]...

# Presets ship with the checkout. AW_ROOT is bin/task-config's.
_pc_presets_file() { printf '%s/lib/profile-presets.toml' "$AW_ROOT"; }

_pc_usage() {
  cat <<'EOF'
Usage: task-config profile list
       task-config profile show <name>
       task-config profile add <name> --preset <preset> --model <id> --key-env <VAR> [options]
       task-config profile add <name> --base-url <url> --model <id> --key-env <VAR> [options]
       task-config profile test <name> [--timeout <secs>]
       task-config profile remove <name>

Agent profiles (#355) live in $TASK_FORCE_HOME/profiles.toml (default
~/.task-force/profiles.toml) and are used with `task-work … --profile <name>`.

list     Names, agent, model and base URL. Never a key.
show     The resolved profile: every variable a launch sets, and whether the
         key's variable is set here. Never its value.
add      Write a profile, validated as a launcher would read it.
           --preset <name>    start from a preset (lib/profile-presets.toml)
           --base-url <url>   ANTHROPIC_BASE_URL (required without a preset)
           --model <id>       the gateway's model id; every tier defaults to it
           --key-env <VAR>    the variable holding the key, sent as
                              ANTHROPIC_API_KEY (x-api-key). Export it from
                              your shell rc.
           --pin <tier>=<id>  pin sonnet, haiku, opus or subagent (repeatable)
           --env <K>=<V>      one more variable (repeatable)
           --force            replace a profile of that name
test     One short `claude -p` run through the profile, in a throwaway
         directory, registering no radio role: auth, the model that answered,
         one tool call, the time it took. Exits non-zero on any failure.
           --timeout <secs>   stop claude and fail after this long (default 60,
                              or $TASK_CONFIG_PROFILE_TEST_TIMEOUT)
remove   Delete a profile, leaving the rest of the file as it was.
EOF
  _pc_presets_help
}

# The presets and their one-liners, for the usage text.
_pc_presets_help() {
  local parsed
  parsed=$(_aw_profile_parse "$(_pc_presets_file)" 2>/dev/null) || return 0
  printf '\nPresets:\n'
  awk -F'\t' '
    $1 ~ /^presets\.[^.]+\./ { p = substr($1, 9); sub(/\..*/, "", p); if (!(p in s)) { s[p] = 1; o[++n] = p } }
    $1 ~ /^presets\.[^.]+\.about$/ { p = substr($1, 9); sub(/\..*/, "", p); a[p] = $2 }
    END { for (i = 1; i <= n; i++) printf "  %-12s %s\n", o[i], a[o[i]] }
  ' <<<"$parsed"
}

# _pc_parse <file> — sets PC_PARSED, or says why the file does not parse.
_pc_parse() {
  local file="$1" rc=0 line rest
  PC_PARSED=""
  [[ -f "$file" ]] || return 0
  PC_PARSED=$(_aw_profile_parse "$file") || rc=$?
  (( rc == 0 )) && return 0
  line=$(grep '^ERR' <<<"$PC_PARSED" | head -1)
  rest="${line#ERR$'\t'}"
  echo "Error: $file does not parse: line ${rest%%$'\t'*}: ${rest#*$'\t'}." >&2
  echo "       task-force reads a TOML subset: tables, one-line strings, integers, booleans" >&2
  echo "       and one-line inline tables." >&2
  PC_PARSED=""
  return 1
}

# Profile names in file order, one per line.
_pc_names() {
  awk -F'\t' '$1 ~ /^profiles\./ { p = substr($1, 10); sub(/\..*/, "", p); if (!(p in s)) { s[p] = 1; print p } }' <<<"$1"
}

_pc_has() { _pc_names "$1" | grep -qxF -- "$2"; }

_pc_valid_name() {
  [[ "$1" =~ ^[A-Za-z0-9_-]+$ ]] && return 0
  echo "Error: '$1' is not a valid profile name (letters, digits, - and _)." >&2
  return 1
}

# _pc_load <name> — aw_profile_load against the agent profiles are for, with
# a stand-in for every key_env source that is unset here: `show` and `add`
# describe a profile, they do not launch it. The stand-in is local to this
# call (dynamic scope), so nothing outlives it. Sets PC_KEY_SRCS, one
# `SRC<TAB>set|unset` per key_env source.
_pc_load() {
  local name="$1" src
  PC_KEY_SRCS=""
  while IFS= read -r src; do
    [[ -n "$src" && "$src" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
    if [[ -n "${!src:-}" ]]; then
      PC_KEY_SRCS+="$src"$'\tset\n'
    else
      PC_KEY_SRCS+="$src"$'\tunset\n'
      local -x "$src=task-force-stand-in"
    fi
  done < <(awk -F'\t' -v p="profiles.$name.key_env." 'index($1, p) == 1 { print $2 }' <<<"$PC_PARSED")
  aw_profile_load "$name" claude
}

# --- list --------------------------------------------------------------------

_pc_list() {
  local file
  file=$(aw_profile_file)
  if [[ ! -f "$file" ]]; then
    echo "No profiles: $file does not exist yet. Add one with task-config profile add."
    return 0
  fi
  _pc_parse "$file" || return 1
  if [[ -z "$(_pc_names "$PC_PARSED")" ]]; then
    echo "No profiles in $file. Add one with task-config profile add."
    return 0
  fi
  awk -F'\t' '
    $1 ~ /^profiles\./ {
      r = substr($1, 10); p = r; sub(/\..*/, "", p); f = substr(r, length(p) + 2)
      if (!(p in s)) { s[p] = 1; o[++n] = p }
      if (f == "agent") ag[p] = $2
      else if (f == "model") mo[p] = $2
      else if (f == "env.ANTHROPIC_BASE_URL") bu[p] = $2
    }
    END {
      w1 = 4; w2 = 5; w3 = 5
      for (i = 1; i <= n; i++) {
        p = o[i]
        if (length(p) > w1) w1 = length(p)
        if (length(ag[p]) > w2) w2 = length(ag[p])
        if (length(mo[p]) > w3) w3 = length(mo[p])
      }
      fmt = "%-" w1 "s  %-" w2 "s  %-" w3 "s  %s\n"
      printf fmt, "NAME", "AGENT", "MODEL", "BASE URL"
      for (i = 1; i <= n; i++) {
        p = o[i]
        printf fmt, p, (ag[p] == "" ? "-" : ag[p]), (mo[p] == "" ? "-" : mo[p]), (bu[p] == "" ? "-" : bu[p])
      }
    }
  ' <<<"$PC_PARSED"
  printf '\n(%s)\n' "$file"
}

# --- show --------------------------------------------------------------------

_pc_show() {
  local name="${1:-}" file k kind v state
  [[ -n "$name" ]] || { echo "Error: profile show needs a profile name" >&2; return 1; }
  _pc_valid_name "$name" || return 1
  file=$(aw_profile_file)
  _pc_parse "$file" || return 1
  _pc_load "$name" || return 1

  printf 'profile : %s\n' "$name"
  printf 'file    : %s\n' "$file"
  printf 'agent   : claude\n'
  printf 'model   : %s\n' "$AW_PROFILE_MODEL"
  printf '\nA launch sets:\n'
  while IFS=$'\t' read -r k kind v; do
    [[ -n "$k" ]] || continue
    if [[ "$kind" == ref ]]; then
      state=$(awk -F'\t' -v s="$v" '$1 == s { print $2 }' <<<"$PC_KEY_SRCS")
      printf '  %s  from $%s (%s here)\n' "$k" "$v" "${state:-unset}"
    else
      printf '  %s=%s\n' "$k" "$v"
    fi
  done <<<"$AW_PROFILE_VARS"
  if grep -q $'\tunset$' <<<"$PC_KEY_SRCS"; then
    printf '\nThe key'"'"'s variable is unset here, so a launch on this profile is refused.\n'
    printf 'Export it from your shell rc.\n'
  fi
  return 0
}

# --- add ---------------------------------------------------------------------

# A TOML basic string the #355 reader takes back: only \" and \\ are escaped,
# and no tab or newline may appear (the caller has refused those).
_pc_q() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  printf '"%s"' "$s"
}

# Key/value lists are `K<TAB>v` lines (no namerefs: bash 3.2).
# _pc_kv_set <list> <k> <v> — the list with k replaced in place, else appended.
_pc_kv_set() {
  _PC_K="$2" _PC_V="$3" awk -F'\t' '
    BEGIN { k = ENVIRON["_PC_K"]; v = ENVIRON["_PC_V"] }
    $1 == k { print k "\t" v; done = 1; next }
    $0 != "" { print }
    END { if (!done) print k "\t" v }
  ' <<<"$1"
}

# An inline table from a list: { K = "v", … }.
_pc_inline() {
  local k v out=""
  while IFS=$'\t' read -r k v; do
    [[ -n "$k" ]] || continue
    [[ -z "$out" ]] || out+=", "
    out+="$k = $(_pc_q "$v")"
  done <<<"$1"
  printf '{ %s }' "$out"
}

# _pc_splice <name> <file> [block] — the file with profile <name>'s tables
# (its [profiles.<name>] header and any [profiles.<name>.*] header, with the
# lines under them) cut out, and <block> put where the first of them was.
# Comment lines that run up to the next table's header stay, since they
# introduce that table; so do the comments above the profile's own header.
# Blank lines that open that run stay only when a block takes the profile's
# place, so a removal does not leave a double gap.
_pc_splice() {
  _PC_BLOCK="${3:-}" awk -v n="$1" '
    function hname(l,   h) { h = l; sub(/^[ \t]*\[[ \t]*/, "", h); sub(/[ \t]*\].*$/, "", h); return h }
    function ours(h) { return h == "profiles." n || index(h, "profiles." n ".") == 1 }
    function flush() {
      if (ENVIRON["_PC_BLOCK"] == "") sub(/^([ \t]*\n)+/, "", pend)
      printf "%s", pend; pend = ""
    }
    /^[ \t]*\[/ {
      if (ours(hname($0))) {
        if (!placed && ENVIRON["_PC_BLOCK"] != "") { print ENVIRON["_PC_BLOCK"]; placed = 1 }
        inblk = 1; pend = ""; next
      }
      if (inblk) { flush(); inblk = 0 }
      print; next
    }
    inblk {
      if ($0 ~ /^[ \t]*(#.*)?$/) pend = pend $0 "\n"; else pend = ""
      next
    }
    { print }
    END { if (inblk) flush() }
  ' "$2"
}

# _pc_commit <name> <new-content-file> <file> <expect: present|absent>
#
# Check the would-be file (it parses, the profile loads or is gone) in a
# scratch home, then write it. Nothing is written on a failed check.
_pc_commit() {
  local name="$1" new="$2" file="$3" expect="$4" scratch rc=0
  scratch=$(mktemp -d)
  cp "$new" "$scratch/profiles.toml"
  (
    export TASK_FORCE_HOME="$scratch"
    if [[ "$expect" == present ]]; then
      _pc_parse "$scratch/profiles.toml" || exit 1
      _pc_load "$name" >/dev/null
    else
      _pc_parse "$scratch/profiles.toml" || exit 1
      if _pc_has "$PC_PARSED" "$name"; then
        echo "Error: profile '$name' is not written as [profiles.$name] tables in $file," >&2
        echo "       so it cannot be cut out without touching other lines. Edit it by hand." >&2
        exit 1
      fi
    fi
  ) || rc=$?
  rm -rf "$scratch"
  (( rc == 0 )) || return 1
  mkdir -p "$(dirname "$file")"
  cat "$new" > "$file"
}

_pc_add() {
  local name="" preset="" base_url="" model="" key_env="" force=""
  local envs="" pins=""
  local -a cli_env=() cli_pin=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --preset|--base-url|--model|--key-env|--pin|--env|--auth)
        [[ $# -ge 2 ]] || { echo "Error: $1 requires a value" >&2; return 1; }
        case "$1" in
          --preset) preset="$2" ;;
          --base-url) base_url="$2" ;;
          --model) model="$2" ;;
          --key-env) key_env="$2" ;;
          --pin) cli_pin+=("$2") ;;
          --env) cli_env+=("$2") ;;
          --auth)
            echo "Error: --auth is not offered: a profile sends its key as ANTHROPIC_API_KEY" >&2
            echo "       (the x-api-key header) only. ANTHROPIC_AUTH_TOKEN is refused, because with it" >&2
            echo "       Claude Code also sent the machine's saved Anthropic key to the gateway" >&2
            echo "       (docs/agent-profiles-spike.md, section 6)." >&2
            return 1 ;;
        esac
        shift 2 ;;
      --preset=*|--base-url=*|--model=*|--key-env=*|--pin=*|--env=*)
        local opt="${1%%=*}" val="${1#*=}"
        shift
        set -- "$opt" "$val" "$@" ;;
      --auth=*) set -- --auth "${1#*=}" "${@:2}" ;;
      --force) force=1; shift ;;
      -h|--help) _pc_usage; return 0 ;;
      -*) echo "Error: unknown option for profile add: $1" >&2; return 1 ;;
      *)
        [[ -z "$name" ]] || { echo "Error: profile add takes one name (got '$name' and '$1')" >&2; return 1; }
        name="$1"; shift ;;
    esac
  done

  [[ -n "$name" ]] || { echo "Error: profile add needs a profile name" >&2; return 1; }
  _pc_valid_name "$name" || return 1

  if [[ -n "$preset" ]]; then
    local pparsed known kpath v rest
    pparsed=$(_aw_profile_parse "$(_pc_presets_file)") \
      || { echo "Error: $(_pc_presets_file) does not parse." >&2; return 1; }
    if ! grep -q "^presets\.$preset\." <<<"$pparsed" || [[ ! "$preset" =~ ^[A-Za-z0-9_-]+$ ]]; then
      known=$(awk -F'\t' '$1 ~ /^presets\./ { p = substr($1, 9); sub(/\..*/, "", p); if (!(p in s)) { s[p] = 1; o = o (o == "" ? "" : ", ") p } } END { print o }' <<<"$pparsed")
      echo "Error: no preset '$preset'. Presets: ${known:-none}." >&2
      return 1
    fi
    while IFS=$'\t' read -r kpath v; do
      rest="${kpath#presets."$preset".}"
      case "$rest" in
        base_url) [[ -n "$base_url" ]] || base_url="$v" ;;
        env.*) envs=$(_pc_kv_set "$envs" "${rest#env.}" "$v") ;;
        pin.*) pins=$(_pc_kv_set "$pins" "${rest#pin.}" "$v") ;;
      esac
    done < <(grep "^presets\.$preset\." <<<"$pparsed")
  fi

  if [[ -z "$base_url" ]]; then
    if [[ -n "$preset" ]]; then
      echo "Error: preset '$preset' has no fixed address: pass --base-url <url>." >&2
    else
      echo "Error: profile add needs --preset <name> or --base-url <url>." >&2
    fi
    return 1
  fi
  [[ -n "$model" ]] || { echo "Error: profile add needs --model <the gateway's model id>." >&2; return 1; }
  [[ -n "$key_env" ]] || {
    echo "Error: profile add needs --key-env <VAR>, the variable holding the gateway's key." >&2; return 1; }
  [[ "$key_env" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || {
    echo "Error: --key-env takes a variable name, not '$key_env'." >&2
    echo "       Name the variable that holds the key; its value never goes in the file." >&2
    return 1; }

  # Base URL first, then the preset's env, then --env, each overriding.
  local kv k v merged="ANTHROPIC_BASE_URL"$'\t'"$base_url"
  while IFS=$'\t' read -r k v; do
    [[ -z "$k" ]] || merged=$(_pc_kv_set "$merged" "$k" "$v")
  done <<<"$envs"
  envs="$merged"
  for kv in ${cli_env[@]+"${cli_env[@]}"}; do
    [[ "$kv" == *=* && -n "${kv%%=*}" ]] || { echo "Error: --env takes K=V, not '$kv'." >&2; return 1; }
    k="${kv%%=*}"
    [[ "$k" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || { echo "Error: --env name '$k' is not a valid variable name." >&2; return 1; }
    envs=$(_pc_kv_set "$envs" "$k" "${kv#*=}")
  done
  for kv in ${cli_pin[@]+"${cli_pin[@]}"}; do
    [[ "$kv" == *=* ]] || { echo "Error: --pin takes <tier>=<id>, not '$kv'." >&2; return 1; }
    k="${kv%%=*}"
    case "$k" in
      sonnet|haiku|opus|subagent) ;;
      *) echo "Error: unknown pin '$k' (sonnet, haiku, opus or subagent)." >&2; return 1 ;;
    esac
    [[ -n "${kv#*=}" ]] || { echo "Error: --pin $k= needs a model id." >&2; return 1; }
    pins=$(_pc_kv_set "$pins" "$k" "${kv#*=}")
  done

  # What the reader cannot take back: a tab or a newline in a value.
  local tv
  for tv in "$model" "$key_env" "$base_url" ${cli_env[@]+"${cli_env[@]}"} ${cli_pin[@]+"${cli_pin[@]}"}; do
    if [[ "$tv" == *$'\t'* || "$tv" == *$'\n'* ]]; then
      echo "Error: a value may not contain a tab or a newline." >&2; return 1
    fi
  done

  local file
  file=$(aw_profile_file)
  _pc_parse "$file" || return 1
  if _pc_has "$PC_PARSED" "$name" && [[ -z "$force" ]]; then
    echo "Error: profile '$name' already exists in $file. Pass --force to replace it." >&2
    return 1
  fi

  local block new
  block=$(
    printf '[profiles.%s]\n' "$name"
    printf 'agent   = "claude"\n'
    printf 'model   = %s\n' "$(_pc_q "$model")"
    printf 'env     = %s\n' "$(_pc_inline "$envs")"
    printf 'key_env = { ANTHROPIC_API_KEY = %s }\n' "$(_pc_q "$key_env")"
    if [[ -n "$pins" ]]; then printf 'pin     = %s\n' "$(_pc_inline "$pins")"; fi
  )
  new=$(mktemp)
  if _pc_has "$PC_PARSED" "$name"; then
    # --force: in place, so the file keeps its order.
    _pc_splice "$name" "$file" "$block" > "$new"
  elif [[ -s "$file" ]]; then
    # Appended, one blank line after whatever the file ended with.
    printf '%s\n\n%s\n' "$(cat "$file")" "$block" > "$new"
  else
    printf '%s\n' "$block" > "$new"
  fi

  if ! _pc_commit "$name" "$new" "$file" present; then
    rm -f "$new"
    echo "Nothing written." >&2
    return 1
  fi
  rm -f "$new"

  printf '%s profile %s in %s.\n' "$([[ -n "$force" ]] && _pc_has "$PC_PARSED" "$name" && echo Replaced || echo Added)" "$name" "$file"
  if [[ -z "${!key_env:-}" ]]; then
    printf 'Warning: $%s is unset here. Export it from your shell rc before a launch:\n' "$key_env"
    printf '         a launch on this profile is refused until it is set.\n'
  fi
  printf 'Check it with: task-config profile test %s\n' "$name"
}

# --- remove ------------------------------------------------------------------

_pc_remove() {
  local name="${1:-}" file new
  [[ -n "$name" ]] || { echo "Error: profile remove needs a profile name" >&2; return 1; }
  _pc_valid_name "$name" || return 1
  file=$(aw_profile_file)
  [[ -f "$file" ]] || { echo "Error: no profile file at $file." >&2; return 1; }
  _pc_parse "$file" || return 1
  if ! _pc_has "$PC_PARSED" "$name"; then
    echo "Error: no profile '$name' in $file. Profiles there: $(_pc_names "$PC_PARSED" | paste -sd, - | sed 's/,/, /g')." >&2
    return 1
  fi
  new=$(mktemp)
  _pc_splice "$name" "$file" > "$new"
  if ! _pc_commit "$name" "$new" "$file" absent; then
    rm -f "$new"; echo "Nothing written." >&2; return 1
  fi
  rm -f "$new"
  printf 'Removed profile %s from %s.\n' "$name" "$file"
}

# --- test --------------------------------------------------------------------

# What `test` asks: read one file with one tool, answer with what it says. The
# nonce is in no prompt, so the answer carries it only if the tool ran.
_PC_TEST_PROMPT='Use the Read tool to read the file probe.txt in the current directory, then reply with its contents and nothing else.'

# How long `test` waits for claude before it stops it and fails: a gateway
# that accepts the connection and never answers would otherwise hang it.
_PC_TEST_TIMEOUT_DEFAULT=60

# _pc_stop <pid> — TERM the process and its children, KILL what is left after
# 3s. Portable: no timeout(1) on macOS.
_pc_stop() {
  local pid="$1"
  command -v pkill >/dev/null 2>&1 && pkill -TERM -P "$pid" 2>/dev/null
  kill -TERM "$pid" 2>/dev/null
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.2
  done
  command -v pkill >/dev/null 2>&1 && pkill -KILL -P "$pid" 2>/dev/null
  kill -KILL "$pid" 2>/dev/null
  return 0
}

_pc_test() {
  local name="" timeout="${TASK_CONFIG_PROFILE_TEST_TIMEOUT:-$_PC_TEST_TIMEOUT_DEFAULT}"
  local file key_src key tmp out err rc=0 t0 t1 nonce
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --timeout)
        [[ $# -ge 2 ]] || { echo "Error: --timeout requires a value" >&2; return 1; }
        timeout="$2"; shift 2 ;;
      --timeout=*) timeout="${1#--timeout=}"; shift ;;
      -*) echo "Error: unknown option for profile test: $1" >&2; return 1 ;;
      *)
        [[ -z "$name" ]] || { echo "Error: profile test takes one name (got '$name' and '$1')" >&2; return 1; }
        name="$1"; shift ;;
    esac
  done
  [[ "$timeout" =~ ^[1-9][0-9]*$ ]] || {
    echo "Error: the profile test timeout must be a positive number of seconds, not '$timeout'." >&2; return 1; }
  [[ -n "$name" ]] || { echo "Error: profile test needs a profile name" >&2; return 1; }
  _pc_valid_name "$name" || return 1
  command -v jq >/dev/null 2>&1 || { echo "Error: profile test needs jq." >&2; return 1; }
  command -v claude >/dev/null 2>&1 || { echo "Error: profile test needs claude on PATH." >&2; return 1; }
  file=$(aw_profile_file)
  # The launchers' own check, unset key included: a profile test refuses
  # what a launch would.
  aw_profile_load "$name" claude || return 1
  key_src=$(awk -F'\t' '$1 == "ANTHROPIC_API_KEY" && $2 == "ref" { print $3 }' <<<"$AW_PROFILE_VARS")
  key="${key_src:+${!key_src}}"

  tmp=$(mktemp -d)
  nonce="tf-probe-$RANDOM$RANDOM$RANDOM"
  printf '%s\n' "$nonce" > "$tmp/probe.txt"
  out="$tmp/.out" err="$tmp/.err"

  t0=$(date +%s)
  (
    cd "$tmp" || exit 1
    # No radio identity: the run registers nothing and wakes no one. And no
    # bearer token from this shell: the profile's x-api-key is the only
    # credential the gateway should see (spike, section 6).
    unset TASK_FORCE_ROLE TASK_FORCE_PM_ROLE TASK_FORCE_AUTO_SUBMIT TASK_FORCE_LOADOUT ZELLIJ_TAB \
          ANTHROPIC_AUTH_TOKEN
    aw_profile_export
    exec claude -p "$_PC_TEST_PROMPT" --model "$AW_PROFILE_MODEL" \
      --output-format stream-json --verbose --allowedTools Read --max-turns 4 </dev/null
  ) >"$out" 2>"$err" &
  # The watchdog: poll every 0.2s, so a quick run is not held to a whole
  # second, and stop claude once the timeout has passed.
  local cpid=$! ticks=0 timed_out=""
  while kill -0 "$cpid" 2>/dev/null; do
    if (( ticks >= timeout * 5 )); then
      timed_out=1
      _pc_stop "$cpid"
      break
    fi
    sleep 0.2
    ticks=$(( ticks + 1 ))
  done
  wait "$cpid" 2>/dev/null
  rc=$?
  t1=$(date +%s)

  local report
  report=$(jq -r -R -s --arg nonce "$nonce" '
    [split("\n")[] | fromjson? | select(type == "object")] as $ev
    | ([$ev[] | select(.type == "assistant") | .message] ) as $msgs
    | ([$msgs[] | .model // empty | select(. != "<synthetic>")] | first) as $model
    | ([$msgs[] | .content[]? | select(.type == "tool_use") | .name] | unique) as $tools
    | ([$ev[] | select(.type == "result")] | last) as $res
    | ([$msgs[] | select(.model == "<synthetic>") | .content[]? | select(.type == "text") | .text] | first) as $synth
    | {
        model: ($model // ""),
        tools: ($tools | join(",")),
        nonce: ((($res.result // "") | tostring | contains($nonce))),
        is_error: (($res.is_error // false) or ($res == null)),
        error: ((if ($res.is_error // false) then ($res.result // $res.subtype // "") else "" end) as $e
                | if ($e | tostring) != "" then $e else ($synth // "") end | tostring)
      }
    | [.model, .tools, (.nonce | tostring), (.is_error | tostring), (.error | gsub("[\u001f\n]"; " "))] | join("\u001f")
  ' "$out" 2>/dev/null) || report=""

  local model="" tools="" saw_nonce="false" is_error="true" gw_err=""
  [[ -z "$report" ]] || IFS=$'\x1f' read -r model tools saw_nonce is_error gw_err <<<"$report"
  if [[ -n "$timed_out" ]]; then
    gw_err="timed out after ${timeout}s with no answer from the gateway; claude was stopped (--timeout <secs> or \$TASK_CONFIG_PROFILE_TEST_TIMEOUT to wait longer)"
  elif [[ -z "$gw_err" && ( "$is_error" == true || $rc -ne 0 ) ]]; then
    gw_err=$(tail -5 "$err" | tr '\n' ' ')
  fi
  # Whatever came back, the key does not leave this function.
  [[ -z "$key" ]] || gw_err="${gw_err//"$key"/<key>}"
  rm -rf "$tmp"

  local ok=1 auth tool
  # Auth is inferred, not observed: claude reports no auth status, but a
  # message from a real model means the gateway took the key. A rejected key
  # yields only Claude Code's own `<synthetic>` error message.
  if [[ -n "$model" ]]; then auth="ok"; else auth="FAILED"; ok=0; fi
  if [[ -n "$tools" && "$saw_nonce" == true ]]; then
    tool="ok ($tools)"
  elif [[ -n "$tools" ]]; then
    tool="FAILED (called $tools, but the answer did not carry the file's contents)"; ok=0
  else
    tool="FAILED (no tool call)"; ok=0
  fi
  [[ "$is_error" == true || $rc -ne 0 || -n "$timed_out" ]] && ok=0

  printf 'profile test: %s (model %s, %s)\n' "$name" "$AW_PROFILE_MODEL" "$file"
  printf '  auth      : %s\n' "$auth"
  printf '  answered  : %s\n' "${model:--}"
  printf '  tool use  : %s\n' "$tool"
  printf '  elapsed   : %ss\n' "$(( t1 - t0 ))"
  if (( ok )); then
    printf 'OK\n'
    return 0
  fi
  printf '  error     : %s\n' "${gw_err:-claude exited $rc with no error message}"
  printf 'FAILED\n'
  return 1
}

aw_profile_cmd() {
  local sub="${1:-}"
  [[ $# -gt 0 ]] && shift
  case "$sub" in
    list)   _pc_list "$@" ;;
    show)   _pc_show "$@" ;;
    add)    _pc_add "$@" ;;
    test)   _pc_test "$@" ;;
    remove) _pc_remove "$@" ;;
    ""|-h|--help|help) _pc_usage ;;
    *) echo "Error: unknown profile subcommand '$sub' — expected add, list, show, test or remove" >&2; return 1 ;;
  esac
}
