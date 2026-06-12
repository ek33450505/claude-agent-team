#!/usr/bin/env bats
# tests/cast-guard-py.bats — Prove-refusal tests for scripts/cast_guard.py
#
# Follows the cast-db-contract.bats precedent: BATS @test blocks invoke
# python3 against scripts/cast_guard.py to cover the same 5+1 cases as
# cast-blast-radius-guard.bats (shell guard parity).
#
# Python heredoc rule: paths passed via os.environ, never shell-interpolated
# into Python source. All heredoc bodies are single-quoted (<< 'PYEOF').

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

# ---------------------------------------------------------------------------
# Helper: write a Python test script to a temp file, run it, assert success.
# The Python script calls safe_rmtree and must exit 0 (refusal paths) or
# exit 1 (the allowed-in-radius path where rmtree should succeed).
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# 1. Refuse out-of-radius — target outside blast_radius → FATAL + canary survives
# ---------------------------------------------------------------------------
@test "safe_rmtree refuses path outside blast radius (canary survives)" {
  local target radius py
  target="$(mktemp -d)"
  touch "$target/canary"
  radius="$(mktemp -d)"

  py="$(mktemp)"
  cat > "$py" << 'PYEOF'
import os, sys
sys.path.insert(0, os.environ['REPO_DIR'] + '/scripts')
from cast_guard import safe_rmtree
target = os.environ['TARGET_PATH']
radius = os.environ['RADIUS_PATH']
try:
    safe_rmtree(target, radius, label="test")
    print("ERROR: no exception raised")
    sys.exit(1)
except RuntimeError as e:
    msg = str(e)
    if 'FATAL' not in msg:
        print(f"ERROR: 'FATAL' not in message: {msg}")
        sys.exit(1)
    sys.exit(0)
PYEOF

  TARGET_PATH="$target" RADIUS_PATH="$radius" REPO_DIR="$REPO_DIR" \
    run python3 "$py"
  assert_success

  # Canary must survive the refused delete
  [ -f "$target/canary" ]

  rm -rf "$target" "$radius" "$py"
}

# ---------------------------------------------------------------------------
# 2. Allow in-radius — target strictly inside blast_radius → success + target removed
# ---------------------------------------------------------------------------
@test "safe_rmtree allows path strictly inside blast radius (target removed)" {
  local radius target py
  radius="$(mktemp -d)"
  target="${radius}/sub-$$"
  mkdir "$target"
  touch "$target/file"

  py="$(mktemp)"
  cat > "$py" << 'PYEOF'
import os, sys
sys.path.insert(0, os.environ['REPO_DIR'] + '/scripts')
from cast_guard import safe_rmtree
target = os.environ['TARGET_PATH']
radius = os.environ['RADIUS_PATH']
try:
    safe_rmtree(target, radius, label="test")
    sys.exit(0)
except RuntimeError as e:
    print(f"ERROR: unexpected refusal: {e}")
    sys.exit(1)
PYEOF

  TARGET_PATH="$target" RADIUS_PATH="$radius" REPO_DIR="$REPO_DIR" \
    run python3 "$py"
  assert_success

  [ ! -d "$target" ]

  rm -rf "$radius" "$py"
}

# ---------------------------------------------------------------------------
# 3. Refuse home — target is HOME, blast_radius is elsewhere → FATAL
#    HOME is set to a temp dir so real home is never the operand.
# ---------------------------------------------------------------------------
@test "safe_rmtree refuses user home directory (FATAL)" {
  local temp_home py
  temp_home="$(mktemp -d)"

  py="$(mktemp)"
  cat > "$py" << 'PYEOF'
import os, sys
sys.path.insert(0, os.environ['REPO_DIR'] + '/scripts')
from cast_guard import safe_rmtree
target = os.environ['TARGET_PATH']
radius = os.environ['RADIUS_PATH']
try:
    safe_rmtree(target, radius, label="test")
    print("ERROR: no exception raised")
    sys.exit(1)
except RuntimeError as e:
    msg = str(e)
    if 'FATAL' not in msg:
        print(f"ERROR: 'FATAL' not in message: {msg}")
        sys.exit(1)
    sys.exit(0)
PYEOF

  # Set HOME to temp_home so expanduser("~") returns it, making it the "home"
  TARGET_PATH="$temp_home" RADIUS_PATH="/tmp/safe-radius-$$" HOME="$temp_home" \
    REPO_DIR="$REPO_DIR" run python3 "$py"
  assert_success

  rm -rf "$temp_home" "$py"
}

