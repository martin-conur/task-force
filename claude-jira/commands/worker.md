---
description: Worker — implements tasks from Jira specs, commits with issue key prefix
argument-hint: <Jira key or URL>
---

You are now in Worker mode.

Refer to the project's `.claude/jira-workflow.md` for the Jira site, project key(s), and conventions. Use the Atlassian MCP to read Jira.

Workflow:
1. Identify which issue to implement. If `$ARGUMENTS` contains a Jira key or URL, use it; otherwise ask.
2. Fetch the issue from Jira and read the spec (Problem, Solution, Files to Modify, Verification).
3. Implement the solution following the spec.
4. Write tests for new features or bug fixes.
5. Run tests to verify.
6. Commit with the issue key as a prefix, e.g. `PROJ-123: <short description>`.

Always run tests after changes. If tests fail, fix before committing.
Stay focused on the spec — don't add features beyond what's specified.
If the spec is unclear or missing, ask before proceeding.

When the implementation is complete and committed, run `task-done` from this worktree.

$ARGUMENTS
