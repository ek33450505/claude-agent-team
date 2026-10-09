#!/usr/bin/env bats
# tests/scripts/cast-stack-detect.bats
# Tests for scripts/cast-stack-detect.sh
# All tests are isolated to BATS_TEST_TMPDIR — never touch real $HOME or the repo.

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
SCRIPT="$REPO_DIR/scripts/cast-stack-detect.sh"

setup() {
  FAKE_REPO="$BATS_TEST_TMPDIR/fake-repo"
  FAKE_HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$FAKE_REPO" "$FAKE_HOME"
  unset CLAUDE_SUBPROCESS
}

# --write only persists into a real git work-tree top-level; tests that expect a write
# must make the target one. Quiet, no user config needed (init only).
git_init() {
  git init -q "$1"
}

# ── Test 1: vite-react (non-TS) detected from package.json ───────────────
@test "detects vite-react from package.json with vite dep and no typescript" {
  printf '%s\n' '{"scripts":{"build":"vite build","lint":"eslint ."},"dependencies":{"vite":"^5.0.0","react":"^18.0.0"}}' \
    > "$FAKE_REPO/package.json"

  run bash "$SCRIPT" "$FAKE_REPO"
  [ "$status" -eq 0 ]

  DETECT_OUT="$output" python3 << 'PY'
import json, os
d = json.loads(os.environ['DETECT_OUT'])
assert d['framework'] == 'vite-react', f"Expected vite-react, got: {d['framework']}"
assert d['language'] == 'javascript', f"Expected javascript, got: {d['language']}"
PY
}

# ── Test 2: BATS tests/run.sh detected as test command ────────────────────
@test "detects bash tests/run.sh when tests/run.sh exists" {
  mkdir -p "$FAKE_REPO/tests"
  touch "$FAKE_REPO/tests/run.sh"

  run bash "$SCRIPT" "$FAKE_REPO"
  [ "$status" -eq 0 ]

  DETECT_OUT="$output" python3 << 'PY'
import json, os
d = json.loads(os.environ['DETECT_OUT'])
assert d['test_cmd'] == 'bash tests/run.sh', f"Expected 'bash tests/run.sh', got: {d['test_cmd']}"
PY
}

# ── Test 3: python detected from pyproject.toml ───────────────────────────
@test "detects python language from pyproject.toml" {
  printf '%s\n' '[build-system]' > "$FAKE_REPO/pyproject.toml"
  printf '%s\n' 'requires = ["setuptools"]' >> "$FAKE_REPO/pyproject.toml"
  printf '%s\n' '[tool.pytest.ini_options]' >> "$FAKE_REPO/pyproject.toml"
  printf '%s\n' 'testpaths = ["tests"]' >> "$FAKE_REPO/pyproject.toml"

  run bash "$SCRIPT" "$FAKE_REPO"
  [ "$status" -eq 0 ]

  DETECT_OUT="$output" python3 << 'PY'
import json, os
d = json.loads(os.environ['DETECT_OUT'])
assert d['language'] == 'python', f"Expected python, got: {d['language']}"
assert d['test_cmd'] == 'pytest', f"Expected pytest, got: {d['test_cmd']}"
PY
}

# ── Test 4: unknown repo exits 0 and emits unknown fallback ───────────────
@test "unknown repo emits unknown framework and exits 0" {
  # FAKE_REPO has no package.json, pyproject.toml, Makefile, or cast-*.sh
  run bash "$SCRIPT" "$FAKE_REPO"
  [ "$status" -eq 0 ]

  DETECT_OUT="$output" python3 << 'PY'
import json, os
d = json.loads(os.environ['DETECT_OUT'])
assert d['language'] == 'unknown', f"Expected unknown, got: {d['language']}"
assert d['framework'] == 'unknown', f"Expected unknown, got: {d['framework']}"
assert 'inferred_at' in d, "Missing inferred_at"
assert d['inferred_by'] == 'cast-stack-detect.sh', f"Wrong inferred_by: {d['inferred_by']}"
PY
}

