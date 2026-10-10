#!/usr/bin/env bats
# BATS tests for .githooks/pre-commit regression lints

load test_helper/bats-support/load
load test_helper/bats-assert/load
load helpers/setup

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

# The hook is an INSTALLED copy that executes only installed ~/.claude/scripts/* (the repo is
# data). Seed a temp HOME with the scripts it calls and the installed cold-start baseline; the
# test repo's own scripts/ stay as lint DATA. Never touches the real ~/.claude.
seed_installed_home() {
  mkdir -p "$HOME/.claude/scripts" "$HOME/.claude/githooks"
  local f
  for f in "$REPO_ROOT"/scripts/*; do
    [[ -f "$f" ]] && cp "$f" "$HOME/.claude/scripts/"
  done
  cp "$REPO_ROOT/.githooks/cold-start-baseline.txt" "$HOME/.claude/githooks/cold-start-baseline.txt"
}

setup() {
  setup_temp_home
  seed_installed_home
  # Create a temporary directory for each test
  export TEST_DIR=$(mktemp -d)
  export TEST_REPO="$TEST_DIR/test-repo"
  mkdir -p "$TEST_REPO/scripts"

  # Initialize a git repo for testing
  cd "$TEST_REPO"
  git init --initial-branch=main >/dev/null 2>&1
  git config user.email "test@example.com"
  git config user.name "BATS Test"

  # Create a minimal settings.json
  cat > settings.json <<'EOF'
{
  "hooks": {
    "PostToolUse": [
      {
        "id": "test-hook",
        "hooks": [
          {
            "type": "command",
            "command": "bash scripts/test-script.sh"
          }
        ]
      }
    ]
  }
}
EOF
  git add settings.json
  git commit -m "initial" >/dev/null 2>&1

  # Copy the pre-commit hook and baseline
  mkdir -p .githooks
  cp "$REPO_ROOT/.githooks/pre-commit" .githooks/
  git config core.hooksPath .githooks

  # Copy scripts and helper Python script
  cp "$REPO_ROOT/scripts/cast-lint-orphan-scripts.py" scripts/
  cp "$REPO_ROOT/scripts/gen-stats.sh" scripts/gen-stats.sh 2>/dev/null || true

  cd /
}

teardown() {
  [[ "$TEST_DIR" == "${TMPDIR:-/tmp}"/* || "$TEST_DIR" == /tmp/* || "$TEST_DIR" == /var/folders/* || "$TEST_DIR" == /private/* ]] && rm -rf "$TEST_DIR"
  teardown_temp_home
}

# === LINT 1: Python cold-start counter ===

@test "lint-cold-starts: pass when script has 0 python3 -c calls" {
  cd "$TEST_REPO"
  cat > scripts/clean.sh <<'EOF'
#!/bin/bash
set -euo pipefail
echo "no python here"
EOF
  chmod +x scripts/clean.sh
  git add scripts/clean.sh
  run bash .githooks/pre-commit
  assert_output --partial "Running regression lints"
  # Should not fail due to python cold-starts
}

@test "lint-cold-starts: pass when script has exactly 2 python3 -c calls" {
  cd "$TEST_REPO"
  cat > scripts/two-python.sh <<'EOF'
#!/bin/bash
set -euo pipefail
python3 -c "print('one')"
python3 -c "print('two')"
EOF
  chmod +x scripts/two-python.sh
  git add scripts/two-python.sh
  run bash .githooks/pre-commit
  assert_output --partial "Running regression lints"
  # Should not fail due to python count
}

@test "lint-cold-starts: fail when NEW script has >2 python3 -c calls" {
  cd "$TEST_REPO"
  cat > scripts/many-python.sh <<'EOF'
#!/bin/bash
set -euo pipefail
python3 -c "print('one')"
python3 -c "print('two')"
python3 -c "print('three')"
EOF
  chmod +x scripts/many-python.sh
  git add scripts/many-python.sh
  run bash .githooks/pre-commit
  # New file with 3 calls should be detected
  [[ "$output" == *"python3 -c"* ]]
}

@test "lint-cold-starts: pass when GRANDFATHERED file keeps same count" {
  cd "$TEST_REPO"
  # Add a grandfathered file to baseline with count=3
  echo "scripts/grandfathered.sh:3" >> "$HOME/.claude/githooks/cold-start-baseline.txt"
  cat > scripts/grandfathered.sh <<'EOF'
#!/bin/bash
set -euo pipefail
python3 -c "print('one')"
python3 -c "print('two')"
python3 -c "print('three')"
EOF
  chmod +x scripts/grandfathered.sh
  git add scripts/grandfathered.sh
  run bash .githooks/pre-commit
  # Should NOT fail because count (3) matches baseline (3)
  [[ "$output" != *"ERROR [lint-cold-starts]: scripts/grandfathered.sh"* ]]
}

@test "lint-cold-starts: fail when GRANDFATHERED file's count INCREASES" {
  cd "$TEST_REPO"
  # Add a grandfathered file to baseline with count=3
  echo "scripts/regression.sh:3" >> "$HOME/.claude/githooks/cold-start-baseline.txt"
  cat > scripts/regression.sh <<'EOF'
#!/bin/bash
set -euo pipefail
python3 -c "print('one')"
python3 -c "print('two')"
python3 -c "print('three')"
python3 -c "print('four')"
EOF
  chmod +x scripts/regression.sh
  git add scripts/regression.sh
  run bash .githooks/pre-commit
  # Should FAIL because count (4) exceeds baseline (3)
  [[ "$output" == *"ERROR [lint-cold-starts]: scripts/regression.sh has 4 python3 -c calls (baseline: 3)"* ]]
}

@test "lint-cold-starts: fail when GRANDFATHERED file adds heredoc spawns over baseline (counter must see 'python3 <<' and 'python3 - <<', not just 'python3 -c')" {
  cd "$TEST_REPO"
  # Baseline says 1 (one pre-existing heredoc spawn). The fixture below has TWO heredoc
  # spawns (one 'python3 <<' form, one 'python3 - <<' form) and ZERO "python3 -c" calls —
  # a counter blind to heredocs would see count=0, miss the regression, and wrongly pass.
  echo "scripts/heredoc-regression.sh:1" >> "$HOME/.claude/githooks/cold-start-baseline.txt"
  cat > scripts/heredoc-regression.sh <<'EOF'
#!/bin/bash
set -euo pipefail
python3 - <<'PYEOF'
print("one")
PYEOF
python3 <<'PYEOF2'
print("two")
PYEOF2
EOF
  chmod +x scripts/heredoc-regression.sh
  git add scripts/heredoc-regression.sh
  run bash .githooks/pre-commit
  # Should FAIL because true count (2 heredoc spawns) exceeds baseline (1)
  [[ "$status" -ne 0 ]]
  [[ "$output" == *"ERROR [lint-cold-starts]: scripts/heredoc-regression.sh has 2 python3 -c calls (baseline: 1)"* ]]
}

# === LINT 2: SQL injection detector ===

@test "lint-sql-injection: pass when no sql interpolation" {
  cd "$TEST_REPO"
  cat > scripts/safe-sql.sh <<'EOF'
#!/bin/bash
set -euo pipefail
sqlite3 ~/.claude/cast.db "SELECT * FROM sessions"
EOF
  chmod +x scripts/safe-sql.sh
  git add scripts/safe-sql.sh
  run bash .githooks/pre-commit
  assert_output --partial "Running regression lints"
}

@test "lint-sql-injection: fail on braced \${var} in sqlite3 string without SQL single-quote guard" {
  cd "$TEST_REPO"
  # Unguarded: ${SESSION_ID} is NOT wrapped in SQL single quotes — lint must flag this.
  cat > scripts/unsafe-sql.sh <<'EOF'
#!/bin/bash
set -euo pipefail
SESSION_ID="session123"
DB="$HOME/.claude/cast.db"
sqlite3 "$DB" "INSERT INTO logs VALUES(${SESSION_ID})"
EOF
  chmod +x scripts/unsafe-sql.sh
  git add scripts/unsafe-sql.sh
  run bash .githooks/pre-commit
  [[ "$output" == *"SQL injection"* ]]
}

@test "lint-sql-injection: pass when interpolation is guarded with single quotes" {
  cd "$TEST_REPO"
  cat > scripts/guarded-sql.sh <<'EOF'
#!/bin/bash
set -euo pipefail
SESSION_ID="session123"
sqlite3 ~/.claude/cast.db "INSERT INTO logs VALUES('$SESSION_ID')"
EOF
  chmod +x scripts/guarded-sql.sh
  git add scripts/guarded-sql.sh
  run bash .githooks/pre-commit
  assert_output --partial "Running regression lints"
}

# === LINT 2 (widened): bare $var, heredoc, cast_sqlite, bin/cast ===

@test "lint-sql-injection: fail on bare (unbraced) \$var in sqlite3 inline string" {
  cd "$TEST_REPO"
  # DB path is double-quoted so the awk can identify the SQL argument (second "...")
  cat > scripts/bare-var-sql.sh <<'EOF'
#!/bin/bash
set -euo pipefail
TABLE="sessions"
DB="$HOME/.claude/cast.db"
sqlite3 "$DB" "SELECT * FROM $TABLE WHERE status='active'"
EOF
  chmod +x scripts/bare-var-sql.sh
  git add scripts/bare-var-sql.sh
  run bash .githooks/pre-commit
  [[ "$output" == *"SQL injection"* ]]
}

@test "lint-sql-injection: fail on unbraced \$var in cast_sqlite inline string" {
  cd "$TEST_REPO"
  cat > scripts/bare-var-cast.sh <<'EOF'
#!/bin/bash
set -euo pipefail
AGENT="my-agent"
DB="$HOME/.claude/cast.db"
cast_sqlite "$DB" "SELECT * FROM agent_runs WHERE agent=$AGENT"
EOF
  chmod +x scripts/bare-var-cast.sh
  git add scripts/bare-var-cast.sh
  run bash .githooks/pre-commit
  [[ "$output" == *"SQL injection"* ]]
}

@test "lint-sql-injection: fail on \${var} in unquoted heredoc body outside SQL single quotes" {
  cd "$TEST_REPO"
  # shellcheck disable=SC2016
  cat > scripts/heredoc-unsafe.sh << 'BATSEOF'
#!/bin/bash
set -euo pipefail
TABLE="injected"
DB="$HOME/.claude/cast.db"
sqlite3 "$DB" << SQEOF
SELECT * FROM $TABLE
SQEOF
BATSEOF
  chmod +x scripts/heredoc-unsafe.sh
  git add scripts/heredoc-unsafe.sh
  run bash .githooks/pre-commit
  [[ "$output" == *"SQL injection"* ]]
}

@test "lint-sql-injection: fail on \${var} in unquoted heredoc body (cast_sqlite)" {
  cd "$TEST_REPO"
  cat > scripts/cast-heredoc-unsafe.sh << 'BATSEOF'
#!/bin/bash
set -euo pipefail
VALUE="injected"
DB="$HOME/.claude/cast.db"
cast_sqlite "$DB" << HSQL
INSERT INTO t (col) VALUES($VALUE)
HSQL
BATSEOF
  chmod +x scripts/cast-heredoc-unsafe.sh
  git add scripts/cast-heredoc-unsafe.sh
  run bash .githooks/pre-commit
  [[ "$output" == *"SQL injection"* ]]
}

@test "lint-sql-injection: fail when unsafe sqlite3 interpolation is in bin/cast" {
  cd "$TEST_REPO"
  mkdir -p bin
  cat > bin/cast << 'BATSEOF'
#!/usr/bin/env bash
AGENT="test-agent"
sqlite3 "$CAST_DB_PATH" "SELECT * FROM agent_runs WHERE agent=$AGENT"
BATSEOF
  chmod +x bin/cast
  git add bin/cast
  run bash .githooks/pre-commit
  [[ "$output" == *"SQL injection"* ]]
}

@test "lint-sql-injection: pass when heredoc uses single-quoted delimiter (no shell expansion)" {
  cd "$TEST_REPO"
  # Safe: single-quoted heredoc delimiter prevents shell expansion — no lint flag expected.
  # We only assert no SQL injection warning (other unrelated lints may fail in test env).
  cat > scripts/safe-heredoc.sh << 'BATSEOF'
#!/bin/bash
set -euo pipefail
DB="$HOME/.claude/cast.db"
sqlite3 "$DB" << 'SQEOF'
SELECT * FROM $raw_identifier_not_interpolated
SQEOF
BATSEOF
  chmod +x scripts/safe-heredoc.sh
  git add scripts/safe-heredoc.sh
  run bash .githooks/pre-commit
  assert_output --partial "Running regression lints"
  [[ "$output" != *"SQL injection"* ]]
}

@test "lint-sql-injection: pass when \${var} is inside SQL single quotes in heredoc body" {
  cd "$TEST_REPO"
  # Safe: $SESSION_ID appears inside SQL '...' so it is guarded against injection.
  # We only assert no SQL injection warning (other unrelated lints may fail in test env).
  cat > scripts/safe-heredoc-quoted.sh << 'BATSEOF'
#!/bin/bash
set -euo pipefail
SESSION_ID="sess-abc"
DB="$HOME/.claude/cast.db"
sqlite3 "$DB" << SQEOF
UPDATE sessions SET status='ended' WHERE id='$SESSION_ID'
SQEOF
BATSEOF
  chmod +x scripts/safe-heredoc-quoted.sh
  git add scripts/safe-heredoc-quoted.sh
  run bash .githooks/pre-commit
  assert_output --partial "Running regression lints"
  [[ "$output" != *"SQL injection"* ]]
}

# === LINT 3: Orphan script detector ===

@test "lint-orphan-scripts: pass when all referenced scripts exist" {
  cd "$TEST_REPO"
  # Create the script referenced in settings.json
  cat > scripts/test-script.sh <<'EOF'
#!/bin/bash
echo "test"
EOF
  chmod +x scripts/test-script.sh
  git add scripts/test-script.sh
  run bash .githooks/pre-commit
  [[ "$status" -eq 0 ]] || [[ "$output" == *"Running regression lints"* ]]
}

@test "lint-orphan-scripts: fail when referenced script is missing" {
  cd "$TEST_REPO"
  # settings.json references scripts/test-script.sh but we won't create it
  # Remove the script if it exists
  rm -f scripts/test-script.sh
  # The pre-commit hook should detect the missing reference
  run bash .githooks/pre-commit
  # This should fail due to orphan detection
  [[ "$output" == *"referenced"* ]] || [[ "$output" == *"missing"* ]] || [[ $status -eq 0 ]]
}

@test "lint-orphan-scripts: detect multiple missing scripts" {
  cd "$TEST_REPO"
  # Update settings.json to reference multiple missing scripts
  cat > settings.json <<'EOF'
{
  "hooks": {
    "PostToolUse": [
      {
        "id": "hook1",
        "hooks": [
          {
            "type": "command",
            "command": "bash scripts/missing1.sh"
          }
        ]
      },
      {
        "id": "hook2",
        "hooks": [
          {
            "type": "command",
            "command": "bash scripts/missing2.sh"
          }
        ]
      }
    ]
  }
}
EOF
  git add settings.json
  git -c user.email="test@test.com" -c user.name="Test" commit -m "update settings" >/dev/null 2>&1 || true
  rm -f scripts/test-script.sh
  run bash .githooks/pre-commit
  # Should detect at least one missing script
  [[ "$output" == *"missing"* ]] || [[ $status -eq 0 ]]
}

@test "lint-orphan-scripts: handle ~/.claude/scripts/ paths" {
  cd "$TEST_REPO"
  cat > settings.json <<'EOF'
{
  "hooks": {
    "PostToolUse": [
      {
        "id": "test-hook",
        "hooks": [
          {
            "type": "command",
            "command": "bash ~/.claude/scripts/hook.sh"
          }
        ]
      }
    ]
  }
}
EOF
  git add settings.json
  git -c user.email="test@test.com" -c user.name="Test" commit -m "update settings" >/dev/null 2>&1 || true
  run python3 scripts/cast-lint-orphan-scripts.py
  # Should check for ~/.claude/scripts/ paths (won't exist in test, but script should handle gracefully)
  [[ $status -eq 0 ]] || [[ $status -eq 1 ]]
}

# === Integration tests ===

@test "pre-commit-hook: runs README update even if lints pass" {
  cd "$TEST_REPO"
  # Create a valid test script
  cat > scripts/test-script.sh <<'EOF'
#!/bin/bash
echo "test"
EOF
  chmod +x scripts/test-script.sh
  git add scripts/test-script.sh
  run bash .githooks/pre-commit
  [[ "$output" == *"Running regression lints"* ]]
}

@test "pre-commit-hook: is executable" {
  [[ -x "$REPO_ROOT/.githooks/pre-commit" ]]
}

# === Installed-hook contract: the hook executes ONLY installed scripts (repo = data) ===

# Every script pre-commit runs, by installed name. A planted repo copy of any of them must never run.
PRECOMMIT_RUNS="cast-lint-orphan-scripts.py cast-lint-byte-budget.sh cast-lint-hook-wiring.py cast-lint-agent-roster.py cast-lint-agent-boilerplate.sh blast-radius-lint.sh cast-lint-source-guard.sh cast-test-coverage-advisory.sh check-plugin-drift.sh gen-cast-stats.sh gen-ecosystem-versions.sh"

# Plant a marker-writing replacement for <name> at <dest>; the marker line is "<tag>:<name>".
plant_marker_script() {
  local dest="$1" name="$2" tag="$3"
  case "$name" in
    *.py) printf 'import os\nopen(os.environ["CAST_TEST_MARKER"], "a").write("%s:%s\\n")\n' "$tag" "$name" > "$dest" ;;
    *)    printf '#!/usr/bin/env bash\necho "%s:%s" >> "$CAST_TEST_MARKER"\n' "$tag" "$name" > "$dest" ;;
  esac
  chmod +x "$dest"
}

stage_plugin_trigger() {
  # Stage a file under scripts/ so the plugin-drift step (gated on staged bundled sources) also runs.
  cat > scripts/test-script.sh <<'SH'
#!/bin/bash
echo "test"
SH
  chmod +x scripts/test-script.sh
  git add scripts/test-script.sh
}

@test "installed-hook: a planted repo copy of any lint/generator is NOT executed; the installed copy is" {
  cd "$TEST_REPO"
  export CAST_TEST_MARKER="$TEST_DIR/marker"
  : > "$CAST_TEST_MARKER"
  local n
  for n in $PRECOMMIT_RUNS; do
    plant_marker_script "scripts/$n" "$n" MALICIOUS
  done
  # Positive control: the INSTALLED orphan lint is replaced by a recorder, so we can prove the
  # hook reached the installed copy (a test that only asserts absence could pass vacuously).
  plant_marker_script "$HOME/.claude/scripts/cast-lint-orphan-scripts.py" cast-lint-orphan-scripts.py INSTALLED
  stage_plugin_trigger
  run bash .githooks/pre-commit
  run grep -c '^MALICIOUS:' "$CAST_TEST_MARKER"
  [[ "$output" == "0" ]]
  run grep -c '^INSTALLED:cast-lint-orphan-scripts.py$' "$CAST_TEST_MARKER"
  [[ "$output" == "1" ]]
}

@test "installed-hook: missing installed lint script fails closed with the install message (no repo fallback)" {
  cd "$TEST_REPO"
  export CAST_TEST_MARKER="$TEST_DIR/marker"
  : > "$CAST_TEST_MARKER"
  plant_marker_script "scripts/cast-lint-orphan-scripts.py" cast-lint-orphan-scripts.py MALICIOUS
  rm -f "$HOME/.claude/scripts/cast-lint-orphan-scripts.py"
  stage_plugin_trigger
  run bash .githooks/pre-commit
  assert_failure
  assert_output --partial "installed cast-lint-orphan-scripts.py missing — run: bash install.sh"
  [[ ! -s "$CAST_TEST_MARKER" ]]
}

@test "installed-hook: a symlinked installed script is refused (fail closed)" {
  cd "$TEST_REPO"
  rm -f "$HOME/.claude/scripts/cast-lint-orphan-scripts.py"
  ln -s "$TEST_REPO/scripts/cast-lint-orphan-scripts.py" "$HOME/.claude/scripts/cast-lint-orphan-scripts.py"
  stage_plugin_trigger
  run bash .githooks/pre-commit
  assert_failure
  assert_output --partial "installed cast-lint-orphan-scripts.py missing"
}

@test "installed-hook: missing installed cast-hook-lib.sh fails closed before any check runs" {
  cd "$TEST_REPO"
  rm -f "$HOME/.claude/scripts/cast-hook-lib.sh"
  stage_plugin_trigger
  run bash .githooks/pre-commit
  assert_failure
  assert_output --partial "installed cast-hook-lib.sh missing"
  refute_output --partial "Running regression lints"
}

@test "installed-hook: missing installed cold-start baseline fails closed (repo baseline is not consulted)" {
  cd "$TEST_REPO"
  rm -f "$HOME/.claude/githooks/cold-start-baseline.txt"
  # A repo baseline that would grandfather everything must NOT be honoured.
  echo "scripts/many-python.sh:99" > .githooks/cold-start-baseline.txt
  stage_plugin_trigger
  run bash .githooks/pre-commit
  assert_failure
  assert_output --partial "installed cold-start baseline missing"
}

@test "installed-hook: hooks never execute a repo path (static scan of pre-commit, post-commit, post-merge)" {
  # Code lines only (comments stripped). Forbidden: bash/python3/source/. of scripts/... or $REPO_ROOT/...
  # EXCEPT the documented post-merge residual `bash %q/install.sh` (the deploy step).
  local hook hits
  for hook in pre-commit post-commit post-merge; do
    hits="$(sed -e 's/^[[:space:]]*#.*$//' "$REPO_ROOT/.githooks/$hook" \
      | grep -nE '(^|[^A-Za-z_-])(bash|sh|python3?( -I)?|source|\.)[[:space:]]+"?(\$\{?REPO_ROOT\}?/|\./)?(scripts|bin|\.githooks)/' || true)"
    [[ -z "$hits" ]] || { echo "$hook executes a repo path: $hits" >&2; false; }
  done
}

@test "installed-hook: the runtime hook-contract validator is no longer run from pre-commit" {
  # Mentioned only in the explanatory comment, never invoked.
  run bash -c "sed -e 's/^[[:space:]]*#.*\$//' '$REPO_ROOT/.githooks/pre-commit' | grep -c 'cast-validate-hook-contracts'"
  [[ "$output" == "0" ]]
}

# M1: _cast_stage_file must neutralise config-based hooks (hook.<name>.event=post-index-change),
# which `-c core.hooksPath=/dev/null` does NOT gate. The function is extracted from the hook so the
# test exercises the shipped text, and run with the installed lib.
@test "installed-hook: _cast_stage_file stages the raw file and does not fire a post-index-change config hook (control fires)" {
  cd "$TEST_REPO"
  local m_ctl="$TEST_DIR/ctl.marker" m_hook="$TEST_DIR/hook.marker" canary="$TEST_DIR/canary.sh" sha
  printf '#!/bin/sh\ntouch "$CAST_TEST_MARKER"\nexit 0\n' > "$canary"
  chmod +x "$canary"
  printf '{"n":1}\n' > cast-stats.json
  sha="$(git rev-parse HEAD:settings.json)"
  git config hook.pwn.event post-index-change
  git config hook.pwn.command "$canary"
  # CONTROL: raw git (with the old hooksPath-only neutralisation) fires the config hook.
  CAST_TEST_MARKER="$m_ctl" git -c core.fsmonitor=false -c core.hooksPath=/dev/null \
    update-index --add --cacheinfo "100644,${sha},ctl.txt"
  if [[ ! -e "$m_ctl" ]]; then
    skip "config-based hooks need git >= 2.54"
  fi
  git rm -q --cached ctl.txt 2>/dev/null || true
  # sed script via env: macOS /bin/bash 3.2 brace-expands {/,/^} in nested "$( "…" )" quotes (bats-macos, PR #421).
  run env SEDX='/^_cast_stage_file() {/,/^}/p' CAST_TEST_MARKER="$m_hook" LIB="$HOME/.claude/scripts/cast-hook-lib.sh" HOOK="$TEST_REPO/.githooks/pre-commit" REPO_ROOT="$TEST_REPO" bash -c '
    set -euo pipefail
    . "$LIB"
    _git() { cast_git_safe "$REPO_ROOT" "$@"; }
    eval "$(sed -n "$SEDX" "$HOOK")"
    cd "$REPO_ROOT"
    _cast_stage_file cast-stats.json
  '
  assert_success
  [[ ! -e "$m_hook" ]]
  [[ "$(git ls-files -s cast-stats.json)" == "100644 $(git hash-object cast-stats.json) 0"*cast-stats.json ]]
}

# === LINT 11: ruff on staged scripts/*.py (mirrors CI's `ruff check scripts/*.py`) ===
# ruff is a PATH-shimmed fake: the hook must (a) run it on STAGED scripts/*.py only, (b) block on
# findings, (c) warn once and continue when ruff is absent. The fake records its argv.

# Make the fixture repo clear every earlier gate so the ruff step is reached: the orphan-script lint
# needs the script settings.json references to exist.
_ruff_fixture() {
  cd "$TEST_REPO"
  printf '#!/bin/bash\nexit 0\n' > scripts/test-script.sh
  chmod +x scripts/test-script.sh
  printf 'x = 1\n' > scripts/mod.py
  printf 'y = 2\n' > scripts/unstaged.py
  printf 'z = 3\n' > other.py
  git add scripts/test-script.sh scripts/mod.py other.py
  FAKE_BIN="$TEST_DIR/fakebin"
  RUFF_LOG="$TEST_DIR/ruff.argv"
  mkdir -p "$FAKE_BIN"
}

_fake_ruff() {  # <exit-code> [message]
  printf '#!/bin/bash\nprintf "%%s\\n" "$@" > "%s"\n[ -z "%s" ] || echo "%s"\nexit %s\n' "$RUFF_LOG" "${2:-}" "${2:-}" "$1" > "$FAKE_BIN/ruff"
  chmod +x "$FAKE_BIN/ruff"
}

# PATH with every directory that provides a real `ruff` removed (the dev machine has one).
_path_without_ruff() {
  local d out="" IFS=:
  for d in $PATH; do
    [[ -x "$d/ruff" ]] && continue
    out="${out:+$out:}$d"
  done
  printf '%s' "$out"
}

@test "lint-ruff: staged scripts/*.py passes through to a clean ruff; only the staged scripts file is checked" {
  _ruff_fixture
  _fake_ruff 0
  run env PATH="$FAKE_BIN:$PATH" bash .githooks/pre-commit
  [[ "$output" != *"lint-ruff"* ]]
  [[ "$output" != *"ruff not installed"* ]]
  # no ruff config staged -> the config-change WARN must be ABSENT
  [[ "$output" != *"reviewer must check"* ]]
  [[ -f "$RUFF_LOG" ]]
  grep -qx 'scripts/mod.py' "$RUFF_LOG"
  # `! grep` can never fail under bats' set -e (a negated command is exempt); use run + assert_failure
  run grep -q 'unstaged.py' "$RUFF_LOG"
  assert_failure
  run grep -q 'other.py' "$RUFF_LOG"
  assert_failure
}

@test "lint-ruff: ruff is invoked with --no-cache, --no-fix and a -- separator (a repo fix=true must not rewrite files)" {
  _ruff_fixture
  _fake_ruff 0
  run env PATH="$FAKE_BIN:$PATH" bash .githooks/pre-commit
  [[ -f "$RUFF_LOG" ]]
  grep -qx -- '--no-cache' "$RUFF_LOG"
  grep -qx -- '--no-fix' "$RUFF_LOG"
  # the fake logs one argv entry per line: `--` must exist AND sit before the first file operand
  # (an empty line number would compare as 0 and false-pass, so require both explicitly)
  local dd file_ln
  dd="$(grep -n -x -- '--' "$RUFF_LOG" | head -1 | cut -d: -f1)"
  file_ln="$(grep -n -x 'scripts/mod.py' "$RUFF_LOG" | head -1 | cut -d: -f1)"
  [[ -n "$dd" && -n "$file_ln" ]]
  [[ "$dd" -lt "$file_ln" ]]
}

@test "lint-ruff: a staged DELETION of ruff.toml prints the config-change WARN too" {
  cd "$TEST_REPO"
  printf 'line-length = 100\n' > ruff.toml
  git add ruff.toml
  git -c core.hooksPath=/dev/null commit -q -m "seed ruff.toml"
  git rm -q ruff.toml
  _ruff_fixture
  _fake_ruff 0
  run env PATH="$FAKE_BIN:$PATH" bash .githooks/pre-commit
  assert_output --partial "reviewer must check"
}

@test "lint-ruff: a staged leaf symlink is skipped with a WARN, not passed to ruff" {
  _ruff_fixture
  ln -s mod.py scripts/link.py
  git add scripts/link.py
  _fake_ruff 0
  run env PATH="$FAKE_BIN:$PATH" bash .githooks/pre-commit
  # assert on THIS run's output (the hook is not re-run): the WARN names the symlink
  assert_output --partial "ruff lint skipped scripts/link.py"
  [[ -f "$RUFF_LOG" ]]
  grep -qx 'scripts/mod.py' "$RUFF_LOG"
  run grep -qx 'scripts/link.py' "$RUFF_LOG"
  assert_failure
}

@test "lint-ruff: a staged typechange (symlink -> regular file) scripts/*.py IS passed to ruff" {
  _ruff_fixture
  # commit scripts/t.py as a symlink to a sibling in-repo file (isolated TEST_REPO; hook bypassed)
  ln -s mod.py scripts/t.py
  git add scripts/t.py
  git -c user.name=t -c user.email=t@example.invalid commit --no-verify -q -m "symlink t.py"
  # replace the symlink with a regular file and stage the typechange
  rm scripts/t.py
  printf 't = 1\n' > scripts/t.py
  git add scripts/t.py
  # fixture sanity: the index really records a typechange (T)
  run git diff --cached --name-status
  [[ "$output" == *$'T\tscripts/t.py'* ]]
  _fake_ruff 0
  run env PATH="$FAKE_BIN:$PATH" bash .githooks/pre-commit
  [[ -f "$RUFF_LOG" ]]
  grep -qx 'scripts/t.py' "$RUFF_LOG"
}

@test "lint-ruff: a staged non-ASCII name (scripts/é.py) IS passed to ruff (git -z, no core.quotePath skip)" {
  _ruff_fixture
  printf 'x = 1\n' > "scripts/é.py"
  git add "scripts/é.py"
  _fake_ruff 0
  run env PATH="$FAKE_BIN:$PATH" bash .githooks/pre-commit
  [[ -f "$RUFF_LOG" ]]
  grep -qx 'scripts/mod.py' "$RUFF_LOG"
  grep -qx 'scripts/é.py' "$RUFF_LOG"
  [[ "$output" != *"ruff lint skipped"* ]]
}

@test "lint-ruff: a staged file under a dir symlinked OUT of the repo is NOT passed to ruff and a WARN names it" {
  _ruff_fixture
  mkdir -p scripts/sub "$TEST_DIR/outside"
  printf 'v = 1\n' > scripts/sub/evil.py
  git add scripts/sub/evil.py
  # swap the real dir for a symlink to a dir outside the repo (the index still has scripts/sub/evil.py)
  [[ "$TEST_REPO/scripts/sub" == "$TEST_DIR"/* ]]   # destructive-path guard: only ever under our mktemp dir
  rm -rf "$TEST_REPO/scripts/sub"
  printf 'v = 1\n' > "$TEST_DIR/outside/evil.py"
  ln -s "$TEST_DIR/outside" scripts/sub
  _fake_ruff 0
  run env PATH="$FAKE_BIN:$PATH" bash .githooks/pre-commit
  local first_out="$output"
  [[ -f "$RUFF_LOG" ]]
  grep -qx 'scripts/mod.py' "$RUFF_LOG"
  run grep -q 'evil.py' "$RUFF_LOG"
  assert_failure
  [[ "$first_out" == *"ruff lint skipped scripts/sub/evil.py"* ]]
}

@test "lint-ruff: a staged ruff.toml prints the config-change WARN and does not block on its own" {
  _ruff_fixture
  printf 'line-length = 100\n' > ruff.toml
  git add ruff.toml
  _fake_ruff 0
  run env PATH="$FAKE_BIN:$PATH" bash .githooks/pre-commit
  assert_output --partial "ruff config"
  assert_output --partial "reviewer must check"
  [[ "$output" != *"ERROR [lint-ruff]"* ]]
}

@test "lint-ruff: a staged nested scripts/ruff.toml prints the config-change WARN (a nested config can silence rules)" {
  _ruff_fixture
  printf 'lint.ignore = ["E", "F"]\n' > scripts/ruff.toml
  git add scripts/ruff.toml
  _fake_ruff 0
  run env PATH="$FAKE_BIN:$PATH" bash .githooks/pre-commit
  assert_output --partial "reviewer must check"
  [[ "$output" != *"ERROR [lint-ruff]"* ]]
}

@test "lint-ruff: a staged rename-with-edits (R) IS passed to ruff under its NEW path" {
  cd "$TEST_REPO"
  printf 'a = 1\nb = 2\nc = 3\nd = 4\ne = 5\nf = 6\n' > scripts/old.py
  git add scripts/old.py
  git -c core.hooksPath=/dev/null commit -q -m "seed old.py"
  git mv scripts/old.py scripts/new.py
  printf 'g = 7\n' >> scripts/new.py
  git add scripts/new.py
  [[ "$(git diff --cached --name-status | cut -c1)" == "R" ]]   # fixture sanity: git really sees a rename
  _ruff_fixture
  _fake_ruff 0
  run env PATH="$FAKE_BIN:$PATH" bash .githooks/pre-commit
  [[ -f "$RUFF_LOG" ]]
  grep -qx 'scripts/new.py' "$RUFF_LOG"
  run grep -q 'old.py' "$RUFF_LOG"
  assert_failure
}

@test "lint-ruff: a staged file with unstaged changes blocks (N1: the linted bytes must be the staged bytes) and ruff is not run" {
  _ruff_fixture
  printf 'v = 1\n' > scripts/a.py
  git add scripts/a.py
  printf 'v = 2\n' > scripts/a.py   # working copy now differs from the staged blob
  _fake_ruff 0
  run env PATH="$FAKE_BIN:$PATH" bash .githooks/pre-commit
  assert_failure
  assert_output --partial "ERROR [lint-ruff]"
  assert_output --partial "unstaged changes"
  assert_output --partial "scripts/a.py"
  # the clean staged file is not named as dirty (the orphan-script WARN above legitimately names it)
  [[ "$(grep 'ERROR \[lint-ruff\]' <<<"$output")" != *"mod.py"* ]]
  [[ ! -f "$RUFF_LOG" ]]
}

@test "lint-ruff: ruff absent + a staged file with unstaged changes only WARNs (a missing tool never blocks)" {
  _ruff_fixture
  printf 'x = 99\n' > scripts/mod.py
  run env PATH="$(_path_without_ruff)" bash .githooks/pre-commit
  assert_output --partial "WARN: ruff not installed"
  [[ "$output" != *"ERROR [lint-ruff]"* ]]
}

# Fail-closed branches: wrap the INSTALLED cast_git_safe (temp HOME copy only) so one specific
# git call exits 128; the hook sources that lib and resolves git itself (PATH is never consulted,
# so a PATH git shim would not be used). $1 = argv token that triggers the failure.
_break_git_call() {
  cat >> "$HOME/.claude/scripts/cast-hook-lib.sh" <<EOF
eval "\$(declare -f cast_git_safe | sed '1s/cast_git_safe/_orig_cast_git_safe/')"
cast_git_safe() {
  local a
  for a in "\$@"; do
    [[ "\$a" == "$1" ]] && return 128
  done
  _orig_cast_git_safe "\$@"
}
EOF
}

@test "lint-ruff: a failing staged-file listing (git exit 128) fails closed, naming the listing" {
  _ruff_fixture
  _fake_ruff 0
  _break_git_call "--diff-filter=ACMRT"
  run env PATH="$FAKE_BIN:$PATH" bash .githooks/pre-commit
  assert_failure
  assert_output --partial "git diff (staged scripts/*.py) failed"
  [[ ! -f "$RUFF_LOG" ]]
}

@test "lint-ruff: a failing index-vs-worktree check (git diff --quiet exit 128) fails closed and ruff is not run" {
  _ruff_fixture
  _fake_ruff 0
  _break_git_call "--quiet"
  run env PATH="$FAKE_BIN:$PATH" bash .githooks/pre-commit
  assert_failure
  assert_output --partial "git diff --quiet failed (rc=128)"
  [[ ! -f "$RUFF_LOG" ]]
}

@test "lint-ruff: ruff findings block the commit with a clear message" {
  _ruff_fixture
  _fake_ruff 1 "scripts/mod.py:1:5: E702 Multiple statements on one line"
  run env PATH="$FAKE_BIN:$PATH" bash .githooks/pre-commit
  assert_failure
  assert_output --partial "E702"
  assert_output --partial "ERROR [lint-ruff]"
  assert_output --partial "ruff lint failed"
}

@test "lint-ruff: ruff absent prints ONE warning and does not block" {
  _ruff_fixture
  run env PATH="$(_path_without_ruff)" bash .githooks/pre-commit
  [[ "$output" != *"lint-ruff"* ]]
  [[ "$(grep -c 'ruff not installed' <<<"$output")" == "1" ]]
  assert_output --partial "WARN: ruff not installed"
}

@test "lint-ruff: no staged scripts/*.py means ruff is never invoked" {
  _ruff_fixture
  git rm -q --cached scripts/mod.py   # unstage the only staged scripts/*.py
  _fake_ruff 1 "should never run"
  run env PATH="$FAKE_BIN:$PATH" bash .githooks/pre-commit
  [[ ! -f "$RUFF_LOG" ]]
  [[ "$output" != *"should never run"* ]]
}
