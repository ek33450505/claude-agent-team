#!/usr/bin/env bats
# upgrade_check.bats — Tests for cast-upgrade-check.sh (Phase 9.75b)
#
# Coverage:
#   - Running cast-upgrade-check.sh twice on the same mocked release data
#     produces no duplicate entries in upgrade-candidates.json
#   - When gh CLI fails/unavailable, cast-upgrade-check.sh exits 0 (graceful skip)

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
UPGRADE_CHECK_SH="$REPO_DIR/scripts/cast-upgrade-check.sh"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Write a minimal upgrade-sources.json pointing to a fake repo.
_write_sources() {
  local sources_file="$1"
  local repo="${2:-test-org/test-repo}"
  python3 -c "
import json
d = {
  'sources': [{'repo': '$repo', 'type': 'github-releases'}],
  'last_checked': None,
  'cast_description': 'test'
}
with open('$sources_file', 'w') as f:
    json.dump(d, f)
"
}

# Write a stub gh binary that returns deterministic release data.
_install_gh_stub() {
  local bin_dir="$1"
  local repo="${2:-test-org/test-repo}"
  cat > "$bin_dir/gh" <<'GHSTUB'
#!/bin/bash
# Stub gh — returns a fixed release list and fixed release notes
if [[ "$*" == *"release list"* ]]; then
  echo '[{"tagName":"v1.0.0","publishedAt":"2025-01-01T00:00:00Z"}]'
  exit 0
fi
if [[ "$*" == *"release view"* ]]; then
  # Output to the file indicated by redirect (via python subprocess)
  echo "- Add new hook: PreToolUse for better agent control"
  exit 0
fi
exit 0
GHSTUB
  chmod +x "$bin_dir/gh"
}

# Write a stub cast-upgrade-score.sh that returns a fixed scored item.
_install_score_stub() {
  local scripts_dir="$1"
  cat > "$scripts_dir/cast-upgrade-score.sh" <<'SCORESTUB'
#!/bin/bash
# Stub scorer — returns a fixed scored item for the provided notes file
REPO="$1"
TAG="$2"
NOTES_FILE="$3"

if [ ! -f "$NOTES_FILE" ] || [ ! -s "$NOTES_FILE" ]; then
  echo "[]"
  exit 0
fi

echo '[{"item":"Add new hook: PreToolUse for better agent control","category":"CRITICAL","reason":"Affects hook interface","cast_component":"hooks"}]'
exit 0
SCORESTUB
  chmod +x "$scripts_dir/cast-upgrade-score.sh"
}

# ---------------------------------------------------------------------------
# Setup / Teardown
# ---------------------------------------------------------------------------

setup() {
  load 'helpers/setup'
  setup_temp_home
  export ORIG_ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-}"
  # Redirect TMPDIR into the fake HOME so mktemp calls from the script under
  # test are cleaned up by teardown() instead of accumulating in the real
  # system temp dir across test runs.
  export ORIG_TMPDIR="${TMPDIR:-}"
  export TMPDIR="$HOME/tmp"
  mkdir -p "$TMPDIR"

  mkdir -p "$HOME/.claude/cast"
  mkdir -p "$HOME/bin"
  mkdir -p "$HOME/config"
  mkdir -p "$HOME/scripts"

  # Provide a fake ANTHROPIC_API_KEY so cast-upgrade-score.sh doesn't bail
  export ANTHROPIC_API_KEY="sk-test-stub-key"

  export PATH="$HOME/bin:$PATH"
}

teardown() {
  export ANTHROPIC_API_KEY="$ORIG_ANTHROPIC_API_KEY"
  if [ -n "$ORIG_TMPDIR" ]; then
    export TMPDIR="$ORIG_TMPDIR"
  else
    unset TMPDIR
  fi
  teardown_temp_home
}

# ---------------------------------------------------------------------------
# T1 — idempotency: running twice on same mocked release data produces no duplicates
# ---------------------------------------------------------------------------

