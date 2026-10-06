#!/usr/bin/env bash
# Notion tracker module (#236). Sourced after lib/trackers/_default.sh.
#
# This file is meant to be sourced, not executed.
#
# Overrides nothing for task-done. Notion's task-done was byte-identical to
# gh's, `gh pr view` / `gh pr create` included: the spec lives in Notion but the
# PR still lives on the forge. task-work's hooks (#237) carry the real
# divergence — the notion URL predicate, the 32-hex page-id slug, NOTION_URL.

# Anchored to the URL host so a free-form slug that merely contains the text
# (e.g. "my-notion.com-feature") is not misclassified as a URL. Allows any
# subdomain (www., app., or a published-site workspace) so the original
# *.notion.site behavior is preserved. (#158)
aw_tracker_is_ref() {
  [[ "$1" =~ ^https?://([a-zA-Z0-9-]+\.)*notion\.(so|site|com)/ ]]
}

# A bare 32-hex page id becomes its first 8 chars; a `Title-<32hex>` segment
# becomes the title with the id stripped.
aw_tracker_ref_slug() {
  local url="$1" last_seg
  last_seg=$(echo "$url" | sed 's|.*/||' | sed 's|?.*||')
  if [[ "$last_seg" =~ ^[a-f0-9]{32}$ ]]; then
    echo "${last_seg:0:8}"
  else
    echo "$last_seg" | sed 's/-[a-f0-9]\{32\}$//' | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]//g'
  fi
}

aw_tracker_info_key() { echo NOTION_URL; }

aw_tracker_usage_synopsis() {
  echo "  task-work <slug> <notion-url> [options]    # explicit slug + URL (preferred when an agent kicks it off)"
  echo "  task-work <notion-url> [options]           # slug derived from the URL's title segment"
  echo "  task-work <free-form-slug> [options]       # ad-hoc, no Notion URL"
}

aw_tracker_usage_examples() {
  echo '  task-work add-store-filtering "https://www.notion.so/abc123def456abc123def456abc123de"'
  echo "  task-work https://www.notion.so/My-Task-abc123def456abc123def456abc123de"
  echo "  task-work refactor-auth"
  echo "  task-work spike-idea --no-launch"
  echo "  # Stack a follow-up on top of an in-flight branch:"
  echo "  task-work followup <notion-url> --from task/refactor-auth --base main"
}

# ---------------- task-reviewer hooks ----------------
#
# Only the noun differs from the default: the spec still passes to /reviewer
# verbatim, with no PR-body convention to fall back on (#144, #239).
aw_tracker_review_spec_shape() { echo "a Notion page URL"; }
