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

# ---------------------------------------------------------------------------
# 7. Refuse directory-traversal path — path uses ".." to escape blast radius → FATAL
#    Regression for §3.8.A: a path that looks like it's inside the radius (starts
#    with it) but resolves outside via realpath-collapse of ".." must be refused.
# ---------------------------------------------------------------------------
@test "safe_rmtree refuses directory-traversal path that escapes blast radius (sentinel survives)" {
  local radius sentinel_dir py traversal_path depth dotdots

  radius="/tmp/cast-swarm-traversal-test-$$"
  mkdir -p "$radius"

  # Create sentinel outside the radius
  sentinel_dir="$(mktemp -d)"
  touch "$sentinel_dir/__MUST_SURVIVE__"

  # Build traversal path: /tmp/cast-swarm-traversal-test-$$/../../.../sentinel_dir
  # Count '/' in sentinel_dir to determine how many ".." we need to reach /
  depth=$(echo "$sentinel_dir" | tr -cd '/' | wc -c | tr -d ' ')
  dotdots=""
  local i
  for i in $(seq 1 "$depth"); do
    dotdots="${dotdots}/.."
  done
  traversal_path="${radius}${dotdots}${sentinel_dir}"

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

  TARGET_PATH="$traversal_path" RADIUS_PATH="$radius" REPO_DIR="$REPO_DIR" \
    run python3 "$py"
  assert_success

  # Sentinel must survive the refused delete
  [ -f "$sentinel_dir/__MUST_SURVIVE__" ]

  rm -rf "$radius" "$sentinel_dir" "$py"
}

# ===========================================================================
# safe_rmtree_pinned — delete by (parent fd, name); ancestors pinned O_NOFOLLOW
# All fixtures live under $BATS_TEST_TMPDIR; paths reach Python via os.environ.
# ===========================================================================

# Write the shared prologue + the case body (stdin) to $BATS_TEST_TMPDIR/pin.py.
# Case bodies call expect_fatal(fn) / plain calls; exit 0 = behaved as expected.
_pin_script() {
  {
    cat << 'PYEOF'
import os, sys
sys.path.insert(0, os.environ['REPO_DIR'] + '/scripts')
from cast_guard import safe_rmtree_pinned

def expect_fatal(*args):
    try:
        safe_rmtree_pinned(*args, label="test")
    except RuntimeError as e:
        if 'FATAL [safe_rmtree_pinned]' not in str(e):
            print(f"ERROR: bad message: {e}")
            sys.exit(1)
        return
    print(f"ERROR: no exception raised for {args!r}")
    sys.exit(1)

PYEOF
    cat
  } > "$BATS_TEST_TMPDIR/pin.py"
}

# 8. Happy path: removes parent/name incl. nested content, leaves siblings, restores cwd
@test "safe_rmtree_pinned removes parent/name with nested files, leaves siblings, restores cwd" {
  local radius="$BATS_TEST_TMPDIR/radius"
  mkdir -p "$radius/p/name/deep/er" "$radius/p/sibling"
  touch "$radius/p/name/f" "$radius/p/name/deep/er/g" "$radius/p/sibling/keep"

  _pin_script << 'PYEOF'
radius = os.environ['RADIUS_PATH']
before = os.getcwd()
safe_rmtree_pinned(os.path.join(radius, 'p'), 'name', radius, label="test")
if os.getcwd() != before:
    print("ERROR: cwd not restored")
    sys.exit(1)
PYEOF

  RADIUS_PATH="$radius" REPO_DIR="$REPO_DIR" run python3 "$BATS_TEST_TMPDIR/pin.py"
  assert_success
  [ ! -e "$radius/p/name" ]
  [ -f "$radius/p/sibling/keep" ]
}

# 9. Parent outside the blast radius -> FATAL, canary survives
@test "safe_rmtree_pinned refuses parent outside blast radius (canary survives)" {
  local radius="$BATS_TEST_TMPDIR/radius" outside="$BATS_TEST_TMPDIR/outside"
  mkdir -p "$radius" "$outside/name"
  touch "$outside/name/canary"

  _pin_script << 'PYEOF'
expect_fatal(os.environ['OUTSIDE_PATH'], 'name', os.environ['RADIUS_PATH'])
PYEOF

  OUTSIDE_PATH="$outside" RADIUS_PATH="$radius" REPO_DIR="$REPO_DIR" \
    run python3 "$BATS_TEST_TMPDIR/pin.py"
  assert_success
  [ -f "$outside/name/canary" ]
}

# 10. name is a symlink to a victim directory -> FATAL, victim intact
@test "safe_rmtree_pinned refuses name that is a symlink (victim intact)" {
  local radius="$BATS_TEST_TMPDIR/radius" victim="$BATS_TEST_TMPDIR/victim"
  mkdir -p "$radius/p" "$victim"
  touch "$victim/canary"
  ln -s "$victim" "$radius/p/name"

  _pin_script << 'PYEOF'
radius = os.environ['RADIUS_PATH']
expect_fatal(os.path.join(radius, 'p'), 'name', radius)
PYEOF

  RADIUS_PATH="$radius" REPO_DIR="$REPO_DIR" run python3 "$BATS_TEST_TMPDIR/pin.py"
  assert_success
  [ -f "$victim/canary" ]
  [ -L "$radius/p/name" ]
}

# 11. name must be a single component: '..', '.', 'a/b', '' -> FATAL
@test "safe_rmtree_pinned refuses bad names (.. . a/b empty)" {
  local radius="$BATS_TEST_TMPDIR/radius"
  mkdir -p "$radius/p/a/b" "$radius/p/name"
  touch "$radius/p/a/b/canary" "$radius/p/name/canary"

  _pin_script << 'PYEOF'
radius = os.environ['RADIUS_PATH']
parent = os.path.join(radius, 'p')
for bad in ('..', '.', 'a/b', '', 'x\0y'):
    expect_fatal(parent, bad, radius)
PYEOF

  RADIUS_PATH="$radius" REPO_DIR="$REPO_DIR" run python3 "$BATS_TEST_TMPDIR/pin.py"
  assert_success
  [ -f "$radius/p/a/b/canary" ]
  [ -f "$radius/p/name/canary" ]
}

# 12. ANCESTOR swap after the realpath check: radius/p becomes a symlink to a victim
#     dir holding name/. realpath is pinned to the pre-swap answer (simulating the
#     check-then-swap window); the O_NOFOLLOW walk must refuse and the victim survive.
@test "safe_rmtree_pinned refuses an ancestor swapped for a symlink after the check (victim survives)" {
  local radius="$BATS_TEST_TMPDIR/radius" victim="$BATS_TEST_TMPDIR/victimdir"
  mkdir -p "$radius/p/name" "$victim/name"
  touch "$radius/p/name/f" "$victim/name/canary"

  _pin_script << 'PYEOF'
import shutil
radius = os.environ['RADIUS_PATH']
victim = os.environ['VICTIM_PATH']
parent = os.path.join(radius, 'p')

real_realpath = os.path.realpath
frozen = {parent: real_realpath(parent)}      # what the check saw BEFORE the swap
shutil.rmtree(parent)
os.symlink(victim, parent)                    # the swap
os.path.realpath = lambda p, *a, **k: frozen.get(str(p)) or real_realpath(p, *a, **k)

expect_fatal(parent, 'name', radius)
PYEOF

  RADIUS_PATH="$radius" VICTIM_PATH="$victim" REPO_DIR="$REPO_DIR" \
    run python3 "$BATS_TEST_TMPDIR/pin.py"
  assert_success
  [ -f "$victim/name/canary" ]
}