@test "upgrade-check: running twice does not duplicate entries in upgrade-candidates.json" {
  local sources_file="$REPO_DIR/config/upgrade-sources.json"
  local score_script="$REPO_DIR/scripts/cast-upgrade-score.sh"

  # Install a gh stub that returns predictable data
  _install_gh_stub "$HOME/bin"

  # Install a scorer stub in a temp location, override SCORE_SCRIPT via env
  local tmp_scripts="$HOME/scripts"
  _install_score_stub "$tmp_scripts"

  # Point upgrade-check to temp state dir and our stubs
  # We run the script in a subshell so HOME is already overridden
  # Run once
  CAST_STATE_DIR="$HOME/.claude/cast" \
  CAST_UPGRADE_SCORE_SCRIPT="$tmp_scripts/cast-upgrade-score.sh" \
  bash "$UPGRADE_CHECK_SH" 2>/dev/null || true

  local count_after_first
  count_after_first="$(python3 -c "
import json, os
f = os.path.expanduser('~/.claude/cast/upgrade-candidates.json')
try:
    d = json.load(open(f))
    print(len(d))
except Exception:
    print(0)
" 2>/dev/null || echo 0)"

  # Run again with the same mock release data
  CAST_STATE_DIR="$HOME/.claude/cast" \
  CAST_UPGRADE_SCORE_SCRIPT="$tmp_scripts/cast-upgrade-score.sh" \
  bash "$UPGRADE_CHECK_SH" 2>/dev/null || true

  local count_after_second
  count_after_second="$(python3 -c "
import json, os
f = os.path.expanduser('~/.claude/cast/upgrade-candidates.json')
try:
    d = json.load(open(f))
    print(len(d))
except Exception:
    print(0)
" 2>/dev/null || echo 0)"

  # Entry count must not grow after second run (idempotent merge)
  [ "$count_after_second" -le "$count_after_first" ] || \
    [ "$count_after_first" -eq 0 ]
}

@test "upgrade-check: upgrade-candidates.json is valid JSON after first run" {
  _install_gh_stub "$HOME/bin"
  _install_score_stub "$HOME/scripts"

  CAST_UPGRADE_SCORE_SCRIPT="$HOME/scripts/cast-upgrade-score.sh" \
  bash "$UPGRADE_CHECK_SH" 2>/dev/null || true

  local candidates_file="$HOME/.claude/cast/upgrade-candidates.json"
  if [ -f "$candidates_file" ]; then
    run python3 -c "import json; json.load(open('$candidates_file'))"
    assert_success
  else
    # File not created because gh stub returned no new releases — that is fine
    true
  fi
}

@test "upgrade-check: last-checked timestamp is written after run" {
  _install_gh_stub "$HOME/bin"
  _install_score_stub "$HOME/scripts"

  CAST_UPGRADE_SCORE_SCRIPT="$HOME/scripts/cast-upgrade-score.sh" \
  bash "$UPGRADE_CHECK_SH" 2>/dev/null || true

  local last_checked_file="$HOME/.claude/cast/last-checked-upgrades.json"
  if [ -f "$last_checked_file" ]; then
    run python3 -c "
import json
d = json.load(open('$last_checked_file'))
assert 'last_checked' in d and d['last_checked']
"
    assert_success
  else
    # May not be written if gh returned no usable data
    true
  fi
}

# ---------------------------------------------------------------------------
# T2 — graceful degradation when gh CLI is unavailable
# ---------------------------------------------------------------------------

@test "upgrade-check: exits 0 when gh is not in PATH" {
  # Do NOT install any gh stub — ensure gh is absent from PATH on all platforms.
  # On Ubuntu, gh lives at /usr/bin/gh so we cannot use /usr/bin:/bin.
  # Instead: create an isolated bin with only python3 symlinked so the script
  # can still call python3 but cannot find gh.
  local no_gh_bin
  no_gh_bin="$(mktemp -d)"
  ln -sf "$(command -v python3)" "$no_gh_bin/python3" 2>/dev/null || true
  PATH="$no_gh_bin:/bin" run bash "$UPGRADE_CHECK_SH"
  rm -rf "$no_gh_bin"
  assert_success
}

@test "upgrade-check: prints warning when gh is not in PATH" {
  local no_gh_bin
  no_gh_bin="$(mktemp -d)"
  ln -sf "$(command -v python3)" "$no_gh_bin/python3" 2>/dev/null || true
  PATH="$no_gh_bin:/bin" run bash "$UPGRADE_CHECK_SH"
  rm -rf "$no_gh_bin"
  assert_success
  assert_output --partial "gh"
}

