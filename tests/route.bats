#!/usr/bin/env bats

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
ROUTE_SH="$REPO_DIR/scripts/route.sh"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

prompt_json() {
  python3 -c "import json,sys; print(json.dumps({'prompt': sys.argv[1]}))" "$1"
}

run_route() {
  run bash "$ROUTE_SH" <<< "$(prompt_json "$1")"
}

# Read the last log entry's matched_route field
last_log_route() {
  tail -1 "$HOME/.claude/routing-log.jsonl" 2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin).get('matched_route') or '')" 2>/dev/null || echo ""
}

# Read the last log entry's action field
last_log_action() {
  tail -1 "$HOME/.claude/routing-log.jsonl" 2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin).get('action',''))" 2>/dev/null || echo ""
}

setup() {
  export ORIG_HOME="$HOME"
  export HOME="$(mktemp -d)"
  mkdir -p "$HOME/.claude/config"

  cat > "$HOME/.claude/config/routing-table.json" <<'EOF'
{
  "routes": [
    {
      "patterns": [
        "^/plan\\b",
        "plan.*implement",
        "implementation plan",
        "let's build",
        "add.*feature",
        "new feature needed",
        "^add.*page",
        "^add.*route"
      ],
      "agent": "planner",
      "command": "/plan",
      "post_chain": ["auto-dispatch-from-manifest"]
    },
    {
      "patterns": [
        "^/review\\b",
        "code review"
      ],
      "agent": "code-reviewer",
      "command": "/review",
      "post_chain": null
    }
  ],
  "opus_signals": {
    "prefix": "opus:",
    "complexity_patterns": ["design the entire"]
  }
}
EOF

  cat > "$HOME/.claude/config/agent-groups.json" <<'EOF'
{
  "version": "1.0",
  "groups": [
    {
      "id": "morning-start",
      "description": "Morning briefing",
      "patterns": ["good morning", "start my day"],
      "confidence": "hard",
      "waves": [
        { "id": 1, "description": "Briefing", "parallel": true, "agents": ["morning-briefing", "chain-reporter"] }
      ],
      "post_chain": []
    },
    {
      "id": "ship-it",
      "description": "Full ship pipeline",
      "patterns": ["ship it", "ready.*deploy"],
      "confidence": "hard",
      "waves": [
        { "id": 1, "description": "Verify and deploy", "parallel": true, "agents": ["verifier", "test-runner", "devops"] }
      ],
      "post_chain": ["auto-stager", "commit", "push"]
    },
    {
      "id": "daily-wrap",
      "description": "End-of-day wrap-up",
      "patterns": ["end of day", "wrap.*up.*day"],
      "confidence": "soft",
      "waves": [
        { "id": 1, "description": "Chain report", "parallel": true, "agents": ["chain-reporter", "verifier"] }
      ],
      "post_chain": []
    }
  ]
}
EOF
}

teardown() {
  rm -rf "$HOME"
  export HOME="$ORIG_HOME"
}

# ---------------------------------------------------------------------------
# 1. Subprocess guard
# ---------------------------------------------------------------------------

@test "subprocess guard: exits 0 with no output when CLAUDE_SUBPROCESS=1" {
  run env CLAUDE_SUBPROCESS=1 bash "$ROUTE_SH" <<< "$(prompt_json "add a login page")"
  assert_success
  assert_output ""
}

# ---------------------------------------------------------------------------
# 2. Logging-only behavior (no stdout output)
# ---------------------------------------------------------------------------

@test "logging: route.sh produces no stdout for unmatched prompts" {
  run_route "what is the capital of France"
  assert_success
  assert_output ""
}

@test "logging: unmatched prompt logs no_match action" {
  run_route "what is the capital of France"
  assert_equal "$(last_log_action)" "no_match"
}

@test "logging: matched prompt logs matched action with correct agent" {
  run_route "add a login page"
  assert_equal "$(last_log_action)" "matched"
  assert_equal "$(last_log_route)" "planner"
}

