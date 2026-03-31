#!/usr/bin/env bats
# tests/agents/effort-frontmatter.bats — Task 2.5: effort field presence
# Asserts every agent file in agents/core/ has an effort: field in its frontmatter.

bats_require_minimum_version 1.5.0

load '../test_helper/bats-support/load'
load '../test_helper/bats-assert/load'

AGENTS_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../agents/core" && pwd)"

@test "bash-specialist has effort field" {
  grep -q "^effort:" "$AGENTS_DIR/bash-specialist.md"
}

@test "code-reviewer has effort field" {
  grep -q "^effort:" "$AGENTS_DIR/code-reviewer.md"
}

@test "code-writer has effort field" {
  grep -q "^effort:" "$AGENTS_DIR/code-writer.md"
}

@test "commit has effort field" {
  grep -q "^effort:" "$AGENTS_DIR/commit.md"
}

@test "debugger has effort field" {
  grep -q "^effort:" "$AGENTS_DIR/debugger.md"
}

@test "devops has effort field" {
  grep -q "^effort:" "$AGENTS_DIR/devops.md"
}

@test "docs has effort field" {
  grep -q "^effort:" "$AGENTS_DIR/docs.md"
}

@test "frontend-qa has effort field" {
  grep -q "^effort:" "$AGENTS_DIR/frontend-qa.md"
}

@test "merge has effort field" {
  grep -q "^effort:" "$AGENTS_DIR/merge.md"
}

@test "morning-briefing has effort field" {
  grep -q "^effort:" "$AGENTS_DIR/morning-briefing.md"
}

@test "orchestrator has effort field" {
  grep -q "^effort:" "$AGENTS_DIR/orchestrator.md"
}

@test "planner has effort field" {
  grep -q "^effort:" "$AGENTS_DIR/planner.md"
}

@test "push has effort field" {
  grep -q "^effort:" "$AGENTS_DIR/push.md"
}

@test "researcher has effort field" {
  grep -q "^effort:" "$AGENTS_DIR/researcher.md"
}

@test "security has effort field" {
  grep -q "^effort:" "$AGENTS_DIR/security.md"
}

@test "test-runner has effort field" {
  grep -q "^effort:" "$AGENTS_DIR/test-runner.md"
}

@test "test-writer has effort field" {
  grep -q "^effort:" "$AGENTS_DIR/test-writer.md"
}
