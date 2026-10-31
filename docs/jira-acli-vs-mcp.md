# acli vs the Atlassian Remote MCP for claude-jira (#326)

**Verdict: partially.** `acli` covers every Jira operation the claude-jira commands actually perform (read, search, create, edit, label, transition, comment), with JSON output. Three read helpers on the MCP allow-list have no `acli` equivalent: remote issue links, issue-type field metadata, and account lookup by name. **The #325 watcher should read through `acli`**, not the REST API.

Every row below comes from a live run on 2026-10-31: `acli version 1.3.39-stable`, OAuth login, a Jira Cloud site. Reads ran against an existing project. Writes ran on one throwaway issue in a scratch project, `TMP-1`, deleted afterwards. Where a cell rests on `--help` text rather than a run, it says so.

## 1. Operation matrix

"JSON" means the command takes `--json` and prints parseable JSON. "Rich text" is how the command handles description and comment formatting.

### What the loadout uses today

| MCP tool | `acli` command | JSON | Rich text | Notes |
|---|---|---|---|---|
| `getJiraIssue` | `acli jira workitem view KEY --json [--fields f1,f2]` | yes | ADF, raw | `--json` returns the description as an ADF object. Without `--json` the description is flattened to text: headings, lists and code blocks lose their markup. The default fields are `key,issuetype,summary,status,assignee,description`; `--fields` adds more, `updated`, `labels`, `comment` and `issuelinks` included. Takes **one key**: `view A-1,A-2` fails with "Issue does not exist". |
| `searchJiraIssuesUsingJql` | `acli jira workitem search --jql '…' --fields key,labels,status,summary --paginate --json` | yes (also `--csv`, `--count`) | n/a | **Returns 30 results unless `--paginate` is given**, without saying it truncated: 30 versus 421 on the same JQL. **`--fields` refuses `updated` and `created`** (`✗ Error: field 'updated' is not allowed`), along with `*all` and `-field` forms. JQL can still filter and sort on them. |
| `getVisibleJiraProjects` | `acli jira project list --paginate --json` (or `--recent`) | yes | n/a | Default limit 30, like search. |
| `getJiraIssueRemoteIssueLinks` | **none** | — | — | `acli jira workitem link list --key KEY --json` returns `{"issueLinks": [...]}`, which holds issue-to-issue links only. Remote links (a GitHub PR attached to an issue) have no command and are not a `view` field. No loadout command calls this tool today. |
| `getTransitionsForJiraIssue` | **none**, and not needed | — | — | `transition --status NAME` resolves the transition itself by target status name, case-insensitively (`--status done` reached `Done`). The worker's two steps, find the transition and then apply it, become one. |
| `getJiraProjectIssueTypesMetadata` | partial: `acli jira project view --key KEY --json`, then `.issueTypes[]` | yes | n/a | Gives issue type names, ids and hierarchy level. Field metadata (required fields, allowed values) is missing. |
| `getIssueLinkTypes` | `acli jira workitem link type --json` | yes | n/a | Returns `{"issueLinkTypes": [{"name": "Blocks"}, ...]}`, names only, with no inward or outward phrasing. |
| `lookupJiraAccountId` | **none** | — | — | There is no user search. `assign`, `create` and `edit` take `--assignee <email\|accountId\|@me>` directly, so an account id is only needed when the agent knows a display name and nothing else. Verified with `@me`; the email form comes from `--help`. |
| `atlassianUserInfo` | `acli jira auth status` | **no** (text only) | n/a | Prints site, email and auth type. The account id, cloud id and site are also in `~/.config/acli/jira_config.yaml`. |
| `createJiraIssue` | `acli jira workitem create --project KEY --type Task --summary '…' --description-file FILE [--label a,b] [--assignee …] [--parent KEY] --json` | yes (full issue object) | plain text or ADF JSON | **Markdown is not converted.** A markdown file is stored verbatim as one plain paragraph, with `##`, backticks and `-` visible. An ADF JSON file keeps its structure: heading, code mark, bullet list and code block all survived. `--description-file /dev/stdin` works, so the quote-delimited heredoc rule carries over. |
| `editJiraIssue` | `acli jira workitem edit --key KEY [--summary …] [--description-file FILE] [--labels …] [--remove-labels …] [--type …] --yes --json` | yes (`results[]`, `successCount`) | plain text or ADF JSON, as for create | `--yes` is required in a script, or edit prompts. Also takes `--jql` or `--filter` for bulk edits. |
| `transitionJiraIssue` | `acli jira workitem transition --key KEY --status 'In Progress' --yes --json` | yes (`results[]`, `successCount`) | n/a | An unreachable status gives `"status": "FAILURE", "message": "No allowed transitions found for given status"` and **exit 0**. |
| `addCommentToJiraIssue` | `acli jira workitem comment create --key KEY --body-file FILE --json` | yes (`results[]`) | plain text or ADF JSON | Same rule as descriptions: markdown is stored literally, ADF keeps its marks (`code` survived). `--body-file /dev/stdin` works. Reading back, `comment list --json` **flattens bodies to plain text**. `view KEY --fields comment --json` returns the raw ADF. |

