# Memory Architecture MVP — 2026-05-07

## Current State

### What Exists (Code)

| Component | File | Status |
|-----------|------|--------|
| DB table | `agent_memories` (cast.db) | EXISTS — 16 columns including `embedding`, `importance`, `decay_rate`, `valid_to`, `superseded_by`, `confidence` |
| FTS5 index | `agent_memories_fts` (cast.db) | EXISTS — indexes `name`, `description`, `content` |
| Read/retrieve engine | `scripts/cast-memory-router.py` | EXISTS — full FTS5 + cosine re-rank, `--mode retrieve` output, `--fts-only` flag |
| Write wrapper | `scripts/cast-memory-write.sh` | EXISTS — deduplication by exact content match, parameterized SQL |
| DB abstraction | `scripts/cast_db.py` | EXISTS — `db_write`, `db_query`, `db_execute` with retry + lock handling |
| Consolidation | `scripts/cast-memory-consolidate.py` | EXISTS — decay, dedup, archive, promote |
| SubagentStop hook | `scripts/cast-subagent-stop-hook.sh` | WIRED — fires for all agents, parses full `response_text` |
| UserPromptSubmit hook | `scripts/cast-user-prompt-hook.sh` | WIRED — fires on every prompt, has full `prompt` text |

### What's Wired (in `~/.claude/settings.json`)

- `SubagentStop` → `cast-subagent-stop-hook.sh` ✓
- `SubagentStop` → `cast-response-completeness-hook.sh` ✓
- `UserPromptSubmit` → `cast-user-prompt-hook.sh` ✓

### What's NOT Wired (the missing wires)

1. **Write wire missing:** `cast-subagent-stop-hook.sh` parses agent `response_text` but does NOT scan for a `## Facts` block or call `cast-memory-write.sh`. Facts die with the session.
2. **Read wire missing:** `cast-user-prompt-hook.sh` logs prompt metadata to routing_events but does NOT call `cast-memory-router.py --mode retrieve` and does NOT emit `additionalContext` to inject memories into the next prompt.
3. **`agent-memory` rows are stale workaround:** The 32 rows of type `agent-memory` are full MEMORY.md file dumps written by a migration script, not structured facts. They are not retrieved by the router (wrong type token).

### Current State Diagram

```
Agent runs → outputs text → SubagentStop fires
                                    │
                    ┌───────────────┴───────────────┐
                    │ agent_runs update         │ truncation log
                    │ quality_gates log         │ turn-ceiling log
                    └───────────────────────────┘
                    ✗ NO Facts block parse
                    ✗ NO cast-memory-write.sh call

User types prompt → UserPromptSubmit fires
                    │
                    ├── routing_events INSERT ✓
                    ├── user-prompts.jsonl append ✓
                    └── ✗ NO cast-memory-router.py retrieve
                        ✗ NO additionalContext injection
```

---

## Write Pipeline Design

### Facts Block Format (canonical)

```
## Facts
name: <slug-no-spaces-max-80-chars> | type: <user|feedback|project|reference|procedural> | content: <text-max-500-chars>
name: <slug> | type: <type> | content: <text> | confidence: <0.0..1.0>
```

One fact per line. Pipe-delimited. `name` must be a slug (no whitespace). Parser skips malformed lines silently.

### Step-by-step Write Pipeline

**Step 1 — Facts extraction (add to `cast-subagent-stop-hook.sh` Step 2.6):**

After the existing `agent_runs` update block, add a new Python heredoc block:

