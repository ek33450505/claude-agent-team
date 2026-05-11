# CAST v7 — Master Plan
**Filed:** 2026-05-07  
**Status:** Active  
**Goal:** Ship CAST v7.0.0 — clean, audited, documented, and live as an MVP-quality open source release.

Phases 0–5 merged to main today (2026-05-07, PR #25, 672 BATS tests). This plan covers everything that remains. Phases are re-numbered 1–6 in priority order and sized for 1-session execution each.

---

## What's done (context)

| Phase | What shipped |
|---|---|
| 0 | Research sprint + CI contributor experience fixes |
| 1 | Distribution + contributor journey (CONTRIBUTING.md, tutorial, good-first-issue labels) |
| 2 | Hallucination guard (work verifier, chain handoff, code ref guard) |
| 3 | Memory pipeline (write, read, staleness sweep, user_profile type) |
| 4 | Agent contract testing framework (`cast test`, contract runner, 6 BATS) |
| 5 | DX polish (`cast new-agent`, init-repo BATS, hook output compression) |
| **Recovery (2026-05-08, PR #29)** | **Hook output spec recovery + automated prevention guardrails + Engram/Stratum sunset.** See "Phase 0 — Recovery Lessons" below before resuming any phase. |

---

## Phase 0 — Recovery Lessons & Inviolable Rules (READ FIRST)

**This section exists because Phase 4 (Contract Testing, commit be8d924) shipped a session-breaking bug.** A hook emitted `'hookSpecificOutput': json.dumps({...})` — a stringified blob — instead of the spec-required object. The Claude Code CLI evaluated `"additionalContext" in <string>` and threw `q.hookSpecificOutput is not an Object` on every subagent completion. Ed lost a full work day to recovery sessions.

**Why this slipped through every gate:**
- The shape mismatch is invisible at static-analysis time (Python typing accepts both `dict` and `dumps(dict)` as values).
- BATS tested the `cast-validate-hook-contracts.sh` validator in isolation, but no CI job ran the validator against actual hook output.
- The validator was fully written and would have caught the bug — it just wasn't wired in.
- Local cleanup also surfaced 4,908 stale branches (mostly `cast-swarm-*` and `worktree-agent-*`) — slop from agent dispatches that never cleaned up after themselves.

### Automated prevention now in place (PR #29)

| Guardrail | What it prevents | Where it lives |
|---|---|---|
| `hook-contract-validation` CI job | Any hook emitting non-spec `hookSpecificOutput` blocks merge. The exact bug class that crashed sessions yesterday is now a hard CI fail. | `.github/workflows/bats-ci.yml` |
| `scripts/cast-validate-all-hooks.sh` | Orchestrator that fires every wired hook with synthetic stdin and validates output against `cast-validate-hook-contracts.sh`. 5 BATS tests. | `scripts/` |
| `scripts/cast-branch-groomer.sh` + `cast clean` | Stops branch slop accumulating to 4,000+ orphans again. Hard whitelist guards `main`, `feat/*`, `feature/cast-v7-*`, and any branch in an active worktree. 7 BATS tests. | `scripts/` + `bin/cast` |
| `scripts/cast-branch-groomer-schedule.sh` | Weekly dry-run report at `~/.claude/reports/branch-grooming-<date>.md`. Visibility before automation. | `scripts/` |
| Engram + Stratum bridge code removed | Sunset projects can no longer be re-wired by accident. | Deleted `cast-bridge-session-{start,end}.sh`, scrubbed `cast-sync-check.sh` allow-list. |

### Inviolable rules — apply to ALL future phases

1. **Every hook that emits structured output MUST be exercised by a fixture-fired test** that asserts the output is a JSON object with the right shape. The validator already exists; new hooks must be added to `cast-validate-all-hooks.sh`'s discovery loop.
2. **`hookSpecificOutput` is an object, not a stringified blob.** Format: `{"hookSpecificOutput": {"hookEventName": "<EventName>", "additionalContext": "<string>"}}`. Stringify the contents of `additionalContext`, never the `hookSpecificOutput` field itself.
3. **Every agent or skill that creates a branch or worktree MUST clean up on success.** The groomer is a safety net, not the primary mechanism. Failed/abandoned runs must be cleaned manually before session end.
4. **No new mentions of Engram or Stratum** in any CAST code, hooks, settings, agent definitions, or rules. Historical CHANGELOG/journal mentions are preserved as accurate history; new code must not reference them.
5. **Before introducing a new structured-output surface** (cast.db schema, jsonl event log, agent-status JSON), write the contract validator and its CI gate in the SAME PR that introduces the surface. Do not defer.
6. **Run `cast clean --dry-run` before every commit/push** in any session that dispatches agents. If the output shows >5 stale branches, run `--apply` before push.

### Open follow-ups from 2026-05-08 audit (address opportunistically)

Three audits ran during the recovery session — bash-specialist (DONE, all clean), researcher (DONE_WITH_CONCERNS, 7 findings), security (pending at time of writing, will land on PR #29 when complete). Verified findings:

| # | Severity | Finding | Disposition |
|---|---|---|---|
| R6 | LOW (real) | `cast-response-completeness-hook.sh` is wired in `settings.json` with absolute path `~/Projects/personal/claude-agent-team/scripts/...` instead of `~/.claude/scripts/...`. Breaks if repo is moved or cloned to a different path. | Fix in v7 Phase 1 (friction reduction). One-line settings.json edit + re-run install. |
| R5 | MEDIUM (real) | Only 3 of 30 agents have `agent-contracts/<name>.contract.yaml`. The contract testing framework from old Phase 4 is built but coverage is 10%. | v7 Phase 4 territory. Decide coverage target during Agent Inventory Audit. |
| R-bonus | MEDIUM (real) | The existing `contract-test` CI job has `\|\| true` AND `continue-on-error: true` — it runs but its result is decorative, not enforced. Different from the new `hook-contract-validation` job (which IS enforced). | Add to v7 Phase 1 or Phase 6 final-CI sweep: remove suppression, gate PRs on contract-test results. |
| R2 | LOW (real) | LLM-eval hooks (`type: prompt` and `type: agent` entries in `settings.json`) are skipped by the contract validator since they have no `command` field. If a prompt-type hook emits malformed BLOCK/ALLOW, no test catches it. | Future: extend validator to recognize LLM-eval hook variants. Not urgent — these hooks don't emit `hookSpecificOutput`. |
| R4 | MEDIUM | No migration sequence guard — `cast-db-migrate-v32.sh` is the latest, idempotent via `IF NOT EXISTS`, but no registry verifies all 32 migrations applied in order. | Defer; add to a future "DB safety" phase. |
| R7 | INFO | 50+ scripts in `scripts/` not wired in any settings.json — mix of CLI utilities and possibly retired hooks. Inventory unclear. | v7 Phase 4 (Agent Inventory Audit) extends to scripts/ inventory. |
| R1 | FALSE POSITIVE | Researcher claimed "hook contract validator not in CI." Verified: the new `hook-contract-validation` job in `.github/workflows/bats-ci.yml` IS the wired-in enforcement. | None. Validated correct. |
| R3 | FALSE POSITIVE | Researcher claimed "agents/ has 2 entries vs 30 claimed." Verified: `agents/core/` + `agents/personal/` contain 30 .md files. Researcher only listed top-level dirs. | None. |
| Bash (DONE) | — | bash-specialist found zero critical/high bugs in the 6 changed/new shell scripts. JSON construction safe, heredocs single-quoted, exit codes correct, stdin parsing safe, empty-output guarded, macOS/Ubuntu portable. | None. |
| **S-M1** | **MEDIUM (real, post-merge)** | **PII/secrets passthrough in `cast-subagent-stop-hook.sh`.** Agent response `Summary` and `Concerns` are serialized into `additionalContext` AND written to `cast.db quality_gates.feedback`. No redaction. If an agent's response includes an API key (e.g. an error message containing a token), it leaks to (a) the parent session context and (b) the queryable DB. | **Address as the FIRST item in v7 Phase 1.** Apply `cast-redact.py` (already in `scripts/`) to `summary` and `concerns` before serializing. ~10 line fix. |
| S-M2 | MEDIUM (real, post-merge) | Fork PRs from outside contributors will execute arbitrary code on the CI runner via the new `hook-contract-validation` job (it runs every hook script with `CLAUDE_SUBPROCESS=0` to bypass the subprocess guard). Currently CI has no elevated permissions and no secrets, so blast radius is bounded — but social-engineering risk grows as contributor count grows. | v7 Phase 6 (release) — enable GitHub's "Require approval for outside collaborators" on the repo, OR add a `pull_request` branch filter that only runs on maintainer-pushed branches. |
| S-L1 | LOW (informational) | `cast-subagent-stop-hook.sh:613` uses `echo` with bash interpolation into a JSON literal. `SAFE_AGENT` is correctly sanitized (strips non-`[a-zA-Z0-9_-]`), so no live injection. But the pattern is regression-prone — a future edit could omit the sanitization. | Future cleanup — refactor to `printf '%s'` inside a double-quoted template. Not urgent. |
| S-L2 | LOW (informational) | `cast-branch-groomer.sh` reads `gh pr list` headRefName output into a bash array. Currently only used for `==` comparison (no interpolation), so safe. If future code ever passes these values to `git` invocations, this becomes exploitable. | Note in code comment as a constraint. |

### Phase-startup ritual (do this for Phases 1–6 below)

Before writing any code in a new v7 phase session:
1. `git status --short` (using `-c submodule.recurse=false` if in worktree) — confirm clean tree.
2. `bash scripts/cast-validate-all-hooks.sh --source` — confirm all 26 hooks emit valid output BEFORE making changes.
3. `cast clean --dry-run` — surface any stale branches; clean if needed.
4. Note the current `git rev-parse HEAD` for rollback.

After completing the phase, before commit:
1. `bash scripts/cast-validate-all-hooks.sh --source` — re-confirm all hooks valid (the gate that failed last week).
2. `bats tests/` — full BATS suite green (one pre-existing local flake on `core.hooksPath` is acceptable; CI runs in clean env).
3. PR description must list each new hook/script and confirm it's in the validator's discovery loop.

---

## Phase 1 — Pipeline Friction Reduction
**Effort:** 2–4 hours | **Branch:** `feature/cast-v7-phase-1-friction`

Fixes the orchestration overhead and safety gaps that make every session slightly more painful than it needs to be. Ship this first so later phases benefit from the improvements.

### 1.1 — Push agent over-defensiveness fix
**Issue:** Push agent re-runs BATS even when caller explicitly says skip. Burns turns and breaks flow.  
**Fix:** Edit `~/.claude/agents/push.md` — add rule: "If caller's prompt explicitly says skip tests or no tests, do not run BATS. Only run BATS if no instruction given or caller asks for it."  
**Test:** Add acceptance test to BATS suite: mock push agent receives "skip tests" prompt → BATS not invoked.

### 1.2 — `install.sh` dirty-tree guard
**Issue:** `install.sh` silently overwrites uncommitted working-tree edits. No guard.  
**Fix:** Add `git status --short` check at top of install.sh. If any modified/staged files exist in paths that install.sh touches, refuse with a named-file error message.  
**Test:** BATS test with a dirty tree → install.sh exits 1 with helpful message.

### 1.3 — Inline whitelist expansion
**Issue:** CLAUDE.md inline whitelist is too narrow. Single-line doc trims, single-value config tweaks, and typo fixes all route through the full 7-batch agent chain. Heavyweight for trivial edits.  
**Fix:** Expand whitelist in CLAUDE.md to include:
- Single-line doc trims (≤3 lines, no executable code)
- Single-value config tweaks in existing settings (not new keys)
- Sub-100-byte string corrections (typos, whitespace)  
**Note:** No test needed — this is a CLAUDE.md policy change.

### 1.4 — `CAST_ALLOW_DIRTY_COMPACT` bypass
**Issue:** `cast-pre-compact-hook.sh` blocks `/compact` when the working tree is dirty. Mid-session compacts without staging create unnecessary friction.  
**Fix:** At top of `cast-pre-compact-hook.sh`: if `CAST_ALLOW_DIRTY_COMPACT=1` is set, skip the dirty check but still log to cast.db.  
**Test:** BATS test: CAST_ALLOW_DIRTY_COMPACT=1 with dirty tree → exits 0.

### 1.5 — Close duplicate GitHub issues
**Issue:** Multiple duplicate issues filed during May 7 session: #4 + #23 (same CONTRIBUTING fix), #5 + #18 (same BATS task), #7 + #20 (same --help task), #8 + #21 (same --help task).  
**Fix:** Close the duplicates (#23, #18, #20, #21) with "duplicate of #X" comment. Leave the originals open.

---

## Phase 2 — Full Repo & Docs Audit
**Effort:** 3–5 hours | **Branch:** `feature/cast-v7-phase-2-docs`

The repo hasn't had a full documentation pass since v4.6. Before v7.0.0 ships publicly, everything needs to match current reality.

### 2.1 — README v7 refresh
**Issues:**
- Elevator pitch is v4.6-era copy. CAST is now v6.0+, 30 agents, 672 tests.
- Badge stats need verification: agent count, test count, version number.
- `## Install` section covers Homebrew only — add manual `bash install.sh` path for non-Homebrew users.
- Architecture diagram section describes old flow (pre-memory, pre-contracts).

**Fix:** Full README rewrite pass:
- Update all badges to verified-correct numbers (use `git ls-files tests/ | xargs grep -c "^@test" | awk -F: '{sum+=$2} END{print sum}'` for test count)
- Update elevator pitch to lead with the trifecta: hook enforcement + audit trail + typed agent registry
- Add v7.0.0 to version history table
- Verify all internal links (#section anchors, docs/ relative links)

### 2.2 — CHEATSHEET agents table (#17)
**Issue:** 13 agents added after CHEATSHEET was last updated are missing from the agents table.  
**Fix:** Audit `agents/core/` and `~/.claude/agents/` against CHEATSHEET entries. Add missing rows. Verify model column matches CLAUDE.md registry.

### 2.3 — Add `--help` to `cast-validate.sh` and `cast-notify.sh` (#7, #8)
**Issue:** Two scripts are missing `--help` flags (good-first-issue asks).  
**Fix:** Add `--help` / `-h` handler at top of each script that prints usage and exits 0.  
**Test:** 2 BATS tests each (help exits 0, help output contains "Usage:").

### 2.4 — BATS tests for `cast-agent-color.sh` and `cast-budget-alert.sh` (#5, #19, #22)
**Issue:** `cast-agent-color.sh` has no BATS coverage and is missing color entries for 13 agents. `cast-budget-alert.sh` needs no-db path coverage.  
**Fix:**
- Add color entries for the 13 missing agents (resolve #22)
- Write `tests/cast-agent-color.bats` (≥4 tests: known agent returns color, unknown returns default, all 30 agents have an entry, --list flag)
- Write `tests/cast-budget-alert-nodc.bats` (≥3 tests: no-db path exits 0 gracefully, missing cast.db produces no error, empty db produces no alert)

### 2.5 — docs/ freshness sweep
**Check each file for accuracy:**
- `docs/known-limitations.md` — limitation #1 is partially resolved (flag it). Verify #2 (nesting depth) is still accurate for current Claude Code version.
- `docs/CAST_AGENT_CONVENTIONS.md` — verify model names match current registry (Haiku 3 is retired; Haiku 4.5 is canonical).
- `docs/architecture/ARCHITECTURE.md` — does it describe current hook flow, cast.db schema (v8), memory pipeline?
- `docs/tutorial/getting-started.md` — walk through it; verify commands still work with v6.0 CLI.
- `docs/TOKEN-OPTIMIZATION.md` — partially superseded by Phase 5 hook compression. Update or note what's shipped vs pending.

### 2.6 — CONTRIBUTING.md final cleanup
**Issue:** #4 (fix stale agent-quality-rubric path) was partially addressed in the Phase 2 commit. Verify the fix landed and the link now resolves. Close #4.

---

## Phase 3 — Token & Cost Optimization
**Effort:** 3–5 hours | **Branch:** `feature/cast-v7-phase-3-tokens`

From `research/2026-05-07-token-optimization.md`. Hook output compression landed in Phase 5. Three items remain — plus carryover from Phase 2 below.

### 3.0 — Discovery / measurement gate (NEW — added post-Phase-2, READ FIRST)

Phase 2 caught a master-plan claim of "13 missing CHEATSHEET agents" that turned out to be 1 in reality. Lesson carried forward: every Phase 3 task quotes a number (~7,500 tokens, 4,000–5,000 savings, 10x cost reduction). **Measure before cutting.** Before any 3.1–3.4 work, run:

1. `cast status` token counter snapshot for: 1 haiku dispatch, 1 sonnet dispatch, 1 opus dispatch. Record actual injected token sizes.
2. Decompose: how many of those tokens are CLAUDE.md vs `rules/*.md` vs agent frontmatter vs memory injection? Use `wc -c` and a quick token-rough estimate (chars/4).
3. Pin numbers to `/tmp/cast-v7-phase3-token-baseline.txt` and reference them in every 3.x prompt.

If the actual baseline shows `rules/` injection is <3,000 tokens (not 7,500), Section 3.1 is not high-impact — re-evaluate before doing the migration work.

If the baseline shows it's higher than 7,500, the gain is bigger — say so.

This 3.0 step is non-negotiable. It's the discovery-first pattern from Phase 2 made permanent.

### 3.1 — Rules deduplication / agent-tier routing (HIGH IMPACT)
**Issue:** `~/.claude/rules/` injects ~7,500 tokens into every agent dispatch, including lightweight haiku agents (commit, push, merge) that only need CLAUDE.md + shell.md. **Verify the 7,500 number against 3.0's pinned baseline before proceeding.**
**Fix:** Create `rules/core/` subset (~2,500 tokens: CLAUDE.md summary + shell.md + agent-specific). Lightweight agents (commit, push, merge, code-reviewer) load core only. Implementation agents (code-writer, debugger, planner, researcher) load full rules.  
**Estimated savings:** 4,000–5,000 tokens/dispatch on haiku agents (~75% reduction for that tier).  
**Note:** Verify via `cast status` token counter before/after.

### 3.2 — System prompt caching enforcement
**Issue:** Memory injection from `cast-memory-router.py` may be inserted before stable content, breaking the 5-minute Anthropic cache boundary.  
**Fix:** Enforce prompt ordering: `[stable: CLAUDE.md + rules + agent frontmatter] → [variable: memory injection + task prompt]`. Add a cast.db tag to track cache-hit rate per agent type.  
**Estimated savings:** 10x cost reduction on the stable prefix slice (~$0.08/M vs $0.80/M per input token).

### 3.3 — Memory injection scoping
**Issue:** `cast-memory-router.py --mode retrieve` returns the same memory candidates regardless of agent type. A `commit` agent retrieves project+reference memories it can't act on.  
**Fix:** Add `--agent-type` filter to retrieve mode. Lightweight agents (commit, push) skip `project` and `reference` type memories. Only `feedback` and `user` types are injected.  
**Test:** BATS test: `cast-memory-router.py --mode retrieve --agent-type commit` does not return `type=project` memories.

### 3.4 — REC-09: effort:xhigh decision
**Issue:** `planner.md` and `debugger.md` have `effort: xhigh` despite being `model: sonnet` (effort field is silently ignored on non-Opus).  
**Decision needed:** (a) Promote planner/debugger to `model: opus` + keep `effort: xhigh`, or (b) remove `effort: xhigh` from non-Opus agents and document as N/A.  
**Recommendation:** Option (b) — clean up the frontmatter noise. Opus is expensive; sonnet is the right call for these agents unless a specific dispatch warrants it. Document in CLAUDE.md agent registry.

### 3.5 — Phase 2 carryover (open issues + bugs)

These surfaced during Phase 2 execution and are bundled into Phase 3 as opportunistic fixes — they all touch token cost / agent behavior in ways that align with the phase theme. Do NOT defer them past Phase 3.

| # | Severity | Item | Location | Fix |
|---|---|---|---|---|
| C1 | LOW (security) | `event_enabled()` in `cast-notify.sh:98` interpolates `$EVENT_TYPE` into a `python3 -c` double-quoted string. Single-quote in `$1` breaks Python string boundary. Internal use only; low exploitability. | `scripts/cast-notify.sh:65` (validation) and `:98` (call site) | Add an `EVENT_TYPE` whitelist check at line 65: `case "$EVENT_TYPE" in blocked\|queue_complete\|budget_alert\|briefing_ready) ;; *) echo "Unknown event type: $EVENT_TYPE" >&2; exit 1 ;; esac`. Or pass via `sys.argv[1]` instead of interpolation. ~5 lines + 1 BATS regression test. |
| C2 | MEDIUM (correctness) | Validator `--source` flag misnomer: `bash scripts/cast-validate-all-hooks.sh --source` reads runtime copies at `~/.claude/scripts/`, not repo source. Carried from Phase 1; would have caught Phase 1's cwd-changed regression sooner. | `scripts/cast-validate-all-hooks.sh` | Either (a) make `--source` actually read from `scripts/` (repo) and add a `--runtime` flag for the existing behavior, or (b) rename the existing flag to `--runtime` and add a new `--source` that reads repo. Add a BATS test that asserts `--source` reads from `scripts/<file>` and `--runtime` reads from `~/.claude/scripts/<file>`. The test is the rule from Phase 1's lesson "when I write a `--source` flag, the next thing I write should be a BATS test that asserts it reads from `scripts/`." |
| C3 | LOW (DX) | `bats tests/` is non-recursive in BATS 1.13.0. Running it locally executes only 79 of 89 BATS files (719 of 793 tests). CI uses explicit globs and is fine, but the local invocation pattern misleads. | invocation pattern | Either: (a) add a `tests/run.sh` wrapper that uses CI's exact glob list, or (b) document the pattern in CONTRIBUTING.md and CHEATSHEET. Option (a) preferred — less drift risk. |
| C4 | LOW (orchestration) | Phase 2 Batch 5 `test-runner` agent ran for 8.5 min on `bats tests/` and the `[CAST-TRUNCATED]` hook fired. Likely cause: BATS streams 700+ lines of `ok N` output and the agent's output buffer overflows. | `~/.claude/agents/core/test-runner.md` (or wherever the prompt lives) | Update the test-runner prompt to pipe BATS through `bats --tap` + summarize counts via grep, OR have it run targeted file lists. Either approach keeps the agent's buffer under the truncation threshold. Add a CI cast.db query to verify `agent_truncations` table doesn't show test-runner regressions. |
| C5 | INFO (visibility) | 217 `cast-swarm-*` branches accumulated in the 2026-05-08 sessions. All under the 14-day shield, so `cast clean` won't touch them yet. They'll all become candidates on 2026-05-22. | branch hygiene | Either run `cast clean --apply` on 2026-05-22 manually, or add a calendar reminder. Long-term: research-tier agents (`researcher`, `bash-specialist`, `security`) still auto-isolate into worktrees+branches per the 2026-05-08 journal. Phase 4 (Agent Inventory) is the right place to revisit auto-isolation defaults. |
| C6 | INFO (sunset hygiene) | `scripts/cast-cron-setup.sh` references `/Users/edkubiak/JARVIS/` as a backup destination path. `scripts/pa-weather-prefetch.sh` is a JARVIS output-target script left intentionally per `~/.claude/rules/project-catalog.md`. Both pre-date the JARVIS archive; both classified as not Rule 4 violations during Phase 2 review. | `scripts/cast-cron-setup.sh:45`, `scripts/pa-weather-prefetch.sh` (whole file) | Phase 4 (Agent Inventory + scripts/ inventory) decides whether to move these to `scripts/archive/` or leave alone. No action in Phase 3 unless they actively break something. |
| C7 | INFO (process) | The `[CAST-TRUNCATED]` hook is correct and useful; orchestrator handled it well by running gates inline. But the pattern of "agent truncates → orchestrator falls back to inline" should be a documented escape hatch, not an ad-hoc move. | orchestrate skill | Add a section to `~/.claude/skills/orchestrate/SKILL.md` describing the fallback rule: "If `[CAST-TRUNCATED]` fires on a read-only gate agent (test-runner, code-reviewer, security), the orchestrator may run the gate's commands inline as a substitute." This formalizes what we did in Phase 2 Batch 5. |

C1 + C2 are the only ones that touch executable behavior and need code-writer/bash-specialist dispatch. C3, C4, C7 are doc/skill updates. C5, C6 are deferrals to track. Treat C1 + C2 as required Phase 3 deliverables; the rest are bonus if there's time.

---

## Phase 4 — Agent Inventory Audit
**Effort:** 2–3 hours | **Branch:** `feature/cast-v7-phase-4-agents`

Audit current agent inventory before adding anything new. Only add what fills a demonstrated gap.

### 4.1 — Agent dispatch frequency audit
**Query:** `sqlite3 ~/.claude/cast.db "SELECT agent, COUNT(*) as dispatches, MAX(ended_at) as last_seen FROM agent_runs WHERE started_at > datetime('now', '-90 days') GROUP BY agent ORDER BY dispatches DESC;"`  
**Output:** Disposition table at `research/agent-inventory-audit-v7.md`  
**Verdicts:** KEEP / MERGE-INTO-X / RETIRE for each agent.

### 4.2 — Frontmatter drift audit
**Issue (C7):** Phase 5 fixed code-writer/debugger/security model mismatch. More may exist.  
**Fix:** For every agent in `agents/core/`:
- `model:` field matches CLAUDE.md Agent Registry table
- `tools:` list is accurate (no tools listed that the agent never uses)
- `description:` matches actual behavior (dispatch-triggering copy)  
**Update CLAUDE.md Agent Registry table to match.**

### 4.3 — Constrained cherry-pick (post-audit)
**Rule:** Only run this step after 4.1 and 4.2 complete.  
**Net change cap:** ≤2 new agents, ≤3 new hooks. Each addition must address a gap identified in 4.1.  
**Candidates to evaluate:**
- `perf-sentinel` — does CAST need it given cast.db already tracks timing?
- `dep-auditor` — package change reviewer; useful for Homebrew formula work
- `adr-writer` — Architecture Decision Record author; fits the v7 docs push

---

## Phase 4.5 — Top-Tier Dev Team Foundation
**Effort:** 8–12 hours | **Branch:** `feature/cast-v7-phase-4-5-quality`

The "fewer-but-better" execution phase. Phase 4 produced the audit + truncation baseline; Phase 4.5 acts on them. The framing Ed set on 2026-05-09: "top-tier developer agents — cover all agent infra and logic so we don't have to revisit. Fix all the bugs, the truncations, the miscommunications. Solid foundation."

Coverage target — every stage of an Anthropic-developer workflow has exactly one well-defined agent (or skill):
**project creation → architecture → implementation → testing → review → security → perf → API/migration → deps → git → docs → release → CI/infra → eval/benchmark → marketing copy.**

### 4.5.0 — Discovery research (gate, ~1h)
Researcher scope: "What does an Anthropic developer's full workflow look like in 2026?" Use Anthropic docs + Claude Code best-practices posts + WebSearch. Output: `research/anthropic-dev-workflow-gaps-v7.md`. Pin findings before deciding adds.

Specific gap-validation questions:
- Is `eval-writer` (writes Claude API evals / benchmark fixtures) a real Anthropic-developer-essential agent, or a niche?
- Is a deep PR-reviewer (holistic, at PR-open time) distinct enough from per-unit code-reviewer to warrant a separate agent?
- Is `marketing-copy` (landing-page hero, blog drafts, README pitch, social posts) better as an agent or as a routine (Phase 4.6) — the latter if the trigger is webhook (release tag) rather than dispatch.
- What does Anthropic's own internal dev tooling cite as the "standard agent inventory"? (If they've published anything — docs, blog posts, internal showcase.)

### 4.5.1 — Critical bug fixes
Three blockers identified by `research/agent-truncation-baseline-v7.md`:
1. **`unknown` agent-type 93.9% truncation rate** — logging bug. 168 of ~179 dispatches log without proper agent_type. Audit `PostToolUse` and `cast_emit_event` paths; verify `agent_type` is consistently set. Pre-tool-guard validation: block any dispatch lacking valid agent type. **CRITICAL — without this fix, all future truncation telemetry is garbage.**
2. **`merge` agent 31% truncation → convert to skill** (Ed's call). Merge is mostly approval gates + `git merge` + cleanup — deterministic shell, not model-mediated. Replace with a `/merge` skill that auto-dispatches the script, with explicit prompt only for genuine ambiguity.
3. **`bash-specialist` 21% truncation** — implement output caps (Bash: 100 lines max via tail; `--no-pager` on git; BATS through `--tap` then `tail -20`; Read 200 lines max with offset/limit for large files).

### 4.5.2 — Retirements
Tier 1 (safe, no integration deps, role covered by another agent):
- `standup-writer` — morning-briefing covers git activity
- `pr-narrator` — researcher produces equivalent prose
- `knowledge-curator` — Obsidian workflow not active
- `learning-scout` — researcher handles topic research; sonnet cost with zero ROI

Tier 2 (requires routing-table cleanup):
- `adr-writer` — remove `adr/architecture decision` from routing-table or redirect to researcher
- `task-triage` — remove Todoist/inbox routing keywords
- `meeting-prep` — remove calendar routing keywords

`migration-reviewer` — RETIRE if Phase 4.5 can't fix its routing trigger. Routing tested in 4.5.0 discovery. If broken, retire; if fixable, KEEP.

### 4.5.3 — Merges
- `email-drafter` → docs (move `email/draft/compose/reply/gmail` keywords to docs)
- `portfolio-sync` → docs (move `portfolio/sync/readme stats` keywords to docs)

### 4.5.4 — Adds (gated on 4.5.0 research)
Provisional candidates pending research validation:
- `eval-writer` — write evals/benchmark fixtures for Claude API + agent prompt regressions. Anthropic-specific value.
- `pr-reviewer` — holistic PR review at PR-open time (distinct from per-unit code-reviewer). Reads whole diff + commit history + linked issues.
- `marketing-copy` — landing pages, blog posts, README hero, social. Replaces what pr-narrator was attempting.

Rule: each add must address a measurable gap from 4.5.0 research. No additions without justification.

### 4.5.5 — Quality investments per kept agent
For every agent that survives the cuts, name and execute ONE measurable improvement:
- **Output caps** — Bash 100 lines, Read 200 lines, structured output preferred over prose
- **Handoff schema strictness** — every agent ends with required keys (`files_changed`, `status`, `blockers`); orchestrator validates JSON shape, not just regex match on `Status:`
- **Tool-list trim** — read each agent's frontmatter; remove tools the agent never uses (audit via cast.db tool-call telemetry if available, else manual review)
- **Truncation-aware prompt structure** — high-truncation agents (commit, push, planner) get prompt restructuring: file-presence check first, action second, summary third — recoverable if mid-task truncation hits
- **Per-agent memory pool** — agents with recurring decision patterns (commit, debugger, security) get dedicated memory directories

### 4.5.6 — Chain-verify mapping
Every code-modifying agent auto-dispatches a verify agent:
- code-writer → code-reviewer (already wired)
- bash-specialist → code-reviewer (currently optional; make mandatory)
- debugger → test-runner (verify fix actually fixes)
- security → code-reviewer + dedicated security-regression test
- migration-reviewer (if kept) → test-runner against migration fixtures

The principle: no code-modifying agent reports DONE without a chained verification step. The `cast-claimed-work-verifier` hook already enforces some of this — extend coverage to all code-modifying agents.

### 4.5.7 — Cross-repo count sync
Update agent counts wherever they appear:
- `claude-agent-team` — README badge (auto-stamped via gen-stats), CHEATSHEET, install.sh hint text
- `claude-code-dashboard` — `/agents` page UI, any "30 agents" string
- `cast-website` (under `~/Projects/personal/`) — hero copy, features section
- `homebrew-cast` formula description
- `Edward_Kubiak` portfolio README (mechanical only — full marketing push moves to post-v8)

### 4.5.8 — PR #45 CI fixes
Bundle into the 4.5 PR per Ed's call: 3 BATS jobs (bats, bats-macos, bats-ubuntu) failed on PR #45. Likely candidates:
- New effort-frontmatter assertions hit a path/fixture issue in CI
- Possible `bats-ci.yml` missing scripts/*.py copy step (per `feedback_bats_ci_copy_py.md`)
- Run debugger on the failed jobs first

---

## Phase 4.6 — CAST Routines (sibling phase, can run after 4.5 or in parallel)
**Effort:** 6–10 hours | **Branch:** `feature/cast-v7-phase-4-6-routines`

The reframe Ed surfaced on 2026-05-09: the agents we're retiring (task-triage, meeting-prep, standup-writer, knowledge-curator, learning-scout, pr-narrator) weren't bad agents — they were **mistargeted dispatch**. Their work is scheduled or webhook-triggered, not on-demand-via-keyword. Phase 4.6 generalizes the JARVIS PA migration pattern (RemoteTrigger + cron, per `project_jarvis_pa.md`) from Ed-only to user-installable.

This is also the deliverable that makes CAST meaningfully different from "Claude Code with extra agents" — it's an admin layer for "automate my dev life." Direct precedent for the v8 desktop app's value prop.

### 4.6.1 — Routine framework
- Define `cast routines` CLI surface: `list`, `status`, `enable`, `disable`, `trigger <name>`
- Routines stored as YAML/JSON specs under `~/.claude/routines/<name>.yaml`
- Each routine: trigger (cron string OR webhook OR remote-trigger), agent to dispatch, prompt template, output destination
- BATS coverage for the framework before any routines ship

### 4.6.2 — Convert retired agents to routines
- `task-triage` → cron daily 8am (if Todoist MCP wired) OR webhook on Todoist task-created
- `meeting-prep` → webhook on Google Calendar event-created (if MS365/GCal MCP wired)
- `standup-writer` → cron daily 8am (git activity + Todoist completed yesterday → standup format)
- `knowledge-curator` → cron weekly Sunday (Obsidian vault scan)
- `learning-scout` → cron weekly Sunday (WebSearch on user-defined topics → Obsidian writeback)
- `pr-narrator` → GitHub webhook on PR-opened

For each: the agent file moves from `agents/core/` to `routines/<name>/agent.md`; the routine YAML wires the trigger.

### 4.6.3 — New routines (greenfield)
- `email-triage` (Gmail webhook on new mail → Claude Haiku categorize + draft replies)
- `release-celebration` (GitHub webhook on release tag → marketing-copy post draft to LinkedIn/dev.to)
- `daily-CAST-health` (cron daily → cast doctor → notify if regressions)
- `weekly-cost-report` (cron Sunday → /cost + /usage aggregation → email summary)

### 4.6.4 — Local admin UI
- Add `/routines` page to `claude-code-dashboard` showing routine status, last-run, next-run, recent output
- Manual trigger button per routine
- This is the precursor to v8's desktop admin UI

### 4.6.5 — Documentation
- New `docs/routines.md` — what they are, how to author one, how triggers wire
- README section explaining routines vs agents (the dispatch-vs-schedule distinction)
- CHEATSHEET row per routine

### 4.6.6 — MCP availability pre-flight (in-line addition to Wave 4c, added 2026-05-10)
**Why:** The runner built in Wave 2 will happily dispatch a Gmail-dependent routine even if the Gmail MCP isn't wired — fails confusingly mid-dispatch with cryptic MCP errors. Routines that need MCP integrations (email-triage, meeting-prep, knowledge-curator, learning-scout) must fail-fast with a clear actionable message.
- Add optional `mcp_required: [<server-name>, ...]` field to routine YAML spec
- Runner reads field, probes each required MCP server (one-shot test call via `cast-managed-agent.sh --define-only` or equivalent), exits 1 with clear "MCP <name> not reachable — wire it in settings.json mcpServers and retry" on failure
- BATS coverage: routine with unreachable MCP fails-fast; routine with no `mcp_required` field still dispatches (backward compatible)
- Slots into Wave 4c (where the MCP-dependent routines are authored)

---

## Phase 4.9 — Truncation-Resilient Status Emission (NEW — added 2026-05-10)
**Effort:** ~0.5 day | **Branch:** `feature/cast-v7-phase-4-9-status-resilience`
**Why:** Tonight's session evidence — 7 of 9 substantive agent dispatches truncated mid-summary; work was on disk in every case, only the prose tail got cut. Phase 4.8.5's front-loaded Status emission helps the orchestrator parse what landed but doesn't eliminate the "did it work?" question when the response itself never returns a Status line.

### Design
- Every code-modifying agent writes `~/.claude/agent-status/<agent_id>.json` BEFORE writing the prose summary. Schema: `{schema_version, status, agent, summary, concerns[], files_changed[], next_actions[], timestamp}`.
- Orchestrator falls back to reading the status file if the response is missing a Status line after one retry. Treats file-status as source of truth.
- Existing `cast-status-write.sh` plumbing reused — adds a "write before summary" convention to agent definitions in `agents/core/`.
- BATS coverage: dispatching an agent that hits the truncation pattern (simulated via short max-tokens) still resolves to its file-written Status.

### Why before docs/ecosystem
This change touches `agents/core/*.md` (frontmatter or boilerplate) and the orchestrate skill. Doing it before the docs sweep means docs reflect the new convention from day one. Doing it before the ecosystem sync means agent definitions sync once with the new convention rather than syncing twice.

---

## Phase 4.10 — cast.db Schema Drift Cleanup (NEW — added 2026-05-10)
**Effort:** ~2-3 hours | **Branch:** `feature/cast-v7-phase-4-10-db-drift`
**Why:** Per the open memory `project_cast_db_schema_drift_2026-05-10.md`: `routing_events.agent_id` column missing in production; `agent_truncations` table missing in BATS test envs without migrations 009/010. Silent failures landing in `~/.claude/logs/db-write-errors.log`. Observability you can't trust is worse than no observability. Phase 5 has shipped — this is no longer blocked.

### Design
- Audit `~/.claude/logs/db-write-errors.log` to enumerate the actual write failures hitting production now
- Add migration `013-schema-drift-fix.sql` with idempotent ALTER TABLE blocks (try/except on each ALTER to survive existing-column errors)
- Ensure migrations 009 + 010 + 013 run on BATS test setup (audit `tests/test_helper/cast-setup.bash` or equivalent)
- BATS coverage: `routing_events.agent_id` write succeeds; `agent_truncations` insert succeeds in fresh test env
- After fix, verify `db-write-errors.log` is empty for 24h before declaring done (optional verification step before merge)

### Why before docs/ecosystem
Silent DB write failures = bad data in production right now. Better to fix the observability layer before any new docs claim "CAST has full observability."

---

## Phase 4.8 — Stability + Memory Hardening (CAST tighten)
**Effort:** 1.5–2 days | **Branch:** `feature/cast-v7-phase-4-8-stability`
**Decided:** 2026-05-10 (Ed). Frame: "v7 = tighten CAST further, v8 = the app." This phase closes the highest-leverage stability/memory gaps surfaced from two pieces of research Ed dropped 2026-05-10 (local-LLM memory architecture + Claude Code limitations as of May 2026). The vector-DB / observer-process / formal-retry-policy work is intentionally **deferred to v8** (see v8 plan §"Memory v2 + Reliability layer") — those change the data model and add dependencies, which conflicts with v7's "set in stone" goal.

### Why these four (and not the bigger architecture)
The full memory architecture from the research (vector DB + decoupled observer + 3-tier semantic/episodic/procedural) is a multi-week build and changes cast.db's shape. v7 is shipping. These four items each take half a day, leverage the schema and hooks already in place, and close the recurring bug classes Ed has hit:
- 3-week-old stale auto-memory pointing at wires that were never connected (2026-05-05 incident, see `feedback_memory_verification.md`)
- Bugs encountered before, debugged again from scratch (no episodic recall)
- Auto-memories landing silently with no review surface (cluttered MEMORY.md indexes)
- "Silent fake success" risk that Anthropic Claude Code itself ships around in 2026 (try/catch returning sample data when API integration fails)

### 4.8.1 — Episodic incidents table
- Add migration `migrations/011-incidents.sql` with schema:
  ```sql
  CREATE TABLE IF NOT EXISTS incidents (
    id TEXT PRIMARY KEY,
    occurred_at TEXT NOT NULL,
    problem_summary TEXT NOT NULL,
    fix_summary TEXT,
    related_files TEXT,         -- JSON array
    related_commit TEXT,
    resolution_status TEXT,     -- open | fixed | wont-fix | duplicate
    surfaced_by TEXT             -- agent name or 'manual'
  );
  CREATE INDEX IF NOT EXISTS idx_incidents_occurred ON incidents(occurred_at);
  ```
- Auto-populate hook: `cast-incident-record.sh` fires when `debugger` agent ends with Status: DONE — extracts problem from initial prompt, fix from final summary, files from `files_changed`.
- CLI surface: `cast incidents recent [N]`, `cast incidents search <kw>` (sqlite LIKE for v7; FTS in v8).
- Morning briefing surface: top 3 unresolved incidents.

### 4.8.2 — Flag-for-review pattern for auto-memory
- Today: `cast-memory-router.py --mode write` lands memories silently into `~/.claude/projects/<id>/memory/`.
- New: route auto-writes to `~/.claude/projects/<id>/memory/_pending/` instead. The auto-writer flags low-confidence writes (e.g., short text, no clear category, mentions retired entities).
- Morning briefing surfaces pending review queue; one-key approve/reject on a `cast memory review` TUI prompt.
- Auto-promote after 7 days if not reviewed (failsafe — no entries lost).
- Manual writes (when Ed says "remember this") bypass the queue and land immediately.

### 4.8.3 — Stale-memory TTL warning
- Add `last_seen` and `verified_at` columns to memory metadata (frontmatter — markdown extension, no schema change).
- `cast doctor` adds a "stale memory" check: any auto-memory with `verified_at` > 30 days old AND naming a specific path/function/flag gets surfaced for re-verification.
- Closes the 2026-05-05 bug class where the memory was honest about its observation but the world had moved.

### 4.8.4 — Anti-fake-success guard hook
- New PreToolUse hook on Edit + Write: `cast-no-fake-success-guard.sh`.
- Greps the new content for the pattern Anthropic's own users report: `try.*except.*return.*\(sample\|fake\|mock\|placeholder\|dummy\)` (Python) and `try.*catch.*return\s*[\[{].*\(sample\|fake\|mock\)` (JS/TS).
- On match: warns inline (not a hard block — too many false positives in test files) and logs to `cast.db quality_gates`.
- Test-file-aware: skip if the file path contains `/tests/` or `.test.` or `.spec.`.
- The bar is "developer notices this in the diff," not "block the edit."

### 4.8.5 — Front-load Status emission (agent definition convention)
- Insight from 2026-05-10 journal: agents complete the work then truncate before reporting. Status is the *last* thing they emit and the *first* thing context overrun cuts off. Mid-orchestration recovery has worked tonight via inline diff-verification, but it's a recurring tax.
- Update agent definitions: emit `Status: DONE` on its own line **as soon as the work is verifiably on disk**, then write `## Handoff` and `## Work Log` after. Summary becomes the optional tail, not the load-bearing contract.
- This is a one-line edit in each of the 21 agent prompts modified by Phase 4.5.5 — fold in here rather than reopening that PR.

### 4.8.6 — Test gate + push + PR
- Full BATS suite green before commit
- PR titled "CAST v7 Phase 4.8: Stability + Memory Hardening — episodic incidents, review queue, TTL, fake-success guard"
- Merge before Phase 5

### Coordination with other v7 phases
- **Runs after Phase 4.6** (routines framework) — routines might want to consume the incidents table.
- **Runs before Phase 4.7** (ecosystem sync) — the new schema columns and CLI commands need to land before the cross-repo sync references them.
- **Independent of Phase 5/5.5/6** — no overlap.

---

## Phase 5 — Two-Copy Mirroring Resolution
**Effort:** 1–2 hours | **Branch:** `feature/cast-v7-phase-5-mirror`

The `rules-core/` + `~/.claude/rules/` two-copy pattern is a drift hazard. Every phase so far has required a path correction mid-flight.

### 5.1 — Drift audit
Run: `for f in rules-core/*; do diff "$f" ~/.claude/rules/"$(basename $f)" && echo "OK" || echo "DRIFT: $f"; done`  
Document findings in `research/rules-drift-audit-v7.md`.

### 5.2 — Resolution decision
Choose one:

| Option | Pros | Cons |
|---|---|---|
| **Keep as-is + add drift CI check** | Familiar; zero migration risk | Drift risk remains; install.sh hazard |
| **Symlink runtime → repo source** | Single source of truth; zero drift possible | Shell resolution edge cases |
| **Move everything to `~/.claude/`, stop mirroring** | Simplest for solo use | Loses repo-trackable rules; harder for contributors |

**Recommended:** Option A + CI check. Add a `rules-drift.yml` CI job that diffs rules-core/ against a reference snapshot. Fails if any file diverges. Low risk, zero migration.

### 5.3 — Fix any drift found in 5.1
Apply fixes or update install.sh copy step to be the canonical sync mechanism.

---

## Phase 6 — CAST v7 Release
**Effort:** 2–3 hours | **Branch:** `feature/cast-v7-phase-6-release`

Everything needed to cut a v7.0.0 release that's presentable as an Anthropic portfolio piece.

### 6.1 — Version bump
- `bin/cast`: bump `CAST_VERSION` to `7.0.0`
- `README.md`: update version badge + version history table entry for v7.0.0
- `CHANGELOG.md` (create if missing): entry for v7.0.0 summarizing phases 0–5 + the v7 work

### 6.2 — Homebrew formula update
- Compute new sha256 for the release tarball
- Update `~/Projects/personal/homebrew-cast/Formula/cast.rb` — url + sha256
- Commit + push tap

### 6.3 — cast-claudes_journal v0.2.0 release
**From deferred backlog:**
1. In `~/Projects/personal/cast-claudes_journal/`, bump VERSION to `0.2.0`, commit, push, tag `v0.2.0`
2. Update `~/Projects/personal/homebrew-claudes-journal/Formula/claudes-journal.rb` — url + sha256

### 6.4 — Mechanical portfolio sync
**Mechanical only — no marketing push (deferred to post-v8 per Ed 2026-05-09).**
- `Edward_Kubiak` README: update CAST stats (agent count, test count, version, Phase 4.5/4.6 highlights)
- `claude-code-dashboard` README: verify it references v7 once release is cut
- `cast-website`: hero copy stat sync (agent count, test count, version)
- `homebrew-cast` formula description: version bump
- LinkedIn/GitHub bio: minimal version-string update (no announcement post)

### 6.5 — Final CI + health check
- `cast doctor` passes cleanly on a fresh install
- `bash tests/run.sh --tap | tail -5` green (target: ~900 tests after 4.5/4.6 additions)
- `cast test commit` runs against fixture without error
- All open PRs closed or merged
- No stale branches

### 6.5b — `cast doctor` expansion (NEW — added 2026-05-10)
**Why:** Tonight's session evidence + `feedback_memory_verification.md` (2026-05-05 incident: 3-week-old memory pointed at a hook that was never wired). Current `cast doctor` catches the basics; v7 lockdown should mean it catches the "wires-missing" class too.
- Check every hook in `~/.claude/settings.json` resolves to a script that exists and is executable
- Check every MCP server in `mcpServers` is reachable (one-shot ping with short timeout — best-effort, warn-not-fail if a server is intentionally offline)
- Check every `agents/core/*.md` has parseable YAML frontmatter
- Check every `routines/*.yaml` validates (after Phase 4.6 ships)
- BATS coverage for each new check

### 6.5c — Incident corpus backfill (NEW — added 2026-05-10)
**Why:** Phase 4.8.1 shipped the `incidents` table empty. v7 ships with a useful corpus instead of waiting for organic accumulation.
- One-pass review of last 30 days of `~/Documents/Claude/` journal + the `feedback_*.md` memories that document specific bug classes
- Write 10–20 incidents to the `incidents` table covering the recurring patterns: macOS leniency blind spots, Python heredoc injection, gen-stats README leak, bash 3.2 parameter expansion, BSD-vs-GNU stat, commit agent file-drops, agent truncation rate
- Each row: occurred_at, problem_summary, fix_summary, related_files, related_commit (if traceable), resolution_status='fixed', surfaced_by='manual-backfill-v7-lockdown'
- Run via a one-shot Python script committed to `scripts/cast-incident-backfill-v7.py` (delete after run or leave as historical artifact — Ed's call)

### 6.5d — Branch protection on main (NEW — added 2026-05-10)
**Why:** Right now nothing on GitHub stops a direct-to-main push. v7 "set in cement" framing means main should be PR-only.
- After v7.0.0 tag lands, enable on `ek33450505/claude-agent-team` (or `ek33450505/cast` post-rename): "Require a pull request before merging" + "Require status checks to pass before merging" (require: `bats`, `bats-ubuntu`, `bats-macos`, `CodeQL`)
- 2-minute mechanical GitHub setting — but verify locally by attempting a direct push (should be rejected)
- Document the rule in CLAUDE.md / working-conventions.md so future Claude doesn't try to push direct

### 6.6 — Marketing push: DEFERRED to post-v8
The big-marketing-push deliverables are intentionally held until the v8 desktop app is shippable. v7 is technical depth (a portfolio piece for technical reviewers); v8 is the product story (what tells the public-facing narrative). Pushing v7 marketing now spends visibility on a release that's a setup for the real one.

Items moved to post-v8:
- LinkedIn long-form CAST announcement
- dev.to / Hashnode article series (Phase-by-phase deep dives)
- Demo video / screencast
- Help-wanted issues batch (drafted in `research/archive/2026-05-09-help-wanted-issues-draft.md`, archived during Phase 4 housekeeping)
- Anthropic Discord / community announcements
- Twitter / Bluesky thread
- HackerNews / Reddit show-and-tell
- Recruiter outreach citing CAST as portfolio

Rationale: v7 ships as a clean technical release that lives on the README and Homebrew tap. v8 (CAST Desktop) is the moment the project graduates from "personal workshop" to "product story." Marketing once, with the bigger story, lands harder than two narrower pushes.

---

## Deferred / Out of Scope for v7

These are real but not blocking v7:

| Item | Why deferred |
|---|---|
| Todoist MCP SubagentStop pilot | Todoist MCP server not configured in mcpServers |
| Journal cancel-flag hardening | Needs behavioral spec agreement first |
| `cast report --ci` (GitHub Actions summary) | Nice-to-have; not blocking v7 |
| Managed Agents v2 (RemoteTrigger integration) | Phase 6b work; separate session |
| Model routing for overqualified agents | Phase 3.2 covers the easy wins; full routing tree is a larger architectural decision |

---

## Sequencing

```
Phase 1 (friction) → Phase 2 (docs) → Phase 3 (tokens) → Phase 4 (agent audit)
                                                              ↓
                                          Phase 4.5 (top-tier dev team)  ← critical bug fixes + retires + adds + quality
                                                              ↓
                                          Phase 4.6 (routines)           ← can run after 4.5 or parallel; sibling
                                                              ↓
                                          Phase 5 (mirror cleanup)
                                                              ↓
                                          Phase 6 (release — mechanical, no marketing push)
                                                              ↓
                                          [v8 — CAST Desktop bundle]    ← see research/cast-v8-master-plan.md
                                                              ↓
                                          Phase 6.6 marketing push (held until v8 ships)
```

- Phases 2 and 3 can run in parallel sessions (different files).
- Phase 4 must come after Phase 2 (CHEATSHEET + frontmatter must be clean before the inventory audit is meaningful).
- Phase 4.5 must come after Phase 4 (acts on Phase 4's audit + truncation baseline).
- Phase 4.6 can run after 4.5 or in parallel — different surface area (routines, not agents).
- Phase 6 must be last in the v7 sequence.
- v8 (desktop app) is a separate plan; marketing waits for v8 to ship.

## v8 — CAST Desktop (forward pointer)

v7 ships as a technical-depth release. v8 bundles Forge (Tauri terminal) + claude-code-dashboard + voice into a single OS app — the product story. Master plan in `research/cast-v8-master-plan.md`.

The "really cool when it's ready" anchor (Ed, 2026-05-09). v7 finishes; v8 is when CAST graduates from personal workshop to shippable product. The team-sharing / SaaS pivot is v9-and-beyond territory and depends on v8 landing first.

---

## Open GitHub Issues → Phase mapping

| Issue | Phase | Action |
|---|---|---|
| #4 — Stale CONTRIBUTING.md cross-reference | Phase 2.6 | Verify fix landed, close |
| #5 — BATS tests for cast-agent-color.sh | Phase 2.4 | Implement + close |
| #7 — --help for cast-validate.sh | Phase 2.3 | Implement + close |
| #8 — --help for cast-notify.sh | Phase 2.3 | Implement + close |
| #17 — 13 missing agents in CHEATSHEET | Phase 2.2 | Implement + close |
| #18 — BATS tests for cast-agent-color.sh (dup of #5) | Phase 1.5 | Close as duplicate |
| #19 — BATS for cast-budget-alert no-db | Phase 2.4 | Implement + close |
| #20 — --help for cast-validate.sh (dup of #7) | Phase 1.5 | Close as duplicate |
| #21 — --help for cast-notify.sh (dup of #8) | Phase 1.5 | Close as duplicate |
| #22 — Color entries for 13 missing agents | Phase 2.4 | Implement + close |
| #23 — Stale CONTRIBUTING.md (dup of #4) | Phase 1.5 | Close as duplicate |

---

*Plan written 2026-05-07. Supersedes cast-future-roadmap.md (file did not exist) and phases 7/8/9 from 2026-04-25-cast-roadmap-update.md.*
