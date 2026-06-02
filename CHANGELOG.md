# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

- **`task-done --remove-worktree` now force-deletes reviewer branches so `task-reviewer` re-dispatch isn't blocked.** The cleanup's `git branch -d` is the safe-delete variant that requires the branch to be fully merged into HEAD — correct for worker branches (don't drop unmerged work), but wrong for reviewer worktrees, whose `task/review-pr<N>` branch is forked from the PR's head ref and is never going to land in main (the PR is). Result: every reviewer cleanup left `task/review-pr<N>` behind as an orphan, and the next `task-reviewer <N>` refused to dispatch via its per-PR guard with `Error: a review worktree or branch already exists`. The user had to manually `git branch -D task/review-pr<N>` between every re-review round. `task-done` now branches on the `PR_NUMBER=` marker that `task-reviewer` writes into the worktree's `.info` file: when present it does `git branch -D` (scaffold-only, safe to force); when absent worker behavior is unchanged. Lands across the `task-done-std` and `task-done-local` drift groups (7 binaries). (#148)
- **Radio session corruption on long-running workers — `LOADOUT` / `AGENT` / `TAB_ID` no longer lost mid-life.** Three-bug cluster surfaced by `--auto` workers running for hours: Claude Code's `SessionEnd` hook fires repeatedly with non-`clear|resume` reasons (the diagnostic added in #150 caught bursts of 144 invocations in ~25s, payload literally a single `y` character, `reason=<unset>` — phantom calls upstream of the documented hook contract), each one wiping `~/.task-force/radio/sessions/<role>.info`. The next `busy`/`ready` hook re-seeded the file with `LOADOUT=unknown`, empty `TAB_ID=`, and `AGENT=claude` (silently flipping kiro-* workers), which then broke `radio send`'s tab-id-based wake-up — PM pings landed in the mailbox silently and never woke the worker. Three concrete fixes: **(#140 Fix B)** `_zellij_tab_id_by_name` now matches the emoji-prefixed visible name (`⏸️ <slug>` / `▶️ <slug>` / `❓︎ <slug>`) so the re-seed's tab-id lookup survives `_rename_tab`'s repaints; **(#140 Fix C / #150 / #151)** `cmd_register` writes a `<role>.loadout` (and now `<role>.agent`) sidecar atomically BEFORE the `.info` write (so a kill mid-call leaves a recoverable state), `_ensure_session_file` reads from those sidecars on re-seed (TOCTOU-safe via `cat || true`), and `cmd_unregister`'s skip-list now also short-circuits on empty `reason` — treating the cascade pattern the same as `clear` / `resume`. Real-exit reasons (`logout` / `prompt_input_exit` / `other`) still flow through and clean up normally. Net result: a worker that previously degraded after 4–8 hours (or sooner under heavy subagent use) now keeps its full identity through the cascade, and PM `radio send` keeps waking it via the original `TAB_ID`. (#140, #150, #151)
- **`task-reviewer`'s spec-issue cross-check now works on `claude-jira` / `claude-notion` / `claude-local`.** The dispatcher and the `/reviewer` prompt were both GitHub-only: `parse_issue_number` rejected anything that wasn't a bare integer or `github.com/.../issues/N`; PR-body auto-detect only matched `Closes #N`; the URL-synthesis step always emitted a GitHub issues URL; and the prompt hardcoded `gh issue view <M>` for spec lookup. Net result: in any non-gh loadout, `task-reviewer <pr> <spec-id>` silently degraded to a diff-only review. The dispatcher is now loadout-aware (detects from its own file path) — `claude-gh` keeps numeric / URL parsing and PR-body auto-detect; `claude-jira` / `claude-notion` / `claude-local` accept any non-empty 2nd positional arg as an opaque spec identifier (Jira key, Notion URL, local task slug) and pass it through to `/reviewer` unchanged. The 4 dispatcher bodies stay byte-identical (drift-checked). Each loadout's `commands/reviewer.md` now points the spec-lookup step at the right tool: GH stays on `gh issue view`; `claude-jira` uses `mcp__atlassian__getJiraIssue`; `claude-notion` uses `mcp__notion__notion-fetch`; `claude-local` reads `tasks/<id>-<slug>.md` via the `Read` tool. With no 2nd arg in a non-gh loadout, the wrapper emits a clear "PR-body auto-detect is GitHub-only — pass the spec id explicitly" advisory and proceeds diff-only. **Upgrading**: re-run `task-init <loadout>` after pulling this change so the updated `/reviewer` prompt lands in `.claude/commands/`. (#144)

### Changed

- **`task-reviewer` redesigned from a long-lived listener-tab model into a dispatch-style worker.** New surface: `task-reviewer <pr-url-or-number> [<issue-url-or-number>] [--no-auto] [--no-launch]` (claude variants) / `[--no-trust-all] [--no-launch]` (kiro). Each invocation spawns a fresh zellij tab + git worktree on the PR's head ref, runs a thorough review (spec-compliance cross-check + `code-review` skill on the diff), posts a single PR comment with findings, and radios PM back with `review-complete-clean` or `review-complete-with-findings`. **Auto-permission is the default** — the `/reviewer` prompt's authority boundaries rule out merge / push / approve / close / Status edits, so hands-off dispatch is safe; pass `--no-auto` (or `--no-trust-all` for kiro) to drop into the interactive permission path. PM no longer needs a pre-spawned reviewer tab — the previous no-arg, in-place tab takeover (shipped in #135, rolled out in #137) is gone. Affects `claude-gh`, `claude-jira`, `claude-notion`, `claude-local`, and `kiro-gh`. The per-loadout `bin/task-reviewer`, the `/reviewer` slash command + kiro agent, PM's reviewer-delegation guidance, and the README / workflow docs were all rewritten. (#138)

  **Upgrading**: existing projects that already ran `task-init claude-gh` (or the matching `task-init <loadout>` for claude-jira / claude-notion / claude-local / kiro-gh) **must re-run** `task-init <loadout>` after pulling this change. The new `/reviewer` slash command (or the kiro `reviewer` agent) lives in the loadout's `commands/` (or `agents/`) directory and gets copied into `.claude/commands/` (or `.kiro/agents/`) by `task-init`. Without that re-run, the spawned reviewer tab will fail with `Unknown command: /reviewer`. PM's "Delegating review" guidance and the radio-handoffs table also got expanded — re-running `task-init` pulls those in too.
- **`radio read <id>` now auto-acks (moves `inbox/` → `processed/`).** The previous `read` + `ack` split was a workflow footgun: workers would `read` a message, act on it, forget to `ack`, and every subsequent `radio check` would re-list the stale entry identically — making PM's silence indistinguishable from PM never having pinged. `read` now collapses both beats by default. An explicit `radio read --peek <id>` (alias: `--no-ack`) is the escape hatch for "I just want to see what's in there without consuming it." `radio ack <id>` is now idempotent: if the message was already moved by a prior `read`, it exits 0 with a friendly "already processed" line so existing `read && ack` scripts and muscle memory keep working. This is a deliberate UX change, not a bug fix — the old behavior was the intended (broken) design. (#131)

### Added

- **`task-work --auto` spawns the worker tab without stealing focus from the caller.** Zellij's `new-tab` has no `--no-focus` flag, so dispatching a worker from PM always snapped focus into the new tab — friction when running 3–4 parallel `--auto` workers back-to-back. `aw_launch_tab` now takes an optional `stay_on_caller_tab` arg; `--auto` task-work threads `$AUTO_MODE` through so the launcher captures the caller's tab position via `zellij action list-tabs --json` before `new-tab`, then snaps focus back with `go-to-tab <pos+1>` after. Default `task-work` and `task-work --plan` are unchanged — both still land in the new tab (planner is interactive; you want to be there). Defensive: all gates (`$ZELLIJ` unset, `jq` missing, empty position, non-zero `go-to-tab`) fall through to the legacy focus-shift path; the worker spawn never aborts because the snap-back failed. (#130)
- **Opt-in auto-submit on radio wake-up for `--auto` workers.** `radio send`'s zellij `write-chars` wake-up has always written `radio check\n` (LF) into the recipient's pane, leaving it sitting in the input box until the user pressed Enter. For workers launched via `task-work --auto` — already an explicit autonomy opt-in, and idle most of their life waiting on PM — that human gate is friction with no upside. `task-work --auto` now exports `TASK_FORCE_AUTO_SUBMIT=1`; `radio register` / `_ensure_session_file` persist that as `AUTO_SUBMIT=1` in the session file; `cmd_send` reads it and switches the wake-up byte to CR (`\r`), which Claude Code's raw-mode input binds to Enter. PM and default (non-`--auto`) workers leave the flag unset and keep the LF wake-up, so a `radio check` ping can never corrupt a partially-typed prompt. (#128)

## [0.2.2] — 2026-05-23

Patch release. Extends the cross-tab targeting fix from `v0.2.1` (radio) to `task-done`, and hardens the radio session lifecycle so intra-session Claude events (`/clear`, `/compact`, resume) don't brick subsequent radio operations.

### Fixed

- **`task-done` close-tab no longer targets the focused tab.** The final `zellij action close-tab` in `*/bin/task-done` had no explicit tab id, so if the user switched focus to another tab (e.g., PM) while a worker was auto-cleaning up, the wrong tab got closed — destroying the user's active session. Same root cause as #102, in a different binary. `task-done` now captures the worker's stable `TAB_ID=` from its radio session file *before* `radio unregister` runs, and closes the tab via `zellij action close-tab-by-id`. If no tab id can be captured (zellij not running, no role, missing session file), close-tab is skipped — never falls back to the unscoped call. (#107, #108)
- **Radio session file survives intra-session Claude events.** Claude Code's `SessionEnd` hook fires on `/clear`, `/compact`, and session resume in addition to real exit. The old `radio unregister` hook proceeded unconditionally, wiping the session file mid-life — observed in production as bursts of 40+ unregister calls within ~25s, with subsequent `busy`/`ready`/`send` operations logging "no session file" for the now-missing role. `cmd_unregister` now reads the JSON payload piped by the hook and skips when `reason` is `clear` or `resume`; manual `radio unregister` (no stdin payload) still works. Companion `_ensure_session_file` in `_update_state` self-heals if a stale unregister did get through. (#108)

### Internal

- New bats coverage: `tests/radio_lifecycle.bats` and `tests/task_done_close_tab.bats` pin the contract for both fixes.

## [0.2.1] — 2026-05-22

Radio polish + reliability patch. Lifecycle / UX fixes building on the `v0.2.0` radio rollout, plus a tab-targeting fix that hardens cross-tab routing.

### Fixed

- **Radio hooks no-op when `$TASK_FORCE_ROLE` is unset.** Plain `claude` in a task-force-equipped repo was getting blocked at every prompt because the `UserPromptSubmit` hook (and friends) erred out when no role was set. Hook-invoked subcommands (`busy`, `ready`, `check`, `unregister`, `register --role ""`) now silently exit 0 when role is missing; user-invoked subcommands (`read`, `ack`) still fail loudly. (#93, #96)
- **Auto-unregister radio sessions on session/worker end.** Worker session files were orphaning in `~/.task-force/radio/sessions/` after a worker finished. Two new lifecycle beats: a Claude `SessionEnd` hook calls `radio unregister`; `task-done` calls `radio unregister` before tearing down the worktree. (#94, #97)
- **Radio tab/pane actions no longer target the focused tab.** Both `_rename_tab` (idle/busy emoji prefix) and `radio send` (wake-up via `radio check`) used `zellij action` calls without explicit tab targeting, so they clobbered whichever tab the user happened to be focused on — e.g. PM's tab name got rewritten when a worker auto-unregistered, and `radio send --to pm` from worker B mis-delivered the wake-up to worker A. Now both paths drive zellij via stable tab/pane ids captured at `radio register` time (`TAB_ID=` in the session file), with `rename-tab-by-id` and `write-chars --pane-id`. Routing is name-collision-proof and survives user-driven `rename-tab`. (#102, #103)

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

[Unreleased]: https://github.com/martin-conur/task-force/compare/v0.2.2...HEAD
[0.2.2]: https://github.com/martin-conur/task-force/compare/v0.2.1...v0.2.2
[0.2.1]: https://github.com/martin-conur/task-force/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/martin-conur/task-force/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/martin-conur/task-force/compare/v0.0.1...v0.1.0
