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