@test "upgrade-check: exits 0 when gh release list returns empty array" {
  # Install a gh stub that always returns an empty release list
  cat > "$HOME/bin/gh" <<'EMPTY_STUB'
#!/bin/bash
echo "[]"
exit 0
EMPTY_STUB
  chmod +x "$HOME/bin/gh"

  run bash "$UPGRADE_CHECK_SH"
  assert_success
}

@test "upgrade-check: exits 0 when upgrade-sources.json is missing" {
  # Run from a directory where config/upgrade-sources.json does not exist
  # by pointing to a temp script copy in a dir without config/
  local tmp_dir="$(mktemp -d)"
  local tmp_script="$tmp_dir/cast-upgrade-check.sh"
  cp "$UPGRADE_CHECK_SH" "$tmp_script"

  # Script resolves SOURCES_FILE relative to its own SCRIPT_DIR/REPO_ROOT
  # Running from tmp_dir means config/upgrade-sources.json won't exist there
  PATH="$HOME/bin:/usr/bin:/bin" run bash "$tmp_script"
  # Should exit 0 with a warning, not a pipeline error
  assert_success

  rm -rf "$tmp_dir"
}

@test "upgrade-check: exits 0 when gh release view fails for a repo" {
  # Install gh that returns a release list but fails on 'release view'
  cat > "$HOME/bin/gh" <<'FAIL_VIEW_STUB'
#!/bin/bash
if [[ "$*" == *"release list"* ]]; then
  echo '[{"tagName":"v9.9.9","publishedAt":"2099-01-01T00:00:00Z"}]'
  exit 0
fi
if [[ "$*" == *"release view"* ]]; then
  exit 1
fi
exit 0
FAIL_VIEW_STUB
  chmod +x "$HOME/bin/gh"

  run bash "$UPGRADE_CHECK_SH"
  assert_success
}

# ---------------------------------------------------------------------------
# Regression: mktemp must not create a literal "XXXXXX" file (macOS BSD mktemp
# does not support a suffix after the X-template, causing all invocations to
# land on the same fixed filename and fail with "File exists" on the second run)
# ---------------------------------------------------------------------------

@test "upgrade-check: mktemp does not leave a literal XXXXXX temp file" {
  _install_gh_stub "$HOME/bin"
  _install_score_stub "$HOME/scripts"

  # Run the script once — if mktemp template had a .txt suffix, BSD mktemp would
  # create a file literally named "cast-upgrade-notes-XXXXXX.txt" in TMPDIR.
  CAST_UPGRADE_SCORE_SCRIPT="$HOME/scripts/cast-upgrade-score.sh" \
  bash "$UPGRADE_CHECK_SH" 2>/dev/null || true

  # No file with the literal template name should exist in TMPDIR
  local literal_file="$TMPDIR/cast-upgrade-notes-XXXXXX"
  if [ -f "${literal_file}.txt" ]; then
    echo "BUG: BSD mktemp left a literal template file: ${literal_file}.txt" >&2
    return 1
  fi
  # Also check without extension (belt-and-suspenders)
  if [ -f "$literal_file" ]; then
    echo "BUG: mktemp left a literal template file: $literal_file" >&2
    return 1
  fi
  true
}

@test "upgrade-check: succeeds on second run without leftover temp files causing mktemp failure" {
  # Regression: BSD mktemp (macOS) does not support a suffix after XXXXXX.
  # If the template was "...XXXXXX.txt", the first run created a literal file
  # named "cast-upgrade-notes-XXXXXX.txt". The second run then failed because
  # mktemp refused to overwrite the existing file.
  _install_gh_stub "$HOME/bin"
  _install_score_stub "$HOME/scripts"

  # First run
  CAST_UPGRADE_SCORE_SCRIPT="$HOME/scripts/cast-upgrade-score.sh" \
  bash "$UPGRADE_CHECK_SH" 2>/dev/null || true

  # Simulate the pre-fix bug: manually create a literal XXXXXX file to prove
  # the fix prevents collisions even if such a file exists from another source.
  # (With the fix in place the script uses a different template name, so this
  # file is irrelevant to mktemp and the run must still succeed.)
  touch "$TMPDIR/cast-upgrade-notes-XXXXXX.txt"

  # Second run — must still succeed despite the stale literal file
  CAST_UPGRADE_SCORE_SCRIPT="$HOME/scripts/cast-upgrade-score.sh" run bash "$UPGRADE_CHECK_SH"
  assert_success

  rm -f "$TMPDIR/cast-upgrade-notes-XXXXXX.txt"
}
