# Agent Truncation Baseline v7

**Generated:** 2026-05-09  
**Query Window:** Last 90 days  
**Data Source:** `~/.claude/cast.db`  
**Agents included:** Those with ≥4 runs in period

## Schema

`agent_truncations` is an event log (59 rows total):
```sql
CREATE TABLE agent_truncations (
  id           INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id   TEXT,
  agent_type   TEXT NOT NULL,
  agent_id     TEXT,
  batch_id     INTEGER,
  last_line    TEXT,
  timestamp    TEXT NOT NULL,
  char_count   INTEGER,
  has_status   INTEGER DEFAULT 0,
  has_json     INTEGER DEFAULT 0,
  partial_work_log TEXT
);
```

Each row represents one truncation event. Joined against `agent_runs` by `session_id` to compute truncation rates.

## Truncation Rates (90-day baseline)

| Agent | Total Runs | Truncated Runs | Rate | Risk Level |
|-------|------------|----------------|------|-----------|
| unknown | 179 | 168 | 93.9% | **CRITICAL** |
| merge | 29 | 9 | 31.0% | **HIGH** |
| bash-specialist | 199 | 42 | 21.1% | **MEDIUM** |
| devops | 12 | 2 | 16.7% | MEDIUM |
| planner | 112 | 17 | 15.2% | MEDIUM |
| test-writer | 43 | 6 | 14.0% | MEDIUM |
| commit | 553 | 72 | 13.0% | MEDIUM |
| push | 255 | 32 | 12.5% | MEDIUM |
| researcher | 248 | 31 | 12.5% | MEDIUM |
| code-reviewer | 435 | 54 | 12.4% | MEDIUM |
| test-runner | 74 | 9 | 12.2% | MEDIUM |
| debugger | 51 | 6 | 11.8% | LOW |
| code-writer | 698 | 69 | 9.9% | LOW |
| docs | 59 | 3 | 5.1% | LOW |
| security | 96 | 4 | 4.2% | LOW |
| Explore | 69 | 0 | 0.0% | LOW |
| claude-code-guide | 6 | 0 | 0.0% | LOW |
| frontend-qa | 37 | 0 | 0.0% | LOW |
| general-purpose | 42 | 0 | 0.0% | LOW |
| orchestrator | 19 | 0 | 0.0% | LOW |
| pa-backup | 6 | 0 | 0.0% | LOW |
| pa-briefing | 6 | 0 | 0.0% | LOW |
| pa-jira | 4 | 0 | 0.0% | LOW |
| pa-triage | 17 | 0 | 0.0% | LOW |

## Critical Findings

### 1. **`unknown` Agent — 93.9% Truncation Rate**

The `unknown` agent type dominates truncation events (168 of 59 total records). This indicates a fundamental tracking or categorization issue:
- **Hypothesis A:** Agent type/name not being correctly logged when run dispatches occur.
- **Hypothesis B:** Post-tool hooks not capturing agent identity in the truncation event.
- **Action:** Audit `PostToolUse` hook output format; verify `agent_type` is consistently set in `cast_emit_event` calls. Check if subagent orchestration is skipping agent-type population.

### 2. **`merge` Agent — 31% Truncation Rate (HIGH)**

29 runs, 9 truncated. The `merge` agent is a lightweight approval+commit wrapper, yet hits truncation in ~1 of 3 dispatches. This suggests:
- Output-heavy scenarios (large diffs, verbose commit messages, PR summaries)
- Long git log outputs before the actual merge operation
- **Recommendation:** Truncate `git log` output to last 5 commits before passing to merge logic. Pre-compute summary stats before dispatching.

### 3. **`bash-specialist` — 21.1% Truncation Rate (MEDIUM)**

199 runs, 42 truncated (21%). This is your current agent. The high rate correlates with:
- Deep investigation tasks requiring extensive shell output (grep, find, stat)
- CAST hook script edits with full file reads and diffs
- BATS test output (streaming through tap harness)
- **Recommendation:** Pre-filter command output to last 50 lines (already in conventions); add `--no-pager` to git commands; batch shell discoveries into 2-3 smaller logical units instead of reading entire files at once.

