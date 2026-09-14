# Captured `SessionEnd` hook payloads

Corpus of real Claude Code `SessionEnd` hook invocations, captured from a
production `~/.task-force/radio/log` spanning 2026-05-24 → 2026-09-14 (10,008
lines, 3,207 `unregister` wipes). Tests feed these to `radio unregister` on
stdin so the payload filter is exercised against shapes Claude Code actually
emits, rather than against hand-built JSON.

Why this corpus exists: #187 and #182 both shipped guards that were verified
only against synthetic inputs and were then dead or wrong in production —
#187's wipe filter never saw the empty payload that is 98.7% of real
invocations, and #182's repo filter routes on a `repo:` field that 0 of 399
real messages carry. Assert against captures, not against what the payload
*should* look like.

## Provenance

The log records the full payload only on the `unregister: proceeding` path, so
only real-exit reasons were recoverable verbatim. Every file below preserves
the exact field set and field order of what was captured; **values** are
redacted — session/prompt UUIDs replaced with `00000000-…` placeholders and
absolute paths with `/example/repo` — because the originals carry the
developer's local filesystem layout.

| File | Provenance | Reason | Observed |
|---|---|---|---|
| `sessionend-empty.stdin` | Zero-byte stdin. Not logged pre-#187 (that was the bug) — the shape is "hook fired, stdin non-tty, no payload". | *(none)* | 3,165 of 3,207 wipes (98.7%) |
| `sessionend-other.json` | Verbatim shape, redacted values. 5-key variant (no `prompt_id`). | `other` | 23 |
| `sessionend-prompt-input-exit.json` | Verbatim shape, redacted values. 6-key variant (with `prompt_id`). | `prompt_input_exit` | 19 |
| `sessionend-clear.json` | **Reconstructed**, not captured — the skip path logs no payload. Built from `sessionend-other.json` with `reason` swapped. | `clear` | 15 skips logged (payload unavailable) |
| `cascade-y.stdin` | The literal single `y` byte from #151's PR-#150 diagnostic: 144 invocations in ~25s, all identical. | *(unparseable)* | see #151 |

No `logout` payload appears in the corpus: the window contains none.

## Adding to it

Capture from a live session rather than writing JSON by hand:

```bash
grep 'unregister: proceeding' ~/.task-force/radio/log | sed 's/.*payload=//' | jq -c 'keys' | sort | uniq -c
```

Redact `session_id`, `prompt_id`, `transcript_path`, and `cwd`; leave the field
set and order untouched, and record the observed count in the table above.
