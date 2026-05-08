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

From `research/2026-05-07-token-optimization.md`. Hook output compression landed in Phase 5. Three items remain.

### 3.1 — Rules deduplication / agent-tier routing (HIGH IMPACT)
**Issue:** `~/.claude/rules/` injects ~7,500 tokens into every agent dispatch, including lightweight haiku agents (commit, push, merge) that only need CLAUDE.md + shell.md.  
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

### 6.4 — Portfolio sync
- `Edward_Kubiak` README: update CAST stats (agent count, test count, version, new Phase 5 features)
- `claude-code-dashboard` README: verify it references v7 once release is cut
- LinkedIn/GitHub bio: update version reference if present

### 6.5 — Final CI + health check
- `cast doctor` passes cleanly on a fresh install
- `bats tests/` green (≥672 tests)
- `cast test commit` runs against fixture without error
- All open PRs closed or merged
- No stale branches

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
Phase 1 (friction) → Phase 2 (docs) → Phase 3 (tokens) → Phase 4 (agents) → Phase 5 (mirror) → Phase 6 (release)
```

Phases 2 and 3 can run in parallel sessions (different files). Phase 4 must come after Phase 2 (CHEATSHEET + frontmatter must be clean before the inventory audit is meaningful). Phase 6 must be last.

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
