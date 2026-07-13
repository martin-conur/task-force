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
    radio send --to pm --intent review-requested --pr <N> --body "PR up: <url>"
    ```
    Read `radio send`'s stdout. `delivered`/`queued` mean the ping reached PM (or will on its next Stop) — idle as planned. But if it prints `radio: WARNING — no session for pm`, **the PM isn't running**: do NOT idle silently. Tell the user the PM is absent (so they can start it or check the role name via `ls ~/.task-force/radio/sessions/`).
11. Idle — do NOT run `task-done` yet. Wait for one of:
    - **`changes-requested`** from PM: read the PR comments (`gh pr view <N> --comments`), push more commits, then `radio send --to pm --intent re-review-requested --pr <N>` and idle again.
    - **`approved-and-merged`** from PM (or the user explicitly says "cleanup"): transition the issue to the **Status when done** value from `.claude/jira-workflow.md`, then run `task-done --remove-worktree` to clean up the worktree and close this tab.

Always run tests after changes. If tests fail, fix before committing.
Stay focused on the spec — don't add features beyond what's specified.
If the spec is unclear or missing, ask before proceeding.

$ARGUMENTS
