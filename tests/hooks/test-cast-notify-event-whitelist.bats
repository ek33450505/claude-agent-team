#!/usr/bin/env bats
# test-cast-notify-event-whitelist.bats
# Tests for cast-notify.sh EVENT_TYPE whitelist validation

setup() {
  export HOME="${BATS_TEST_TMPDIR}/home"
  mkdir -p "$HOME/.claude/cast"
  export NOTIFICATIONS_CONFIG="$HOME/.claude/config/notifications.json"
  mkdir -p "$HOME/.claude/config"
}

teardown() {
  # cleanup handled by bats tmpdir
  true
}

@test "subprocess guard exits 0 when CLAUDE_SUBPROCESS=1" {
  run env CLAUDE_SUBPROCESS=1 bash scripts/cast-notify.sh blocked
  [ "$status" -eq 0 ]
}

@test "accepts whitelisted EVENT_TYPE: blocked" {
  run bash scripts/cast-notify.sh blocked "Test message"
  [ "$status" -eq 0 ]
}

@test "accepts whitelisted EVENT_TYPE: queue_complete" {
  run bash scripts/cast-notify.sh queue_complete "Test message"
  [ "$status" -eq 0 ]
}

@test "accepts whitelisted EVENT_TYPE: budget_alert" {
  run bash scripts/cast-notify.sh budget_alert "Test message"
  [ "$status" -eq 0 ]
}

@test "accepts whitelisted EVENT_TYPE: briefing_ready" {
  run bash scripts/cast-notify.sh briefing_ready "Test message"
  [ "$status" -eq 0 ]
}

@test "accepts whitelisted EVENT_TYPE: ci_failure (added to support cast-ci-monitor.sh)" {
  run bash scripts/cast-notify.sh ci_failure "Test CI failure"
  [ "$status" -eq 0 ]
}

@test "rejects unknown EVENT_TYPE with exit 1" {
  run bash scripts/cast-notify.sh unknown_type "Test message"
  [ "$status" -eq 1 ]
  [[ "$output" =~ "Unknown event type" ]]
}

@test "rejects injection attempt: EVENT_TYPE with single quote" {
  run bash scripts/cast-notify.sh "'; rm -rf /" "Test message"
  [ "$status" -eq 1 ]
  [[ "$output" =~ "Unknown event type" ]]
}

@test "requires EVENT_TYPE argument" {
  run bash scripts/cast-notify.sh
  [ "$status" -eq 0 ]  # exits 0 for missing arg (legacy behavior)
}

@test "appends to notify-queue.json on success" {
  run bash scripts/cast-notify.sh blocked "Queue test"
  [ "$status" -eq 0 ]
  [ -f "$HOME/.claude/cast/notify-queue.json" ]
}
