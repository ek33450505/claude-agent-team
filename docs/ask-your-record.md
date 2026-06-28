# Ask-Your-Record — `cast ask`

**Status:** Shipped in CAST v9 A3 (U1–U6)

## What It Is

`cast ask "<question>"` is a full-text query engine over your entire **CAST record** — the audit trail of every agent run, dispatch decision, incident, plan, reflection, and transcript. Powered by SQLite FTS5 (BM25 ranking) with optional local semantic re-rank via Ollama. Everything stays on your machine.

It turns the CAST database into a searchable product: "When did I touch X? Which agent changed Y? What did I decide about Z?"

---

## Quick Start

### Basic Search

```bash
# Search the entire record
cast ask "launchctl"

# Filter by source kind
cast ask "migration rollback" --kind incident

# Limit results and show semantic re-ranking
cast ask "what did I decide about redaction" --semantic

# Search within a date range
cast ask "oauth bug" --since 2026-06-01

# Get JSON output for scripting
cast ask "agent dispatch timeout" --json | jq '.[0]'
```

### Flags

- `--kind K` — filter to one source: `agent_run`, `incident`, `dispatch`, `memory`, `plan`, `journal`, `transcript`
- `--since YYYY-MM-DD` — include results from this date forward
- `--limit N` — cap results (default: 10)
- `--semantic` — re-rank top FTS hits by embedding cosine similarity (requires Ollama + semantic layer)
- `--no-refresh` — skip lazy index refresh (faster; may miss very recent rows)
- `--json` — emit raw JSON (a bare array of result objects) instead of formatted snippets

### What Gets Indexed

| Kind | Source | Content |
|------|--------|---------|
| `agent_run` | `cast.db` `agent_runs` | Agent response prose, findings, status blocks |
| `incident` | `cast.db` `incidents` | Problem/fix summaries, escalations |
| `dispatch` | `cast.db` `dispatch_decisions` | Routing decisions, criteria, timing |
| `memory` | `cast.db` `agent_memories` | Agent memory title + description + content |
| `plan` | `cast.db` `plan_sessions` | Plan text for a batch or multi-agent session |
| `journal` | `~/Documents/Claude/YYYY-MM/*.md` | Personal reflection & decision log |
| `transcript` | `~/.claude/projects/*/*.jsonl` | Agent JSONL transcripts (user + assistant turns only; tool/thinking turns filtered) |

---

## How It Works

### 1. Lazy Index Refresh (On-Demand)

Every `cast ask` invocation runs an incremental **index refresh** first, unless `--no-refresh` is passed. This is fast because:

- Per-kind high-water mark on `ts` (timestamp) — only new rows since the last index run are added
- Fail-open — if refresh fails, the search still runs against the stale index
- Non-blocking — the query runs immediately after the refresh completes

Explicitly rebuild the index:

```bash
python3 scripts/cast-ask-index.py --rebuild
python3 scripts/cast-ask-index.py --rebuild --kind agent_run  # Single kind
```

### 2. FTS5 Search (BM25 Ranking)

The indexer populates a virtual FTS5 table (`record_fts`) with:

- **Indexed (full-text searchable):** `kind`, `title`, `body` (the prose and source kind)
- **Unindexed (filter/metadata only):** `ref_id`, `ts`, `agent`, `project`, `mtype` (memory type)

`cast ask` searches the indexed columns and sorts by **BM25 relevance** (term frequency + document length normalization). Top results appear first.

### 3. Optional Semantic Re-Rank (Local Embeddings)

If `--semantic` is passed and the optional `record_embed` table is populated:

1. Embed the query once using Ollama `nomic-embed-text` (768-dim) at `localhost:11434`
2. Cosine-similarity re-rank the top FTS results
3. Return re-ranked order

**Fail-open:** If Ollama is down, embeddings don't exist, or the model is missing, `--semantic` silently falls back to pure BM25 — it never hangs or blocks.

### 4. Populate Semantic Layer (Opt-In)

```bash
# Embed all indexed rows
python3 scripts/cast-ask-index.py --embed

# Incremental: only new rows since last embed
python3 scripts/cast-ask-index.py --embed  # (default mode)

# Rebuild + re-embed everything
python3 scripts/cast-ask-index.py --rebuild --embed
```

---

## Schema (Source of Truth: `scripts/cast-db-init.sh`)

### `record_fts` — FTS5 Virtual Table

```sql
CREATE VIRTUAL TABLE record_fts USING fts5(
  kind,                -- indexed (also used as an equality filter)
  ref_id  UNINDEXED,   -- source row id / file path
  ts      UNINDEXED,   -- ISO 8601 timestamp
  title,               -- indexed
  body,                -- indexed
  agent   UNINDEXED,   -- filter metadata
  project UNINDEXED,   -- filter metadata
  mtype   UNINDEXED    -- memory type
);
```

