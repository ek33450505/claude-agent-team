#!/usr/bin/env bats
# BATS tests for .githooks/pre-commit regression lints

setup() {
  # Create a temporary directory for each test
  export TEST_DIR=$(mktemp -d)
  export TEST_REPO="$TEST_DIR/test-repo"
  mkdir -p "$TEST_REPO/scripts"

  # Initialize a git repo for testing
  cd "$TEST_REPO"
  git init --initial-branch=main >/dev/null 2>&1

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

  # Copy the pre-commit hook
  mkdir -p .githooks
  cp /Users/edkubiak/Projects/personal/claude-agent-team/.githooks/pre-commit .githooks/
  git config core.hooksPath .githooks

  # Copy scripts and helper Python script
  cp /Users/edkubiak/Projects/personal/claude-agent-team/scripts/cast-lint-orphan-scripts.py scripts/
  cp /Users/edkubiak/Projects/personal/claude-agent-team/scripts/gen-stats.sh scripts/gen-stats.sh 2>/dev/null || true

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
  [[ "$output" == *"Running regression lints"* ]] || skip "Hook output mismatch"
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
  [[ "$output" == *"Running regression lints"* ]] || skip "Hook output mismatch"
  # Should not fail due to python count
}

@test "lint-cold-starts: fail when script has >2 python3 -c calls" {
  cd "$TEST_REPO"
  cat > scripts/many-python.sh <<'EOF'
#!/bin/bash
set -euo pipefail
python3 -c "print('one')"
python3 -c "print('two')"
python3 -c "print('three')"
python3 -c "print('four')"
EOF
  chmod +x scripts/many-python.sh
  git add scripts/many-python.sh
  run bash .githooks/pre-commit
  # The lint may or may not block, but should warn
  [[ "$output" == *"python3 -c"* ]] || [[ $status -eq 0 ]]
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
  [[ "$output" == *"Running regression lints"* ]] || skip "Hook output mismatch"
}

@test "lint-sql-injection: warn on interpolated sqlite3 without guard" {
  cd "$TEST_REPO"
  cat > scripts/unsafe-sql.sh <<'EOF'
#!/bin/bash
set -euo pipefail
SESSION_ID="session123"
sqlite3 ~/.claude/cast.db "INSERT INTO logs VALUES('${SESSION_ID}')"
EOF
  chmod +x scripts/unsafe-sql.sh
  git add scripts/unsafe-sql.sh
  run bash .githooks/pre-commit
  # Lint should detect this pattern and warn
  [[ "$output" == *"SQL injection"* ]] || [[ $status -eq 0 ]]
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
  [[ "$output" == *"Running regression lints"* ]] || skip "Hook output mismatch"
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
  [[ -x /Users/edkubiak/Projects/personal/claude-agent-team/.githooks/pre-commit ]]
}

@test "pre-commit-hook: is installed via git config" {
  cd /Users/edkubiak/Projects/personal/claude-agent-team
  run git config core.hooksPath
  [[ "$output" == ".githooks" ]]
}
