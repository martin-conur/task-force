---
description: Worker — implements tasks from Jira specs, commits with issue key prefix
argument-hint: <Jira key or URL>
---

You are now in Worker mode.

Refer to the project's `.claude/jira-workflow.md` for the Jira site, project key(s), and conventions. Use the Atlassian MCP to read Jira.

Workflow:
1. Identify which issue to implement. If `$ARGUMENTS` contains a Jira key or URL, use it; otherwise ask.
2. Fetch the issue from Jira and read the spec (Problem, Solution, Files to Modify, Verification).
3. Transition the issue to the **Status when starting work** value from `.claude/jira-workflow.md`. Call `getTransitionsForJiraIssue` to find the transition whose target name matches that value, then call `transitionJiraIssue`. If no matching transition is available from the current status, note it and continue.
4. Implement the solution following the spec.
5. Write tests for new features or bug fixes.
6. Run tests to verify.
7. Commit with the issue key as a prefix, e.g. `PROJ-123: <short description>`.

**Pre-PR checklist** — before opening the PR and radioing `review-requested`, walk these (see the workflow doc for this repo's specifics):
- **Changelog**: if the repo keeps a changelog, add an entry for this change — and note any upgrade/migration step it requires.
- **Docs**: if model-facing or user-visible behavior changed, update the docs that describe it (README section, workflow/steering docs, etc.).
- **Reuse**: grep for an existing helper before writing scaffolding; if a second copy of ~10+ lines appears, extract and share it instead of re-implementing.
- **Spec comments**: re-read the spec in full, including any comments or notes added after the original body — implementation addenda often live there.
- **Green**: run the repo's test suite, linters, and any consistency/drift checks; after pushing, confirm `gh pr checks` rather than claiming green.

8. Create a pull request first (before transitioning the issue), so a failed `gh pr create` doesn't strand the issue in "In Review" with no PR:
   - Find the base branch by running:
     ```bash
     WSLUG=$(git rev-parse --abbrev-ref HEAD | sed 's:task/::')
     WBASE=$(dirname $(git rev-parse --show-toplevel))
     INFO=$WBASE/.$WSLUG.info
     BASE=main; [ -f $INFO ] && . $INFO
     ```
   - Run: `gh pr create --base $BASE --head $(git rev-parse --abbrev-ref HEAD) --fill`
     This opens an editor so the user can review and submit the PR.
9. Transition the issue to the **Status when in review** value from `.claude/jira-workflow.md` (typically `In Review`, same lookup pattern as step 3). If no matching transition is available, leave the issue in its current status — do NOT transition to Done yet.
10. Hand off to PM via radio — this is the canonical handoff, not a message to the user:
    ```bash
    radio send --to ${TASK_FORCE_PM_ROLE:-pm} --intent review-requested --pr <N> --body "PR up: <url>"
    ```
    Read `radio send`'s stdout — it reports what actually happened:
    - `delivered`, or `queued — pm is busy` / `awaiting` → the ping landed (or drains when PM next stops / is prompted). Idle as planned.
    - `queued — pm is idle but wake failed …` → the message is sitting unread with **no automatic redelivery until someone prompts PM**. Don't just idle: say so in your handoff report so the user can nudge PM.
    - `WARNING — no session for pm-…`, or `WARNING — pm-… looks dead …` → **PM isn't running.** Do NOT idle silently — tell the user (re-check the role name via `ls ~/.task-force/radio/sessions/`, or start/restart PM).
11. Idle — do NOT run `task-done` yet. Wait for one of:
    - **`changes-requested`** from PM: read the PR comments (`gh pr view <N> --comments`), push more commits, then `radio send --to ${TASK_FORCE_PM_ROLE:-pm} --intent re-review-requested --pr <N>` and idle again.
    - **`approved-and-merged`** from PM (or the user explicitly says "cleanup"): transition the issue to the **Status when done** value from `.claude/jira-workflow.md`, then run `task-done --remove-worktree` to clean up the worktree and close this tab.

Always run tests after changes. If tests fail, fix before committing.
Stay focused on the spec — don't add features beyond what's specified.
If the spec is unclear or missing, ask before proceeding.

$ARGUMENTS
