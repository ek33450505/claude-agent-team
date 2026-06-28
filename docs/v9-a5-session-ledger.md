# Session Ledger — `cast ledger`

**Status:** Shipped in CAST v9 A5

## What It Is

`cast ledger [SESSION_ID]` is a portable, SHA-256-stamped per-session audit receipt rendered **entirely from cast.db**. It captures everything that happened in a session — agents, decisions, file writes, quality gates, and integrity flags — and signs it with a deterministic digest. Nothing leaves the machine; this is data sovereignty.

Use it to:
- Export a tamper-evident receipt of your work for compliance, review, or archival
- Verify a receipt hasn't been modified by re-deriving the digest from cast.db
- Prove what happened in a session (agent runs, files touched, routing decisions, costs)

---

## Quick Start

### Basic Usage

```bash
# Render the most recent session (default)
cast ledger

# Render a specific session
cast ledger abc123def456

# Render the last 3 sessions
cast ledger --last 3

# Render all sessions since a date
cast ledger --since 2026-06-20

# Export to a file
cast ledger --out ~/Desktop/session-receipt.md

# Emit JSON instead of Markdown
cast ledger --json
```

### Verify a Receipt

```bash
# Verify a previously-written receipt file
cast ledger --verify ~/Desktop/session-receipt.md

# Exit code: 0 = PASS, 1 = TAMPERED (digest mismatch)
echo $?
```

### Flags

| Flag | Argument | Purpose |
|------|----------|---------|
| `SESSION_ID` | positional | Render a specific session ID |
| `--last` | `N` | Render the N most-recent sessions |
| `--since` | `YYYY-MM-DD` | Render all sessions since this date (inclusive) |
| `--json` | — | Emit JSON instead of Markdown |
| `--out` | `FILE` | Write output to FILE instead of stdout |
| `--verify` | `FILE` | Verify a receipt file and exit (0=PASS, 1=TAMPERED) |
| `--db` | `PATH` | Override DB path (default: `CAST_DB_PATH` or `~/.claude/cast.db`) |

---

## Receipt Sections

Each receipt is composed of the following sections, sourced from cast.db:

### Header
- Session ID, project, project root, start/end times, duration, status
- Source: `sessions` table

### Models & Cost
- Distinct models used, token counts (input/output/cache), total USD cost
- Source: aggregated from `agent_runs` table

### Agents
- Table: Agent, Model, Status, Duration (ms), Cost (USD), Tool Uses
- Source: `agent_runs` table

### Files Changed
- Table: File path, Tool used, Agent that touched it
- Source: `file_writes` table

### Decisions & Gates
- **Routes:** Routing decision snapshots (action, matched route, event type)
- **Gates:** Quality gate results (agent, gate type, pass/fail, retry count)
- Source: `routing_events` and `quality_gates` tables

### Integrity
- Counters for protocol violations, hallucinations, truncations, completeness flags
- Detailed rows if any are present (honest degradation: 0 = not recorded)
- Source: `agent_protocol_violations`, `agent_hallucinations`, `agent_truncations`, `completeness_events` tables

### Digest
- `sha256:` prefix followed by 64-hex SHA-256 stamp at the bottom
- Derived from a canonical JSON representation of all sections above

---

## Tamper-Evidence Model

The digest is **deterministic** and **re-derivable**:

1. **Canonical Data Structure:** All receipt sections are serialized to JSON with sorted keys, ensuring byte-for-byte reproducibility.
2. **SHA-256 Digest:** The entire JSON is hashed once to produce the digest.
3. **Verify Mode:** `cast ledger --verify FILE` re-derives the digest from cast.db for each session in the receipt, then compares against the embedded digest.

**Guarantee:** If you run `cast ledger --verify` and it returns PASS, the receipt matches the current cast.db state for that session. If TAMPERED, either:
- The receipt file was edited
- The cast.db rows for that session were modified (unlikely under normal use, as cast.db is write-guarded)
- The session does not exist in cast.db

---

## Output Formats

### Markdown (Default)

Human-readable receipt with sections, tables, and inline digests:

