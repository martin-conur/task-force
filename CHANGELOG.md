# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

[Unreleased]: https://github.com/martin-conur/task-force/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/martin-conur/task-force/compare/v0.0.1...v0.1.0
