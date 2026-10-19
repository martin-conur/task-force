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

    d=$(mktemp -d); cp v2/*.json "$d"/; kiro-cli agent upgrade --no-backup "$d"; cp "$d"/*.json .

| File | Input hooks | What it is for |
|------|-------------|----------------|
| `radio-and-user.json` | the three radio hooks (kiro-gh), plus the user's own `stop` hook and a `preToolUse` hook with a `matcher` and `timeout_ms` | an upgraded config of a repo task-init already set up: the merge must leave it alone, and the strip must take out the radio entries and nothing else |
| `radio-only.json` | the three radio hooks only | the strip empties `hooks` and drops the key |
| `user-only.json` | the user's own `agentSpawn` and `stop` hooks | a config with no radio hooks yet: the merge must add them in the universal shape |

Things the upgrade did that the tests rely on:

- Entries are named `<trigger>-<n>` and sorted by trigger.
- `timeout` is in seconds (`timeout_ms: 5000` became `5`), and an entry that
  had none got `10`.

A config that task-init's merge then edits still passes
`kiro-cli agent validate`, and a second `kiro-cli agent upgrade --dry-run`
reports it `already universal`. The `kiroUpgrade` fingerprint does not make
kiro-cli reject or re-upgrade it.
