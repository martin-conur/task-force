# Claude Code through an Anthropic-compatible gateway in task-force (#354)

**Verdict: it works, with three things a profile must get right.** A task-force worker and reviewer both ran their full flow on an open model through Fireworks: radio registered and woke them, auto mode ran, tool search, MCP and skills worked, and the gateway reported prompt-cache reads. What a profile must get right:

1. **Send the key as `x-api-key`, never as `ANTHROPIC_AUTH_TOKEN` alone.** With `ANTHROPIC_AUTH_TOKEN`, Claude Code also sent the machine's saved Anthropic Console key as `x-api-key`. Fireworks read that header, so every request failed with 401, and the user's Anthropic key went to a third party.
2. **Pin `ANTHROPIC_DEFAULT_SONNET_MODEL`.** That pin is what moves the auto-mode classifier. Unpinned, the classifier asks the gateway for `claude-sonnet-5`. `CLAUDE_CODE_AUTO_MODE_MODEL` on its own does not move it.
3. **Deliver the variables some way other than a prefix on `task-work`.** The tab `task-work` opens starts from the zellij server's environment, so a prefix on the command line never reaches the agent.

Every row below comes from live runs on 2026-11-05: Claude Code 2.1.311, Fireworks (`https://api.fireworks.ai/inference`), model id `glm-latest`, which Fireworks resolved to `accounts/fireworks/models/glm-5p3`. The scratch repo was a private `tf-spike-354` with a `claude-local` install and a two-function Python codebase. Where a cell rests on documentation rather than a run, it says so.

## Method

All traffic went through a local logging reverse proxy (`ANTHROPIC_BASE_URL=http://127.0.0.1:<port>`) that forwarded each request unchanged to `https://api.fireworks.ai/inference`. For each request it logged the requested model, the model the gateway served, the auth header *names* (never values), the status, the tool count and the usage block. That log is the evidence for every claim about which model was asked for. A request a profile failed to pin shows up there under its `claude-*` id.

The worker and reviewer read the profile from the scratch repo's committed `.claude/settings.json`. That file had an `env` block and an `apiKeyHelper` that reads the key from the macOS Keychain, so no key was written to any file. Why it could not come from a prefix is in section 7.

- **Worker:** `task-work tasks/001-add-subtract.md --auto`. The ticket: add `subtract()` with a test, call a project MCP tool, invoke a project skill, and put both results in the PR body.
- **Reviewer:** `ANTHROPIC_MODEL=glm-latest task-reviewer <pr-url> tasks/001-add-subtract.md` on the PR that worker opened.
- **Headless probes** (`claude -p`) for the header and pinning experiments, run with the parent session's `CLAUDE*` variables unset.

## 1. Radio

**Works unchanged.** The hooks fire because they live in `.claude/settings.json`, which is independent of the model.

| Check | Result |
|---|---|
| `SessionStart` register | Worker: `tab_id_src=zellij pane_id=51 pane_id_src=env`, `AUTO_SUBMIT=1`. Reviewer: the same, `pane_id=52`. |
| Wake | Twice to the worker: `send: woke … (src=recorded)`, then `prompt-hook: surfaced 1 unread message(s)`, then `read+ack`. Both times the worker acted on the message. |
| Agent → PM | Worker `review-requested` and reviewer `review-complete-with-findings` both sent. The scratch repo had no PM, so both queued with `no session for pm-tf-spike-354`. The reviewer then kept its tab open, as designed. |
| `Stop` hook | Marked the role `idle` at each turn end. |

## 2. Permission modes and which tiers pin

**Auto mode works.** The classifier ran (14 calls in the worker, 15 in the reviewer, all `glm-latest`). It approved a `rm` inside a compound command and sent no refusals.

Claude Code prints this in the TUI on the first auto-mode start through a gateway, and waits for a key:

> We're changing auto mode to no longer charge for classifier requests in Claude Code. However, this session isn't eligible because your requests go through 127.0.0.1:18354 … y to continue · n to cancel

The prompt **blocks a hands-off worker** until someone presses `y`. It appeared for the first worker and not for the reviewer launched minutes later, so it looks like a once-per-machine notice. In `-p` it is printed to stderr and does not block.

Which model each background caller asks for:

| Caller | Unpinned | Pinned by |
|---|---|---|
| Main loop | `ANTHROPIC_MODEL` | `ANTHROPIC_MODEL` |
| Auto-mode classifier | **`claude-sonnet-5`**. FireRouter served it with `glm-5p3` (`x-firerouter-trace-id`, a `cost` field in usage) without saying so. A direct `curl` naming `claude-sonnet-5` was refused instead (`FireRouter needs an Anthropic credential …`). | **`ANTHROPIC_DEFAULT_SONNET_MODEL`**. `CLAUDE_CODE_AUTO_MODE_MODEL=glm-latest` without the Sonnet pin still sent `claude-sonnet-5` (3 classifier calls). |
| Subagent, no model given | inherits the main model (`glm-latest`) | `CLAUDE_CODE_SUBAGENT_MODEL` (belt and braces) |
| Explore subagent, and an `Agent` call with `model: haiku` | not run unpinned | `ANTHROPIC_DEFAULT_HAIKU_MODEL` |
| `opus` alias, `opusplan` | not exercised | `ANTHROPIC_DEFAULT_OPUS_MODEL` (documented, not run) |

