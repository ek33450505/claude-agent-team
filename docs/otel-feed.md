# CAST Native OTLP Feed

**Status:** Increment 1 — feed plumbing live. Duplicate recorder-hook retirement deferred to a later increment.

## What This Is

Claude Code emits native OpenTelemetry signals (metrics + events/logs) continuously. CAST captures this stream in a **local-only OTLP receiver** and sinks it into `cast.db` — the same durable store you query for session data, agent runs, and routing decisions.

**Core principle:** One feed in, one store, many read-surfaces. OTLP is the *feed*. cast.db remains the *durable store* and *query surface*. The feed plumbing unlocks native-first architecture without cloud lock-in.

## Architecture

```
┌──────────────┐
│  Claude Code │  native telemetry (metrics + events)
└──────┬───────┘
       │ OTLP + gzip
       │ HTTP POST → /v1/metrics, /v1/logs, /v1/traces
       ▼
127.0.0.1:4318 (localhost, enforced; never remote)
┌─────────────────────────────────────┐
│ cast-otel-collector.py (daemon)     │
│ • fail-open (HTTP 200 on error)     │
│ • auto-decompresses gzip            │
│ • logs to ~/.claude/logs/            │
│ • runs via launchd                  │
└──────────────┬──────────────────────┘
               │ parameterized SQL
               │ (cast.db.db_execute)
               ▼
       ~/.claude/cast.db
    ┌─────────────────────┐
    │ otel_metrics        │ 8 metric types
    │ otel_events         │ 15 event types
    └─────────────────────┘
               ▲
               │
    (many read-surfaces:
     queries, dashboards,
     honesty checks, doctor)
```

## Default State: ON (Local-First)

**Default state:** ON. The OTEL feed is active after a fresh `bash install.sh`.

All telemetry goes **only to localhost:4318** — enforced at the socket level. Nothing is sent to Anthropic or any remote endpoint. This is separate from Anthropic's own operational telemetry (governed by `DISABLE_TELEMETRY`, which CAST sets to `1` simultaneously to opt out of that).

**Privacy guarantee (doc-verified against code.claude.com):**
- `CLAUDE_CODE_ENABLE_TELEMETRY` and the `OTEL_*` exporter keys control where Claude Code sends its native OTLP signals — these go to our local collector at `127.0.0.1:4318`, never off-machine.
- `DISABLE_TELEMETRY=1` opts out of Anthropic's separate operational telemetry. CAST sets this in the same fragment so both concerns are covered.
- Content logging (prompt text, tool arguments, API response bodies) requires explicit `OTEL_LOG_*` opt-in keys. CAST does NOT set these. What lands in `cast.db` is **metadata only** — counts, durations, event names.

To turn the local feed off: `bash scripts/cast-otel.sh disable`

## Verified Environment Variables

These 6 keys ship in `managed-settings.d/00-env.json` (the durable source of truth — survives reinstall):

| Key | Value | Purpose |
|-----|-------|---------|
| `CLAUDE_CODE_ENABLE_TELEMETRY` | `1` | Activates Claude Code's native OTLP emission |
| `OTEL_METRICS_EXPORTER` | `otlp` | Sends metrics to the OTLP endpoint |
| `OTEL_LOGS_EXPORTER` | `otlp` | Sends events/logs to the OTLP endpoint |
| `OTEL_EXPORTER_OTLP_PROTOCOL` | `http/json` | Wire format |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | `http://localhost:4318` | Local collector only |
| `DISABLE_TELEMETRY` | `1` | Opts out of Anthropic operational telemetry |

**Note:** No `OTEL_LOG_*` content-logging keys are set. Metadata only.

**Port override:** Set `CAST_OTEL_PORT` to bind to a different port (default: 4318).

## Enable / Disable

The feed is **ON by default** after install. The daemon (`com.cast.otel-collector`) auto-starts at login via launchd (`RunAtLoad=true`).

### Disable collector and telemetry

```bash
bash scripts/cast-otel.sh disable
```

This command:
1. Removes the 5 OTEL telemetry keys from `~/.claude/managed-settings.d/00-env.json` (the durable fragment)
2. Regenerates `~/.claude/settings.json` from fragments
3. Unloads the launchd agent

The change survives reinstall because `disable` writes to the fragment, not just `settings.json`.

### Re-enable collector and telemetry

```bash
bash scripts/cast-otel.sh enable
```

