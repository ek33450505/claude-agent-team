# CAST Honesty / Anti-Hallucination Feature

**Date:** 2026-06-08  
**Trigger:** deep-research skill verification failure (PR #133) — verify phase bucketed *failed checks* as *refutations*, laundering its own timeout into false confidence.

## Problem: Why This Exists

On the night of 2026-06-08, the deep-research harness reported "all 25 claims refuted by adversarial verification — research inconclusive." False. The verifier subagents had each **failed to emit a verdict** (Anthropic service rate-limited them), and the harness logged *absence of a verdict* as a *refutation*. 

The principle: **a verification system that cannot distinguish "I checked and it's false" from "I failed to check" is worse than no verification — it launders its own failure into false confidence.**

Honesty about completion is now a first-class CAST concern: a false "done" breaks trust in every output and wastes real money on hallucinated evidence.

## What Already Exists: The Active Honesty Layer

Four real sensors write to `cast.db` on live hook events. **`cast doctor` reads all three active tables and derives the fourth check.** They are the foundation; this session surfaced them.

### Table 1: `agent_hallucinations`
- **Source:** `scripts/cast_claimed_work_verifier.py` (SubagentStop hook)
- **Signals:** An agent claimed to create a file (e.g., "wrote `~/path/to/results.json`") but the file does not exist after the subagent returned.
- **Current state:** Row writes work. Observability: live via `cast doctor` — surfaces "N agents hallucinated file creation" with per-agent breakdown.

### Table 2: `completeness_events`
- **Source:** `scripts/cast-response-completeness-hook.sh` (SubagentStop hook)
- **Signals:** Agent returned without a Status block (protocol violation) or output was truncated at the model's token limit.
- **Current state:** Row writes work. Observability: live via `cast doctor` — reads and flags truncation events with per-severity breakdown.

### Table 3: `agent_protocol_violations`
- **Source:** `scripts/cast-agent-protocol-check.sh` (SubagentStop hook)
- **Signals:** Agent prose says "dispatching agent X" but never actually called the dispatch tool. Prose-only dispatch claims with zero tool evidence.
- **Current state:** Row writes work. Observability: live via `cast doctor` — reads and flags protocol violations with per-agent breakdown.

### Check 4: `silent truncations` (maxTurns) — Derived, not a table
- **Source:** Derived from `agent_runs` table (no dedicated hook required)
- **Signals:** An agent_runs row remains stuck in `status='running'` for >2 hours (pre-reaper), or bears `status='abandoned'` with an `abandoned_at` timestamp in the last 7 days (reaped by the cast-abandon-stale-runs.py reaper). Indicates the agent hit the maxTurns cap and was stopped silently without emitting a Status block.
- **Current state:** Row reads work. Observability: live via `cast doctor` — detects and flags suspected maxTurns truncations with per-agent count.

### Table 4: `code_ref_checks` _(RETIRED — v9 Phase C U7b)_
- **Source:** _(removed in v9 S5)_ — the unwired `cast-code-ref-guard.sh` guard was purged as dead code (high false-positive rate: it extracted bare tokens like `foo()` and grepped `scripts/`+`bin/`, manufacturing false `NOT_FOUND` rows for legit external references).
- **Signals:** Agent claimed a function/file/path exists (e.g., "`foo()` in scripts/") but grep found nothing.
- **Current state:** **RETIRED in v9 Phase C U7b.** Table removed from canonical schema (`cast-db-init.sh`), honesty doctor surface, and `check-honesty-table.py` allowlist. No writer has ever existed in a wired hook; 0 rows at time of retirement. Physical DROP from live DB is a separate gated maintenance step.

### Key Finding (Shipped)

**All three active honesty tables are now read by `cast doctor`.** They write into a database that is actively queried and surfaced to the user. The honesty feature is **live and observable**. (The fourth sensor class — `code_ref_checks` — had no wired writer and was retired in v9 Phase C U7b.)

## Design Principle: Honest Degradation

The reference is deep-research's three-outcome verify: `confirmed` / `refuted` / **`unverified`**.

Encode it everywhere: **when a check cannot run, it must report that it couldn't — never emit a clean/green result.** If a doctor surface has no data for a table, it prints `INFO ... no rows`. Never `OK 0`. Otherwise the honesty feature commits the exact bug it is meant to catch.

Concretely: if `agent_hallucinations` is empty because the SubagentStop hook never fired (not because no hallucinations occurred), the doctor surface prints `INFO agent_hallucinations: 0 rows (hook may not have fired)`, not `OK 0 hallucinations detected`.

## Decision: What We Built

**Rank 1 — `cast doctor` honesty surface** (SHIPPED — PR #135, extended v9 Phase C)

A read-only block in `bin/cast _cmd_doctor` (lines 2330–2449) that aggregates the three active tables (`agent_hallucinations`, `completeness_events`, `agent_protocol_violations`) and derives the fourth check (silent truncations via agent_runs). Prints results with honest degradation. (`code_ref_checks` was retired in v9 Phase C U7b — writer never wired; 0 rows.)

- **Green (OK):** Table has 0 rows (or no qualifying rows in the 7-day window).
- **Orange (WARN):** Table has N rows in the last 7 days; lists affected agents + counts.
- **Blue (INFO):** Table is absent or hook status is unknown; admits the uncertainty.

**Status:** Activates all four checks with zero new failure surface (read-only queries, never a hook). Tested via `tests/cast-doctor-honesty.bats` on an isolated temp HOME. Shipped and live in current releases.

## Deferred: And Why (Honest About the Risk)

**Rank 2 — test-exit-code verifier** (DEFERRED, not this session)

Extend `cast_claimed_work_verifier.py` to flag when an agent's Status block says `DONE` or "tests pass" but its own emitted TAP shows `not ok` lines.

**Why deferred:** This is the **most false-positive-prone mechanism** we could build. Done wrong, it repeats the deep-research bug one level up — mistaking "couldn't parse the TAP" for "caught a hallucination." 

**Safe spec for when it IS built:** Flag **ONLY on positive contradiction** (both Status=DONE and emitted `not ok` present, in the same subagent output). **Never emit a row for missing/unparseable evidence** — absent data is unverified, not a violation. Reference `agents/core/test-runner.md` for the emitted count/status format.

**Risk tolerance:** A false-positive accusation erodes trust as fast as a false "done." Agents flagged for honest work learn to ignore the guard, which defeats the entire feature.

---

**Rank 3 — `cast-code-ref-guard.sh` wiring** (REMOVED v9 S5; TABLE RETIRED v9 Phase C U7b)

The script was never wired to any hook (high cry-wolf risk: it extracted bare tokens like `foo()` and grepped `scripts/`+`bin/`, manufacturing false `NOT_FOUND` rows for legit external references). It was purged as dead code in the v9 S5 sweep rather than wired. The `code_ref_checks` table (always 0 rows) was subsequently retired from the canonical schema in v9 Phase C U7b — removed from `cast-db-init.sh`, the honesty doctor surface, and `check-honesty-table.py`. Physical DROP from the live DB is a separate gated maintenance step.

---

**Rank 4 — Evidence-bearing completion** (DEFERRED, soft convention first)

Make "done requires attached evidence (command + exit code / diff)" a **soft convention** in `rules-core/working-conventions.md` first. Observe via the doctor surface. Do NOT build it as a blocking hook now — mass false-positives across researchers/planners that legitimately do evidence-free work (recommendations, analysis) would flood the table and erode trust.

Revisit after three weeks of Rank 1 data.

## Pushback on the Original Task List (Honest, Not Compliance)

### (a) "Honest degradation" is a principle, not an open-ended audit task

The task asked for a design that "captures a design discussion + decisions so the rationale isn't lost." Honesty / anti-hallucination is not a discrete feature to ship — it is an **operating principle** that shapes every control we build. The increment this session is Rank 1: surface the principle in one place, using the four tables that already exist.

### (b) "Verify-before-relay" is half-built; the unbuilt half is the dangerous Rank 2

File-existence checking (`agent_hallucinations`) is done. The unbuilt half is test-verdict validation (Rank 2), which is the most likely to produce false positives. Separate them so we can ship file-check observability before court-case-grade test validation.

### (c) The signal already exists; the increment is surface, not a new event type

`agent_hallucinations` exists (writes happen via SubagentStop hook). We are not inventing a new table. We are reading it.

### (d) "Collaboration ethos / pushback as default" is a values change for agent system prompts, not a control

A separate item on the original task list was "encode agent culture: pushback over compliance; honesty over false completion." That is important — but it is a **system-prompt and memory convention**, not an anti-hallucination control. It belongs in `agents/core/<agent>.md` system-prompt-frontmatter sections, not in this doc. Keep them separate so controls remain testable.

## Trust Economics (One Paragraph)

False positives erode trust as fast as false "done": an agent flagged for honest work teaches the maintainer to ignore the guard. That is why we ship Rank 1 (whose worst failure is *displaying a number*) before Rank 2/code-ref-guard (whose worst failure is *accusing an honest agent of hallucinating*). The ordering reflects a hard lesson: honesty systems can lie about the data *they read*, not just the work they verify. Build the safe reads first. Court-grade verdict systems come later, if at all.

---

## Related Memories & Decisions

- `[[project_deep_research_skill_home]]` — The bug that triggered this discussion; "verify failures under load were bucketed as refutations."
- `[[feedback_honesty_over_false_completion]]` — User commitment: never report work done/passing/verified unless it actually is. False completion breaks trust in ALL outputs.
- `[[feedback_use_docker_to_verify_tests]]` — Corollary: when claiming tests pass, attach evidence from an isolated run, not a guess.
- `[[project_cast_db_endpoint_audit]]` — Prior audit that found the four tables existed (Phase 2, PR #113).

---

**Status:** Shipped. Rank 1 implemented and live (PR #135, extended v9 Phase C, `cast doctor` §13 active).
