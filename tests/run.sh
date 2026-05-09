#!/usr/bin/env bash
# Run all BATS tests — matches CI glob list exactly (BATS 1.13.0 is non-recursive)
set -euo pipefail
cd "$(dirname "$0")/.."
exec bats tests/*.bats tests/hooks/*.bats tests/agents/*.bats tests/scripts/*.bats "$@"