# ---------------------------------------------------------------------------
# 3. Pattern false-positive removal
# ---------------------------------------------------------------------------

@test "false-positive: 'we need to' does NOT trigger planner" {
  run_route "we need to think about this"
  assert_equal "$(last_log_action)" "no_match"
}

@test "false-positive: 'i want to' does NOT trigger planner" {
  run_route "i want to understand what this does"
  assert_equal "$(last_log_action)" "no_match"
}

@test "false-positive: 'finalize' does NOT trigger planner" {
  run_route "finalize the report"
  assert_equal "$(last_log_action)" "no_match"
}

@test "false-positive: 'wrap up' does NOT trigger planner" {
  run_route "wrap up the PR description"
  assert_equal "$(last_log_action)" "no_match"
}

@test "false-positive: standalone 'implement' does NOT trigger planner" {
  run_route "implement"
  assert_equal "$(last_log_action)" "no_match"
}

# ---------------------------------------------------------------------------
# 4. Pattern true-positives
# ---------------------------------------------------------------------------

@test "true-positive: 'add a login page' matches planner" {
  run_route "add a login page"
  assert_equal "$(last_log_route)" "planner"
}

@test "true-positive: \"let's build this\" matches planner" {
  run_route "let's build this"
  assert_equal "$(last_log_route)" "planner"
}

@test "true-positive: 'new feature needed' matches planner" {
  run_route "new feature needed"
  assert_equal "$(last_log_route)" "planner"
}

@test "true-positive: '/plan' matches planner" {
  run_route "/plan"
  assert_equal "$(last_log_route)" "planner"
}

@test "true-positive: 'code review' matches code-reviewer" {
  run_route "code review please"
  assert_equal "$(last_log_route)" "code-reviewer"
}

# ---------------------------------------------------------------------------
# 5. System message skip
# ---------------------------------------------------------------------------

@test "system skip: '<task-' produces no output and no log" {
  run_route "<task-notification> something"
  assert_success
  assert_output ""
}

@test "system skip: '<system-' produces no output and no log" {
  run_route "<system-reminder> always be helpful"
  assert_success
  assert_output ""
}

# ---------------------------------------------------------------------------
# 6. Group routing
# ---------------------------------------------------------------------------

@test "group routing: hard-confidence group match emits [CAST-DISPATCH-GROUP] directive" {
  run_route "good morning"
  assert_success
  assert_output --partial "CAST-DISPATCH-GROUP"
}

@test "group routing: matched output contains the group id" {
  run_route "good morning"
  assert_output --partial "morning-start"
}

@test "group routing: unmatched prompt falls through to routing-table" {
  run_route "code review please"
  assert_output --partial "CAST-DISPATCH"
  refute_output --partial "CAST-DISPATCH-GROUP"
}

@test "group routing: group pre-check runs before routing-table (group match wins)" {
  # 'good morning' matches group fixture but has no routing-table entry
  # so only CAST-DISPATCH-GROUP directive should appear — no single-agent directive
  run_route "good morning"
  assert_output --partial "CAST-DISPATCH-GROUP"
  refute_output --partial "\"agent\":"
}

@test "group routing: matching is case-insensitive" {
  run_route "GOOD MORNING"
  assert_success
  assert_output --partial "CAST-DISPATCH-GROUP"
  assert_output --partial "morning-start"
}

@test "group routing: directive format is [CAST-DISPATCH-GROUP: <id>]" {
  run_route "ship it"
  assert_output --partial "[CAST-DISPATCH-GROUP: ship-it]"
}

@test "group routing: soft-confidence group match still emits CAST-DISPATCH-GROUP directive" {
  run_route "end of day"
  assert_success
  assert_output --partial "CAST-DISPATCH-GROUP"
  assert_output --partial "daily-wrap"
}
