#!/usr/bin/env bats
# backend-frontend-writer-chains.bats — Contract tests for backend-writer and frontend-writer
# chain/group configuration.
#
# RATIONALE: The backend-writer and frontend-writer agents were added to the codebase to support
# parallel implementation waves. This test guards:
#   1. Both agents are defined in config/chain-map.json and chain to ["code-reviewer"]
#   2. The "full-feature-implementation" group in config/agent-groups.json includes a parallel
#      wave-2-implement with both agents, marked parallel: true, and post_chain: ["code-reviewer", "commit"]
#
# These configs are critical to the CAST dispatch chain and agent orchestration. Regressions here
# would silently break feature-dispatch fan-out.

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
CHAIN_MAP="$REPO_DIR/config/chain-map.json"
AGENT_GROUPS="$REPO_DIR/config/agent-groups.json"

# ---------------------------------------------------------------------------
# chain-map.json tests
# ---------------------------------------------------------------------------

@test "chain-map.json: file exists" {
  [ -f "$CHAIN_MAP" ]
}

@test "chain-map.json: valid JSON" {
  run jq empty "$CHAIN_MAP"
  assert_success
}

@test "chain-map.json: backend-writer key exists" {
  run jq '.["backend-writer"]' "$CHAIN_MAP"
  assert_success
  [ -n "$output" ] && [ "$output" != "null" ]
}

@test "chain-map.json: backend-writer chains to code-reviewer" {
  run jq -r '.["backend-writer"] | .[]' "$CHAIN_MAP"
  assert_success
  assert_output "code-reviewer"
}

@test "chain-map.json: frontend-writer key exists" {
  run jq '.["frontend-writer"]' "$CHAIN_MAP"
  assert_success
  [ -n "$output" ] && [ "$output" != "null" ]
}

@test "chain-map.json: frontend-writer chains to code-reviewer" {
  run jq -r '.["frontend-writer"] | .[]' "$CHAIN_MAP"
  assert_success
  assert_output "code-reviewer"
}

# ---------------------------------------------------------------------------
# agent-groups.json tests
# ---------------------------------------------------------------------------

@test "agent-groups.json: file exists" {
  [ -f "$AGENT_GROUPS" ]
}

@test "agent-groups.json: valid JSON" {
  run jq empty "$AGENT_GROUPS"
  assert_success
}

@test "agent-groups.json: groups array exists" {
  run jq '.groups' "$AGENT_GROUPS"
  assert_success
  assert_output --regexp '\['
}

@test "agent-groups.json: full-feature-implementation group exists" {
  run jq -r '.groups[] | select(.id == "full-feature-implementation") | .id' "$AGENT_GROUPS"
  assert_success
  assert_output "full-feature-implementation"
}

@test "agent-groups.json: full-feature-implementation group has waves" {
  run jq '.groups[] | select(.id == "full-feature-implementation") | .waves' "$AGENT_GROUPS"
  assert_success
  [[ "$output" == *"wave-2-implement"* ]]
}

@test "agent-groups.json: wave-2-implement exists in full-feature-implementation" {
  run jq -r '.groups[] | select(.id == "full-feature-implementation") | .waves[] | select(.id == "wave-2-implement") | .id' "$AGENT_GROUPS"
  assert_success
  assert_output "wave-2-implement"
}

@test "agent-groups.json: wave-2-implement is parallel: true" {
  run jq '.groups[] | select(.id == "full-feature-implementation") | .waves[] | select(.id == "wave-2-implement") | .parallel' "$AGENT_GROUPS"
  assert_success
  assert_output "true"
}

@test "agent-groups.json: wave-2-implement agents includes backend-writer" {
  run jq '.groups[] | select(.id == "full-feature-implementation") | .waves[] | select(.id == "wave-2-implement") | .agents[]' "$AGENT_GROUPS"
  assert_success
  assert_output --partial "backend-writer"
}

@test "agent-groups.json: wave-2-implement agents includes frontend-writer" {
  run jq '.groups[] | select(.id == "full-feature-implementation") | .waves[] | select(.id == "wave-2-implement") | .agents[]' "$AGENT_GROUPS"
  assert_success
  assert_output --partial "frontend-writer"
}

@test "agent-groups.json: wave-2-implement has exactly 2 agents (backend-writer and frontend-writer)" {
  run jq '.groups[] | select(.id == "full-feature-implementation") | .waves[] | select(.id == "wave-2-implement") | .agents | length' "$AGENT_GROUPS"
  assert_success
  assert_output "2"
}

@test "agent-groups.json: full-feature-implementation post_chain includes code-reviewer and commit" {
  run jq '.groups[] | select(.id == "full-feature-implementation") | .post_chain | contains(["code-reviewer", "commit"])' "$AGENT_GROUPS"
  assert_success
  assert_output "true"
}

@test "agent-groups.json: full-feature-implementation post_chain has code-reviewer first, commit second" {
  run jq '.groups[] | select(.id == "full-feature-implementation") | .post_chain | .[0] == "code-reviewer" and .[1] == "commit"' "$AGENT_GROUPS"
  assert_success
  assert_output "true"
}

# ---------------------------------------------------------------------------
# Consistency checks across both files
# ---------------------------------------------------------------------------

@test "consistency: backend-writer appears in both chain-map and agent-groups" {
  run jq '.["backend-writer"]' "$CHAIN_MAP"
  assert_success
  run jq '.groups[].waves[].agents[] | select(. == "backend-writer")' "$AGENT_GROUPS"
  assert_success
}

@test "consistency: frontend-writer appears in both chain-map and agent-groups" {
  run jq '.["frontend-writer"]' "$CHAIN_MAP"
  assert_success
  run jq '.groups[].waves[].agents[] | select(. == "frontend-writer")' "$AGENT_GROUPS"
  assert_success
}