```python
# Scan response_text for ## Facts block
import re, os, sys

response_text = os.environ.get('CAST_STOP_RESPONSE_TEXT', '')
agent = os.environ.get('CAST_STOP_AGENT', 'unknown')
project = os.path.basename(os.getcwd())
script_dir = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, script_dir)

try:
    from cast_db import db_execute, db_query
except ImportError:
    raise SystemExit(0)

# Extract Facts block
facts_match = re.search(r'## Facts\s*\n(.*?)(?=\n##|\Z)', response_text, re.DOTALL)
if not facts_match:
    raise SystemExit(0)

facts_block = facts_match.group(1).strip()
MAX_FACTS = 5
parsed = 0

for line in facts_block.splitlines():
    if parsed >= MAX_FACTS:
        break
    line = line.strip()
    if not line:
        continue
    # Parse pipe-delimited fields
    fields = {}
    for part in line.split('|'):
        if ':' in part:
            k, _, v = part.strip().partition(':')
            fields[k.strip()] = v.strip()
    
    name = fields.get('name', '')
    mem_type = fields.get('type', '')
    content = fields.get('content', '')[:500]
    confidence = float(fields.get('confidence', '1.0') or '1.0')
    
    VALID_TYPES = {'user', 'feedback', 'project', 'reference', 'procedural'}
    SLUG_RE = re.compile(r'^[a-zA-Z0-9_-]{1,80}$')
    
    if not name or not SLUG_RE.match(name) or mem_type not in VALID_TYPES or not content:
        continue
    
    # Deduplication: exact content match bumps updated_at only
    existing = db_query(
        "SELECT id FROM agent_memories WHERE agent = ? AND name = ? LIMIT 1",
        (agent, name)
    )
    if existing:
        db_execute(
            "UPDATE agent_memories SET content=?, updated_at=datetime('now'), confidence=?, valid_to=NULL "
            "WHERE id=?",
            (content, confidence, existing[0]['id'])
        )
    else:
        db_execute(
            "INSERT INTO agent_memories (agent, project, type, name, description, content, "
            "created_at, updated_at, confidence, valid_from) "
            "VALUES (?, ?, ?, ?, ?, ?, datetime('now'), datetime('now'), ?, datetime('now'))",
            (agent, project, mem_type, name, content[:100], content, confidence)
        )
    parsed += 1
```

**Step 2 — No new script needed.** The write logic lives inside `cast-subagent-stop-hook.sh` as a new Step 2.6 heredoc. This keeps hook dispatch count at 1 for SubagentStop.

**Deduplication strategy:** Match on `(agent, name)` — name is the stable slug identity. Exact-content match refreshes `updated_at`. Content changes overwrite with `valid_to=NULL` to reactivate. No fuzzy/cosine dedup at write time (too slow for a sync hook path).

**Conflict with existing SubagentStop behavior:** None. The Facts block scan happens after all existing steps (agent_runs, truncation, quality_gates). It reads `CAST_STOP_RESPONSE_TEXT` which is already exported.

---

## Read Pipeline Design

### Step-by-step Read Pipeline

**Step 1 — Retrieve relevant memories (add to `cast-user-prompt-hook.sh`):**

After the existing routing_events INSERT, add:

```python
# Memory retrieval and injection
import subprocess, json, os

prompt_text = data.get('prompt', '')
session_id = data.get('session_id', '')
project = os.path.basename(os.getcwd().rstrip('/')) or 'unknown'

if not prompt_text or len(prompt_text.strip()) < 10:
    raise SystemExit(0)

script_dir = os.path.dirname(os.path.abspath(__file__))
router = os.path.join(script_dir, 'cast-memory-router.py')

if not os.path.isfile(router):
    raise SystemExit(0)

try:
    result = subprocess.run(
        ['python3', router, '--mode', 'retrieve', '--agent', 'shared',
         '--prompt', prompt_text[:500], '--top-n', '5', '--fts-only'],
        capture_output=True, text=True, timeout=5
    )
    memories = json.loads(result.stdout or '[]')
except Exception:
    memories = []

if not memories:
    raise SystemExit(0)

# Format as key:value lines for injection
lines = []
for m in memories:
    score = m.get('score', 0)
    if score < 0.3:  # minimum relevance threshold
        continue
    mem_type = m.get('type', '')
    name = m.get('name', '')
    content = m.get('content', '')[:200]
    lines.append(f"[memory:{mem_type}:{name}] {content}")

if not lines:
    raise SystemExit(0)

context_block = "Relevant memory context:\n" + "\n".join(lines)

# Emit as additionalContext
import json as _json
print(_json.dumps({
    "hookSpecificOutput": {
        "hookEventName": "UserPromptSubmit",
        "additionalContext": context_block
    }
}))
```

