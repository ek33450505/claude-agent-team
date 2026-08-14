Run a comprehensive CAST system health check.

$ARGUMENTS

Executes `bash ~/.claude/scripts/cast-validate.sh` (structural checks) **and** `cast doctor`
(honesty + durability surface), then reports:
- Hook wiring: registration, script resolution, double-fire risk
- Agent count vs expected, frontmatter validity, and ghost-name cross-check
  (`chain-map.json`, `policies.json`, `agent-groups.json`)
- cast.db accessibility, schema/migration state, and table counts
- Scheduled-routine status (`launchctl list | grep cast` — the `com.cast.*` agents;
  the old `castd` daemon is retired, replaced by launchd/cron)
- Durability: backup + snapshot age, litestream replica lag, offline queue depth
- Honesty signals: hallucinations, protocol violations, silent truncations,
  and any BLOCKED / stuck-`running` agent runs

Surface any failures as actionable items.

Before acting on a flagged item, read the source line that emits it. Several checks
report conditions that are self-healing or working-as-designed, and at least one has
been observed giving advice that is wrong for its actual input population — the
message alone is not sufficient grounds to change anything on disk.
