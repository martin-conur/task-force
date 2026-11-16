#!/usr/bin/env bash
# The on-demand skills task-init installs beside the workflow doc (#398).
#
# This file is meant to be sourced, not executed.
#
# A skill holds content the workflow doc points at but no role needs every
# turn: radio-troubleshooting is the "When radio misbehaves" runbook, which
# only whoever hits a radio error reads. Moving it out of the always-loaded doc
# is the point (#395), so the doc keeps one rule that says when to load it.
#
# Shipped per assistant, not per loadout: `skills/<assistant>/<name>/SKILL.md`
# in the task-force checkout, installed at `.<assistant>/skills/<name>/SKILL.md`
# in the repo. Claude Code reads `.claude/skills/`; kiro-cli's V3 engine scans
# `.kiro/skills/*/SKILL.md` the same way (checked against kiro-cli 3.3.0).
#
# Three consumers, which is why this is a lib: each task-init installs them,
# lib/local-only.sh lists the claude ones in the exclude block, and
# lib/loadout-artifacts.sh takes them back out on `task-config set` /
# `task-remove`.
#
# Exports:
#   tf_skill_names <assistant>           one shipped skill name per line
#   tf_skill_src <assistant> <name>      the shipped SKILL.md
#   tf_skill_rel <assistant> <name>      where it lands, repo-relative
#   install_skills <loadout-dir> <repo>  install every skill for that loadout's
#                                        assistant (needs lib/install-file.sh,
#                                        honours INSTALL_POLICY like install_file)

TF_SKILLS_ROOT="$(dirname "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)")/skills"

tf_skill_names() {
  local skill
  for skill in "$TF_SKILLS_ROOT/$1"/*/SKILL.md; do
    [[ -f "$skill" ]] || continue
    basename "$(dirname "$skill")"
  done
  return 0
}

tf_skill_src() { printf '%s/%s/%s/SKILL.md' "$TF_SKILLS_ROOT" "$1" "$2"; }
tf_skill_rel() { printf '.%s/skills/%s/SKILL.md' "$1" "$2"; }

install_skills() {
  local loadout assistant name
  loadout=$(basename "$(cd "$1" && pwd -P)")
  assistant="${loadout%%-*}"
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    install_file "$(tf_skill_src "$assistant" "$name")" \
      "$2/$(tf_skill_rel "$assistant" "$name")" "skill: $name"
  done < <(tf_skill_names "$assistant")
}
