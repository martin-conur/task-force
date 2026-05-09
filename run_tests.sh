#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
BATS="$REPO_ROOT/tests/libs/bats-core/bin/bats"

if [[ ! -x "$BATS" ]]; then
  echo "bats-core not found. Run: git submodule update --init --recursive"
  exit 1
fi

# Allow running a single suite: ./run_tests.sh task_done
if [[ $# -gt 0 ]]; then
  exec env BATS_LIB_PATH="$REPO_ROOT/tests/libs" "$BATS" "$REPO_ROOT/tests/$1.bats"
fi

exec env BATS_LIB_PATH="$REPO_ROOT/tests/libs" "$BATS" "$REPO_ROOT/tests"/*.bats
