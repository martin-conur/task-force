#!/usr/bin/env bash
# Claude Code agent module (#236). Sourced after the tracker module.
#
# This file is meant to be sourced, not executed.
#
# Empty of behaviour on purpose, and that emptiness is the finding: task-done
# has NO agent axis at all. `diff claude-gh/bin/task-done kiro-gh/bin/task-done`
# was empty, and neither copy ever mentioned `claude` or `kiro-cli` — the file
# only ever removes a worktree, sweeps radio state and closes a tab, none of
# which cares which agent was sitting in it.
#
# The file exists anyway so the parity suite covers both axes from #236 onward
# rather than gaining a dimension in #237: a loadout whose agent module is
# missing fails a test today, not after task-work moves too.
#
# task-work's agent hooks (#237) are where this earns its keep — the launch
# line, --plan, --auto's permission-mode meaning, the usage Options block.