With the full set pinned (section 7), no request in either run asked for a `claude-*` id, and every request went to the gateway. That covers the main loop, the classifier, the Explore subagent and an explicit `haiku` subagent. Claude Code's own `modelUsage` in `-p --output-format json` **does not list classifier calls at all**, so it cannot show a leak. Use the gateway's logs or a proxy.

Fireworks refuses a bare Claude id with a 400 unless an Anthropic credential is attached on the Fireworks side. A forgotten pin therefore fails loudly on this gateway, *except* on the path the classifier took, where FireRouter substituted a model without saying so. Don't rely on either behaviour: pin.

`task-reviewer` puts `ANTHROPIC_MODEL=claude-sonnet-5-5` in its tab prefix unless `ANTHROPIC_MODEL` is already set. A repo's `.claude/settings.json` `env` block overrides it (tested: process env `claude-sonnet-5-5`, settings env `glm-latest`, request sent for `glm-latest`). A prefix-only profile must pre-set `ANTHROPIC_MODEL`, as this run did.

## 3. Tools: tool search, MCP, skills

| Feature | Result |
|---|---|
| Tool search (`ENABLE_TOOL_SEARCH=true`) | On. Every request carried `ToolSearch` and a deferred-tool placeholder, subagent requests included (6 to 14 tools in each request instead of the full list). |
| MCP | A project `.mcp.json` stdio server with one tool. The worker found it with `ToolSearch` (`select:mcp__spike__spike_multiply`) and called it: `{"a": 6, "b": 7}` → `{"result":42}`. |
| Skills | A project skill under `.claude/skills/` was invoked through `Skill` and its instructions followed. The `/worker` and `/reviewer` command prompts were followed too (section 5). |
| Subagents | `Agent` with general-purpose and Explore both ran and returned results. |

## 4. Prompt caching and cost

**Fireworks reports cache reads.** It never reports `cache_creation_input_tokens`: caching is automatic prefix caching, and the `cache_control` markers Claude Code sends do not change what is reported.

| Run | Requests | Uncached input | Cache read | Output | Cache hit | Cost | Without cache |
|---|---|---|---|---|---|---|---|
| Worker (ticket, PR, two radio rounds) | 36 | 97,203 | 1,397,930 | 5,082 | 93.5% | **$0.52** | $2.12 |
| Reviewer (spec check, review, comment, radio) | 36 | 143,792 | 1,362,101 | 10,507 | 90.5% | **$0.60** | $2.15 |

Costs use the per-token rates FireRouter reported in its own `cost_details` for `glm-5p3`: $1.40/M uncached input, $0.26/M cache read, $4.40/M output. Plain `glm-latest` responses carry no cost field, so treat these as estimates and check the Fireworks billing page for the real figure. **Don't trust Claude Code's own cost display here.** It prices an unrecognized model with a guessed rate (`"costBasis":"unknown"`), and it showed $0.41 two minutes into the worker run.

Claude Code also warns `Model "glm-latest" isn't recognized · context assumed to be 200k tokens`. `CLAUDE_CODE_MAX_CONTEXT_TOKENS=<window>` sets the real window (documented, not run). Set it once the model's window is known, so auto-compaction triggers at the right point.

## 5. Quality

**Worker: finished the ticket.** It added `subtract()` and `test_subtract`, and ran `uv run --with pytest pytest -q` (2 passed). It used the `<title>: <desc>` commit prefix, bumped the task's frontmatter status, and pushed. It opened a PR whose body starts with `## Summary`, then `Closes …`, then both spike results. Checking CI, it correctly reported "no run exists" for a repo with no workflows instead of claiming green. Two defects:

- **Its first turn ended at the skill output.** The test skill said "reply with exactly the canary string and nothing else", and the model did exactly that and ended its turn. That comes from how the test was written, not from the model. A radio wake got it going again.
- **One radio body was lost.** It ran `radio send … --body - <<'BODY'`, and radio stored the body as a literal `-`. After being told "body on stdin, not via `--body`", its next send was correct. The worker prompt already says stdin. GLM read it as `--body -`.

The PR title came out as `task/add subtract`. `gh pr create --fill` takes the branch name when there are several commits, so that is not model-specific.

