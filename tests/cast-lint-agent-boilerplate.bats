#!/usr/bin/env bats
# Tests for cast-lint-agent-boilerplate.sh
#
# Gate contract: exit 0 when no verbatim skill lines appear in agent defs;
# exit 1 when any sentinel is copy-pasted.
# Hermetic: uses temp dirs + CAST_AGENTS_DIR env override; never touches
# the real agents/core/ or ~/.claude during fixture tests.

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
LINT_SH="$REPO_DIR/scripts/cast-lint-agent-boilerplate.sh"

# ---------------------------------------------------------------------------
# Setup / Teardown — isolated temp HOME + fake agents dir per test
# ---------------------------------------------------------------------------

setup() {
  export ORIG_HOME="$HOME"
  export HOME="$(mktemp -d)"
  FAKE_AGENTS="$(mktemp -d)"
}

teardown() {
  [[ "$FAKE_AGENTS" == /tmp/* || "$FAKE_AGENTS" == /var/folders/* ]] \
    || { echo "refusing to rm outside tmp: $FAKE_AGENTS" >&2; return 1; }
  rm -rf "$FAKE_AGENTS"
  rm -rf "$HOME"
  export HOME="$ORIG_HOME"
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

_write_agent() {
  # Usage: _write_agent "filename.md" "body content"
  local fname="$1"
  local body="$2"
  printf '%s\n' "$body" > "$FAKE_AGENTS/$fname"
}

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

@test "exit 0 when agents dir is empty" {
  run env CAST_AGENTS_DIR="$FAKE_AGENTS" bash "$LINT_SH"
  assert_success
}

@test "exit 0 when agent only references skill by name (not verbatim)" {
  _write_agent "good-agent.md" "---
name: good-agent
skills: [cast-conventions]
---
## Protocol
See cast-conventions skill for the status-writer pattern and YAGNI principle.
"
  run env CAST_AGENTS_DIR="$FAKE_AGENTS" bash "$LINT_SH"
  assert_success
}

@test "exit 1 when agent contains verbatim status-writer source line" {
  _write_agent "bad-agent.md" "---
name: bad-agent
---
## Status
source ~/.claude/scripts/status-writer.sh 2>/dev/null || true
"
  run env CAST_AGENTS_DIR="$FAKE_AGENTS" bash "$LINT_SH"
  assert_failure
  assert_output --partial "bad-agent.md"
}

@test "exit 1 when agent contains verbatim YAGNI line" {
  _write_agent "bad-agent.md" "---
name: bad-agent
---
## Principles
- **YAGNI:** Build only what was asked. No extra features or nice-to-haves.
"
  run env CAST_AGENTS_DIR="$FAKE_AGENTS" bash "$LINT_SH"
  assert_failure
  assert_output --partial "bad-agent.md"
}

@test "error output names the matched sentinel (truncated)" {
  _write_agent "bad-agent.md" "source ~/.claude/scripts/status-writer.sh 2>/dev/null || true"
  run env CAST_AGENTS_DIR="$FAKE_AGENTS" bash "$LINT_SH"
  assert_failure
  assert_output --partial "matched sentinel:"
}

@test "exit 0 for clean agent with own status format section" {
  # Agent has its own Status block format section but NOT the verbatim skill lines
  _write_agent "clean-agent.md" "---
name: clean-agent
skills: [cast-conventions]
---
## Completion Report

Status: DONE | DONE_WITH_CONCERNS | BLOCKED | NEEDS_CONTEXT
Summary: [what was done]
Concerns: [if DONE_WITH_CONCERNS]
"
  run env CAST_AGENTS_DIR="$FAKE_AGENTS" bash "$LINT_SH"
  assert_success
}

@test "exit 1 when agent contains cast_write_status template with placeholders" {
  _write_agent "bad-agent.md" '---
name: bad-agent
---
cast_write_status "<STATUS>" "<one-line summary>" "<your-agent-name>" "<concerns or empty>" 2>/dev/null || true
'
  run env CAST_AGENTS_DIR="$FAKE_AGENTS" bash "$LINT_SH"
  assert_failure
  assert_output --partial "bad-agent.md"
}

@test "exit 1 when agent contains status file prose instruction opening" {
  _write_agent "bad-agent.md" "Before emitting your prose Status line, write a machine-readable status file at ~/.claude/agent-status/..."
  run env CAST_AGENTS_DIR="$FAKE_AGENTS" bash "$LINT_SH"
  assert_failure
}

@test "finding includes line number" {
  _write_agent "bad-agent.md" "---
name: bad-agent
---
## Notes
source ~/.claude/scripts/status-writer.sh 2>/dev/null || true
"
  run env CAST_AGENTS_DIR="$FAKE_AGENTS" bash "$LINT_SH"
  assert_failure
  # Line 5 contains the sentinel
  assert_output --partial "bad-agent.md:5:"
}

@test "multiple agents — only failing agent is reported" {
  _write_agent "clean.md" "---
name: clean
---
References the cast-conventions skill by name only."
  _write_agent "dirty.md" "source ~/.claude/scripts/status-writer.sh 2>/dev/null || true"
  run env CAST_AGENTS_DIR="$FAKE_AGENTS" bash "$LINT_SH"
  assert_failure
  assert_output --partial "dirty.md"
  refute_output --partial "clean.md"
}
