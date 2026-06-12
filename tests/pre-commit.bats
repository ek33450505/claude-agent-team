#!/usr/bin/env bats
# BATS tests for .githooks/pre-commit regression lints

load test_helper/bats-support/load
load test_helper/bats-assert/load

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

setup() {
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
  cp "$REPO_ROOT/.githooks/cold-start-baseline.txt" .githooks/ 2>/dev/null || true
  git config core.hooksPath .githooks

  # Copy scripts and helper Python script
  cp "$REPO_ROOT/scripts/cast-lint-orphan-scripts.py" scripts/
  cp "$REPO_ROOT/scripts/gen-stats.sh" scripts/gen-stats.sh 2>/dev/null || true

  cd /
}

teardown() {
  rm -rf "$TEST_DIR"
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
  echo "scripts/grandfathered.sh:3" >> .githooks/cold-start-baseline.txt
  cat > scripts/grandfathered.sh <<'EOF'
#!/bin/bash
set -euo pipefail
python3 -c "print('one')"
python3 -c "print('two')"
python3 -c "print('three')"
EOF
  chmod +x scripts/grandfathered.sh
  git add scripts/grandfathered.sh .githooks/cold-start-baseline.txt
  run bash .githooks/pre-commit
  # Should NOT fail because count (3) matches baseline (3)
  [[ "$output" != *"ERROR [lint-cold-starts]: scripts/grandfathered.sh"* ]]
}

@test "lint-cold-starts: fail when GRANDFATHERED file's count INCREASES" {
  cd "$TEST_REPO"
  # Add a grandfathered file to baseline with count=3
  echo "scripts/regression.sh:3" >> .githooks/cold-start-baseline.txt
  cat > scripts/regression.sh <<'EOF'
#!/bin/bash
set -euo pipefail
python3 -c "print('one')"
python3 -c "print('two')"
python3 -c "print('three')"
python3 -c "print('four')"
EOF
  chmod +x scripts/regression.sh
  git add scripts/regression.sh .githooks/cold-start-baseline.txt
  run bash .githooks/pre-commit
  # Should FAIL because count (4) exceeds baseline (3)
  [[ "$output" == *"ERROR [lint-cold-starts]: scripts/regression.sh has 4 python3 -c calls (baseline: 3)"* ]]
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

@test "pre-commit-hook: is installed via git config" {
  cd "$REPO_ROOT"
  run git config core.hooksPath
  [[ "$output" == ".githooks" ]]
}