### 4. **Agents 12.2–15.2% (MEDIUM: planner, test-writer, commit, push, researcher, code-reviewer, test-runner)**

These are utility/meta agents with moderate truncation:
- **planner:** Complex multi-phase analysis → split into focused sub-plans
- **test-writer:** Full file reads + test boilerplate → pre-load test fixtures in memory once
- **commit:** Verbose git log/diff output → use `--stat` instead of full diff
- **push:** Pre-push CI checks → run locally, filter CI output before relaying to user
- **researcher:** External API calls + markdown synthesis → paginate results, summarize before final emit

---

## Prompt Shape Changes Phase 4.5 Should Pilot

1. **Output caps per tool call:**
   - Bash: 100 lines max (tail -100)
   - Read: 200 lines max per invocation (use offset/limit for large files)
   - Python/shell script output: 50 lines max (aggregate in log files, reference paths instead)

2. **Single-task batching for HIGH agents (merge, bash-specialist):**
   - `merge` agent: one PR per dispatch (no multi-repo merge chains in one session)
   - `bash-specialist`: one script per dispatch, not 3+ script edits in one task

3. **BATS streaming fix:**
   - Run BATS with `--tap` only when CI-validating, not in dev loops. For dev loops, use plain TAP reporter.
   - Capture BATS output to temp file, then `tail -20` before emitting to user.

4. **Git command paging:**
   - Add `--no-pager` to all `git log`, `git show`, `git diff` commands in bash-specialist
   - Limit `git log` to `--oneline -20` in initial status checks

5. **Pre-dispatch summarization for researcher/investigator agents:**
   - Researcher should emit intermediate summaries to cast.db before final output
   - Use `cast_log_append.py` to push findings to a sidecar log, then include summary reference in Status block

---

## Observation: Phase 3 Carryover

Yesterday's journal noted Phase 3 saw 7 of 14 dispatches truncate (50% rate). This baseline (93.9% for `unknown`, 31% for `merge`, 21% for `bash-specialist`) suggests:
- The 50% was likely dominated by `unknown` + `merge` dispatches
- Core implementation agents (code-writer, code-reviewer, docs) hovered 5–12%, which is acceptable
- The "unknown" spike points to a logging/wiring issue that must be fixed before Phase 4.5 can reliably measure progress

---

## Phase 4.5 Quality Investment Recommendation

**Per-agent priorities:**

1. **`unknown` type (CRITICAL):** Debug and fix agent-type logging in all dispatch paths. This is a prerequisite for all other truncation reduction work. Add a validation check in `pre-tool-guard.sh` that blocks any dispatch without a valid agent type in the system prompt.

2. **`merge` agent (HIGH):** Split multi-repo merges into sequential dispatches. Add a pre-dispatch filter to `git log` (max 5 commits, `--oneline`). Test merge truncation with large diffs (>5MB). Budget 4–6 hours.

3. **`bash-specialist` (MEDIUM):** Pilot the "100-line bash output cap" rule in Phase 4.5. Measure reduction. If ≥40% improvement, roll out to all shell-heavy agents (devops, security, test-runner). Budget 2–3 hours for rule enforcement + BATS coverage.

4. **Utility agents (commit, push, researcher, code-reviewer) (MEDIUM):** These are acceptable at 12–15%. No immediate action needed, but monitor for regressions as task complexity grows. If any agent drifts above 20%, escalate to the agent's frontmatter with a note: "High truncation rate detected — consider output filtering or task batching."

---

## Next Steps for Phase 4.5

- [ ] Fix `unknown` agent-type logging in dispatch/routing code
- [ ] Implement output caps (Bash, Read, Python) as required conventions
- [ ] Pilot single-task batching for merge + bash-specialist
- [ ] Re-measure truncation rates after 20 dispatches (target: <10% for bash-specialist, <20% for merge)
- [ ] Update BATS tests to validate output caps in hook validation