**Reviewer: a sensible verdict with the `reviewed <sha>` line (#348).** The comment's verdict line read `**Verdict:** changes-requested — reviewed e3643c6a3dad907c073cfb4ec577796f306260f7`, and the radio body's first line was `reviewed e3643c6…`. It re-ran the tests and checked each spec item. It noted that no CI run existed, checked the commit messages for skip markers, and said that "green" could not be claimed. It raised two valid in-scope nits: the test does not catch an operand-order bug, and `.gitignore` lacks `__pycache__`. It also found a **real task-force bug**: `bin/task-board` files a task whose status is `in-review` under **Todo**, because its case only handles `in-progress` and `done`, while `claude-local/commands/worker.md` sets `in-review`. It flagged that as out of scope for a separate ticket, which matches the tight-PR norm.

## 6. Header style

**Fireworks takes either header on its own.** `x-api-key: <key>` and `Authorization: Bearer <key>` both returned 200 on a direct `curl`.

**Through Claude Code, only `x-api-key` works on this machine:**

| Credential | Headers Claude Code sent | Result |
|---|---|---|
| `ANTHROPIC_API_KEY=<fw key>` | `x-api-key` (the Fireworks key) | 200 |
| `ANTHROPIC_AUTH_TOKEN=<fw key>` | `Authorization: Bearer <fw key>` **and** `x-api-key: sk-ant-api0…` (108 chars, the saved Console key) | 401 `The API key you provided is invalid.` Claude Code kept retrying with backoff: 9 attempts in two minutes before I stopped it. |
| `ANTHROPIC_AUTH_TOKEN` plus `ANTHROPIC_API_KEY=""` | the same two headers | 401 |
| `apiKeyHelper` printing the fw key | `Authorization: Bearer <fw key>` and `x-api-key: <fw key>` (same value) | 200; the TUI warns `apiKeyHelper overriding saved Console key` |

The `ANTHROPIC_AUTH_TOKEN` row matters beyond the 401: **it sends an Anthropic API key to a third-party gateway.** The gateway docs say a saved claude.ai *login* is not sent while a gateway credential is active. A saved *Console API key* was sent. A machine with no saved key would not see this, but a profile cannot know which kind of machine it is on.

In interactive mode, `ANTHROPIC_API_KEY` asks once for approval before it overrides a subscription (documented, not run), which would block a hands-off tab the first time. `apiKeyHelper` showed no such prompt.

## 7. Verdict: what a profile must carry

```bash
ANTHROPIC_BASE_URL=https://api.fireworks.ai/inference
ANTHROPIC_API_KEY=<gateway key>              # x-api-key. Or apiKeyHelper. Never ANTHROPIC_AUTH_TOKEN alone (section 6).
ANTHROPIC_MODEL=glm-latest
ANTHROPIC_DEFAULT_SONNET_MODEL=glm-latest    # moves the auto-mode classifier
ANTHROPIC_DEFAULT_HAIKU_MODEL=glm-latest     # background calls, Explore, model: haiku subagents
ANTHROPIC_DEFAULT_OPUS_MODEL=glm-latest      # opus alias, opusplan
CLAUDE_CODE_SUBAGENT_MODEL=glm-latest        # subagents with no model of their own
ENABLE_TOOL_SEARCH=true
# recommended once the model's window is known:
CLAUDE_CODE_MAX_CONTEXT_TOKENS=<window>
```

`CLAUDE_CODE_AUTO_MODE_MODEL` is not part of the set: on its own it did not move the classifier, and with the Sonnet pin it adds nothing.

**Delivery is the launcher's job.** Neither run could take the profile as an env prefix:

- **`task-work` drops a prefix.** `VAR=x task-work …` reaches `task-work`, not the agent: the tab is a new `bash -ic` started from the zellij server's environment (`lib/zellij-tab.sh` `new-tab`). A probe tab opened with `SPIKE_PROBE_VAR=reached` in front saw `<unset>`. Only `TASK_FORCE_HOME` is forwarded today (#262). `task-reviewer` forwards `ANTHROPIC_MODEL` and nothing else.
- **The settings `env` block works,** and it overrides the process env. But a committed `.claude/settings.json` applies the profile to every session in the repo, and `settings.local.json` is not copied into worktrees outside `--local-only` installs. A profile mechanism should splice its variables into the tab's prefix the way `RADIO_ENV_PREFIX` carries the role, and read the key in the tab (Keychain, or the user's rc) rather than putting it on a command line.

**What does not work, or needs a human:**

- **The auto-mode billing notice** (section 2) blocks the first gateway session on a machine in auto mode until someone presses `y`.
- **The workspace trust prompt** blocks the first session in a new folder. That is not gateway-specific, but a profile spike on a scratch repo hits it.
- **`modelUsage` and Claude Code's cost display** are blind to classifier calls and misprice unknown models. Verify routing and cost on the gateway side.
- **Context window:** assumed to be 200k until `CLAUDE_CODE_MAX_CONTEXT_TOKENS` is set.
- **Claude Code pings `GET <base>/api/hello` at startup.** Fireworks returns 404, which does no harm.