**Step 2 — `cast-memory-router.py` is ready as-is.** The `--mode retrieve --fts-only` path requires no modification. FTS5 is confirmed present on `cast.db`. The `--fts-only` flag skips Ollama and runs in ~10-30ms — safe for a sync hook.

**Retrieval strategy (no embeddings):**
- FTS5 MATCH on prompt text against `name + description + content`
- Fallback: full scan ordered by `updated_at DESC` if FTS returns no rows
- Score: `0.3*recency + 0.2*importance + 0.25*fts_rank_norm + 0.25*cosine_sim(0.0)`
- Filter: score >= 0.3 before injection; top-5 cap

**Injection format (key:value lines, not prose):**
```
[memory:feedback:no-mock-db] Integration tests must hit real DB — mock/prod divergence burned us last quarter
[memory:project:merge-freeze] Merge freeze begins 2026-03-05 for mobile release cut
```

---

## Minimal Viable Implementation

**Scope: 2 files modified, ~80 lines added total**

| File | Change | Lines |
|------|--------|-------|
| `scripts/cast-subagent-stop-hook.sh` | Add Step 2.6: Facts block parser + write to agent_memories | ~50 |
| `scripts/cast-user-prompt-hook.sh` | Add Step 3: retrieve memories + emit additionalContext | ~35 |

**What this achieves end-to-end:**
1. Any agent that emits `## Facts` will have those facts persisted to `agent_memories`
2. Any user prompt will retrieve top-5 relevant memories and inject them as context
3. FTS5 is already in place — zero schema changes needed
4. Deduplication by `(agent, name)` prevents bloat
5. `--fts-only` keeps hook latency under 50ms

**What it does NOT achieve (defer):**
- Embeddings (requires Ollama or Anthropic embed API)
- Per-agent filtering at retrieval (retrieves `agent='shared'` pool only in MVP)
- Staleness expiry (valid_to logic deferred to Phase 3.2)
- `user_profile` type injection (separate scope — see below)

---

## Cross-Agent Memory Scoping

**Recommendation: three-tier scoping**

| Scope | `agent` column value | Who reads it |
|-------|---------------------|--------------|
| Per-agent | `<agent-name>` e.g. `debugger` | Only that agent's retrieve calls |
| Project-shared | `shared` | All agents on same project |
| Global (user_profile) | `global` | All agents regardless of project_root |

**Rationale:**
- `shared` pool already exists and the router supports it (`OR am.agent = 'shared'`)
- Per-agent scope allows agent-specific learned behavior without polluting others
- `global` scope is new — needed for user_profile (see below)

**Write rule:** Facts emitted with `type: user` → write to `agent='global'`. All others → write to `agent=<emitting-agent>`. Cross-agent useful facts (type=`project` or `feedback`) → write to `agent='shared'`.

**Conflict risk:** Low. The `(agent, name)` UNIQUE-ish dedup (via ON CONFLICT) prevents two agents from creating divergent versions of the same named fact. If two agents write `name: merge-freeze`, the second write updates the first — last-writer wins, which is correct behavior for project state facts.

---

## Staleness Detection (Minimal, No Embeddings)

**Approach: age + importance decay, with explicit invalidation**

1. **Recency decay:** Already built into `relevance_score()` in `cast-memory-router.py`:
   ```
   recency = exp(-decay_rate * age_hours / 8760)
   ```
   Default `decay_rate=0.993` → a memory at 30 days scores ~0.65 of a fresh one, 90 days ~0.28.

2. **Explicit invalidation:** When an agent emits a fact with the same `name` as an existing entry, the write pipeline overwrites content and sets `valid_to=NULL` (reactivates). Old content is replaced — no time-travel needed.