# ── Test 5: --write with _manual guard does not overwrite cast.json ────────
@test "--write with _manual guard skips overwrite" {
  git_init "$FAKE_REPO"
  mkdir -p "$FAKE_REPO/.claude"
  printf '%s\n' '{"repo_class":"personal","stack":{"_manual":true,"framework":"my-custom","language":"rust"}}' \
    > "$FAKE_REPO/.claude/cast.json"
  printf '%s\n' '{"dependencies":{"vite":"^5.0.0"}}' \
    > "$FAKE_REPO/package.json"

  run bash "$SCRIPT" "$FAKE_REPO" --write
  [ "$status" -eq 0 ]

  # cast.json must still carry the _manual marker and original framework
  CAST_JSON_PATH="$FAKE_REPO/.claude/cast.json" python3 << 'PY'
import json, os
with open(os.environ['CAST_JSON_PATH']) as f:
    d = json.load(f)
assert d['stack'].get('_manual') is True, f"_manual guard removed! got: {d['stack']}"
assert d['stack'].get('framework') == 'my-custom', f"framework overwritten! got: {d['stack']}"
PY
}

# ── Test 6: --write on fresh repo creates cast.json with stack block ───────
@test "--write on fresh repo writes stack block to cast.json" {
  git_init "$FAKE_REPO"
  mkdir -p "$FAKE_REPO/.claude"
  # No cast.json yet — directory exists but file is absent
  printf '%s\n' '{"scripts":{"build":"vite build"},"dependencies":{"vite":"^5.0.0"}}' \
    > "$FAKE_REPO/package.json"

  run bash "$SCRIPT" "$FAKE_REPO" --write
  [ "$status" -eq 0 ]
  [ -f "$FAKE_REPO/.claude/cast.json" ]

  CAST_JSON_PATH="$FAKE_REPO/.claude/cast.json" python3 << 'PY'
import json, os
with open(os.environ['CAST_JSON_PATH']) as f:
    d = json.load(f)
assert 'stack' in d, f"No stack block written: {d}"
assert d['stack'].get('framework') == 'vite-react', f"Wrong framework: {d['stack']}"
assert 'inferred_at' in d['stack'], "Missing inferred_at in written stack"
PY
}

# ── Test 7: vite + typescript → vite-ts ──────────────────────────────────
@test "detects vite-ts when vite dep AND typescript dep both present" {
  printf '%s\n' '{"dependencies":{"vite":"^5.0.0","react":"^18.0.0"},"devDependencies":{"typescript":"^5.0.0"}}' \
    > "$FAKE_REPO/package.json"

  run bash "$SCRIPT" "$FAKE_REPO"
  [ "$status" -eq 0 ]

  DETECT_OUT="$output" python3 << 'PY'
import json, os
d = json.loads(os.environ['DETECT_OUT'])
assert d['framework'] == 'vite-ts', f"Expected vite-ts, got: {d['framework']}"
assert d['language'] == 'typescript', f"Expected typescript, got: {d['language']}"
PY
}

# ── Test 8: vitest.config-only repo (no vite in deps) → vite framework ───
@test "vitest.config.ts alone triggers vite framework detection" {
  # No package.json — vitest.config.ts is the only signal
  printf '%s\n' "import { defineConfig } from 'vitest/config'" > "$FAKE_REPO/vitest.config.ts"
  printf '%s\n' "export default defineConfig({ test: { include: ['src/**/*.test.ts'] } })" \
    >> "$FAKE_REPO/vitest.config.ts"

  run bash "$SCRIPT" "$FAKE_REPO"
  [ "$status" -eq 0 ]

  DETECT_OUT="$output" python3 << 'PY'
import json, os
d = json.loads(os.environ['DETECT_OUT'])
# language unknown (no pkg.json), framework should be vite-react (non-TS default without language signal)
assert d['framework'] in ('vite-react', 'vite-ts'), f"Expected vite framework, got: {d['framework']}"
PY
}

# ── Test 9: *.bats without tests/run.sh → test_cmd=bats tests/ ───────────
@test "*.bats files without tests/run.sh set test_cmd to bats tests/" {
  mkdir -p "$FAKE_REPO/tests"
  touch "$FAKE_REPO/tests/my-feature.bats"
  # No tests/run.sh — only a .bats file

  run bash "$SCRIPT" "$FAKE_REPO"
  [ "$status" -eq 0 ]

  DETECT_OUT="$output" python3 << 'PY'
import json, os
d = json.loads(os.environ['DETECT_OUT'])
assert d['test_cmd'] == 'bats tests/', f"Expected 'bats tests/', got: {d['test_cmd']}"
PY
}

