# cast.db as an MCP Server — `cast mcp`

**Status:** Shipped in CAST v9 F4

## What It Is

`cast mcp serve` exposes the CAST observability record (cast.db) as a **read-only Model Context Protocol (MCP) server** over stdio. Any Claude Code session can connect to the local server and query the record: "What did we decide? What broke? What did it cost?" Everything stays on your machine.

The server is a lightweight, stdlib-only Python stdio server (`scripts/cast-mcp-server.py`) that opens cast.db in read-only mode and surfaces five curated tools: routing decisions, incident log, cost attribution, session metadata, and full-text search. It identifies as `cast-record` v1.0.0 and speaks MCP protocol version `2025-06-18`.

**Core principle:** One durable store (cast.db), many read-surfaces. MCP is a native boundary instead of bespoke `cast` plumbing — any session, dashboard, or teammate can query the record over a standard protocol.

**Default state:** OFF (inert). You must opt in.

---

## Quick Start

### Option 1: Add to `.mcp.json`

In a project directory, add the server to the project's `.mcp.json`:

```json
{
  "mcpServers": {
    "cast-record": {
      "type": "stdio",
      "command": "cast",
      "args": ["mcp", "serve"]
    }
  }
}
```

Restart Claude Code; the server is then available in sessions opened in that project. `cast mcp config` prints this snippet anytime.

### Option 2: Register via CLI

```bash
claude mcp add cast-record -- cast mcp serve
```

### Verify

```bash
cast mcp status
```

Output (the runtime prints fully-resolved absolute paths; shown here with `~` for brevity):

```
cast mcp: server ~/.claude/scripts/cast-mcp-server.py
cast mcp: cast.db ~/.claude/cast.db
cast mcp: handshake OK (protocol 2025-06-18)
```

If cast.db is missing, `cast mcp status` reports that and exits non-zero — no crash.

---

## CLI — `cast mcp`

| Subcommand | Description |
|---|---|
| `cast mcp serve` | Run the stdio server (invoked by MCP clients via `.mcp.json`; not normally run by hand) |
| `cast mcp config` | Print the `.mcp.json` snippet and `claude mcp add` command for registration |
| `cast mcp status` | Check cast.db presence and run an `initialize` handshake self-test |
| `cast mcp --help`, `cast mcp help` | Show usage |

---

## Tools — Curated Read-Only Interface

Five tools expose the record. Each returns a one-line row count followed by a JSON array of matching rows.

| Tool | Arguments | Returns |
|---|---|---|
| `cast_decisions` | `limit` (1–200, default 10) | Recent agent-dispatch routing decisions (from `dispatch_decisions`). Fields: `id`, `session_id`, `prompt_snippet`, `chosen_agent`, `model`, `effort`, `parallel`, `created_at`, `outcome`. |
| `cast_incidents` | `limit` (1–200, default 10), optional `query` keyword filter | Past incident log — error classes and fixes (from `incidents`). The `query` filter matches `problem_summary` or `fix_summary`. |
| `cast_cost` | `by` (`agent`\|`session`\|`branch`, default `agent`), `limit` (1–200, default 10) | Cost aggregation from `agent_runs`, grouped by the requested dimension. Per group: total `cost_usd` and run count. `by=branch` reports "branch attribution unavailable" on DBs predating the `branch` column. |
| `cast_sessions` | `limit` (1–200, default 10) | Recent session metadata (from `sessions`). Fields: `id`, `project`, `project_root`, `started_at`, `ended_at`, `status`. (Per-session cost is available via `cast_cost by=session`, which reads `agent_runs`.) |
| `cast_ask` | `query` (required), `limit` (1–200, default 10) | FTS5 full-text search over the indexed CAST record (`record_fts`), BM25-ranked. Each match includes `kind`, `ref_id`, `ts`, `title`, a highlighted `snippet`, `agent`, and `mtype`. Reports "full-text index unavailable" if `record_fts` is absent. |

---

## Resources — Passive Application-Controlled Reads

Five URI-addressable resources (read-only):

| Resource | Content |
|---|---|
| `cast://schema` | Exposed tables in cast.db and their row counts. Metadata only — no data sampling. |
| `cast://decisions/recent` | Most recent 10 routing decisions (same as `cast_decisions` with `limit=10`). |
| `cast://incidents/recent` | Most recent 10 incidents (same as `cast_incidents` with `limit=10`). |
| `cast://cost/summary` | Cost roll-up by agent (same as `cast_cost by=agent`, `limit=10`). |
| `cast://sessions/recent` | Most recent 10 sessions (same as `cast_sessions` with `limit=10`). |

---

## Security & Local-First

**Read-only by construction.** The tool surface has no write/insert/update/delete operation — only the five curated readers above. There is no arbitrary-SQL tool. (Anthropic's own sqlite MCP reference server was archived over a SQL-injection hole; CAST avoids that surface entirely.)

**Read-only at the driver, too.** cast.db is opened with `mode=ro` (SQLite read-only URI), so any write attempt fails at the driver layer before reaching the database.

**Query guards:**
- `limit` arguments are clamped to the range 1–200.
- FTS5 query tokens and LIKE wildcards are escaped, so metacharacters match literally and cannot broaden or break a query.
- Stdin request lines are capped at 1 MB to guard against memory exhaustion.

**Network boundary.** The server speaks **stdio only** — no TCP socket, no network bind. It cannot be reached off-machine.

**Content privacy.** Record content is redacted at **write time** by the CAST hook pipeline; the server returns stored rows as-is and performs no additional redaction.

---

## Limitations & Honest Degradation

The `initialize` handshake always succeeds (it does not touch cast.db); degradation surfaces at the **tool-call** layer as an honest text message, never a crash or a silent empty result:

- **Missing / unreadable cast.db** — tool calls return text like `cast.db unavailable or table missing: …`.
- **`cast_cost by=branch` on an older DB** — returns `branch attribution unavailable on this DB (column absent from schema)`. The `branch` column ships in the current `cast-db-init.sh`; older databases self-heal on the next `install.sh`.
- **`cast_ask` without the FTS index** — returns `full-text index unavailable (record_fts table absent)`. The index is built/refreshed by `cast ask` (see [Ask-Your-Record](ask-your-record.md)).

---

## Related Docs

- [Ask-Your-Record](ask-your-record.md) — `cast ask` full-text search over the record
- [OTEL Feed](otel-feed.md) — local telemetry capture into cast.db
