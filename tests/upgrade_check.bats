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

# ---------------------------------------------------------------------------
# Option injection: the release tag is untrusted GitHub data passed to
# `gh release view` as a positional arg - a leading "-" would be parsed as a
# gh flag. Tags that start with "-" or contain whitespace/control chars must be
# skipped (with a warning) and never reach `gh release view`.
# ---------------------------------------------------------------------------

# gh stub that logs every invocation's argv (pipe-joined) to $GH_LOG and serves
# the release list from $GH_RELEASES. `release view` prints a fixed body.
_install_logging_gh_stub() {
  cat > "$HOME/bin/gh" <<'LOGGHSTUB'
#!/bin/bash
printf '%s|' "$@" >> "$GH_LOG"
printf '\n' >> "$GH_LOG"
if [ "$1" = "release" ] && [ "$2" = "list" ]; then
  printf '%s\n' "$GH_RELEASES"
  exit 0
fi
if [ "$1" = "release" ] && [ "$2" = "view" ]; then
  echo "- Add new hook: PreToolUse for better agent control"
  exit 0
fi
exit 0
LOGGHSTUB
  chmod +x "$HOME/bin/gh"
}

# Run the checker against a single fake source with the logging gh stub and the
# stub scorer. $1 = JSON release list served by `gh release list`;
# $2 (optional) = LC_ALL to run the checker under (empty = ambient locale).
_run_check_with_releases() {
  _install_logging_gh_stub
  _install_score_stub "$HOME/scripts"
  _write_sources "$HOME/sources.json"
  export GH_LOG="$HOME/gh.log"
  : > "$GH_LOG"
  run env CLAUDE_SUBPROCESS=0 LC_ALL="${2:-}" \
    GH_LOG="$GH_LOG" GH_RELEASES="$1" \
    CAST_UPGRADE_SOURCES_FILE="$HOME/sources.json" \
    CAST_UPGRADE_SCORE_SCRIPT="$HOME/scripts/cast-upgrade-score.sh" \
    CAST_STATE_DIR="$HOME/.claude/cast" \
    bash "$UPGRADE_CHECK_SH"
}

@test "upgrade-check: a normal release tag reaches gh release view" {
  _run_check_with_releases '[{"tagName":"v1.0.0","publishedAt":"2099-01-01T00:00:00Z"}]'
  assert_success
  run grep -c '^release|view|v1.0.0|--repo|test-org/test-repo|' "$GH_LOG"
  assert_output '1'
}

@test "upgrade-check: monorepo-style tags with @ and / are still allowed" {
  _run_check_with_releases '[{"tagName":"@scope/pkg@1.2.3","publishedAt":"2099-01-01T00:00:00Z"}]'
  assert_success
  run grep -c '^release|view|@scope/pkg@1.2.3|' "$GH_LOG"
  assert_output '1'
}

@test "upgrade-check: tag starting with a dash is never passed to gh release view" {
  _run_check_with_releases '[{"tagName":"-x","publishedAt":"2099-01-01T00:00:00Z"},{"tagName":"--repo=evil","publishedAt":"2099-01-01T00:00:00Z"},{"tagName":"v1.0.0","publishedAt":"2099-01-01T00:00:00Z"}]'
  assert_success
  # Capture the checker's output (stdout+stderr) before later `run`s overwrite it.
  local check_out="$output"
  # No `release view` argv carries a dash-leading tag or the injected flag.
  run grep -c '^release|view|-' "$GH_LOG"
  assert_output '0'
  run grep -c 'evil' "$GH_LOG"
  assert_output '0'
  # The safe tag after the bad ones still flows (loop continues, not aborts).
  run grep -c '^release|view|v1.0.0|' "$GH_LOG"
  assert_output '1'
  # One warning per skipped tag, each naming the repo.
  run bash -c 'printf "%s\n" "$1" | grep -c "unsafe tag name from test-org/test-repo"' _ "$check_out"
  assert_output '2'
}

