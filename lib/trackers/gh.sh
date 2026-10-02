#!/usr/bin/env bash
# GitHub Projects tracker module (#236). Sourced after lib/trackers/_default.sh.
#
# This file is meant to be sourced, not executed.
#
# Overrides nothing for task-done: the defaults in _default.sh *are* the gh
# behaviour, since four of the seven task-done copies were byte-identical and gh
# was one of them. task-work's hooks (#237) are where this module earns its
# keep — ref parsing, the issue-N slug, the GH_URL sidecar key.
