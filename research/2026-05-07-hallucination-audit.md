# Hallucination Audit — 2026-05-07

## Taxonomy + Current Coverage

| Category | Description | Current Guard | Gap |
|---|---|---|---|
| Stat claims | Public badge / README numbers wrong | `cast-stat-claim-guard.sh` (PreToolUse, blocks write) | COVERED |
| Agent-claimed work | Agent says "wrote X" but X doesn't exist or is unchanged | None | **UNCOVERED** |
| Chain hallucination | Agent B misreports what Agent A did | None | **UNCOVERED** |
| Memory citation | Stale/nonexistent memory entry cited as current fact | None | **UNCOVERED** |
| Code reference | Suggests function/import that doesn't exist in repo | None | **UNCOVERED** |

The existing `cast-stat-claim-guard.sh` is a PreToolUse hook that blocks `Write`/`Edit` calls to `README.md` when the badge test count mismatches `git ls-files`. It is narrow by design: it only guards one very specific claim shape. The four categories below are fully unaddressed.

---

## Category 1: Agent-Claimed Work (Post-Agent Verification)

**Current:** `cast-subagent-stop-hook.sh` records `status`, `ended_at`, `duration_ms`, and `response` to `agent_runs`. It detects truncation (missing Status block) and quality-gate outcomes for `code-reviewer`, `test-runner`, and `security`. It does **not** verify any specific claim made inside the agent's Work Log.

**Guard Design — `cast-claimed-work-verifier.py` (called from SubagentStop hook, Step 2.6)**

The hook already has `CAST_STOP_RESPONSE_TEXT` in env. Add a new step after Step 2 (db mirror):

1. **Extract file paths from Work Log.** Regex on the response text:
   ```
   Files changed:\s*([\s\S]+?)(?=\n\n|$)
   ```
   Also scan for inline patterns: `` `path/to/file` ``, `wrote X`, `created X`, `updated X`.
2. **For each claimed path:** `os.path.exists(path)` and `os.path.getmtime(path)` vs. agent start time (from `agent_runs.started_at`). A file that exists but was last modified *before* the agent started was not written by this run.
3. **Log discrepancies to `agent_hallucinations` table.** Never block (v1 = observability only).

**Schema for `agent_hallucinations`:**
```sql
CREATE TABLE IF NOT EXISTS agent_hallucinations (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id  TEXT,
    agent_name  TEXT NOT NULL,
    claim_type  TEXT NOT NULL,          -- 'file_write' | 'test_pass' | 'command_output'
    claimed_value TEXT,                 -- what agent said it did
    actual_value  TEXT,                 -- what disk/process actually shows
    timestamp   TEXT NOT NULL,
    verified    INTEGER DEFAULT 0       -- 0=unverified, 1=confirmed true, -1=confirmed false
);
```

**v1 threshold (observe-only):** Log everything, emit a `[CAST-HALLUCINATION-WARN]` banner via `hookSpecificOutput` if >2 unverified file claims in one agent run.

**v2 escalation trigger:** Promote to blocking when: agent claims >3 files and >1 is unverifiable, AND agent is `code-writer` or `test-writer`. These are the high-damage agents.

**Performance cost:** `os.path.exists` + `os.path.getmtime` for N paths is essentially free (~1ms per path). The regex scan on a 2KB Work Log adds <5ms. Total overhead: negligible.

**Complexity:** 3–4 hours. The hook infrastructure already exists; this is a new Python block appended to `cast-subagent-stop-hook.sh` and a schema migration.

**Damage potential: HIGH.** An agent claiming to have written a test file that doesn't exist will silently pass code review. This is the most directly harmful category: downstream agents make decisions based on what upstream agents claim they did.

---

## Category 2: Chain Hallucination (Structured Handoff)

**Current:** The `/orchestrate` skill reads an Agent Dispatch Manifest and passes each agent's prompt verbatim. When Agent B's prompt says "Agent A completed X", that text was written by the *planner* at plan-write time, not by Agent A at runtime. The current `## Work Log` section in agent outputs is human-readable prose that the orchestrator does NOT structurally parse or inject — it's visible to the user but not machine-verified.

**Guard Design — Mandatory `## Handoff` block**

Agents are instructed (via `cast-conventions` skill) to emit a `## Handoff` section as a machine-parseable structured block AFTER the `## Work Log` and BEFORE the Status block:

```
## Handoff
agent: code-writer
status: DONE
files_written: ["src/hooks/useAuth.ts", "src/hooks/useAuth.test.ts"]
tests_added: 4
tests_passing: true
key_outputs:
  - "Added useAuth hook with JWT refresh logic"
  - "All 4 new tests pass"
blockers: []
```