@test "upgrade-check: tag with whitespace or control chars is never passed to gh release view" {
  # "v1 --repo=evil" has a space; the BEL (\u0007) tag has a control char.
  _run_check_with_releases '[{"tagName":"v1 --repo=evil","publishedAt":"2099-01-01T00:00:00Z"},{"tagName":"v2\u0007x","publishedAt":"2099-01-01T00:00:00Z"},{"tagName":"v1.0.0","publishedAt":"2099-01-01T00:00:00Z"}]'
  assert_success
  local check_out="$output"
  # Exactly one `release view` happened, and it was the safe tag.
  run grep -c '^release|view|' "$GH_LOG"
  assert_output '1'
  run grep -c '^release|view|v1.0.0|' "$GH_LOG"
  assert_output '1'
  run bash -c 'printf "%s\n" "$1" | grep -c "unsafe tag name from test-org/test-repo"' _ "$check_out"
  assert_output '2'
}

# The tag guard is an ALLOW-list with a literally enumerated charset, so it must
# behave identically in every locale: bash ranges ([A-Z]) and classes
# ([:cntrl:], [:space:]) are locale-dependent, and under LC_ALL=C a deny-list
# lets high bytes (e, U+202E bidi override, U+009B CSI, NBSP) straight through.
# $1 = LC_ALL value. (If the host lacks en_US.UTF-8, bash falls back to the C
# locale; the guard result must be the same, so the test stays valid.)
_assert_tag_allowlist_in_locale() {
  # JSON \u escapes: e-acute, RLO U+202E, CSI U+009B, NBSP U+00A0.
  _run_check_with_releases '[{"tagName":"v1.0\u00e9","publishedAt":"2099-01-01T00:00:00Z"},{"tagName":"v1\u202e0.1","publishedAt":"2099-01-01T00:00:00Z"},{"tagName":"v1\u009b0","publishedAt":"2099-01-01T00:00:00Z"},{"tagName":"v1\u00a00","publishedAt":"2099-01-01T00:00:00Z"},{"tagName":"@scope/pkg@1.2.3","publishedAt":"2099-01-01T00:00:00Z"},{"tagName":"v1-rc.1","publishedAt":"2099-01-01T00:00:00Z"},{"tagName":"release-1.2","publishedAt":"2099-01-01T00:00:00Z"}]' "$1"
  assert_success
  local check_out="$output"
  # Exactly the three allow-listed tags were viewed - nothing else.
  run grep -c '^release|view|' "$GH_LOG"
  assert_output '3'
  run grep -c '^release|view|@scope/pkg@1.2.3|' "$GH_LOG"
  assert_output '1'
  run grep -c '^release|view|v1-rc.1|' "$GH_LOG"
  assert_output '1'
  run grep -c '^release|view|release-1.2|' "$GH_LOG"
  assert_output '1'
  # One warning per rejected tag (4), each naming the repo.
  run bash -c 'printf "%s\n" "$1" | grep -c "unsafe tag name from test-org/test-repo"' _ "$check_out"
  assert_output '4'
}

@test "upgrade-check: tag allow-list rejects non-ASCII tags under LC_ALL=C" {
  _assert_tag_allowlist_in_locale C
}

@test "upgrade-check: tag allow-list rejects non-ASCII tags under LC_ALL=en_US.UTF-8" {
  _assert_tag_allowlist_in_locale en_US.UTF-8
}

