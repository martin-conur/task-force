# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

- **Radio zellij actions now scope to the role's own tab/pane, not the focused tab.** `_rename_tab` and `radio send` previously used `zellij action rename-tab` / `go-to-tab-name` + `write-chars`, which target whichever tab is focused at the moment. With a PM and one or more workers running side-by-side, that leaked: a worker's auto-unregister could clobber PM's tab name, and `radio send --to pm` from worker B (while worker A was focused) could deliver `radio check` to the wrong tab. `radio register` now resolves and persists the role's stable `tab_id` as `TAB_ID=` in the session file, and both `_rename_tab` (`rename-tab-by-id`) and `cmd_send` (`write-chars --pane-id`) drive their actions by that id — so renames, duplicate tab names, and stale `TAB=` mid-flip can't misroute a wake-up. A defense-in-depth `$ZELLIJ_TAB` mismatch check guards against future regressions. (#102)

## [0.2.1] — 2026-05-22

Radio polish patch. Three lifecycle / UX fixes building on the `v0.2.0` radio rollout.

### Fixed

- **Radio hooks no-op when `$TASK_FORCE_ROLE` is unset.** Plain `claude` in a task-force-equipped repo was getting blocked at every prompt because the `UserPromptSubmit` hook (and friends) erred out when no role was set. Hook-invoked subcommands (`busy`, `ready`, `check`, `unregister`, `register --role ""`) now silently exit 0 when role is missing; user-invoked subcommands (`read`, `ack`) still fail loudly. (#93, #96)
- **Auto-unregister radio sessions on session/worker end.** Worker session files were orphaning in `~/.task-force/radio/sessions/` after a worker finished. Two new lifecycle beats: a Claude `SessionEnd` hook calls `radio unregister`; `task-done` calls `radio unregister` before tearing down the worktree. (#94, #97)

### Added

- **Idle/busy emoji in zellij tab names.** `radio` now prefixes the current tab with `⏸️` (idle) or `▶️` (busy) so you can see at a glance which workers are mid-turn vs. waiting on input — useful when running several workers in parallel. `TAB=` in the session file is kept in sync so `radio send`'s `go-to-tab-name` wake-up still finds the renamed tab. (#95, #99)

## [0.2.0] — 2026-05-21

Headline: **PM ↔ worker radio messaging.** A persistent mailbox CLI plus a canonical 5-row handoff protocol baked into every role's prompt. Workers now defer `Status=Done` and worktree cleanup until the PM signals `approved-and-merged`, so the whole spec → review → merge loop runs through `radio send`.

### Added

- **PM ↔ worker messaging (radio):** new `radio` mailbox CLI (`send` / `check` / `read` / `ack` / `register` / `ready` / `busy` / `unregister` / `orphans`) plus `task-pm` for in-place PM-tab takeover. Hook-driven session registration is auto-installed by every `task-init` (claude-\* via `.claude/settings.json` jq merge, kiro-\* via `.kiro/hooks/`). Idle recipients are woken via `zellij action go-to-tab-name`; busy recipients queue-and-defer. (#63)
- **Canonical radio handoff protocol** baked into every role's prompt — 5 transitions: `spec-ready`, `review-requested`, `re-review-requested`, `changes-requested`, `approved-and-merged`. Worker now delays `Status=Done` and `task-done --remove-worktree` until PM signals `approved-and-merged`. (#75, #82)
- **`task-init` seeds `Bash(radio *)`** into `.claude/settings.json` `permissions.allow` across all claude loadouts so radio calls don't trigger permission prompts. (#83)
- **`task-init --restore`:** fill in only the files that are missing; never touch anything that already exists. Lets you restore a deleted slash command / agent without re-typing your board IDs. (#37)
- **`task-init --workflow` / `--commands`:** scope the run to just the workflow doc, or just the slash commands / agents. Compose with `--force` / `--restore` for surgical refreshes. (#37)
- **Per-file `[k]eep / [o]verwrite / [d]iff` prompt:** in a TTY, when a target already exists `task-init` prompts per file (default = keep). Old behavior was hard-fail with "Use --force." (#37)
- **Placeholder preservation:** when re-rendering the workflow doc, previously-filled `{OWNER}` / `{REPO}` / `{PROJECT}` / `{SITE}` / `{KEY}` / `{BOARD}` values are carried forward automatically. Precedence: this-run flag → existing-file value → leave the `{PLACEHOLDER}` token. (#37)
- **Shared helpers:** `lib/install-file.sh` (exists / prompt / diff / overwrite / keep decision) and `lib/preserve-placeholders.sh` (generic placeholder extractor), with unit tests in `tests/install_file.bats` and `tests/preserve_placeholders.bats`. (#37)

### Changed

- **`claude-gh` / `kiro-gh` now standardize on the `gh` CLI** for issue and project reads (previously: GitHub MCP). `task-init claude-gh` seeds a read-only `gh` allow-list into `.claude/settings.json` (`gh issue view *`, `gh project view *`, `gh search issues *`, etc.) so the PM / planner / worker can read freely; mutations stay confirmation-gated. The GitHub MCP is documented as an **optional** add-on for users who frequently mutate Projects v2 fields. (#69)
- **Read-only allow-list seeding across Claude loadouts.** `task-init claude-jira` and `task-init claude-notion` now seed `.claude/settings.json` with read-only `mcp__atlassian__*` / `mcp__notion__*` patterns so PM / planner / worker reads are auto-approved. `claude-local` continues to rely on Claude Code's built-in file tools. Mutations across all loadouts remain confirmation-gated. (#69)
- **`task-init` no longer hard-fails when target files exist.** In a TTY it now prompts per file (`[k]eep / [o]verwrite / [d]iff`, default = keep). In a non-TTY context it silently skips existing files and exits 0. `--force` (unchanged behavior) remains for unconditional overwrite. (#37)

### Fixed

- Installer prompts: arrow keys (↑/↓/←/→) now provide readline navigation instead of echoing raw escape sequences (`^[[A`). Switched `read -rp` → `read -erp` in `install.sh`, `task-init`, and `*/bin/task-init`. (#23)
- **task-init:** silenced ShellCheck SC2016 false-positive on the `_preserve_placeholders` regex backticks. `main` had been red on this check since #37. (#71)

### Docs

- README now documents the radio messaging channel and the normal PM/worker workflow. (#79)
- README synced to the canonical handoff model: 5-row handoff table, 8-step walkthrough with `Status=In Review` beat and radio-driven cleanup. (#87)

### Internal

- **CI:** ShellCheck / Bats / Drift status checks are now required on `main` branch protection. (#73)

## [0.1.0] — 2026-05-19

First feature release since `v0.0.1`. Highlights: two new local-tracking loadouts (`claude-local`, `kiro-local`), `--from` / `--plan` / `--auto` flags for `task-work`, a CI drift-check guardrail across all 7 loadouts, macOS CI coverage, and a string of safety fixes for `task-done` / submodules / stale-base worktrees.

### Added

- **Loadouts:** `claude-local` and `kiro-local` — local markdown task tracking, no external tracker required (#30, #34)
- **Loadout docs:** README coverage for the new local loadouts (#33)
- **Claude slash commands** (`/planner`, `/pm`, `/worker`) + `gh-workflow.md` template installed by `task-init` (#25)
- **`task-work --from <ref>`:** fork the new worktree's branch from an arbitrary git ref (stacked PRs become first-class); independent of `--base` (#57)
- **`task-work --plan` / `--auto`:** launch the worker in Claude's plan-mode or auto-permission-mode (Claude loadouts only) (#45)
- **`task-work` auto-refresh:** if local `<base>` is strictly behind `origin/<base>`, warn and fork from `origin/<base>` instead of stale local tip (#62)
- **Drift-check guardrail:** `tools/check-drift.sh` + sentinel regions across all 7 loadouts' `task-work` / `task-done`; wired into CI as a third job (#58)
- **macOS in CI:** Bats runs on both `ubuntu-latest` and `macos-latest` (#56)
- **LICENSE:** MIT (#51)

### Changed

- `task-init` installs slash commands and agents at the project level instead of overwriting global Claude config (#22)
- `task-init` **copies** slash commands and agents into the project instead of symlinking — survives re-installs and supports parallel projects (#36)
- `task-done --remove-worktree` skips the removal confirmation when intent is already declared (#41)
- `task-done` attempts a safe `git branch -d` after worktree removal — no orphan local branches when the branch is fully merged (#43)

### Fixed

- `task-work` no longer silently reuses an existing branch on name collision — warns loudly with branch-tip and divergence info before reusing (#44)
- `task-done` no longer silently swallows the *"working trees containing submodules cannot be moved or removed"* error — deinits submodules before `git worktree remove` and surfaces real failures (#59)
- CI shellcheck now covers all loadouts and is clean across BSD/GNU coreutils on macOS (#52, #55)

### Internal

- Test temp-dir cleanups moved to bats `teardown()` so they fire even on assertion failure (#64)
- Bats suite at **460 tests** across 7 loadouts × 2 OS

[Unreleased]: https://github.com/martin-conur/task-force/compare/v0.2.1...HEAD
[0.2.1]: https://github.com/martin-conur/task-force/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/martin-conur/task-force/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/martin-conur/task-force/compare/v0.0.1...v0.1.0
