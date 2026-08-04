# CAST Ecosystem GitHub Audit — 2026-05-09

**Audited by:** researcher agent  
**Repos checked:** 15 (ek33450505/*)  
**Data source:** GitHub API via `gh api repos/ek33450505/<repo>`

---

## Repo Summary Table

| Repo | Description | Topics | Discussions | Issues Open | Notes |
|------|-------------|--------|-------------|-------------|-------|
| [claude-agent-team](https://github.com/ek33450505/claude-agent-team) | Local-first OS layer for Claude Code. Specialist agents, semantic routing, policy gates, event sourcing, and zero cloud lock-in. | 15 topics | YES | 3 | Homepage set. Flagship repo. |
| [claude-code-dashboard](https://github.com/ek33450505/claude-code-dashboard) | Real-time observability UI for CAST. Sessions, agent analytics, hook health, memory browser, and SQLite explorer — all local, no cloud. | 16 topics | no | 2 (dupe) | Homepage URL missing. Issues #6 and #8 appear to be duplicates (same title). |
| [cast-hooks](https://github.com/ek33450505/cast-hooks) | 13 Claude Code hook scripts — observability, safety guards, and agent dispatch directives | 9 topics | no | 0 | Homepage missing. |
| [cast-dash](https://github.com/ek33450505/cast-dash) | Terminal UI dashboard for Claude Code — htop for CAST | 10 topics | no | 0 | Homepage missing. |
| [cast-claudes_journal](https://github.com/ek33450505/cast-claudes_journal) | Give Claude a journal — session continuity for Claude Code | 3 topics | no | 0 | THIN topics — only 3. Missing: `cast`, `ai-agents`, `developer-tools`. Homepage missing. |
| [cast-agents](https://github.com/ek33450505/cast-agents) | 17 specialist Claude Code agents — commit, debug, review, plan, and more | 7 topics | no | 0 | Homepage missing. |
| [cast-memory](https://github.com/ek33450505/cast-memory) | Persistent memory for Claude Code agents — FTS5 search, relevance scoring, shared pool, semantic embeddings, MCP server | 10 topics | no | 0 | Homepage missing. |
| [cast-observe](https://github.com/ek33450505/cast-observe) | Session-level observability for Claude Code — cost tracking, agent run history, token spend | 9 topics | no | 0 | Homepage URL set to empty string. |
| [cast-security](https://github.com/ek33450505/cast-security) | Security hooks and audit trail for Claude Code | 9 topics | no | 0 | Homepage missing. |
| [cast-parallel](https://github.com/ek33450505/cast-parallel) | Split CAST plan execution across parallel worktree sessions | 9 topics | no | 0 | Homepage missing. |
| [homebrew-cast](https://github.com/ek33450505/homebrew-cast) | Homebrew tap for CAST — Claude Agent Specialist Team | **0 topics** | no | 0 | **MISSING TOPICS.** Add: `homebrew`, `homebrew-tap`, `cast`, `claude-code`. |
| [homebrew-cast-dash](https://github.com/ek33450505/homebrew-cast-dash) | Homebrew tap for cast-dash | **0 topics** | no | 0 | **MISSING TOPICS.** Add: `homebrew`, `homebrew-tap`, `cast`, `claude-code`. |
| [homebrew-cast-hooks](https://github.com/ek33450505/homebrew-cast-hooks) | Homebrew tap for cast-hooks | **0 topics** | no | 0 | **MISSING TOPICS.** Add: `homebrew`, `homebrew-tap`, `cast`, `claude-code`. |
| [homebrew-claudes-journal](https://github.com/ek33450505/homebrew-claudes-journal) | Homebrew tap for Claude's Journal | **0 topics** | no | 0 | **MISSING TOPICS.** Add: `homebrew`, `homebrew-tap`, `cast`, `claude-code`. |
| [Edward_Kubiak](https://github.com/ek33450505/Edward_Kubiak) | Kubiak Portfolio | **0 topics** | no | 0 | **MISSING TOPICS.** Portfolio site — out of CAST ecosystem scope, but add: `portfolio`, `react`, `vite`. Homepage missing. |

---

## Repos with Discussions Enabled

Only one repo has GitHub Discussions enabled:

- **claude-agent-team** — Discussions ON. Two community-style issues (#40, #41) exist, suggesting discussion threads may be a better home for those.

All other 14 repos have Discussions disabled.

---

## Open Issues by Repo

### claude-agent-team (3 open)
| # | Title | Labels |
|---|-------|--------|
| 44 | cast-ci-monitor.sh: Python JSON string injection at lines 243,254 (medium) | bug, bash |
| 41 | What agents would you add to CAST? (community wishlist) | enhancement, help wanted |
| 40 | Share your favorite CAST hook pattern (community discussion) | enhancement, help wanted |

> **Note:** Issues #40 and #41 read like Discussions threads, not bug/feature issues. Consider moving to Discussions.

### claude-code-dashboard (2 open — apparent duplicates)
| # | Title | Labels |
|---|-------|--------|
| 8 | Add empty-state copy to the Sessions page when no data exists | documentation, help wanted, good first issue |
| 6 | Add empty-state copy to Sessions page when no data exists | documentation, help wanted, good first issue |

> **Note:** Issues #6 and #8 appear to be duplicates. Close one.

### All other repos: 0 open issues

---

## Flags and Action Items

| Priority | Repo | Issue |
|----------|------|-------|
| HIGH | claude-agent-team | Issue #44 (Python JSON injection bug) — open bug, needs fix |
| MED | claude-code-dashboard | Issues #6 + #8 are duplicates — close one |
| MED | homebrew-cast | Missing topics — 0 topics harms discoverability |
| MED | homebrew-cast-dash | Missing topics — 0 topics |
| MED | homebrew-cast-hooks | Missing topics — 0 topics |
| MED | homebrew-claudes-journal | Missing topics — 0 topics |
| MED | cast-claudes_journal | Only 3 topics — thin for discoverability |
| LOW | claude-code-dashboard | Homepage URL not set (empty string) |
| LOW | cast-observe | Homepage URL set to empty string |
| LOW | All cast-* and homebrew-* | No homepageUrl set — `https://castframework.dev` or per-repo links should be added |
| LOW | claude-agent-team | Issues #40 + #41 (wishlist/discussion) better suited as GitHub Discussions threads |
| LOW | Edward_Kubiak | 0 topics, no homepage — minor, out of ecosystem scope |

---

## Summary

- **All 15 repos are public** — no visibility issues.
- **All repos have Issues enabled** — consistent.
- **Only claude-agent-team has Discussions** — intentional for the flagship; others don't need it unless community traffic grows.
- **4 Homebrew taps have zero topics** — highest discoverability risk since tap users often search by `homebrew-tap` topic.
- **The flagship (claude-agent-team) has the strongest metadata** — description, 15 topics, homepage, discussions.
- **1 open bug** on claude-agent-team (#44, Python injection) is the only active actionable bug.

---

Sources:
- GitHub API: `gh api repos/ek33450505/<repo>` — verified live 2026-05-09
- GitHub Issues API: `gh issue list --repo ek33450505/<repo>` — verified live 2026-05-09
