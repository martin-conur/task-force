#!/usr/bin/env bash
# Kiro CLI agent module (#236). Sourced after the tracker module.
#
# This file is meant to be sourced, not executed.
#
# Empty of behaviour on purpose — see lib/agents/claude.sh for why. task-done
# has no agent axis: the three kiro copies were byte-identical to the matching
# claude ones, including the `radio unregister --manual` and mailbox sweep,
# because removing a worktree and closing a tab does not depend on which agent
# was in it.
#
# task-work's agent hooks (#237) are where the kiro divergence lives: -m/--model,
# -a/--trust-all, TASK_WORK_TRUST_ALL normalization, the aw_require_kiro_agent
# preflight (#218), and --auto meaning auto-submit only rather than a permission
# mode.