```markdown
# CAST Session Receipt

- **Session:** abc123def456
- **Project:** myapp (~/code/myapp)
- **Started:** 2026-06-27T14:22:00Z
- **Ended:** 2026-06-27T15:10:30Z
- **Duration:** 48m 30s
- **Status:** completed

## Models & Cost

- **Models:** claude-sonnet-4-6, claude-haiku-4-5-20251001
- **Input tokens:** 124,567
- **Output tokens:** 8,932
- **Cache read tokens:** 45,000
- **Cache creation tokens:** 0
- **Total cost:** $0.8234

## Agents (4)

| Agent | Model | Status | Duration (ms) | Cost (USD) | Tool Uses |
|-------|-------|--------|---------------|------------|-----------|
| code-writer | claude-sonnet-4-6 | DONE | 45000 | 0.4120 | 23 |
| debugger | claude-sonnet-4-6 | DONE | 28000 | 0.2890 | 15 |
| commit | claude-haiku-4-5-20251001 | DONE | 1200 | 0.0034 | 1 |
| code-reviewer | claude-haiku-4-5-20251001 | DONE | 800 | 0.0190 | 0 |

## Files Changed (7)

| File | Tool | Agent |
|------|------|-------|
| src/App.tsx | Write | code-writer |
| src/App.test.tsx | Write | test-writer |
| docs/API.md | Write | docs |

## Decisions & Gates

**Routes:**
- `dispatch` / `code-writer` / `dispatch-trigger`
- `review` / `code-reviewer` / `post-dispatch`

**Gates:**
- `code-writer` / `code-quality` / passed=true / retries=0
- `code-reviewer` / `contract` / passed=true / retries=0

## Integrity

- **Protocol violations:** 0
- **Hallucinations:** 0
- **Truncations:** 0
- **Completeness flags:** 0

---
Digest: sha256:a1b2c3d4e5f6g7h8i9j0k1l2m3n4o5p6q7r8s9t0u1v2w3x4y5z6a7b8c9d0
```

### JSON

Structured JSON with receipt and digest:

```bash
cast ledger --json | jq .
```

```json
{
  "receipt": {
    "session": {
      "id": "abc123def456",
      "project": "myapp",
      "project_root": "~/code/myapp",
      "started_at": "2026-06-27T14:22:00Z",
      "ended_at": "2026-06-27T15:10:30Z",
      "status": "completed"
    },
    "totals": {
      "models": ["claude-sonnet-4-6", "claude-haiku-4-5-20251001"],
      "input_tokens": 124567,
      "output_tokens": 8932,
      "cache_read_input_tokens": 45000,
      "cache_creation_input_tokens": 0,
      "cost_usd": 0.8234
    },
    "agents": [
      {
        "agent": "code-writer",
        "model": "claude-sonnet-4-6",
        "status": "DONE",
        "duration_ms": 45000,
        "cost_usd": 0.412,
        "tool_uses": 23
      }
    ],
    "files": [
      {
        "file_path": "src/App.tsx",
        "tool_name": "Write",
        "agent_name": "code-writer"
      }
    ],
    "routes": [],
    "gates": [],
    "integrity": {
      "agent_protocol_violations": [],
      "agent_hallucinations": [],
      "agent_truncations": [],
      "completeness_events": []
    }
  },
  "digest": "sha256:a1b2c3d4e5f6g7h8i9j0k1l2m3n4o5p6q7r8s9t0u1v2w3x4y5z6a7b8c9d0"
}
```

---

## Batch Receipts

Render multiple sessions in one invocation:

```bash
# Last 5 sessions, Markdown (separated by ---)
cast ledger --last 5 > ~/Desktop/batch-receipt.md

# Last 5 sessions, JSON (array)
cast ledger --last 5 --json > ~/Desktop/batch-receipt.json

# Verify a batch receipt
cast ledger --verify ~/Desktop/batch-receipt.json
```

**Markdown batches:** Multiple receipts separated by `---`. Verify runs on all sessions in sequence.

**JSON batches:** Array of receipt objects, each with its own digest. Verify checks all.

---

## Database Path Resolution

By default, `cast ledger` reads from `~/.claude/cast.db`. Override with:

```bash
# Environment variable
CAST_DB_PATH=/path/to/custom.db cast ledger

# Flag
cast ledger --db /path/to/custom.db

# SQLite URL
CAST_DB_URL="sqlite:///path/to/custom.db" cast ledger
```

---

## Design Notes

- **Read-only:** Cast ledger never writes to cast.db — it is a pure query and serialization tool
- **Fail-open:** Every section is wrapped in try/except. Missing tables or columns result in honest "0 recorded" counts, not crashes
- **Deterministic:** The SHA-256 digest is reproducible on any machine with the same cast.db
- **Privacy-preserving export:** Because the receipt is a portable artifact, raw agent-output columns (`raw_excerpt`, `partial_work_log`, `last_line`, etc.) are excluded from integrity rows — only counts and safe descriptors are rendered. cast.db itself stays local inside `~/.claude`; off-machine sync is gated by the v9 A1 egress sentinel

---

## Roadmap

**v9 A5 (Current):** Session ledger and digest.

**v9 A7 (Shipped):** Provenance hash-chain. Extend the digest to chain across sessions, creating a tamper-evident audit trail of your entire work history (session N references a digest of session N-1). Shipped — see [Provenance Chain](v9-a7-provenance-chain.md).

---

## Related Docs

- [Ask-Your-Record](ask-your-record.md) — Full-text search over your record
- [Observability Guide](observability/OBSERVABILITY.md) — cast.db schema reference
- [Backups](backups.md) — Off-machine sync and secret scanning
