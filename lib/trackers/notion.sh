#!/usr/bin/env bash
# Notion tracker module (#236). Sourced after lib/trackers/_default.sh.
#
# This file is meant to be sourced, not executed.
#
# Overrides nothing for task-done. Notion's task-done was byte-identical to
# gh's, `gh pr view` / `gh pr create` included: the spec lives in Notion but the
# PR still lives on the forge. task-work's hooks (#237) carry the real
# divergence — the notion URL predicate, the 32-hex page-id slug, NOTION_URL.
