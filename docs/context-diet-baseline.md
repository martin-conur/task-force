# Context diet: baseline (#396)

This is the before picture for the context-diet epic (#395). The epic wants the
always-loaded workflow doc down from about 75 KB to under 10 KB per loadout.
Every later item in it is measured against the numbers here. Nothing in the
templates changed to produce them.

Reproduce the tables with:

```bash
tools/context-diet-baseline.sh --prs 372,373,376,379,380,382,383,386,387,390
```

The epic's verify step runs the same script with no `--prs`, which takes the
last 10 merged PRs, and compares the two. Run it from the main checkout or any
of its worktrees: it finds the transcripts by the paths `task-work` launched
agents in, so a clone somewhere else has to pass
`--main-root <the checkout task-work ran in>`. It needs `gh`, `jq` and `git`,
and it only reads.

## Window

The last 10 PRs merged before this item: #372, #373, #376, #379, #380, #382,
#383, #386, #387 and #390. They closed issues #371, #370, #375, #322, #378,
#381, #232 and #377, #384, #385 and #388. The first was opened on 2026-11-06
and the last merged on 2026-11-08. Every one was a claude worker with a claude
reviewer, so every transcript the method needs was on disk.

When this was measured, `.claude/gh-workflow.md` was 67,799 bytes at the
window's start (`df94f08`) and 77,456 at its end (`fbacac7`). Every claude
session in this repo loads it through the `CLAUDE.md` import.

## Tokens per issue and review beats

| Issue | PR | Merged | Worker | Reviewer | Planner | Total | Worker start | Reviewer start | Review req / re-req | Verdicts | Incidents |
|---|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| #388 | #390 | 2026-11-08 | 18.4M | 1.2M | – | 19.6M | 72.8K | 75.0K | 1 / 0 | 1 | 0 |
| #385 | #387 | 2026-11-08 | 14.6M | 1.2M | – | 15.8M | 71.5K | 70.7K | 1 / 0 | 1 | 0 |
| #384 | #386 | 2026-11-08 | 15.2M | 966.1K | – | 16.2M | 71.1K | 66.1K | 1 / 0 | 1 | 0 |
| #232, #377 | #383 | 2026-11-08 | 13.6M | 857.4K | – | 14.4M | 64.2K | 72.7K | 1 / 1 | 1 | 0 |
| #381 | #382 | 2026-11-07 | 4.2M | 812.6K | – | 5.0M | 63.9K | 72.4K | 2 / 1 | 1 | 0 |
| #378 | #380 | 2026-11-07 | 8.4M | 884.1K | – | 9.3M | 63.4K | 71.6K | 1 / 1 | 1 | 0 |
| #322 | #379 | 2026-11-07 | 26.3M | 1.0M | – | 27.3M | 70.6K | 65.2K | 1 / 0 | 1 | 0 |
| #375 | #376 | 2026-11-07 | 7.3M | 787.4K | – | 8.1M | 63.4K | 64.7K | 1 / 1 | 1 | 0 |
| #370 | #373 | 2026-11-07 | 31.7M | 676.1K | – | 32.3M | 69.5K | 64.3K | 1 / 1 | 1 | 0 |
| #371 | #372 | 2026-11-06 | 14.7M | 791.3K | – | 15.5M | 69.4K | 64.0K | 1 / 1 | 1 | 0 |

Mean tokens per issue: **16.3M** over the 10 PRs.

The token columns sum every API call in the role's transcripts, subagents
included: input + cache creation + cache read + output. Almost all of it is
cache reads. Each call re-reads the whole context, so a turn costs roughly what
the context holds at that moment, and the starting context is paid again on
every turn of the session. That is the reason the epic goes after the starting
context first.

*Review req / re-req* counts the worker's `review-requested` and
`re-review-requested` beats to the PM. *Verdicts* counts the reviewer comments on the PR that carry a
`reviewed <sha>` verdict line. Every PR got exactly one review, and every
reviewer radioed back `review-complete-clean` except #372's, which came back
with findings.

A beat is not always a round of changes. The script counts the beats, and
reading the message bodies sorts them:

- **Findings fixed (4):** #372 and #376 fixed nits. #380 fixed a README nit and
  rebased. #383 reworked how it decided liveness. Only #372's review came back
  with findings; for the other three the PM forwarded the nits of a clean
  verdict as `changes-requested`, per the tight-PR norm.
- **Rebase only (1):** #373 rebased onto #372 and rewrapped one comment.
- **Merge incident (1):** #382's second `review-requested` reported that the
  PR was closed, not merged, after the PM had sent `approved-and-merged`. Its
  re-request then merged main back in. This is a PM-side merge failure, not a
  review round, and the radio-incident count below does not see it.

So 4 of the 10 PRs went through a round of changes from review, and 6 did not.

## Starting context per role

| Role | Sessions | Median | Min | Max |
|---|---:|---:|---:|---:|
| pm | 1 | 71.3K | 71.3K | 71.3K |
| planner | 0 | – | – | – |
| worker | 10 | 69.5K | 63.4K | 72.8K |
| reviewer | 10 | 68.4K | 64.0K | 75.0K |

This is the context of the first API call each session made: input + cache
creation + cache read, read from the first main-chain assistant message's
`usage` in `~/.claude/projects/<project>/*.jsonl`. It is the same number
`/context` reports at the first turn, but `/context` needs an interactive
session, and the transcripts already hold the number for every past session.
It covers the system prompt, the tools, `CLAUDE.md` with the imported workflow
doc, and the role's command prompt with its arguments.

The PM row is the one PM session that ran this window, started 2026-11-06. It
used 26.8M tokens over its whole life, which ran past the window into
2026-11-13. The per-issue table does not include them: the PM's turns serve
every issue at once, and nothing in its transcript says which issue a turn was
for. A PM started on 2026-11-16, after the doc had grown
to 77 KB, opened at 79.1K.

No planner ran in the window: no session in any of this machine's transcripts
was started with `/planner`. So the planner row is empty. The planner's prompt
(`planner.md`, 2,445 bytes) is about 3.9 KB shorter than the worker's
(`worker.md`, 6,341 bytes), so a planner would open
at roughly the worker's figure less 1K tokens, about 68K. That is an estimate,
not a measurement. The script measures a planner once one runs: a session
started with `/planner` in a worker's worktree (`task-work --plan`) is counted
as the planner's.

The roughly 10K spread between the lowest and highest worker and reviewer
starts is not explained here. The doc grew during the window, but the starts
do not rise in step with it (#379's worker opened at 70.6K on 2026-11-07, and
#383's at 64.2K a day later). Every one of those starts is still above 63K,
which is the figure the epic has to bring down.

## Radio incidents

None that the method can see. No `radio send` in the window's worker and
reviewer transcripts got back a `WARNING` (no session, looks dead) or a
`queued — … wake failed` line.

The radio log cannot see this window. gc rotates it at about 1 MB and keeps the
tail, and the current log starts on 2026-11-09, the day after the last merge.
So the log could not be checked for the PM's own sends (`changes-requested`,
`approved-and-merged`) in the window. The PM transcript was not scanned for
them either.

## What the method could not see

- **The PM's sends and the radio log for the window.** The log was rotated past
  it, as above.
- **Tokens the PM spent per issue.** Covered above: 26.8M across the session,
  not split by issue.
- **What a beat was for.** The script counts beats. Whether one was a review
  round, a rebase or an incident takes reading its body, as above.
- **kiro sessions.** kiro-cli does not write Claude Code transcripts, so a kiro
  worker or reviewer would show as `–`. None ran in this window. A later window
  with one has to be read from kiro's own logs.
- **The planner,** which did not run; its starting context above is estimated.
- **Durability.** `radio gc` expires the PM mailbox's `processed/` messages
  after 14 days, so the review-beat column reads 0 / 0 for this window from
  about 2026-11-22 on. The Verdicts column, which comes from the PR comments,
  stays. Claude Code removes transcripts after its `cleanupPeriodDays` (30 by
  default), and after that the token columns go to `–` as well. The tables
  above are the durable record. To reproduce them, the script has to run while
  the state is still on disk.
- **Exact `/context` breakdown.** The usage numbers give the total only, not
  how much of it is the workflow doc. The doc's byte size is the stand-in.
