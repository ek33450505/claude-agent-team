#!/usr/bin/env bats

# Tests for three new cast doctor checks:
# - Check 14: Agent frontmatter parses
# - Check 15: MCP servers reachable
# - Check 16: Routines validate

setup() {
  load 'helpers/setup'
  setup_temp_home  # sets HOME to a temp dir; exports ORIG_HOME
  export CAST_AGENTS_DIR="${HOME}/.claude/agents"
  # Use an isolated temp dir as the "repo" — never touch the real repo's routines/
  export CAST_REPO_DIR="${HOME}/fake-repo"
  mkdir -p "$CAST_AGENTS_DIR"
  mkdir -p "${HOME}/.claude/cast/events"
  mkdir -p "${CAST_REPO_DIR}/routines"
}

teardown() {
  teardown_temp_home
}

@test "check 14: agent frontmatter validates valid agent" {
  cat > "${CAST_AGENTS_DIR}/valid-agent.md" <<'AGENT'
---
name: test-agent
description: A test agent
tools:
  - bash
model: haiku
---

Body content here.
AGENT

  run bash bin/cast doctor
  [ "$status" -eq 0 ]
  [[ "$output" =~ "Agent frontmatter: all 1 pass native format check" ]]
}

@test "check 14: agent frontmatter catches missing name" {
  cat > "${CAST_AGENTS_DIR}/bad-agent.md" <<'AGENT'
---
description: A test agent
tools:
  - bash
---

Body.
AGENT

  run bash bin/cast doctor
  [ "$status" -eq 0 ]
  [[ "$output" =~ "Agent frontmatter: errors found" ]]
  [[ "$output" =~ "bad-agent.md: missing 'name'" ]]
}

@test "check 14: agent frontmatter catches missing description" {
  cat > "${CAST_AGENTS_DIR}/no-desc.md" <<'AGENT'
---
name: test
tools:
  - bash
---

Body.
AGENT

  run bash bin/cast doctor
  [ "$status" -eq 0 ]
  [[ "$output" =~ "Agent frontmatter: errors found" ]]
  [[ "$output" =~ "no-desc.md: missing 'description'" ]]
}

@test "check 14: agent frontmatter catches missing tools" {
  cat > "${CAST_AGENTS_DIR}/no-tools.md" <<'AGENT'
---
name: test
description: Test
---

Body.
AGENT

  run bash bin/cast doctor
  [ "$status" -eq 0 ]
  [[ "$output" =~ "Agent frontmatter: errors found" ]]
  [[ "$output" =~ "no-tools.md: missing 'tools'" ]]
}

@test "check 14: agent frontmatter catches no frontmatter block" {
  echo "Body only, no frontmatter." > "${CAST_AGENTS_DIR}/bare.md"

  run bash bin/cast doctor
  [ "$status" -eq 0 ]
  [[ "$output" =~ "Agent frontmatter: errors found" ]]
  [[ "$output" =~ "bare.md: no frontmatter block" ]]
}

@test "check 15: MCP servers reports none configured" {
  cat > "${HOME}/.claude/settings.json" <<'JSON'
{
  "hooks": {},
  "mcpServers": {}
}
JSON

  run bash bin/cast doctor
  [ "$status" -eq 0 ]
  [[ "$output" =~ "MCP servers: none in settings.json" ]]
}

@test "check 15: MCP servers reports healthy HTTP server" {
  cat > "${HOME}/.claude/settings.json" <<'JSON'
{
  "hooks": {},
  "mcpServers": {
    "test-server": {
      "url": "http://localhost:3000"
    }
  }
}
JSON

  # Mock curl to succeed (status 0 = reachable)
  cat > "${HOME}/curl-mock.sh" <<'CURL'
#!/bin/bash
exit 0
CURL
  chmod +x "${HOME}/curl-mock.sh"

  # Replace curl in PATH
  export PATH="${HOME}:$PATH"
  ln -sf "${HOME}/curl-mock.sh" "${HOME}/curl"

  run bash bin/cast doctor
  [ "$status" -eq 0 ]
  [[ "$output" =~ "MCP servers: 1 configured, all reachable" ]]
}

