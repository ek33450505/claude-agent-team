#!/usr/bin/env bats

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

setup() {
  export ORIG_HOME="$HOME"
  export HOME="$(realpath "$(mktemp -d)")"
  mkdir -p "$HOME/.claude/agent-status"
}

teardown() {
  rm -rf "$HOME"
  export HOME="$ORIG_HOME"
}

# ---------------------------------------------------------------------------
# Phase 4.9: status file fallback recovers recent status
# ---------------------------------------------------------------------------

@test "status file fallback recovers Status when written within 300-second window" {
  local agent="test-agent-$$"
  local status_dir="$HOME/.claude/agent-status"

  # Create a status file with current timestamp
  local status_file="${status_dir}/${agent}-$(date -u +%Y%m%dT%H%M%SZ).json"
  cat > "$status_file" << 'EOF'
{"agent":"test-agent","status":"DONE","summary":"test operation completed","concerns":[],"timestamp":"2026-05-11T10:00:00Z"}
EOF

  # Simulate the fallback logic from orchestrate skill
  run bash -c "
    LATEST=\$(ls -t '$status_dir'/${agent}-*.json 2>/dev/null | head -1)
    if [ -n \"\$LATEST\" ]; then
      FILE_MTIME=\$(python3 -c \"import os,sys; print(int(os.path.getmtime(sys.argv[1])))\" \"\$LATEST\" 2>/dev/null || echo 0)
      FILE_AGE=\$(( \$(date +%s) - FILE_MTIME ))
      if [ \"\$FILE_AGE\" -le 300 ]; then
        python3 -c \"import json,sys; d=json.load(open('\$LATEST')); print(d.get('status','MISSING'))\"
      fi
    fi
  "
  assert_output "DONE"
}

@test "status file fallback skips files older than 300 seconds" {
  local agent="test-agent-old-$$"
  local status_dir="$HOME/.claude/agent-status"

  # Create a status file with an old timestamp (600 seconds in the past)
  local status_file="${status_dir}/${agent}-$(date -u +%Y%m%dT%H%M%SZ).json"
  cat > "$status_file" << 'EOF'
{"agent":"test-agent-old","status":"DONE","summary":"stale status","concerns":[],"timestamp":"2026-05-11T09:50:00Z"}
EOF

  # Set the file's mtime to 600 seconds ago using Python (cross-platform)
  python3 -c "import os, time; os.utime('$status_file', (time.time()-600, time.time()-600))"

  # Simulate the fallback logic — should NOT recover stale file
  run bash -c "
    LATEST=\$(ls -t '$status_dir'/${agent}-*.json 2>/dev/null | head -1)
    if [ -n \"\$LATEST\" ]; then
      FILE_MTIME=\$(python3 -c \"import os,sys; print(int(os.path.getmtime(sys.argv[1])))\" \"\$LATEST\" 2>/dev/null || echo 0)
      FILE_AGE=\$(( \$(date +%s) - FILE_MTIME ))
      if [ \"\$FILE_AGE\" -le 300 ]; then
        python3 -c \"import json,sys; d=json.load(open('\$LATEST')); print(d.get('status','MISSING'))\"
      else
        echo \"STALE\"
      fi
    fi
  "
  assert_output "STALE"
}

@test "status file fallback handles malformed JSON gracefully" {
  local agent="test-agent-bad-$$"
  local status_dir="$HOME/.claude/agent-status"

  # Create a status file with invalid JSON
  local status_file="${status_dir}/${agent}-$(date -u +%Y%m%dT%H%M%SZ).json"
  echo "{invalid json here" > "$status_file"

  # Simulate the fallback logic — should NOT crash
  run bash -c "
    LATEST=\$(ls -t '$status_dir'/${agent}-*.json 2>/dev/null | head -1)
    if [ -n \"\$LATEST\" ]; then
      FILE_MTIME=\$(python3 -c \"import os,sys; print(int(os.path.getmtime(sys.argv[1])))\" \"\$LATEST\" 2>/dev/null || echo 0)
      FILE_AGE=\$(( \$(date +%s) - FILE_MTIME ))
      if [ \"\$FILE_AGE\" -le 300 ]; then
        python3 -c \"import json,sys; d=json.load(open('\$LATEST')); print(d.get('status','MISSING'))\" 2>/dev/null || echo \"JSON_ERROR\"
      fi
    fi
  "
  # Should NOT crash; should exit cleanly
  assert_success
}