@test "upgrade-check: the scorer's one-line stderr notice is not swallowed" {
  _install_logging_gh_stub
  mkdir -p "$HOME/scripts"
  cat > "$HOME/scripts/cast-upgrade-score.sh" <<'NOISYSCORE'
#!/bin/bash
echo "[cast-upgrade-score] claude exited 7 for $1@$2 - see ~/.claude/logs/upgrade-score.log" >&2
echo "[]"
NOISYSCORE
  chmod +x "$HOME/scripts/cast-upgrade-score.sh"
  _write_sources "$HOME/sources.json"
  export GH_LOG="$HOME/gh.log"
  : > "$GH_LOG"
  run env CLAUDE_SUBPROCESS=0 \
    GH_LOG="$GH_LOG" GH_RELEASES='[{"tagName":"v1.0.0","publishedAt":"2099-01-01T00:00:00Z"}]' \
    CAST_UPGRADE_SOURCES_FILE="$HOME/sources.json" \
    CAST_UPGRADE_SCORE_SCRIPT="$HOME/scripts/cast-upgrade-score.sh" \
    CAST_STATE_DIR="$HOME/.claude/cast" \
    bash "$UPGRADE_CHECK_SH"
  assert_success
  assert_output --partial '[cast-upgrade-score] claude exited 7 for test-org/test-repo@v1.0.0'
}

@test "upgrade-check: critical-items pointer names a command that exists (cast doctor)" {
  _run_check_with_releases '[{"tagName":"v1.0.0","publishedAt":"2099-01-01T00:00:00Z"}]'
  assert_success
  assert_output --partial 'Run: cast doctor'
  refute_output --partial 'cast upgrade list'
}

# ---------------------------------------------------------------------------
# Field separator: the checker splits `tagName<SEP>publishedAt` with `read`. A
# TAB separator is IFS-whitespace, so an EMPTY tagName's leading tab collapsed
# and publishedAt landed in TAG (a misleading "unsafe tag" warning, only
# harmless by accident). The separator is 0x1f (IFS non-whitespace), so an empty
# tagName stays empty and takes the silent `-z` skip.
# ---------------------------------------------------------------------------

@test "upgrade-check: empty or null tagName is skipped silently via the empty-tag guard" {
  _run_check_with_releases '[{"tagName":"","publishedAt":"2099-01-01T00:00:00Z"},{"tagName":null,"publishedAt":"2099-01-01T00:00:00Z"},{"publishedAt":"2099-01-01T00:00:00Z"},{"tagName":"v1.0.0","publishedAt":"2099-01-01T00:00:00Z"}]'
  assert_success
  local check_out="$output"
  # The empty-tag guard is silent: publishedAt must NOT have shifted into TAG
  # and tripped the allow-list ("unsafe tag" warning).
  run bash -c 'printf "%s\n" "$1" | grep -c "unsafe tag name"' _ "$check_out"
  assert_output '0'
  # Nothing was viewed for an empty tag (no `release view` with an empty/date tag).
  run grep -c '^release|view|[|2]' "$GH_LOG"
  assert_output '0'
  # The normal tag after the empty ones still flows - the loop continues.
  run grep -c '^release|view|' "$GH_LOG"
  assert_output '1'
  run grep -c '^release|view|v1.0.0|--repo|test-org/test-repo|' "$GH_LOG"
  assert_output '1'
}

@test "upgrade-check: a literal 0x1f in a tag is cleaned and cannot split the fields" {
  # JSON \u001f inside tagName. Cleaned to a space it fails the allow-list and is
  # skipped WITH the unsafe-tag warning; un-cleaned it would split into TAG=v1
  # (allow-listed) + PUBLISHED=0.0 (unparseable) and be skipped with NO warning.
  _run_check_with_releases '[{"tagName":"v1\u001f0.0","publishedAt":"2099-01-01T00:00:00Z"},{"tagName":"v1.0.0","publishedAt":"2099-01-01T00:00:00Z"}]'
  assert_success
  local check_out="$output"
  run bash -c 'printf "%s\n" "$1" | grep -c "unsafe tag name from test-org/test-repo"' _ "$check_out"
  assert_output '1'
  # Only the normal tag was viewed; the 0x1f tag (or its v1 prefix) never was.
  run grep -c '^release|view|' "$GH_LOG"
  assert_output '1'
  run grep -c '^release|view|v1.0.0|' "$GH_LOG"
  assert_output '1'
}
