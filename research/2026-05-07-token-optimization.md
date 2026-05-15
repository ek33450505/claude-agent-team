# Token Optimization Audit — 2026-05-07

## Cost-Per-Workflow Matrix

| Workflow | Model | Est. Input Tokens | Est. Output Tokens | Est. Cost (no cache) | Est. Cost (with caching) |
|---|---|---|---|---|---|
| `commit` agent | Haiku 4.5 | 8,000 | 500 | $0.008 | $0.002 (75% cache read) |
| `code-reviewer` agent | Haiku 4.5 | 12,000 | 800 | $0.013 | $0.004 |
| `planner → code-writer → reviewer → commit` chain | Sonnet+Haiku | 60,000 | 8,000 | $0.300 | $0.120 |
| `researcher` query | Sonnet 4.6 | 25,000 | 4,000 | $0.135 | $0.055 |
| `cast test` (BATS, no API) | None | 0 | 0 | $0.000 | $0.000 |

**Notes:**
- Haiku 4.5: $0.80/M input, $4.00/M output; cache write $1.00/M, cache read $0.08/M
- Sonnet 4.6: $3.00/M input, $15.00/M output; cache write $3.75/M, cache read $0.30/M
- Input token estimates include: CLAUDE.md (~1,200 tokens) + rules (~8,000 tokens) + agent frontmatter (~1,000 tokens) + memory injection (~1,500 tokens) + task prompt + file reads
- Full chain cost assumes planner (20K in, 3K out), code-writer (30K in, 4K out), code-reviewer (8K in, 700 out), commit (4K in, 300 out)
- Caching estimate assumes 60% of input is stable prefix (system prompt + rules) with cache hits at Anthropic's 5-min TTL window

---

## Top 5 Optimization Opportunities

### 1. Rules deduplication / slimming — estimated 35–40% input token reduction per agent dispatch
**Impact: HIGH | Effort: < 1 day**

The `~/.claude/rules/` directory injects ~30KB (≈7,500 tokens) of context into every session. Several rules contain large redundant narrative:
- `working-conventions.md` (7,473 bytes): ~1,900 tokens — most content is workflow reminders already captured in CLAUDE.md or in agent frontmatter
- `project-catalog.md` (3,257 bytes): ~820 tokens — full table of all personal+work projects injected even for `commit` agents that only need repo path
- `stack-context.md` (3,298 bytes): ~830 tokens — frontend stack detail injected for all agents including `commit` and `push`

Opportunity: Create a `rules/core/` subset (CLAUDE.md + shell.md only, ~2,500 tokens) applied to lightweight agents (commit, push, merge, code-reviewer). Full rules load only for implementation agents (code-writer, debugger, planner, researcher). Estimated savings: 4,000–5,000 tokens/dispatch on haiku agents.

### 2. System prompt caching enforcement — estimated 60–70% input cost reduction on repeated dispatches
**Impact: HIGH | Effort: 1–2 days**

Anthropic caches the stable prefix of system prompts with a 5-minute TTL. CAST dispatches multiple agents sequentially within the same plan execution window. If the system prompt (CLAUDE.md + rules) is structurally stable and placed first, cache hits stack across the chain.

Current risk: Memory injection (from `cast-memory-router.py`) is variable and may be inserted before or inline with stable content, breaking the cache boundary. Prompt ordering must enforce: `[stable: CLAUDE.md + rules + agent frontmatter] → [variable: memory injection + task prompt]`. This converts ~7,500 tokens/dispatch from $0.80/M input to $0.08/M cache read — an 10x cost reduction on that slice.

### 3. Model routing for overqualified agents — estimated $0.15–0.25/chain in misrouted spend
**Impact: MEDIUM | Effort: 2–3 days**

Migration-reviewer is currently hardcoded to Opus ($15/M input). Most migration files it reviews are small (<500 lines), making Opus overkill for 80% of cases. Similarly, `researcher` (Sonnet) is used for simple lookups that Haiku could handle.

Decision tree (see section below) shows that 3–4 agent types could downgrade 50–70% of their dispatches to cheaper models with no quality loss. At 10 chains/day: saves ~$0.25/day, ~$90/year, and is relevant to the $0.008–0.013 cost floor for adoption.

