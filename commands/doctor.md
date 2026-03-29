Run a comprehensive CAST system health check.

$ARGUMENTS

Executes `bash ~/Projects/personal/claude-agent-team/scripts/cast-validate.sh` and reports:
- Hook status (existence, executable bit, last-fired timestamp)
- Agent count vs expected
- Routing table coverage (agents with and without routes)
- cast.db accessibility and table counts
- castd daemon status
- Any BLOCKED agent escalations in recent event log

Surface any failures as actionable items.
