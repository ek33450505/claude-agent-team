#!/usr/bin/env bats
# tests/scripts/cast-stack-detect.bats
# Tests for scripts/cast-stack-detect.sh
# All tests are isolated to BATS_TEST_TMPDIR — never touch real $HOME or the repo.

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
SCRIPT="$REPO_DIR/scripts/cast-stack-detect.sh"

setup() {
  FAKE_REPO="$BATS_TEST_TMPDIR/fake-repo"
  mkdir -p "$FAKE_REPO"
  unset CLAUDE_SUBPROCESS
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