@test "check 15: MCP servers reports unreachable server" {
  cat > "${HOME}/.claude/settings.json" <<'JSON'
{
  "hooks": {},
  "mcpServers": {
    "broken-server": {
      "url": "http://127.0.0.1:9999"
    }
  }
}
JSON

  run bash bin/cast doctor
  [ "$status" -eq 0 ]
  [[ "$output" =~ "MCP servers:" ]]
  [[ "$output" =~ "broken-server" ]]
}

@test "check 15: MCP servers handles command-type servers" {
  cat > "${HOME}/.claude/settings.json" <<'JSON'
{
  "hooks": {},
  "mcpServers": {
    "test-cmd": {
      "command": "bash"
    }
  }
}
JSON

  run bash bin/cast doctor
  [ "$status" -eq 0 ]
  [[ "$output" =~ "MCP servers: 1 configured, all reachable" ]]
}

@test "check 16: routines reports none configured" {
  run bash bin/cast doctor
  [ "$status" -eq 0 ]
  [[ "$output" =~ "Routines: none configured" ]]
}

@test "check 16: routines validates required fields" {
  cat > "${CAST_REPO_DIR}/routines/daily.yaml" <<'YAML'
name: daily-routine
agent: researcher
prompt_template: "Summarize today"
schedule: "0 9 * * *"
YAML

  run bash bin/cast doctor
  [ "$status" -eq 0 ]
  [[ "$output" =~ "Routines: 1 configured, all schemas valid" ]]
}

@test "check 16: routines catches missing name" {
  cat > "${CAST_REPO_DIR}/routines/bad.yaml" <<'YAML'
agent: researcher
prompt_template: "Test"
YAML

  run bash bin/cast doctor
  [ "$status" -eq 0 ]
  [[ "$output" =~ "Routines:" ]]
  [[ "$output" =~ "with schema errors" ]]
  [[ "$output" =~ "bad.yaml: missing 'name'" ]]
}

@test "check 16: routines catches missing agent" {
  cat > "${CAST_REPO_DIR}/routines/bad.yaml" <<'YAML'
name: test
prompt_template: "Test"
YAML

  run bash bin/cast doctor
  [ "$status" -eq 0 ]
  [[ "$output" =~ "Routines:" ]]
  [[ "$output" =~ "with schema errors" ]]
  [[ "$output" =~ "bad.yaml: missing 'agent'" ]]
}

@test "check 16: routines catches missing prompt_template" {
  cat > "${CAST_REPO_DIR}/routines/bad.yaml" <<'YAML'
name: test
agent: researcher
YAML

  run bash bin/cast doctor
  [ "$status" -eq 0 ]
  [[ "$output" =~ "Routines:" ]]
  [[ "$output" =~ "with schema errors" ]]
  [[ "$output" =~ "bad.yaml: missing 'prompt_template'" ]]
}

@test "check 16: routines handles .yml extension" {
  cat > "${CAST_REPO_DIR}/routines/weekly.yml" <<'YAML'
name: weekly
agent: code-reviewer
prompt_template: "Review"
YAML

  run bash bin/cast doctor
  [ "$status" -eq 0 ]
  [[ "$output" =~ "Routines: 1 configured, all schemas valid" ]]
}

@test "check 14: CAST_AGENT_CONVENTIONS.md is skipped by frontmatter scope filter" {
  # Create a conventions file (uppercase, no frontmatter) alongside a valid agent.
  # The conventions file should be silently skipped, not trigger frontmatter errors.
  cat > "${CAST_AGENTS_DIR}/CAST_AGENT_CONVENTIONS.md" <<'CONV'
# Agent Conventions

This is a conventions document with no frontmatter.

## Rules

- All agents must have frontmatter
- etc.
CONV

  # Also create a valid agent so the check runs
  cat > "${CAST_AGENTS_DIR}/valid-agent.md" <<'AGENT'
---
name: test-agent
description: A test agent
tools:
  - bash
model: haiku
---

Body content here.
AGENT

  run bash bin/cast doctor
  [ "$status" -eq 0 ]
  [[ "$output" =~ "Agent frontmatter:" ]]
  # Ensure no errors were triggered
  ! [[ "$output" =~ "errors found" ]]
  # Ensure conventions file was not mentioned in output
  ! [[ "$output" =~ "CAST_AGENT_CONVENTIONS" ]]
}
