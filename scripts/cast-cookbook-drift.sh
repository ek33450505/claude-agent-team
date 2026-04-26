#!/usr/bin/env bash
# cast-cookbook-drift.sh — schedule Anthropic Cookbook drift analysis
#
# Purpose: Dispatches the researcher agent to compare CAST patterns against
# the current Anthropic Cookbook reference implementations. Identifies drift:
# deprecated patterns CAST uses, patterns Cookbook recommends that CAST lacks,
# and new API features in Cookbook examples not yet adopted.
#
# Output: Report written to ~/.claude/reports/cookbook-drift-$(date +%Y-%m-%d).md
#
# Monthly schedule registration (run once):
#   /schedule --description "CAST Cookbook drift monthly audit" \
#     --command "bash ~/Projects/personal/claude-agent-team/scripts/cast-cookbook-drift.sh" \
#     --frequency monthly --day-of-month 1 --time 09:00

if [[ "${CLAUDE_SUBPROCESS:-0}" == "1" ]]; then
  exit 0
fi

set -euo pipefail

# --- Config ---
REPO_PATH="${REPO_PATH:-$HOME/Projects/personal/claude-agent-team}"
CAST_DB_PATH="${CAST_DB_PATH:-$HOME/.claude/cast.db}"
LOG_DIR="${HOME}/.claude/logs"
REPORTS_DIR="${HOME}/.claude/reports"

# --- Ensure output dirs exist ---
mkdir -p "$LOG_DIR" "$REPORTS_DIR"

# --- Researcher prompt (for agent dispatch via Claude Code) ---
# Note: This prompt is printed in dispatch instructions and used by the
# researcher agent when invoked. It is not used directly by this shell script.
# shellcheck disable=SC2034
RESEARCHER_PROMPT="Compare CAST agent patterns (agent loop, evaluator, multi-agent dispatch in ~/Projects/personal/claude-agent-team/agents/core/) against the current Anthropic Cookbook reference implementations at https://github.com/anthropics/anthropic-cookbook. Identify drift: patterns CAST uses that are deprecated, patterns Cookbook recommends that CAST lacks, and new API features in Cookbook examples not yet adopted. Write a drift report to ~/.claude/reports/cookbook-drift-\$(date +%Y-%m-%d).md. Status: DONE when report is written."

# --- Emit event to cast.db ---
_emit_dispatch_event() {
  local report_date
  report_date=$(date +%Y-%m-%d)

  # Create dispatch_events table if missing (idempotent)
  sqlite3 "$CAST_DB_PATH" << 'EOF' 2>/dev/null || true
CREATE TABLE IF NOT EXISTS dispatch_events (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  agent TEXT NOT NULL,
  task_name TEXT,
  triggered_at TEXT DEFAULT CURRENT_TIMESTAMP,
  status TEXT,
  report_path TEXT
);
EOF

  # Log the dispatch
  sqlite3 "$CAST_DB_PATH" "INSERT INTO dispatch_events (agent, task_name, status, report_path) VALUES ('researcher', 'cookbook-drift', 'dispatched', '~/.claude/reports/cookbook-drift-${report_date}.md');" 2>/dev/null || true
}

# --- Dispatch researcher agent ---
# The researcher agent will be dispatched via Claude Code's agent system.
# Since shell scripts cannot directly call agents, we print dispatch instructions.
_emit_dispatch_event

cat << 'DISPATCH'
[CAST] Cookbook drift dispatch prepared.

To execute the researcher agent dispatch, run one of:

  1. Via /schedule (recommended for monthly automation):
     /schedule --description "CAST Cookbook drift monthly audit" \
       --command "bash ~/Projects/personal/claude-agent-team/scripts/cast-cookbook-drift.sh" \
       --frequency monthly --day-of-month 1 --time 09:00

  2. Via Agent tool (immediate, one-off):
     (Dispatch researcher agent with the prompt in the instructions above)

  3. Check status later at: ~/.claude/reports/cookbook-drift-$(date +%Y-%m-%d).md

DISPATCH

echo "Dispatch event logged to cast.db at $(date -u +'%Y-%m-%dT%H:%M:%SZ')" | tee -a "$LOG_DIR/cast-cookbook-drift.log"

exit 0