### What #325 adds

| Operation | `acli` command | JSON | Notes |
|---|---|---|---|
| Add a label | `acli jira workitem edit --key KEY --labels NAME --yes --json` | yes | **Appends.** Existing labels are kept. |
| Remove a label | `acli jira workitem edit --key KEY --remove-labels NAME --yes --json` | yes | Removing a label that is not on the issue succeeds and changes nothing. |
| Swap labels in one call | `acli jira workitem edit --key KEY --labels NEW --remove-labels OLD --yes --json` | yes | Verified: `[spike, a]` became `[spike, b]`. |
| Watcher poll: key, labels, status, summary, updated | `acli jira workitem search --jql 'project = KEY AND updated >= "yyyy/MM/dd HH:mm" ORDER BY updated DESC' --fields key,labels,status,summary --paginate --json` | yes | **`updated` cannot be returned**, only filtered on (see §3). Each element is `{key, fields: {labels: [...], status: {name}, summary}}`. An empty result is `[]`, exit 0. |

### Exit codes: check `successCount`, not `$?`

This is the trap for scripts and agents alike.

| Case | Exit | What to check |
|---|---|---|
| `view` of a missing issue | 1 | — |
| `search` with invalid JQL | 1 | — |
| `search` / `view` / `auth status` with no login | 1 | — |
| `transition` to an unreachable status | **0** | `.successCount == 0` |
| `edit` of a missing issue | **0** | `.successCount == 0`, with message "Issue does not exist or you do not have permission to see it." |
| `comment create` on a missing issue | **0** | the `--json` results |
| `edit` with no login | **0** | `.results[0].status == "FAILURE"` |

Every write (`edit`, `transition`, `comment create`, `assign`, `delete`) has to run with `--json`, and its `successCount` has to be checked against the number of keys passed.

## 2. Verdict

**Partially.** An agent on claude-jira can do its whole loop through `acli`: read the spec, search, create, edit, label, transition, comment. The MCP stays the only route for:

- **remote issue links**: no `acli` command. Unused by the loadout's commands today.
- **issue-type field metadata** (required fields, allowed values) for a `create` that needs custom fields. `project view` gives the type names only.
- **account lookup by display name**: `acli` takes an email or `@me` and cannot search.

Two differences matter if the loadout migrates:

1. **Rich text.** `acli` stores markdown as literal text, so an agent writing specs through it has to write ADF JSON to a file, or accept unformatted text. That costs more than the MCP's formatted writes. It is the main argument for keeping writes on the MCP.
2. **Silent write failures.** A failed `acli` write exits 0, as shown above. Every write in a prompt needs `--json` plus a `successCount` check.

So the follow-up, if the PM files one, is a hybrid: reads and simple writes (labels, transitions, plain comments) move to `acli`, which does not drop mid-session; spec-authoring writes and the three helpers above stay on the MCP.

## 3. Watcher read path: `acli`

The watcher is shell, so the MCP is out. `acli` is the better of the two remaining options:

- It is already logged in, through OAuth that refreshes itself, so the watcher holds no secret of its own.
- **Reads fail loudly**: no login gives exit 1 and `✗ Error: unauthorized`. The REST API fails **silently** on exactly the call the watcher makes, as shown below.

### Poll