# ── Test 10: --write emits trailing newline in cast.json ─────────────────
@test "--write appends trailing newline to cast.json" {
  git_init "$FAKE_REPO"
  mkdir -p "$FAKE_REPO/.claude"
  printf '%s\n' '{"repo_class":"personal"}' > "$FAKE_REPO/.claude/cast.json"
  printf '%s\n' '{"dependencies":{"vite":"^5.0.0"}}' > "$FAKE_REPO/package.json"

  run bash "$SCRIPT" "$FAKE_REPO" --write
  [ "$status" -eq 0 ]

  # File must end with a newline (last byte is 0x0a)
  CAST_JSON_PATH="$FAKE_REPO/.claude/cast.json" python3 << 'PY'
import os
path = os.environ['CAST_JSON_PATH']
with open(path, 'rb') as f:
    content = f.read()
assert content.endswith(b'\n'), f"cast.json missing trailing newline, last bytes: {content[-4:]!r}"
PY
}

# ── Test 11: --write as first arg (misparse) → unknown JSON, exit 0, no write ──
@test "--write as first arg yields unknown JSON, exit 0, and writes nothing" {
  # Simulate: cast-stack-detect.sh --write (no repo path — $1 is a flag string)
  # Run from an isolated temp dir so we can verify no file was written.
  ISOLATED_CWD="$BATS_TEST_TMPDIR/guard-test"
  mkdir -p "$ISOLATED_CWD"

  # Run with isolated cwd so any accidental write would appear under ISOLATED_CWD
  run bash -c "cd '$ISOLATED_CWD' && bash '$SCRIPT' --write"
  [ "$status" -eq 0 ]

  # Output must be valid unknown-fallback JSON
  DETECT_OUT="$output" python3 << 'PY'
import json, os
d = json.loads(os.environ['DETECT_OUT'])
assert d['language']    == 'unknown',                f"Expected unknown language, got: {d}"
assert d['framework']   == 'unknown',                f"Expected unknown framework, got: {d}"
assert d['inferred_by'] == 'cast-stack-detect.sh',   f"Wrong inferred_by: {d}"
PY

  # Guard must not have written cast.json into the isolated cwd
  [ ! -f "$ISOLATED_CWD/.claude/cast.json" ]
}

# ── Test 12: --write in a non-repo directory writes nothing ───────────────
@test "--write in a non-git directory writes nothing" {
  printf '%s\n' '{"scripts":{"build":"vite build"},"dependencies":{"vite":"^5.0.0"}}' \
    > "$FAKE_REPO/package.json"

  run bash "$SCRIPT" "$FAKE_REPO" --write --force
  [ "$status" -eq 0 ]

  # Detection output is still produced...
  [[ "$output" == *'"framework": "vite-react"'* || "$output" == *'"framework":"vite-react"'* ]]
  # ...but nothing is persisted, and the refusal says why (stderr is merged into $output)
  [ ! -e "$FAKE_REPO/.claude" ]
  [[ "$output" == *"--write skipped: git could not report a work-tree top-level"* ]]
}

# ── Test 13: --write in a repo SUBDIRECTORY writes nothing there ──────────
@test "--write in a repo subdirectory writes nothing at the subdirectory" {
  git_init "$FAKE_REPO"
  mkdir -p "$FAKE_REPO/scripts"
  printf '%s\n' '{"dependencies":{"vite":"^5.0.0"}}' > "$FAKE_REPO/scripts/package.json"

  run bash "$SCRIPT" "$FAKE_REPO/scripts" --write --force
  [ "$status" -eq 0 ]

  [ ! -e "$FAKE_REPO/scripts/.claude" ]
  [ ! -e "$FAKE_REPO/.claude" ]
  [[ "$output" == *"--write skipped: target is not a git work-tree top-level"* ]]
}

