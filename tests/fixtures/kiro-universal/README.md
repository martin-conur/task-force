# kiro "universal" agent configs

Agent configs as kiro-cli's V3 engine rewrites them, into the format it calls
"universal" (#267). Here `hooks` is an array of
`{name, trigger, action: {type, command}, timeout}` and is no longer an object
keyed by trigger. kiro-cli also adds a `permissions.rules` block and a
`kiroUpgrade` fingerprint. Tests copy these into `.kiro/agents/` to exercise
task-init's radio-hook merge and `lib/loadout-artifacts.sh`'s strip against the
shape kiro-cli actually writes. Hand-built JSON would only show what the shape
*should* look like.

## Provenance

Each file at the top level is the unedited output of

    kiro-cli agent upgrade --no-backup <dir>

on **kiro-cli 2.32.0**, run over the matching input in `v2/`. The inputs are
minimal configs in task-init's own shape, with the radio commands copied
verbatim from what `kiro-gh/bin/task-init` installs. They are kept small on
purpose so the fixtures do not go stale whenever a shipped prompt changes. To
regenerate:

    d=$(mktemp -d); h=$(mktemp -d); cp v2/*.json "$d"/
    env -u TASK_FORCE_ROLE HOME="$h" TASK_FORCE_HOME="$h/tf" \
      "/Applications/Kiro CLI.app/Contents/MacOS/kiro-cli-chat" agent upgrade --no-backup "$d"
    cp "$d"/*.json .

Run it with HOME pointed at a scratch directory, as above, so that kiro-cli
cannot reach your real `~/.kiro`. The `kiro-cli` launcher looks for
`$HOME/.local/bin/kiro-cli-chat`, so under a scratch HOME you have to call the
`kiro-cli-chat` binary by its real path. The command above uses the macOS
install path. The current fixtures were all produced this way, and kiro-cli
wrote its own state (`.kiro/settings/cli.json`, `data.sqlite3`) into the
scratch HOME. `radio-and-user.json`, `radio-only.json` and `user-only.json`
were first made under the real HOME. Regenerating them under a scratch HOME
gave byte-identical files.

| File | Input hooks | What it is for |
|------|-------------|----------------|
| `radio-and-user.json` | the three radio hooks (kiro-gh), plus the user's own `stop` hook and a `preToolUse` hook with a `matcher` and `timeout_ms` | an upgraded config of a repo task-init already set up: the merge must leave it alone, and the strip must take out the radio entries and nothing else |
| `radio-only.json` | the three radio hooks only | the strip empties `hooks` and drops the key |
| `user-only.json` | the user's own `agentSpawn` and `stop` hooks | a config with no radio hooks yet: the merge must add them in the universal shape |
| `no-hooks.json` | none — no `hooks` key | the upgrade writes no `hooks` either, so the merge has no shape to read: it must create an array, not the object-in-a-universal-file hybrid |

Things the upgrade did that the tests rely on:

- Entries are named `<trigger>-<n>` and sorted by trigger.
- `timeout` is in seconds (`timeout_ms: 5000` became `5`), and an entry that
  had none got `10`.

A config that task-init's merge then edits still passes
`kiro-cli agent validate`, and a second `kiro-cli agent upgrade --dry-run`
reports it `already universal`. The `kiroUpgrade` fingerprint does not make
kiro-cli reject or re-upgrade it.

Two more findings on 2.32.0, probed with `agent upgrade --dry-run`, which
classifies each file it is given:

- **`permissions` decides the hooks shape, not `kiroUpgrade`.**
  - Put an object `hooks` in a file that has `permissions` and kiro-cli
    reports it `out of sync (not rebuilt)`, whether or not the file carries
    `kiroUpgrade`. An array `hooks` is accepted in every case.
  - Drop `permissions` from an upgraded file and kiro-cli offers to upgrade
    it again. Drop `kiroUpgrade` instead and the file stays
    `already universal`.
  - A file with no `allowedTools` is classed `v3-only`, and such a file
    carries no fingerprint.
  - So for a file with no `hooks` key, the merge picks the shape from
    `has("permissions")`.
- **Hook `name`s need not be unique.** `agent validate`, `agent upgrade` and
  `agent list` all accept two entries with the same name. Whether both of
  them fire in a live session was not tested.

`agent validate` cannot settle either question. It accepted every variant
tried, the hybrid included, and it exits 0 even when it prints an error.
