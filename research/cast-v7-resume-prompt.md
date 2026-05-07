# CAST v7 — Session Resume Prompt

Paste this into a new Claude Code window to pick up exactly where we left off.

---

## Paste this:

```
We're building CAST v7.0.0 — a clean, audited, documented MVP release of the CAST multi-agent framework.

Context:
- Repo: ~/Projects/personal/claude-agent-team (on branch `main`)
- Phases 0–5 merged to main today (2026-05-07, PR #25, 672 BATS tests passing)
- Master plan is at: research/cast-v7-master-plan.md
- Read that file first — it has all 6 remaining phases, the open GitHub issue → phase mapping, and sequencing notes

What shipped in phases 0–5:
- Phase 0: Research + CI fixes
- Phase 1: Distribution + contributor journey
- Phase 2: Hallucination guard
- Phase 3: Memory pipeline (write/read/staleness)
- Phase 4: Agent contract testing (`cast test`)
- Phase 5: DX polish (`cast new-agent`, hook output compression)

What remains (v7 work):
- Phase 1: Pipeline friction (push agent fix, install.sh dirty guard, inline whitelist expansion, CAST_ALLOW_DIRTY_COMPACT, close duplicate issues #18/#20/#21/#23)
- Phase 2: Full repo + docs audit (README refresh, CHEATSHEET, --help flags for 2 scripts, BATS coverage gaps, docs freshness sweep)
- Phase 3: Token optimization (rules dedup ~35-40% reduction, prompt cache ordering, memory injection scoping, REC-09 cleanup)
- Phase 4: Agent inventory audit (dispatch frequency query, frontmatter drift, constrained cherry-pick ≤2 agents)
- Phase 5: Two-copy mirroring resolution (rules-core/ drift audit + CI check)
- Phase 6: v7.0.0 release (version bump, Homebrew formula update, cast-claudes_journal v0.2.0, portfolio sync)

Start with Phase 1 — run `/plan` with the Phase 1 section from research/cast-v7-master-plan.md as the task. Create branch `feature/cast-v7-phase-1-friction` first.

The goal for the session is to get through as many phases as possible and ship v7.0.0 to main.
```
