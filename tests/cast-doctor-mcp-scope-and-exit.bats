#!/usr/bin/env bats

# Tests for cast doctor fixes DOC-1, DOC-3, and reachability semantics:
# DOC-1: Doctor now reads ~/.claude.json (top-level mcpServers + projects.<cwd>.mcpServers)
# DOC-3: Doctor now exits 1 when checks fail (was always 0)
# Reachability: HTTP 401 is counted as reachable (was false-alarm unreachable)

setup() {
  load 'helpers/setup'
  setup_temp_home  # sets HOME to a temp dir; exports ORIG_HOME
  export CAST_CONFIG_DIR="${HOME}/.claude/config"
  export CAST_DB_PATH="${HOME}/.claude/cast.db"
  export CAST_REPO_DIR="${HOME}/fake-repo"
  mkdir -p "$CAST_CONFIG_DIR"
  mkdir -p "${HOME}/.claude/cast/events"
  mkdir -p "${HOME}/.claude/scripts"
  mkdir -p "${CAST_REPO_DIR}/routines"

  # Initialize a minimal cast.db
  sqlite3 "$CAST_DB_PATH" <<'SQL'
CREATE TABLE IF NOT EXISTS sessions (id INTEGER PRIMARY KEY);
CREATE TABLE IF NOT EXISTS agent_runs (id INTEGER PRIMARY KEY);
CREATE TABLE IF NOT EXISTS routing_events (id INTEGER PRIMARY KEY);
CREATE TABLE IF NOT EXISTS agent_memories (id INTEGER PRIMARY KEY);
CREATE TABLE IF NOT EXISTS tool_call_failures (id INTEGER PRIMARY KEY);
CREATE TABLE IF NOT EXISTS agent_truncations (id INTEGER PRIMARY KEY);
CREATE TABLE IF NOT EXISTS injection_log (id INTEGER PRIMARY KEY);
CREATE TABLE IF NOT EXISTS quality_gates (id INTEGER PRIMARY KEY);
CREATE TABLE IF NOT EXISTS dispatch_decisions (id INTEGER PRIMARY KEY);
CREATE TABLE IF NOT EXISTS task_queue (id INTEGER PRIMARY KEY);
CREATE TABLE IF NOT EXISTS routines (id INTEGER PRIMARY KEY);
CREATE TABLE IF NOT EXISTS incidents (id INTEGER PRIMARY KEY);
CREATE TABLE IF NOT EXISTS plan_sessions (id INTEGER PRIMARY KEY);
CREATE TABLE IF NOT EXISTS memory_consolidation_runs (id INTEGER PRIMARY KEY);
CREATE TABLE IF NOT EXISTS archived_memories (id INTEGER PRIMARY KEY);
CREATE TABLE IF NOT EXISTS budgets (id INTEGER PRIMARY KEY);
SQL
}

teardown() {
  teardown_temp_home
}