**Format rationale:** YAML-ish key:value (not JSON) — easier to read in Work Log output, still machine-parseable with a 5-line regex. Fields:
- `agent` (which agent wrote this)
- `status` (DONE | BLOCKED | DONE_WITH_CONCERNS)
- `files_written` (JSON array of paths)
- `key_outputs` (bullet list, max 3 items — forces agents to be specific)
- `blockers` (empty = none)

**Orchestrator extraction:** The `/orchestrate` skill extracts the `## Handoff` block using:
```python
re.search(r'## Handoff\n([\s\S]+?)(?=\n## |\Z)', output)
```
The extracted block is prepended **verbatim** to the next agent's prompt under a `## Prior Agent Handoff` heading. The orchestrator never paraphrases it.

**How this differs from Work Log:** Work Log is narrative for humans. Handoff is structured for machines. The orchestrator currently ignores Work Log entirely — Handoff is the contract it reads.

**Complexity:** 2–3 hours. No new scripts needed. Update `cast-conventions` skill to mandate the block format, update `/orchestrate` SKILL.md to extract and inject it, add a SubagentStop check that warns when Handoff block is absent.

**Damage potential: MEDIUM-HIGH.** Chain errors compound — a wrong "tests passing" claim propagates to the commit agent which skips test verification. The fix is cheap relative to the damage.

---

## Category 3: Memory Citation Hallucination

**Current state of `cast-memory-router.py`:**
- `retrieve_memories()` filters on `valid_to IS NULL` (active entries only) — this is the staleness gate at read time.
- `decay_rate` and `importance` score are used in relevance ranking but do NOT gate retrieval.
- The `agent_memories` table has `confidence`, `source_type`, `superseded_by` columns — none are checked during retrieval beyond the `valid_to` filter.
- There is **no verification** that file paths, function names, or script paths mentioned in memory `content` still exist on disk.

**The most dangerous case:** A memory entry contains `content: "cast-subagent-worktree-check.sh verifies worktrees after each dispatch"`. An agent reads this memory and confidently states the hook is active — but the hook was wired in settings.json and later removed. The memory records the intent, not the current reality. This is the exact bug class documented in `working-conventions.md § Memory Verification` from 2026-05-05.

**Guard Design — Read-time path verification (before injection)**

Add a `--verify-paths` flag to `cast-memory-router.py` retrieve mode. When set:

1. After scoring, before returning results, scan each memory's `content` for file path patterns:
   ```python
   path_pattern = re.compile(r'(~?/[\w./-]+\.(sh|py|md|ts|js|json))\b')
   ```
2. For each extracted path: `os.path.exists(os.path.expanduser(path))`.
3. If path **does not exist**: set `confidence` to 0.0 and add `"stale_paths": ["..."]` to the output dict. Do not suppress the memory — let the agent see the warning.
4. Log stale detections to `agent_hallucinations` table (reuse Category 1 schema, `claim_type='stale_memory_path'`).

**Why read-time, not write-time:** Write-time verification would catch paths at storage, but memory entries outlive the files they reference. A path that existed when the memory was written may be deleted later. Read-time verification catches the current reality.

**Intersection with Phase 3 staleness sweep:** The staleness sweep (planned) runs as a batch job. This guard is the real-time counterpart — it fires per-retrieval, not per-sweep. Both are needed: the sweep cleans stale entries proactively; this guard catches them before they reach an agent in the gap between sweeps.

**Minimal implementation:** The path regex + `os.path.exists` check adds ~2ms per memory entry. No schema changes needed beyond reusing `agent_hallucinations`.

**Complexity:** 2 hours. Self-contained change to `cast-memory-router.py`.

**Damage potential: MEDIUM.** Memory hallucinations cause confident-sounding but wrong agent behavior. Agents citing a nonexistent hook as "active" then fail to investigate why things aren't working. The 2026-05-05 incident (SessionStart hook never wired despite memory entry) is the canonical example.

---

## Category 4: Code Reference Hallucination

**Current:** No guard. `code-writer` and `code-reviewer` agents freely reference function names, import paths, and module names in their output. There is no post-hoc check that referenced symbols exist in the repo.

**Guard Design — `cast-code-ref-guard.sh`**

**Input:** Agent output text (from `CAST_STOP_RESPONSE_TEXT` in SubagentStop hook).

**Extraction regexes** (applied to agent output, not to repo):
```bash
# Function definitions and references
grep -oP '(?<=function )\w+' 
grep -oP '\b\w+(?=\()' | sort -u  # function call pattern (noisy, filter below)

# Import patterns
grep -oP "(?<=import \{)[^}]+" | tr ',' '\n' | tr -d ' '  # named imports
grep -oP "(?<=from ')[^']+" # module paths
grep -oP "(?<=require\()['\"])[^'\"]+" # require()
grep -oP "(?<=import )['\"][^'\"]+" # default imports
```