```bash
acli jira workitem search \
  --jql 'project = KEY AND labels in ("tf-ready") AND updated >= "2026/10/31 15:00" ORDER BY updated DESC' \
  --fields key,labels,status,summary --paginate --json
# exit != 0 => auth or JQL failure, not "no changes"
# []        => genuinely nothing matched
```

The JQL timestamp `"yyyy/MM/dd HH:mm"` is verified. It has minute resolution and is read in the Jira user's timezone. Because `search` cannot return `updated`, **the watcher keeps its own watermark**: the start time of the previous poll, minus a minute of overlap, with processed `key`+`labels` state used to dedupe the overlap. If the watcher does need an issue's own `updated` value, it costs one call per key:

```bash
acli jira workitem view KEY --fields updated,labels,status --json | jq -r .fields.updated
```

### Label swap

```bash
acli jira workitem edit --key KEY --labels tf-claimed --remove-labels tf-ready --yes --json \
  | jq -e '.successCount == 1' >/dev/null || echo "label swap failed on KEY" >&2
```

### Where the credentials live

- `~/.config/acli/jira_config.yaml` (mode `0600`) holds the profile: site, cloud id, account id, display name, email, auth type. It holds **no token**. The OAuth token is kept elsewhere, presumably in the OS credential store; this spike did not inspect that.
- `acli jira auth login --web` (interactive OAuth) or `acli jira auth login --site S --email E --token < file` (API token) sets it up. `acli jira auth status` checks it.

### The REST alternative, and why not

Basic auth with `email:api-token`:

```bash
# poll: one call that does return updated
curl -sS -u "$JIRA_EMAIL:$JIRA_API_TOKEN" -G "https://$SITE/rest/api/3/search/jql" \
  --data-urlencode 'jql=project = KEY AND updated >= "2026/10/31 15:00"' \
  --data-urlencode 'fields=key,labels,status,summary,updated'
# label swap
curl -sS -u "$JIRA_EMAIL:$JIRA_API_TOKEN" -X PUT -H 'Content-Type: application/json' \
  "https://$SITE/rest/api/3/issue/KEY" \
  -d '{"update":{"labels":[{"add":"tf-claimed"},{"remove":"tf-ready"}]}}'
```

Run without valid credentials on the live site, because no API token was available to this spike:

| Call | No credentials | Wrong token |
|---|---|---|
| `GET /rest/api/3/search/jql` | **200 `{"issues":[],"isLast":true}`** | **200 `{"issues":[],"isLast":true}`**, header `X-Seraph-LoginReason: AUTHENTICATED_FAILED` |
| `GET /rest/api/3/myself` | 401 | 401 |
| `GET` / `PUT /rest/api/3/issue/KEY` | 404 "Issue does not exist…" | — |

A lapsed or mistyped token makes the poll look like "nothing changed" for as long as nobody notices. A REST watcher would have to check `X-Seraph-LoginReason`, or call `/myself`, on every poll. The authenticated success path was not run: it needs a token, which only the user can create. REST's one real advantage, `updated` in the same call, is not worth a credential the watcher has to own and a failure mode it has to detect itself.

## 4. Auth persistence

| | How long it lasts | What lapsing looks like |
|---|---|---|
| `acli` OAuth (`auth login --web`) | `acli` refreshes the token itself. Atlassian documents OAuth 2.0 refresh tokens as rotating and expiring after 90 days without use. Not verified here: the login under test was hours old. | Simulated by running with an empty `HOME` (no profile, which is not the same as an expired token). Reads print `✗ Error: unauthorized: use 'acli [product] auth login' to authenticate` and **exit 1**. Writes print the same message as a `FAILURE` result and **exit 0**. Fix: `acli jira auth login --web`, interactive. |
| Jira API token (basic auth) | Per Atlassian, tokens created since December 2024 expire after 1 to 365 days, chosen at creation; the default is one year. Not verified here: no token was available. | `/myself` gives 401. **Search gives 200 with zero issues** plus `X-Seraph-LoginReason: AUTHENTICATED_FAILED`. Issue reads and writes give 404, not 401. |

For the watcher: on any non-zero `acli` exit, stop polling and tell the PM (or the user) that a re-login is needed, rather than retrying in a loop.