# ── Test 14: --write never targets $HOME or ~/.claude, even if a git root ──
@test "--write refuses \$HOME, ~/.claude and its subdirectories even when they are git roots" {
  mkdir -p "$FAKE_HOME/.claude/scripts"
  git_init "$FAKE_HOME"
  git_init "$FAKE_HOME/.claude"
  git_init "$FAKE_HOME/.claude/scripts"
  printf '%s\n' '{"dependencies":{"vite":"^5.0.0"}}' > "$FAKE_HOME/package.json"
  printf '%s\n' '{"dependencies":{"vite":"^5.0.0"}}' > "$FAKE_HOME/.claude/package.json"
  printf '%s\n' '{"dependencies":{"vite":"^5.0.0"}}' > "$FAKE_HOME/.claude/scripts/package.json"

  for target in "$FAKE_HOME" "$FAKE_HOME/.claude" "$FAKE_HOME/.claude/scripts"; do
    HOME="$FAKE_HOME" run bash "$SCRIPT" "$target" --write --force
    [ "$status" -eq 0 ]
    [[ "$output" == *"--write skipped: target is \$HOME or under ~/.claude"* ]]
  done

  [ ! -e "$FAKE_HOME/.claude/cast.json" ]
  [ ! -e "$FAKE_HOME/.claude/.claude" ]
  [ ! -e "$FAKE_HOME/.claude/scripts/.claude" ]
}

# ── Test 15: an unchanged profile is not rewritten (timestamp-only churn) ──
@test "--write does not rewrite cast.json when only inferred_at would change" {
  git_init "$FAKE_REPO"
  mkdir -p "$FAKE_REPO/.claude"
  printf '%s\n' '{"scripts":{"build":"vite build"},"dependencies":{"vite":"^5.0.0"}}' \
    > "$FAKE_REPO/package.json"

  # Seed cast.json with the profile detection produces, but an old (>7d) timestamp
  run bash "$SCRIPT" "$FAKE_REPO"
  [ "$status" -eq 0 ]
  DETECT_OUT="$output" CAST_JSON_PATH="$FAKE_REPO/.claude/cast.json" python3 << 'PY'
import json, os
stack = json.loads(os.environ['DETECT_OUT'])
stack['inferred_at'] = '2020-01-01T00:00:00Z'
with open(os.environ['CAST_JSON_PATH'], 'w') as f:
    json.dump({'repo_class': 'personal', 'stack': stack}, f, indent=2)
    f.write('\n')
PY
  before="$(cat "$FAKE_REPO/.claude/cast.json")"

  run bash "$SCRIPT" "$FAKE_REPO" --write --force
  [ "$status" -eq 0 ]

  [ "$(cat "$FAKE_REPO/.claude/cast.json")" = "$before" ]
}

# ── Test 16: a CHANGED profile is still rewritten (the skip is not blanket) ─
@test "--write still rewrites cast.json when the profile changed" {
  git_init "$FAKE_REPO"
  mkdir -p "$FAKE_REPO/.claude"
  printf '%s\n' '{"scripts":{"build":"vite build"},"dependencies":{"vite":"^5.0.0"}}' \
    > "$FAKE_REPO/package.json"
  printf '%s\n' '{"repo_class":"personal","stack":{"language":"rust","framework":"stale","inferred_at":"2020-01-01T00:00:00Z"}}' \
    > "$FAKE_REPO/.claude/cast.json"

  run bash "$SCRIPT" "$FAKE_REPO" --write
  [ "$status" -eq 0 ]

  CAST_JSON_PATH="$FAKE_REPO/.claude/cast.json" python3 << 'PY'
import json, os
d = json.load(open(os.environ['CAST_JSON_PATH']))
assert d['stack']['framework'] == 'vite-react', d
assert d['stack']['inferred_at'] != '2020-01-01T00:00:00Z', d
assert d['repo_class'] == 'personal', d
PY
}

# ── Test 17: lib missing => --write fails closed, with a stderr reason ─────
@test "--write fails closed with a reason when cast-hook-lib.sh is not next to the script" {
  git_init "$FAKE_REPO"
  printf '%s\n' '{"dependencies":{"vite":"^5.0.0"}}' > "$FAKE_REPO/package.json"
  # A copy of the script alone: no sibling cast-hook-lib.sh to load
  ALONE="$BATS_TEST_TMPDIR/alone"
  mkdir -p "$ALONE"
  cp "$SCRIPT" "$ALONE/cast-stack-detect.sh"

  run bash "$ALONE/cast-stack-detect.sh" "$FAKE_REPO" --write --force
  [ "$status" -eq 0 ]

  [ ! -e "$FAKE_REPO/.claude" ]
  [[ "$output" == *"--write skipped: cast-hook-lib.sh could not be loaded"* ]]
}

