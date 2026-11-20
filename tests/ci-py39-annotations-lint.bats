#!/usr/bin/env bats
# Tests for scripts/ci-py39-annotations-lint.sh (Python 3.9 annotation gate).
#
# The lint scans scripts/, bin/ and tests/ (maxdepth 1) under its repo root.
# Fixtures live in a throwaway directory outside any git repo, so the script's
# `git rev-parse` falls back to the cwd and scans only the fixture.

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'
load 'helpers/setup'

REPO_ROOT_REAL="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
LINT="$REPO_ROOT_REAL/scripts/ci-py39-annotations-lint.sh"

setup() {
  setup_temp_home
  SHIM_DIR="$BATS_TEST_TMPDIR/shims"
  mkdir -p "$SHIM_DIR"
  local _gui
  for _gui in osascript open terminal-notifier screencapture; do
    printf '#!/bin/bash\nexit 0\n' > "$SHIM_DIR/$_gui"
    chmod +x "$SHIM_DIR/$_gui"
  done
  export PATH="$SHIM_DIR:$PATH"

  FIX="$BATS_TEST_TMPDIR/fixture"
  mkdir -p "$FIX/scripts" "$FIX/bin" "$FIX/tests"
}

teardown() {
  teardown_temp_home
}

@test "passes on the real repo: no Python 3.9 annotation violations" {
  cd "$REPO_ROOT_REAL"
  run bash "$LINT"
  assert_success
  assert_output --partial "All checks passed"
  refute_output --partial "FAIL:"
}

@test "passes on a clean temp .py that uses typing.Optional" {
  cat > "$FIX/scripts/clean.py" <<'EOF'
"""Clean module: typing-based annotations only."""
from typing import Optional


def lookup(key: str) -> Optional[str]:
    return None
EOF
  cd "$FIX"
  run bash "$LINT"
  assert_success
  assert_output --partial "Scanning 1 file(s)"
  assert_output --partial "All checks passed"
}

@test "fails on a PEP-604 return annotation without the future import" {
  cat > "$FIX/scripts/bad_return.py" <<'EOF'
import os


def bad(x: str) -> dict | None:
    return None
EOF
  cd "$FIX"
  run bash "$LINT"
  assert_failure
  assert_output --partial "[missing-future-import] scripts/bad_return.py"
  assert_output --partial "FAIL: Python 3.9 annotation compatibility violations found"
}

@test "passes the same PEP-604 annotation once the future import guards it" {
  cat > "$FIX/scripts/guarded.py" <<'EOF'
from __future__ import annotations


def ok(x: str) -> dict | None:
    return None
EOF
  cd "$FIX"
  run bash "$LINT"
  assert_success
  refute_output --partial "missing-future-import"
}

@test "fails on a module-level PEP-604 variable annotation without the future import" {
  cat > "$FIX/tests/var_annot.py" <<'EOF'
value: int | None = None
EOF
  cd "$FIX"
  run bash "$LINT"
  assert_failure
  assert_output --partial "[missing-future-import] tests/var_annot.py"
}

@test "fails on a PEP-604 parameter annotation without the future import" {
  cat > "$FIX/scripts/param.py" <<'EOF'
def f(x: int | None):
    return x
EOF
  cd "$FIX"
  run bash "$LINT"
  assert_failure
  assert_output --partial "[missing-future-import] scripts/param.py"
}

@test "does not flag a function-local PEP-604 annotation (never evaluated on 3.9)" {
  cat > "$FIX/tests/local_annot.py" <<'EOF'
def f() -> None:
    value: int | None = None
    return value
EOF
  cd "$FIX"
  run bash "$LINT"
  assert_success
  refute_output --partial "missing-future-import"
}

@test "fails on a class-body PEP-604 field without the future import" {
  cat > "$FIX/scripts/row.py" <<'EOF'
from dataclasses import dataclass


@dataclass
class Row:
    x: int | None = None
EOF
  cd "$FIX"
  run bash "$LINT"
  assert_failure
  assert_output --partial "[missing-future-import] scripts/row.py"
}

@test "does not flag a method-local PEP-604 annotation inside a class" {
  cat > "$FIX/scripts/method.py" <<'EOF'
class Row:
    def m(self) -> None:
        value: int | None = None
        return value
EOF
  cd "$FIX"
  run bash "$LINT"
  assert_success
  refute_output --partial "missing-future-import"
}

@test "does not flag docstring prose that looks like a class-body annotation" {
  cat > "$FIX/scripts/doc.py" <<'EOF'
class Row:
    """Summary.

    Returns: dict | None
    """

    def m(self) -> None:
        return None
EOF
  cd "$FIX"
  run bash "$LINT"
  assert_success
  refute_output --partial "missing-future-import"
}

@test "fails on a class-body PEP-604 field after a multi-line class header" {
  cat > "$FIX/scripts/multi.py" <<'EOF'
class D(
    object,
):
    x: int | None = None
EOF
  cd "$FIX"
  run bash "$LINT"
  assert_failure
  assert_output --partial "[missing-future-import] scripts/multi.py"
}

@test "fails on isinstance with a pipe union even with the future import" {
  cat > "$FIX/bin/runtime_isinstance.py" <<'EOF'
from __future__ import annotations
ok = isinstance(3, int | str)
EOF
  cd "$FIX"
  run bash "$LINT"
  assert_failure
  assert_output --partial "[runtime-isinstance-pipe] bin/runtime_isinstance.py"
  refute_output --partial "missing-future-import"
}

@test "fails on a module-level ALL_CAPS pipe type alias even with the future import" {
  cat > "$FIX/scripts/alias.py" <<'EOF'
from __future__ import annotations
NUMERIC = int | float
EOF
  cd "$FIX"
  run bash "$LINT"
  assert_failure
  assert_output --partial "[runtime-type-alias-pipe] scripts/alias.py"
}

@test "does not flag regex alternation inside re.compile as a type union" {
  cat > "$FIX/scripts/pattern.py" <<'EOF'
import re
PATTERN = re.compile("a|b")
EOF
  cd "$FIX"
  run bash "$LINT"
  assert_success
  assert_output --partial "All checks passed"
}

@test "ignores .py files in nested subdirectories (scan is maxdepth 1)" {
  mkdir -p "$FIX/scripts/nested"
  cat > "$FIX/scripts/nested/deep_bad.py" <<'EOF'
def bad(x: str) -> dict | None:
    return None
EOF
  cd "$FIX"
  run bash "$LINT"
  assert_success
  refute_output --partial "deep_bad.py"
}

@test "exits 0 with a nothing-to-check message when no scanned directory has .py files" {
  cd "$FIX"
  run bash "$LINT"
  assert_success
  assert_output --partial "nothing to check"
}

@test "--self-test plants a class-A violation and reports detection" {
  cd "$REPO_ROOT_REAL"
  run bash "$LINT" --self-test
  assert_success
  assert_output --partial "--self-test PASSED: class-A violation correctly detected"
}