### 4. Hook output compression — estimated 1,000–2,000 tokens/dispatch
**Impact: MEDIUM | Effort: < 1 day**

`cast-subagent-stop-hook.sh` receives and logs the agent's full output text (the `output` field in SubagentStop stdin JSON). `cast-user-prompt-hook.sh` reads full prompt text before redacting. Neither of these compress their injected `hookSpecificOutput` JSON payloads.

The SubagentStop hook injects structured review state back into context — if this includes full agent response text it can be 3,000–8,000 tokens. Compress to: status, summary, concerns array, and file list only. Agent full output should never re-enter context via hookSpecificOutput.

### 5. Memory injection scoping — estimated 500–1,500 tokens/dispatch
**Impact: LOW | Effort: < 1 day**

`cast-memory-router.py` uses FTS5 to retrieve relevant memories, but retrieval is not agent-type-scoped in the `--mode retrieve` path. A `commit` agent retrieves the same memory candidates as a `researcher`. Scoping memory retrieval by agent type and filtering out `project`/`reference` type memories for haiku agents (they don't act on them) reduces injection payload with no quality loss.

---

## Model Routing Decision Tree

```
dispatch(agent, prompt):
  ├── Is agent explicitly assigned in CLAUDE.md? → use that model (no override)
  │
  ├── Is prompt length > 8,000 tokens? → sonnet minimum
  │
  ├── Does prompt contain: "architect", "design system", "data model",
  │   "production migration", "compliance", "security audit"? → sonnet or opus
  │
  ├── Does prompt contain: "debug", "trace", "root cause", "stack trace"? → sonnet
  │
  ├── Is task type in [commit, push, merge, code-review, release-notes,
  │   adr-writer, standup-writer, email-drafter]? → haiku (bounded output)
  │
  ├── Is task type in [planner, code-writer, debugger, researcher,
  │   api-contract, perf-sentinel, security]? → sonnet
  │
  ├── Is task type = migration-reviewer AND file_count <= 3
  │   AND no FK constraint drops AND no column removals? → sonnet (save ~$0.12/run)
  │
  └── Default: use model from agent frontmatter
```

**Config surface in `.claude/cast.json`:**
```json
{
  "model_routing": {
    "enabled": true,
    "allow_downgrade": true,
    "keyword_upgrades": ["architecture", "refactor prod", "compliance"],
    "length_threshold_sonnet": 8000,
    "override": {
      "migration-reviewer": "sonnet"
    }
  }
}
```

The dispatch flow reads `cast.json` before resolving the agent model field. Keyword scan runs on the first 500 chars of the prompt (cheap, pre-dispatch).

---

## Deduplication Candidates

| Content | Appears In | Estimated Tokens | Overlap Type |
|---|---|---|---|
| Agent registry table + hook directive syntax | CLAUDE.md + each agent frontmatter `skills: cast-conventions` | ~400 tokens | Full duplicate |
| Stack context (React 19, Vite, Express 5...) | `rules/stack-context.md` + `agents/core/planner.md` body | ~600 tokens | Near-duplicate |
| Working conventions (commit format, branch naming) | `rules/working-conventions.md` + `agents/core/commit.md` body | ~300 tokens | Semantic duplicate |
| Memory injection (procedural type) | `cast-memory-router.py` retrieves procedural memories + agent frontmatter already encodes same procedures | ~400 tokens | Semantic duplicate |
| Status block format | Injected via `cast-conventions` skill + hardcoded in every agent body | ~200 tokens | Full duplicate |

**Total estimated deduplication opportunity: ~1,900 tokens/dispatch (≈15–20% of typical input)**

Deduplication strategy:
1. Remove stack-context block from `planner.md` body — the rules inject it already
2. Strip the agent registry table from CLAUDE.md; it is also in the MEMORY.md index
3. Move Status block format exclusively to `cast-conventions` skill; remove inline copies from agent bodies
4. Filter procedural memories from injection when they duplicate the agent's own frontmatter instructions

---

## Cache Hit Optimization

### What to enforce

1. **Stable prefix ordering (mandatory):** System prompt must follow this order:
   - CLAUDE.md (static)
   - Rules files (static, same set per agent tier)
   - Agent frontmatter / system prompt (static per agent type)
   - Memory injection block (variable — always LAST before the user turn)
   
   If memory injection or hookSpecificOutput is inserted before the static rules block, the cache boundary breaks and all downstream tokens re-bill at full input price.

2. **Rule-set tiers:** Define exactly 2 rule-set bundles:
   - `haiku-tier`: CLAUDE.md + shell.md only (~2,500 tokens stable prefix)
   - `sonnet-tier`: full rules/ directory (~9,000 tokens stable prefix)
   
   Same agent type always gets the same tier → identical stable prefix → cache hit on re-dispatch within 5 minutes.

3. **Memory injection fingerprinting:** Log a hash of the memory injection payload to `cast.db`. If hash matches last dispatch for same agent within 5 minutes, skip re-injection — the cached version is still in the prefix.

### What to show in `cast status`

Add to the status TUI:
```
Cache efficiency (last 24h):
  Hit rate: XX%       Tokens saved: XXX,XXX
  Stable prefix size: X,XXX tokens
  Last cache break: agent=<name>, reason=<memory_injection|rules_change>
```

Read from `agent_runs` table — add columns: `cache_tokens_read`, `cache_tokens_written`, `cache_hit_rate`. The SubagentStop hook can parse these from the Anthropic API response headers (`anthropic-cache-read-input-tokens`).

---

## Implementation Roadmap

### < 1 day (ship now)
- **Hook output compression:** Strip full `output` text from SubagentStop hookSpecificOutput; keep only status/summary/concerns. Edit `cast-subagent-stop-hook.sh`. (Q4 — ~1,500 tokens/dispatch saved)
- **Memory injection scoping:** Add `--agent-type haiku` flag to `cast-memory-router.py` that filters out `project`/`reference` memories for haiku-tier agents. (Q5 — ~600 tokens saved)
- **Dedup: Status block:** Remove inline Status block format from agent bodies where `cast-conventions` skill is already declared. Affects 12+ agents. (Q2 — ~200 tokens/dispatch)

### 2–3 days (next sprint)
- **Rule-set tiers:** Add `rules_tier: haiku|sonnet` to agent frontmatter; `install.sh` maps tier to injected rule subset. (Q2/Q3 — 4,000–5,000 tokens/haiku dispatch)
- **Stable prefix ordering enforcement:** Document and validate that memory injection is always appended after static blocks. Add a lint check to `cast-validate.sh`. (Q4 — 10x cost reduction on stable prefix slice)

### 1 week (infrastructure)
- **Model routing by complexity:** Implement `cast.json` `model_routing` block; wire keyword scan into `cast-managed-agent.sh` before API call. (Q1 — $0.15–0.25/chain savings)
- **cache_hit_rate column in agent_runs:** Parse `anthropic-cache-*` headers in SubagentStop hook; store in DB; surface in `cast status`. (Q4 — visibility prerequisite for optimization)
- **Cost forecasting per workflow:** Use `agent_runs` historical data to project weekly spend by workflow type. Add `cast forecast` subcommand. (Q5 — contributor adoption tool)

---

## Sources

- CLAUDE.md agent registry: `~/.claude/CLAUDE.md` (verified)
- Agent frontmatter files: `agents/core/commit.md`, `code-reviewer.md`, `planner.md`, `migration-reviewer.md` (verified)
- Hook scripts: `scripts/cast-subagent-stop-hook.sh`, `cast-subagent-start-hook.sh`, `cast-user-prompt-hook.sh`, `cast-session-start-hook.sh` (verified)
- DB schema: `sqlite3 ~/.claude/cast.db .schema agent_runs` (verified)
- Memory router: `scripts/cast-memory-router.py` (verified)
- Managed agent dispatch: `scripts/cast-managed-agent.sh` (verified)
- Rules directory sizes: measured via `wc -c` — total 30,068 bytes / ~7,500 tokens (verified)
- Anthropic pricing: Haiku 4.5 $0.80/M in, $4.00/M out; Sonnet 4.6 $3.00/M in, $15.00/M out; Opus 4.7 $15.00/M in, $75.00/M out (per task spec; current as of 2026-05-07)