# ── Test 18: a repo top-level IS written, silently (no refusal noise) ──────
@test "--write on a git top-level emits no refusal message" {
  git_init "$FAKE_REPO"
  printf '%s\n' '{"dependencies":{"vite":"^5.0.0"}}' > "$FAKE_REPO/package.json"

  run bash "$SCRIPT" "$FAKE_REPO" --write --force
  [ "$status" -eq 0 ]
  [ -f "$FAKE_REPO/.claude/cast.json" ]
  [[ "$output" != *"skipped"* ]]
}

# ── Tests 19-23: --write never follows links planted inside the repo ───────
# The repo is agent-writable: <repo>/.claude or <repo>/.claude/cast.json can be a symlink into
# (or a hardlink of) a file the user cares about, e.g. ~/.claude/config/policies.json.
seed_repo_for_link_tests() {
  git_init "$FAKE_REPO"
  printf '%s\n' '{"scripts":{"build":"vite build"},"dependencies":{"vite":"^5.0.0"}}' \
    > "$FAKE_REPO/package.json"
  VICTIM_DIR="$BATS_TEST_TMPDIR/victim"
  mkdir -p "$VICTIM_DIR"
}

@test "--write refuses when <repo>/.claude is a symlink to another directory" {
  seed_repo_for_link_tests
  ln -s "$VICTIM_DIR" "$FAKE_REPO/.claude"

  run bash "$SCRIPT" "$FAKE_REPO" --write --force
  [ "$status" -eq 0 ]

  [ -L "$FAKE_REPO/.claude" ]
  [ -z "$(ls -A "$VICTIM_DIR")" ]
  [[ "$output" == *"--write skipped: <repo>/.claude is a symlink or not a directory"* ]]
}

@test "--write refuses when <repo>/.claude/cast.json is a symlink to an existing file" {
  seed_repo_for_link_tests
  mkdir -p "$FAKE_REPO/.claude"
  printf '%s\n' '{"policies":[{"id":"p1"}]}' > "$VICTIM_DIR/policies.json"
  before="$(cat "$VICTIM_DIR/policies.json")"
  ln -s "$VICTIM_DIR/policies.json" "$FAKE_REPO/.claude/cast.json"

  run bash "$SCRIPT" "$FAKE_REPO" --write --force
  [ "$status" -eq 0 ]

  [ "$(cat "$VICTIM_DIR/policies.json")" = "$before" ]
  [ -L "$FAKE_REPO/.claude/cast.json" ]
  [[ "$output" == *"--write skipped: <repo>/.claude/cast.json is a symlink"* ]]
}

@test "--write refuses a dangling <repo>/.claude/cast.json symlink and creates nothing at its target" {
  seed_repo_for_link_tests
  mkdir -p "$FAKE_REPO/.claude"
  ln -s "$VICTIM_DIR/planted.json" "$FAKE_REPO/.claude/cast.json"

  run bash "$SCRIPT" "$FAKE_REPO" --write --force
  [ "$status" -eq 0 ]

  [ ! -e "$VICTIM_DIR/planted.json" ]
  [[ "$output" == *"--write skipped: <repo>/.claude/cast.json is a symlink"* ]]
}

@test "--write refuses a hardlinked <repo>/.claude/cast.json and leaves both names untouched" {
  seed_repo_for_link_tests
  mkdir -p "$FAKE_REPO/.claude"
  printf '%s\n' '{"stack":{"language":"rust","framework":"stale","inferred_at":"2020-01-01T00:00:00Z"}}' \
    > "$FAKE_REPO/.claude/cast.json"
  ln "$FAKE_REPO/.claude/cast.json" "$VICTIM_DIR/other-name.json"
  before="$(cat "$FAKE_REPO/.claude/cast.json")"

  run bash "$SCRIPT" "$FAKE_REPO" --write --force
  [ "$status" -eq 0 ]

  [ "$(cat "$FAKE_REPO/.claude/cast.json")" = "$before" ]
  [ "$(cat "$VICTIM_DIR/other-name.json")" = "$before" ]
  [[ "$output" == *"--write skipped: <repo>/.claude/cast.json has multiple hard links"* ]]
}