3. **`valid_to` expiry gate:** The router already filters `WHERE valid_to IS NULL` by default. To expire a fact, set `valid_to = datetime('now')`. The consolidation script (`cast-memory-consolidate.py`) handles this weekly via importance threshold.

4. **Manual invalidation:** `cast-memory-router.py --invalidate <id>` sets `valid_to` immediately.

**What's NOT done (and shouldn't be for MVP):** Semantic change detection (requires embeddings), contradiction detection across agents (requires cross-agent read at write time).

---

## Relationship Memory (user_profile type)

### New Memory Type: `user_profile`

Add `user_profile` to `VALID_TYPES` in both `cast-memory-write.sh` and `cast-memory-router.py`.

**Schema: no new columns needed.** Use `agent = 'global'`, `type = 'user_profile'`, `project = NULL`.

```sql
INSERT INTO agent_memories (agent, project, type, name, description, content, created_at, updated_at)
VALUES ('global', NULL, 'user_profile', 'work-hours', 'Ed works 9am-6pm ET', '...', ...)
```

**Injection scope:** Global — inject in ALL sessions regardless of `cwd`. The read pipeline change: in `cast-user-prompt-hook.sh`, after the project-scoped retrieve, run a second retrieve for `agent='global'` with `type='user_profile'`, prepend results to context block.

**Write trigger:** `## Facts` block with `type: user_profile` → SubagentStop parser writes to `agent='global'`. This happens automatically with the same write pipeline — no special case needed beyond adding `user_profile` to VALID_TYPES.

**Example facts:**
```
name: work-hours | type: user_profile | content: Ed works 9am-6pm ET, available for context-sharing at session start
name: comm-style | type: user_profile | content: Prefers terse responses, no trailing summaries, no emojis
name: career-goal | type: user_profile | content: Targeting Anthropic role; CAST+dashboard+Homebrew tap are the portfolio
```

**Conflict risk:** Global scope means a fact written by any agent is visible everywhere. Use very stable, person-scoped slugs (not project-specific names). Naming convention: `user-<attribute>` to namespace from project facts.

---

## Phase 3 Implementation Scope

### In Phase 3 Sprint (2-3 files, < 200 lines)

| Task | File | Effort |
|------|------|--------|
| Facts write pipeline | `cast-subagent-stop-hook.sh` | ~50 lines |
| Memory retrieve + inject | `cast-user-prompt-hook.sh` | ~35 lines |
| Add `user_profile` to VALID_TYPES | `cast-memory-router.py` + `cast-memory-write.sh` | ~4 lines |
| BATS tests for Facts parser | `tests/cast-subagent-stop-hook.bats` | ~30 lines |
| BATS tests for memory inject | `tests/cast-user-prompt-hook.bats` | ~20 lines |

**Total: ~139 lines across 5 files. No schema changes. No new scripts.**

### Defer to Later

| Item | Why defer |
|------|-----------|
| Embeddings at write time | Requires Ollama running; adds 3s to SubagentStop path |
| Per-agent retrieval scoping | Current shared pool is sufficient for MVP validation |
| Cosine dedup at write time | Too slow for sync hook; consolidation script handles it weekly |
| `cast-memory-consolidate.py` cron wiring | Can be done manually until memory volume warrants automation |
| Retrieval analytics / hit logging | Nice-to-have for tuning, not required for first working loop |

---

## Sources

- `scripts/cast-memory-router.py` — verified this session (retrieve + route modes, FTS5 path, --fts-only)
- `scripts/cast-subagent-stop-hook.sh` — verified this session (Steps 1-5, response_text extraction)
- `scripts/cast-user-prompt-hook.sh` — verified this session (routing_events only, no inject)
- `scripts/cast-memory-write.sh` — verified this session (dedup strategy, parameterized SQL)
- `scripts/cast_db.py` — verified this session (db_write, db_query, db_execute APIs)
- `~/.claude/settings.json` — verified this session (SubagentStop + UserPromptSubmit wired hooks)
- `sqlite3 cast.db` queries — verified this session (table schema, FTS5 tables, row counts, SQLite 3.51.0)