### `record_embed` — Semantic Sidecar

```sql
CREATE TABLE record_embed (
  ref_id TEXT,
  kind   TEXT,
  vec    BLOB,         -- 768-dim nomic-embed-text float32 vector
  ts     TEXT,
  PRIMARY KEY (kind, ref_id)
);
```

### FTS5 Not Available?

If your SQLite build lacks FTS5 (rare, but possible in older systems), `cast-db-init.sh` skips creating `record_fts`. The `cast ask` command degrades gracefully — it prints an honest advisory instead of crashing or silently returning nothing.

---

## `cast memory search` — Unified Backend

`cast memory search` now rides the same FTS5 backend:

```bash
cast memory search "<query>" [--agent N] [--project N] [--type T] [--limit N]
```

**Behavior change:** snippets, not full content

Previously, `cast memory search` showed the entire `content` column. Now it shows a highlighted FTS **snippet** — the sentence/paragraph where the match was found. This makes results scannable without flooding the terminal.

For the full content:

```bash
cast memory show <id>  # Show full memory entry
```

If FTS5 is unavailable, an honest advisory is printed.

---

## Health Check: `cast doctor`

`cast doctor` includes an "Ask-Your-Record" rung with honest degradation.

**Populated:**
```
Ask-Your-Record
[ok] ask-record: record_fts 4287 rows indexed (newest 2026-06-27T14:22:00Z)
[ok] ask-record: record_embed 2156 embeddings
```

**Empty / not populated:**
```
Ask-Your-Record
[--] ask-record: record_fts present but empty (0 rows) — run: cast-ask-index.py --rebuild
[--] ask-record: semantic layer not populated (opt-in) — run: cast-ask-index.py --embed
```

**Absent (FTS5 unavailable):**
```
Ask-Your-Record
[--] ask-record: record_fts not present — run cast-db-init.sh then cast-ask-index.py (FTS5 may be unavailable in this sqlite build)
```

No false green — if the index is absent, `cast doctor` tells you so.

---

## Troubleshooting

### Empty Results

**Q: `cast ask "<query>"` returns no results but I know the text exists.**

1. Check the index is fresh:
   ```bash
   python3 scripts/cast-ask-index.py --rebuild --kind agent_run
   ```
2. Verify FTS5 is available:
   ```bash
   sqlite3 ~/.claude/cast.db "SELECT name FROM sqlite_master WHERE type='table' AND name='record_fts';"
   ```
   If no rows, FTS5 is not available in your SQLite build.

3. Verify the source kind has rows:
   ```bash
   cast ask "<query>" --kind agent_run --limit 20
   ```

### Semantic Re-Rank Falling Back

**Q: `--semantic` is ignoring me and falling back to BM25.**

1. Check Ollama is running:
   ```bash
   curl -s http://localhost:11434/api/tags | jq '.models[].name' | grep nomic-embed-text
   ```
   If missing: `ollama pull nomic-embed-text`

2. Check the embed layer exists:
   ```bash
   sqlite3 ~/.claude/cast.db "SELECT COUNT(*) FROM record_embed WHERE kind='agent_run';"
   ```
   If 0: `python3 scripts/cast-ask-index.py --embed`

3. Semantic fallback is silent by design — if `--semantic` returns the same order as plain `cast ask`, the embeddings or Ollama weren't available. Verify Ollama with the `curl` check above and the embed layer with the `record_embed` count.

### FTS5 Not Available

**Q: I'm getting "FTS5 not available in this SQLite build".**

This is honest degradation, not a bug. Both `cast ask` and `cast memory search` now ride the FTS5 backend and print an honest advisory when FTS5 is absent — there is no fallback to LIKE.

**Fix:** Use a SQLite build with FTS5 compiled in. Homebrew's `sqlite` package includes FTS5. The python3 `sqlite3` module on macOS and most Linux distributions already has it.

---

## Design Decision — No Redaction on Index

Journal and transcript text are indexed **verbatim** into `record_fts` — there is deliberately **no redaction step**. 

**Why:** The local record must be a faithful copy of what happened. `cast.db` already lives inside `~/.claude`. Secret protection is owned by the **egress/backup boundary**, not by the local indexer:

- The **off-machine overlay sync** runs a secret-scan gate before syncing data out
- The **egress sentinel** (v9 A1) records off-machine calls to `logs/egress.jsonl`

This keeps `cast ask` truthful and avoids lossy local search.

---

## Related Docs

- [Observability Guide](observability/OBSERVABILITY.md) — cast.db schema reference
- [Token Optimization](TOKEN-OPTIMIZATION.md) — Ollama local routing for embeddings
- [Backups](backups.md) — off-machine overlay sync and secret scanning