@test "--write replaces cast.json via a temp file and leaves no temp file behind" {
  seed_repo_for_link_tests
  mkdir -p "$FAKE_REPO/.claude"
  printf '%s\n' '{"repo_class":"personal"}' > "$FAKE_REPO/.claude/cast.json"
  chmod 600 "$FAKE_REPO/.claude/cast.json"

  run bash "$SCRIPT" "$FAKE_REPO" --write --force
  [ "$status" -eq 0 ]

  [ -f "$FAKE_REPO/.claude/cast.json" ]
  [ ! -L "$FAKE_REPO/.claude/cast.json" ]
  # only cast.json remains in the directory (no .cast.json.tmp-*)
  [ "$(ls -A "$FAKE_REPO/.claude")" = "cast.json" ]
  grep -q '"repo_class": "personal"' "$FAKE_REPO/.claude/cast.json"
  grep -q '"framework"' "$FAKE_REPO/.claude/cast.json"
  # the existing file's mode is preserved
  [ "$(python3 -c "import os,sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777))" "$FAKE_REPO/.claude/cast.json")" = "0o600" ]
}

# Runs the script in the background and fails (killing it) if it has not exited within 5s.
# `timeout` is not on stock macOS, so use a poll-and-kill guard.
run_with_deadline() {
  # fds 3/4 are closed for the child so a hung (killed-late) process can never hold bats' pipes
  bash "$SCRIPT" "$@" > "$BATS_TEST_TMPDIR/dl.out" 2> "$BATS_TEST_TMPDIR/dl.err" 3>&- 4>&- &
  local pid=$! i kid
  for i in $(seq 1 50); do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
  done
  if kill -0 "$pid" 2>/dev/null; then
    # kill the hung python child first (the script runs it as a child, not via exec), then bash
    for kid in $(pgrep -P "$pid" 2>/dev/null); do kill -9 "$kid" 2>/dev/null || true; done
    kill -9 "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    DEADLINE_HIT=1
    return 1
  fi
  wait "$pid"
  DEADLINE_RC=$?
  DEADLINE_ERR="$(cat "$BATS_TEST_TMPDIR/dl.err")"
}

@test "--write refuses a FIFO named cast.json promptly (no hang) and writes nothing" {
  seed_repo_for_link_tests
  mkdir -p "$FAKE_REPO/.claude"
  mkfifo "$FAKE_REPO/.claude/cast.json"

  DEADLINE_HIT=0
  run_with_deadline "$FAKE_REPO" --write --force
  [ "$DEADLINE_HIT" -eq 0 ]
  [ "$DEADLINE_RC" -eq 0 ]
  [ -p "$FAKE_REPO/.claude/cast.json" ]
  [ "$(ls -A "$FAKE_REPO/.claude")" = "cast.json" ]
  [[ "$DEADLINE_ERR" == *"--write skipped: <repo>/.claude/cast.json is not a regular file"* ]]
}

@test "--write refuses a FIFO named .claude promptly and writes nothing" {
  seed_repo_for_link_tests
  mkfifo "$FAKE_REPO/.claude"

  DEADLINE_HIT=0
  run_with_deadline "$FAKE_REPO" --write --force
  [ "$DEADLINE_HIT" -eq 0 ]
  [ "$DEADLINE_RC" -eq 0 ]
  [ -p "$FAKE_REPO/.claude" ]
  [[ "$DEADLINE_ERR" == *"--write skipped: <repo>/.claude is a symlink or not a directory"* ]]
}

@test "--write creates a new cast.json with mode 0666 & ~umask, not a fixed 0644" {
  git_init "$FAKE_REPO"
  printf '%s\n' '{"dependencies":{"vite":"^5.0.0"}}' > "$FAKE_REPO/package.json"

  run bash -c "umask 002; bash '$SCRIPT' '$FAKE_REPO' --write --force"
  [ "$status" -eq 0 ]

  [ "$(python3 -c "import os,sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777))" "$FAKE_REPO/.claude/cast.json")" = "0o664" ]

  # second umask: a hard-coded 0664 would also pass the first case, but not this one
  rm -rf "$FAKE_REPO/.claude"
  run bash -c "umask 027; bash '$SCRIPT' '$FAKE_REPO' --write --force"
  [ "$status" -eq 0 ]
  [ "$(python3 -c "import os,sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777))" "$FAKE_REPO/.claude/cast.json")" = "0o640" ]
}