# Helper: mock curl to return a specific HTTP code
mock_curl_with_code() {
  local http_code="$1"
  cat > "${HOME}/curl" <<CURL
#!/bin/bash
# Mock curl that returns specified HTTP code
# Usage: curl -s -o /dev/null -w '%{http_code}' <url>
while [[ \$# -gt 0 ]]; do
  if [[ "\$1" == "-w" ]]; then
    shift 2  # skip -w and its arg
  elif [[ "\$1" == "-o" ]] || [[ "\$1" == "--max-time" ]]; then
    shift 2
  else
    shift
  fi
done
# Always succeed (rc=0), but output the code to stdout
echo "${http_code}"
CURL
  chmod +x "${HOME}/curl"
  export PATH="${HOME}:$PATH"
}

# Helper: mock curl to fail (connection error)
mock_curl_connection_error() {
  cat > "${HOME}/curl" <<CURL
#!/bin/bash
# Mock curl that fails with connection error
# Output "000" to indicate connection failure, exit 0 (curl's behavior on connection errors)
echo "000"
exit 0
CURL
  chmod +x "${HOME}/curl"
  export PATH="${HOME}:$PATH"
}

@test "DOC-1: top-level mcpServers in ~/.claude.json is reported" {
  mock_curl_with_code "200"

  cat > "${HOME}/.claude.json" <<'JSON'
{
  "mcpServers": {
    "example-server": {
      "url": "http://localhost:3000"
    }
  }
}
JSON

  run bash bin/cast doctor
  # Should NOT exit 1 due to MCP check alone (other checks should pass)
  [[ "$output" =~ "MCP servers: 1 configured, all reachable" ]]
  # Verify "none configured" is NOT in the output
  ! [[ "$output" =~ "MCP servers: none configured" ]]
}

@test "DOC-1: per-project mcpServers in ~/.claude.json is reported" {
  mock_curl_with_code "200"

  local cwd
  cwd="$(pwd)"

  cat > "${HOME}/.claude.json" <<JSON
{
  "projects": {
    "${cwd}": {
      "mcpServers": {
        "project-server": {
          "url": "http://localhost:3001"
        }
      }
    }
  }
}
JSON

  run bash bin/cast doctor
  [[ "$output" =~ "MCP servers: 1 configured, all reachable" ]]
  ! [[ "$output" =~ "MCP servers: none configured" ]]
}

@test "DOC-1: both top-level and per-project mcpServers are merged" {
  mock_curl_with_code "200"

  local cwd
  cwd="$(pwd)"

  cat > "${HOME}/.claude.json" <<JSON
{
  "mcpServers": {
    "global-server": {
      "url": "http://localhost:3000"
    }
  },
  "projects": {
    "${cwd}": {
      "mcpServers": {
        "project-server": {
          "url": "http://localhost:3001"
        }
      }
    }
  }
}
JSON

  run bash bin/cast doctor
  [[ "$output" =~ "MCP servers: 2 configured, all reachable" ]]
}

@test "DOC-1: no MCP config anywhere degrades to INFO and doesn't crash" {
  # Don't create any MCP config files

  run bash bin/cast doctor
  # Doctor may exit 1 due to other checks failing, but MCP check should complete
  [[ "$output" =~ "MCP servers: no config found" ]]
}

@test "DOC-1: malformed ~/.claude.json doesn't crash doctor" {
  # Create invalid JSON
  cat > "${HOME}/.claude.json" <<'JSON'
{
  "mcpServers": [invalid json here
}
JSON

  run bash bin/cast doctor
  # Doctor should still complete successfully (gracefully skip bad JSON)
  # The output should not mention "error" for MCP (JSON parse errors are caught)
  [[ "$output" =~ "MCP servers:" ]]
}

@test "Reachability: HTTP 401 response is counted as reachable (not false-alarm unreachable)" {
  mock_curl_with_code "401"

  cat > "${HOME}/.claude.json" <<'JSON'
{
  "mcpServers": {
    "authenticated-server": {
      "url": "http://localhost:3000/protected"
    }
  }
}
JSON

  run bash bin/cast doctor
  # 401 should be treated as reachable (server responded, even if auth failed)
  [[ "$output" =~ "MCP servers: 1 configured, all reachable" ]]
  ! [[ "$output" =~ "unreachable" ]]
}

@test "Reachability: HTTP 403 response is counted as reachable" {
  mock_curl_with_code "403"

  cat > "${HOME}/.claude.json" <<'JSON'
{
  "mcpServers": {
    "forbidden-server": {
      "url": "http://localhost:3000/admin"
    }
  }
}
JSON

  run bash bin/cast doctor
  [[ "$output" =~ "MCP servers: 1 configured, all reachable" ]]
  ! [[ "$output" =~ "unreachable" ]]
}

@test "Reachability: curl connection failure (000) is counted as unreachable" {
  mock_curl_connection_error

  cat > "${HOME}/.claude.json" <<'JSON'
{
  "mcpServers": {
    "dead-server": {
      "url": "http://192.0.2.1:9999"
    }
  }
}
JSON

  run bash bin/cast doctor
  # Connection error should be reported as unreachable
  [[ "$output" =~ "MCP servers:" ]]
  [[ "$output" =~ "unreachable" ]]
}

@test "DOC-3: doctor exits 1 when a check fails" {
  # Force a check to fail by creating an invalid db
  rm "$CAST_DB_PATH"
  cat > "$CAST_DB_PATH" <<< "not a valid database"

  run bash bin/cast doctor
  # Should exit with non-zero status
  [ "$status" -ne 0 ]
  # Should print an error message about cast.db
  [[ "$output" =~ "cast.db not accessible" ]]
}

@test "DOC-3: doctor's return statement is read (not always 0)" {
  # This test verifies that _cmd_doctor's return statement is actually executed
  # by checking that exit code varies based on check results.
  # Test 9 verifies exit 1 on failure, test 11 verifies overall_ok affects exit code.
  # This test simply confirms the return statement flows through to process exit.

  mock_curl_with_code "200"

  # Create a valid DB and settings
  cat > "${HOME}/.claude/settings.json" <<'JSON'
{
  "hooks": {
    "PreToolUse": [
      { "command": "bash ~/.claude/scripts/h1.sh" },
      { "command": "bash ~/.claude/scripts/h2.sh" },
      { "command": "bash ~/.claude/scripts/h3.sh" },
      { "command": "bash ~/.claude/scripts/h4.sh" }
    ]
  }
}
JSON

  for i in 1 2 3 4; do
    touch "${HOME}/.claude/scripts/h${i}.sh"
    chmod +x "${HOME}/.claude/scripts/h${i}.sh"
  done

  # Run doctor - it will likely fail on other checks (migrations, backups, etc)
  # but that's fine - we're just verifying exit code reflects failures
  run bash bin/cast doctor

  # The exit code should reflect overall health (0 = all pass, 1 = any failure)
  # Since we have an incomplete setup, some checks will fail
  # This verifies the exit code path is active and used
  if [[ "$output" =~ "Some checks need attention" ]]; then
    [ "$status" -ne 0 ]
  else
    [ "$status" -eq 0 ]
  fi
}

@test "DOC-3: doctor exit code reflects overall health, not just last check" {
  mock_curl_with_code "200"

  # Force the hooks check to fail (not enough hooks)
  cat > "${HOME}/.claude/settings.json" <<'JSON'
{
  "hooks": {
    "SomeEvent": [
      { "command": "bash ~/.claude/scripts/only-one.sh" }
    ]
  }
}
JSON

  touch "${HOME}/.claude/scripts/only-one.sh"

  run bash bin/cast doctor
  # Should exit 1 because hooks check failed (only 1 entry, need > 3)
  [ "$status" -ne 0 ]
  [[ "$output" =~ "Hooks registered: only" ]]
  [[ "$output" =~ "Some checks need attention" ]]
}

@test "DOC-1: ~/.claude.json per-project mcpServers with wrong cwd is ignored" {
  mock_curl_with_code "200"

  cat > "${HOME}/.claude.json" <<JSON
{
  "projects": {
    "/some/other/path": {
      "mcpServers": {
        "wrong-project": {
          "url": "http://localhost:3000"
        }
      }
    }
  }
}
JSON

  # Since the project path doesn't match current working directory,
  # the server should not be included
  run bash bin/cast doctor
  # Should report "none configured" because the project path doesn't match cwd
  [[ "$output" =~ "MCP servers: none configured" ]]
}

@test "DOC-1: settings.json mcpServers are still reported (informational parity)" {
  mock_curl_with_code "200"

  # Create mcpServers in settings.json (old path, still scanned for parity)
  cat > "${HOME}/.claude/settings.json" <<'JSON'
{
  "hooks": {
    "PreToolUse": [
      { "command": "bash ~/.claude/scripts/h1.sh" },
      { "command": "bash ~/.claude/scripts/h2.sh" },
      { "command": "bash ~/.claude/scripts/h3.sh" },
      { "command": "bash ~/.claude/scripts/h4.sh" }
    ]
  },
  "mcpServers": {
    "settings-server": {
      "url": "http://localhost:3002"
    }
  }
}
JSON

  # Create hook scripts
  for i in 1 2 3 4; do
    touch "${HOME}/.claude/scripts/h${i}.sh"
    chmod +x "${HOME}/.claude/scripts/h${i}.sh"
  done

  run bash bin/cast doctor
  # Should see the server from settings.json
  [[ "$output" =~ "MCP servers: 1 configured, all reachable" ]]
}

@test "DOC-3: fully clean doctor run exits 0 and prints 'All checks passed'" {
  mock_curl_with_code "200"

  # Set up temp scripts dir with empty migrations (no pending migrations)
  local temp_scripts_dir="${HOME}/.claude-test-scripts"
  mkdir -p "$temp_scripts_dir/migrations"
  cp scripts/cast-migrate.py "$temp_scripts_dir/"
  export CAST_SCRIPTS_DIR="$temp_scripts_dir"

  # Initialize cast.db with all required tables
  sqlite3 "$CAST_DB_PATH" <<'SQL'
CREATE TABLE IF NOT EXISTS schema_migrations (id INTEGER PRIMARY KEY);
SQL

  # Create settings.json with 4+ hooks (threshold is > 3)
  mkdir -p "${HOME}/.claude/scripts"
  cat > "${HOME}/.claude/settings.json" <<'JSON'
{
  "hooks": {
    "PreToolUse": [
      { "command": "bash ~/.claude/scripts/h1.sh" },
      { "command": "bash ~/.claude/scripts/h2.sh" },
      { "command": "bash ~/.claude/scripts/h3.sh" },
      { "command": "bash ~/.claude/scripts/h4.sh" }
    ]
  }
}
JSON

  # Create hook scripts
  for i in 1 2 3 4; do
    touch "${HOME}/.claude/scripts/h${i}.sh"
    chmod +x "${HOME}/.claude/scripts/h${i}.sh"
  done

  # Create backup directory and snapshot
  local backup_root="${HOME}/Library/Application Support/cast/backups"
  mkdir -p "$backup_root"
  touch "$backup_root/cast-snapshot-latest"

  # Create litestream config and replica dir
  mkdir -p "${HOME}/Library/Application Support/cast"
  cat > "${HOME}/Library/Application Support/cast/litestream.yml" <<'LITE'
dbs:
  - path: ~/.claude/cast.db
LITE
  mkdir -p "${HOME}/Library/Application Support/cast/litestream/cast-db"
  touch "${HOME}/Library/Application Support/cast/litestream/cast-db/file"

  run bash bin/cast doctor
  # Should exit 0 when all checks pass
  [ "$status" -eq 0 ]
  # Should print the success message
  [[ "$output" =~ "All checks passed" ]]
  # Verify no WARN-level failures in output
  ! [[ "$output" =~ "^\[!!\]" ]]
}
@test "URL redaction: secrets in URLs are not printed to stdout" {
  mock_curl_with_code "401"

  local temp_scripts_dir="${HOME}/.claude-test-scripts"
  mkdir -p "$temp_scripts_dir/migrations"
  cp scripts/cast-migrate.py "$temp_scripts_dir/"
  export CAST_SCRIPTS_DIR="$temp_scripts_dir"

  sqlite3 "$CAST_DB_PATH" <<'SQL'
CREATE TABLE IF NOT EXISTS schema_migrations (id INTEGER PRIMARY KEY);
SQL

  mkdir -p "${HOME}/.claude/cast/events"
  mkdir -p "${HOME}/.claude/scripts"
  cat > "${HOME}/.claude/settings.json" <<'JSON'
{
  "hooks": {
    "PreToolUse": [
      { "command": "bash ~/.claude/scripts/h1.sh" },
      { "command": "bash ~/.claude/scripts/h2.sh" },
      { "command": "bash ~/.claude/scripts/h3.sh" },
      { "command": "bash ~/.claude/scripts/h4.sh" }
    ]
  }
}
JSON

  for i in 1 2 3 4; do
    touch "${HOME}/.claude/scripts/h${i}.sh"
    chmod +x "${HOME}/.claude/scripts/h${i}.sh"
  done

  local backup_root="${HOME}/Library/Application Support/cast/backups"
  mkdir -p "$backup_root"
  touch "$backup_root/cast-snapshot-latest"

  mkdir -p "${HOME}/Library/Application Support/cast"
  cat > "${HOME}/Library/Application Support/cast/litestream.yml" <<'LITE'
dbs:
  - path: ~/.claude/cast.db
LITE
  mkdir -p "${HOME}/Library/Application Support/cast/litestream/cast-db"
  touch "${HOME}/Library/Application Support/cast/litestream/cast-db/file"

  cat > "${HOME}/.claude.json" <<'JSON'
{
  "mcpServers": {
    "secret-server": {
      "url": "https://user:mypassword@mcp-fixture-host/mcp?api_key=SECRET123&other=value"
    }
  }
}
JSON

  run bash bin/cast doctor
  [ "$status" -eq 0 ]
  [[ "$output" =~ "secret-server" ]]
  ! [[ "$output" =~ "mypassword" ]]
  ! [[ "$output" =~ "SECRET123" ]]
  ! [[ "$output" =~ "user:" ]]
}

@test "URL redaction: scheme, host, port, path preserved" {
  mock_curl_with_code "401"

  local temp_scripts_dir="${HOME}/.claude-test-scripts"
  mkdir -p "$temp_scripts_dir/migrations"
  cp scripts/cast-migrate.py "$temp_scripts_dir/"
  export CAST_SCRIPTS_DIR="$temp_scripts_dir"

  sqlite3 "$CAST_DB_PATH" <<'SQL'
CREATE TABLE IF NOT EXISTS schema_migrations (id INTEGER PRIMARY KEY);
SQL

  mkdir -p "${HOME}/.claude/cast/events"
  mkdir -p "${HOME}/.claude/scripts"
  cat > "${HOME}/.claude/settings.json" <<'JSON'
{
  "hooks": {
    "PreToolUse": [
      { "command": "bash ~/.claude/scripts/h1.sh" },
      { "command": "bash ~/.claude/scripts/h2.sh" },
      { "command": "bash ~/.claude/scripts/h3.sh" },
      { "command": "bash ~/.claude/scripts/h4.sh" }
    ]
  }
}
JSON

  for i in 1 2 3 4; do
    touch "${HOME}/.claude/scripts/h${i}.sh"
    chmod +x "${HOME}/.claude/scripts/h${i}.sh"
  done

  local backup_root="${HOME}/Library/Application Support/cast/backups"
  mkdir -p "$backup_root"
  touch "$backup_root/cast-snapshot-latest"

  mkdir -p "${HOME}/Library/Application Support/cast"
  cat > "${HOME}/Library/Application Support/cast/litestream.yml" <<'LITE'
dbs:
  - path: ~/.claude/cast.db
LITE
  mkdir -p "${HOME}/Library/Application Support/cast/litestream/cast-db"
  touch "${HOME}/Library/Application Support/cast/litestream/cast-db/file"

  cat > "${HOME}/.claude.json" <<'JSON'
{
  "mcpServers": {
    "redacted-server": {
      "url": "https://admin:secret@mcp-fixture-host:8443/mcp/v2?key=TOKEN"
    }
  }
}
JSON

  run bash bin/cast doctor
  [ "$status" -eq 0 ]
  [[ "$output" =~ "https://" ]]
  [[ "$output" =~ "mcp-fixture-host" ]]
  [[ "$output" =~ "8443" ]]
  [[ "$output" =~ "/mcp/v2" ]]
  ! [[ "$output" =~ "admin" ]]
  ! [[ "$output" =~ "secret" ]]
  ! [[ "$output" =~ "TOKEN" ]]
}

@test "HTTP 401 classified as 'responding', not 'unreachable'" {
  mock_curl_with_code "401"

  local temp_scripts_dir="${HOME}/.claude-test-scripts"
  mkdir -p "$temp_scripts_dir/migrations"
  cp scripts/cast-migrate.py "$temp_scripts_dir/"
  export CAST_SCRIPTS_DIR="$temp_scripts_dir"

  sqlite3 "$CAST_DB_PATH" <<'SQL'
CREATE TABLE IF NOT EXISTS schema_migrations (id INTEGER PRIMARY KEY);
SQL

  mkdir -p "${HOME}/.claude/cast/events"
  mkdir -p "${HOME}/.claude/scripts"
  cat > "${HOME}/.claude/settings.json" <<'JSON'
{
  "hooks": {
    "PreToolUse": [
      { "command": "bash ~/.claude/scripts/h1.sh" },
      { "command": "bash ~/.claude/scripts/h2.sh" },
      { "command": "bash ~/.claude/scripts/h3.sh" },
      { "command": "bash ~/.claude/scripts/h4.sh" }
    ]
  }
}
JSON

  for i in 1 2 3 4; do
    touch "${HOME}/.claude/scripts/h${i}.sh"
    chmod +x "${HOME}/.claude/scripts/h${i}.sh"
  done

  local backup_root="${HOME}/Library/Application Support/cast/backups"
  mkdir -p "$backup_root"
  touch "$backup_root/cast-snapshot-latest"

  mkdir -p "${HOME}/Library/Application Support/cast"
  cat > "${HOME}/Library/Application Support/cast/litestream.yml" <<'LITE'
dbs:
  - path: ~/.claude/cast.db
LITE
  mkdir -p "${HOME}/Library/Application Support/cast/litestream/cast-db"
  touch "${HOME}/Library/Application Support/cast/litestream/cast-db/file"

  cat > "${HOME}/.claude.json" <<'JSON'
{
  "mcpServers": {
    "auth-server": {
      "url": "https://api.example.com/mcp"
    }
  }
}
JSON

  run bash bin/cast doctor
  [ "$status" -eq 0 ]
  [[ "$output" =~ "MCP servers: 1 configured, all reachable" ]]
  [[ "$output" =~ "responding (HTTP 401)" ]]
  ! [[ "$output" =~ "unreachable" ]]
  ! [[ "$output" =~ "missing" ]]
}

@test "HTTP 403 classified as 'responding'" {
  mock_curl_with_code "403"

  local temp_scripts_dir="${HOME}/.claude-test-scripts"
  mkdir -p "$temp_scripts_dir/migrations"
  cp scripts/cast-migrate.py "$temp_scripts_dir/"
  export CAST_SCRIPTS_DIR="$temp_scripts_dir"

  sqlite3 "$CAST_DB_PATH" <<'SQL'
CREATE TABLE IF NOT EXISTS schema_migrations (id INTEGER PRIMARY KEY);
SQL

  mkdir -p "${HOME}/.claude/cast/events"
  mkdir -p "${HOME}/.claude/scripts"
  cat > "${HOME}/.claude/settings.json" <<'JSON'
{
  "hooks": {
    "PreToolUse": [
      { "command": "bash ~/.claude/scripts/h1.sh" },
      { "command": "bash ~/.claude/scripts/h2.sh" },
      { "command": "bash ~/.claude/scripts/h3.sh" },
      { "command": "bash ~/.claude/scripts/h4.sh" }
    ]
  }
}
JSON

  for i in 1 2 3 4; do
    touch "${HOME}/.claude/scripts/h${i}.sh"
    chmod +x "${HOME}/.claude/scripts/h${i}.sh"
  done

  local backup_root="${HOME}/Library/Application Support/cast/backups"
  mkdir -p "$backup_root"
  touch "$backup_root/cast-snapshot-latest"

  mkdir -p "${HOME}/Library/Application Support/cast"
  cat > "${HOME}/Library/Application Support/cast/litestream.yml" <<'LITE'
dbs:
  - path: ~/.claude/cast.db
LITE
  mkdir -p "${HOME}/Library/Application Support/cast/litestream/cast-db"
  touch "${HOME}/Library/Application Support/cast/litestream/cast-db/file"

  cat > "${HOME}/.claude.json" <<'JSON'
{
  "mcpServers": {
    "forbidden": {
      "url": "https://api.example.com/forbidden"
    }
  }
}
JSON

  run bash bin/cast doctor
  [ "$status" -eq 0 ]
  [[ "$output" =~ "MCP servers: 1 configured, all reachable" ]]
  [[ "$output" =~ "responding (HTTP 403)" ]]
}