# ---------------------------------------------------------------------------
# 4. Refuse symlink escape — symlink inside radius resolves outside → FATAL
#    Link target must survive.
# ---------------------------------------------------------------------------
@test "safe_rmtree refuses symlink that escapes blast radius (link target survives)" {
  local radius outside link_target link_path py
  radius="$(mktemp -d)"
  outside="$(mktemp -d)"
  link_target="${outside}/escape-target"
  mkdir "$link_target"
  touch "$link_target/canary"
  link_path="${radius}/escape-link"
  ln -s "$link_target" "$link_path"

  py="$(mktemp)"
  cat > "$py" << 'PYEOF'
import os, sys
sys.path.insert(0, os.environ['REPO_DIR'] + '/scripts')
from cast_guard import safe_rmtree
target = os.environ['TARGET_PATH']
radius = os.environ['RADIUS_PATH']
try:
    safe_rmtree(target, radius, label="test")
    print("ERROR: no exception raised")
    sys.exit(1)
except RuntimeError as e:
    msg = str(e)
    if 'FATAL' not in msg:
        print(f"ERROR: 'FATAL' not in message: {msg}")
        sys.exit(1)
    sys.exit(0)
PYEOF

  TARGET_PATH="$link_path" RADIUS_PATH="$radius" REPO_DIR="$REPO_DIR" \
    run python3 "$py"
  assert_success

  # Link target (and its canary) must survive
  [ -f "$link_target/canary" ]

  rm -rf "$radius" "$outside" "$py"
}

# ---------------------------------------------------------------------------
# 5. Refuse root equality — path == blast_radius → FATAL
# ---------------------------------------------------------------------------
@test "safe_rmtree refuses path equal to blast radius root (FATAL)" {
  local dir py
  dir="$(mktemp -d)"

  py="$(mktemp)"
  cat > "$py" << 'PYEOF'
import os, sys
sys.path.insert(0, os.environ['REPO_DIR'] + '/scripts')
from cast_guard import safe_rmtree
target = os.environ['TARGET_PATH']
# blast_radius IS the target — must refuse
try:
    safe_rmtree(target, target, label="test")
    print("ERROR: no exception raised")
    sys.exit(1)
except RuntimeError as e:
    msg = str(e)
    if 'FATAL' not in msg:
        print(f"ERROR: 'FATAL' not in message: {msg}")
        sys.exit(1)
    sys.exit(0)
PYEOF

  TARGET_PATH="$dir" REPO_DIR="$REPO_DIR" run python3 "$py"
  assert_success

  # Directory must survive
  [ -d "$dir" ]

  rm -rf "$dir" "$py"
}

# ---------------------------------------------------------------------------
# 6. No declaration equivalent — blast_radius that does not contain target → FATAL
#    (Python module has no separate "no declaration" concept; the equivalent
#     is an out-of-radius call, already covered in test 1. This test covers
#     the case where blast_radius is a completely unrelated directory.)
# ---------------------------------------------------------------------------
@test "safe_rmtree refuses when blast_radius is unrelated to path (FATAL)" {
  local target radius py
  target="$(mktemp -d)"
  touch "$target/canary"
  radius="$(mktemp -d)"  # unrelated directory

  py="$(mktemp)"
  cat > "$py" << 'PYEOF'
import os, sys
sys.path.insert(0, os.environ['REPO_DIR'] + '/scripts')
from cast_guard import safe_rmtree
target = os.environ['TARGET_PATH']
radius = os.environ['RADIUS_PATH']
try:
    safe_rmtree(target, radius, label="test")
    print("ERROR: no exception raised")
    sys.exit(1)
except RuntimeError as e:
    msg = str(e)
    if 'FATAL' not in msg:
        print(f"ERROR: 'FATAL' not in message: {msg}")
        sys.exit(1)
    sys.exit(0)
PYEOF

  TARGET_PATH="$target" RADIUS_PATH="$radius" REPO_DIR="$REPO_DIR" \
    run python3 "$py"
  assert_success

  [ -f "$target/canary" ]

  rm -rf "$target" "$radius" "$py"
}