**Verification:**
- For **module paths** (`from 'foo'`, `require('foo')`): check `node_modules/foo` or `src/foo` exists.
- For **function names** claimed as "existing" (agent says "uses `useAuth` from `src/hooks`"): `grep -r "function useAuth\|const useAuth\|export.*useAuth" src/`.
- Skip generic names under 4 chars (high false-positive rate).

**Output format per finding:**
```
[VERIFIED]   useAuth — found in src/hooks/useAuth.ts:12
[NOT FOUND]  useSession — no match in repo
[SKIP]       get — too short, skipped
```

**Integration:** New Step 2.7 in `cast-subagent-stop-hook.sh`. Only runs for `code-writer`, `code-reviewer`, `debugger`. Results logged to `agent_hallucinations` (`claim_type='code_ref'`). Emits `[CAST-CODE-REF-WARN]` banner if >1 NOT FOUND.

**Estimated catch rate:** ~40–60% of real code hallucinations. The guard catches explicit references (imports, named function calls) but misses implicit assumptions (agent assumes a method signature that changed). False positives: ~15-20% for generic tokens. Net useful signal: moderate.

**Complexity:** 3–4 hours. New script + SubagentStop integration + schema migration already done in Cat 1.

**Damage potential: MEDIUM.** Code hallucinations cause compile errors or runtime failures in generated code. Caught by tests if test coverage is good; not caught if agents are adding new features in untested paths.

---

## Competitor Patterns Worth Adopting

**LangChain / LangGraph:** Structured tool schemas with predefined input-output validation. The key pattern: agents interact via tools with explicit schemas, not free-form text. CAST can adopt this as "structured Handoff blocks" (Category 2 guard above) — the Handoff block IS the schema enforcement at the inter-agent boundary. LangGraph's graph architecture also supports audit trails and rollback points; CAST's `agent_runs` table gives audit trails but no rollback.

**CrewAI / AutoGen:** Centralized orchestrators that route agent outputs through a validator before propagation. The CAST `/orchestrate` skill is structurally similar, but doesn't validate — it just dispatches. The Category 2 guard (Handoff extraction) is the missing validation step.

**Letta (MemGPT successor):** Persistent memory with explicit "archival" vs "working" memory distinction. The `valid_to` temporal filter in `cast-memory-router.py` is equivalent to Letta's memory invalidation. CAST already has the right schema (`valid_to`, `superseded_by`) — the Category 3 guard adds the missing read-time path verification that Letta achieves via database-level grounding.

**General pattern across all frameworks:** Hallucination detection in production agentic systems is done through layered verification — memory anchoring, semantic grounding, structured tool access — not single-point detection. CAST currently has only one layer (stat-claim guard). The four guards above add independent verification layers without coupling them together.

Sources consulted: [Advanced Techniques for Hallucination Detection in AI](https://sparkco.ai/blog/advanced-techniques-for-hallucination-detection-in-ai), [Top Agentic AI Frameworks 2026](https://o-mega.ai/articles/langgraph-vs-crewai-vs-autogen-top-10-agent-frameworks-2026)

---

## Priority Order

Ranked by: (damage potential) × (1 / implementation cost)

| Rank | Category | Damage | Hours | Ratio | Rationale |
|---|---|---|---|---|---|
| 1 | **Cat 1: Agent-Claimed Work** | HIGH | 3–4h | **HIGH** | Most directly harmful; infrastructure already exists in SubagentStop hook; catches silent failures before they propagate |
| 2 | **Cat 2: Chain Hallucination** | MEDIUM-HIGH | 2–3h | **HIGH** | Cheapest fix (no new scripts, only convention change); errors compound across the chain making downstream failures hard to trace |
| 3 | **Cat 3: Memory Citation** | MEDIUM | 2h | **MEDIUM** | Self-contained change to memory router; documented incident class (2026-05-05) proves it's real; path verification is 2ms overhead |
| 4 | **Cat 4: Code Reference** | MEDIUM | 3–4h | **MEDIUM-LOW** | Only catches explicit references; ~40% catch rate; tests are a better last-mile defense; implement after the first three are stable |

**Single highest-impact guard to implement first: Category 1 (Agent-Claimed Work Verifier)**

Reasoning: It has the highest damage potential (silent write failures block downstream agents and QA), the implementation fits entirely within the existing SubagentStop hook infrastructure, and it produces a reusable `agent_hallucinations` table that Categories 3 and 4 also write to. Building it first establishes the observability foundation the other guards depend on.