This command:
1. Ensures the 5 OTEL telemetry keys are present in `~/.claude/managed-settings.d/00-env.json`
2. Regenerates `~/.claude/settings.json` from fragments
3. Loads the launchd agent

### Check status

```bash
bash scripts/cast-otel.sh status
```

Displays:
- Daemon status (loaded/not loaded, process running)
- Telemetry env key presence in settings.json
- Row counts in `otel_metrics` and `otel_events`

### Start / Stop daemon without config changes

```bash
bash scripts/cast-otel.sh start    # launchctl load (no settings.json mutation)
bash scripts/cast-otel.sh stop     # launchctl unload (no settings.json mutation)
```

Use these if you want to pause the daemon without removing the telemetry keys from settings.json.

**Remember:** Restart Claude Code sessions for telemetry to take effect.

## Local-First Guarantee

- **Bind address:** 127.0.0.1 only — enforced at the socket level. OTLP never binds to a remote interface, never opens to the network.
- **Data residency:** all telemetry lands in `~/.claude/cast.db` on your machine, never sent to the cloud.
- **Content privacy:** By default, Claude Code does NOT set the OTEL_LOG_* opt-ins that would emit prompt text, tool arguments, or response bodies. The event `body` field contains the log-record message and attributes only; sensitive content is not captured.

## What Lands in cast.db

### otel_metrics

Captures Claude Code's internal metrics (CPU, memory, token counts, agent performance timings, etc.).

| Column | Type | Notes |
|--------|------|-------|
| id | INTEGER | auto-increment |
| session_id | TEXT | correlates to sessions table (if set) |
| metric_name | TEXT | e.g., `claude.code.agent.duration_ms`, `claude.code.tokens.input`, etc. (8 types) |
| value | REAL | numeric value (int or float, coerced to float) |
| unit | TEXT | e.g., `ms`, `token`, `percent` |
| attributes | TEXT | JSON: merged resource-level + datapoint-level OTLP attributes |
| time_unix_nano | INTEGER | nanosecond timestamp from Claude Code |
| received_at | TEXT | UTC timestamp when CAST receiver processed the metric |

### otel_events

Captures Claude Code's event stream (task lifecycle, agent state changes, tool invocations, etc.).

| Column | Type | Notes |
|--------|------|-------|
| id | INTEGER | auto-increment |
| session_id | TEXT | correlates to sessions table (if set) |
| event_name | TEXT | e.g., `agent.started`, `tool.called`, `session.ended` (15+ event types) |
| prompt_id | TEXT | prompt correlation ID (when present in event attributes) |
| severity | TEXT | e.g., `INFO`, `WARN`, `ERROR` |
| body | TEXT | JSON: log-record message + all OTLP attributes |
| time_unix_nano | INTEGER | nanosecond timestamp from Claude Code |
| received_at | TEXT | UTC timestamp when CAST receiver processed the event |

## Traces / Spans (Beta — Deferred)

Claude Code may emit OTLP traces (`/v1/traces` POST requests). The receiver accepts these with HTTP 200 (success) but currently ignores them (no-op):

```
POST http://localhost:4318/v1/traces
→ HTTP 200 {}
```

Trace support is a future increment. No span data is currently stored.

## Troubleshooting

### Daemon not running

Check status:
```bash
bash scripts/cast-otel.sh status
```

If the process is not running, start it:
```bash
bash scripts/cast-otel.sh start
```

If it fails to start, check the logs:
```bash
tail -f ~/.claude/logs/otel-collector.log
```

### Port already in use

If port 4318 is in use, override it:
```bash
export CAST_OTEL_PORT=4319
bash scripts/cast-otel.sh start
```

Then update `OTEL_EXPORTER_OTLP_ENDPOINT` in `~/.claude/settings.json` → `env` to match.

### Check row counts

Query the tables directly:
```bash
sqlite3 ~/.claude/cast.db "SELECT COUNT(*) FROM otel_metrics;"
sqlite3 ~/.claude/cast.db "SELECT COUNT(*) FROM otel_events;"
```

If the counts are 0 and you have a running Claude Code session with telemetry enabled, check the logs (see below).

### View receiver logs

```bash
tail -f ~/.claude/logs/otel-collector.log
```

Logs include:
- Server startup / shutdown events
- Gzip decompression errors
- JSON parse errors
- Database write failures
- Per-request metrics/event counts

The receiver is **fail-open:** errors are logged but never crash the daemon or backpressure Claude Code. HTTP responses are always 200 (success).
