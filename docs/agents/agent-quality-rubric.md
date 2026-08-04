# Agent Quality Rubric

Each agent is scored across 5 dimensions. A production-grade agent scores 4-5 on each.

## Dimensions

### 1. Role Clarity (1-5)
- 1: Vague description ("helps with X")
- 3: Clear role, no boundaries defined
- 5: Clear role + explicit "I do NOT do Y" boundary statements

### 2. Workflow Specificity (1-5)
- 1: No workflow, just principles
- 3: Ordered steps but steps are generic
- 5: Numbered workflow with concrete commands, file paths, and decision points

### 3. Output Format (1-5)
- 1: No specified output format
- 3: Output described in prose
- 5: Exact output template with example — copy-paste ready

### 4. Error Handling (1-5)
- 1: No mention of failure cases
- 3: Notes one failure case
- 5: Named failure modes with explicit fallback for each

### 5. Tool Discipline (1-5)
- 1: `tools: *` (wildcard — no restriction)
- 3: Tools listed but `disallowedTools` not used where appropriate
- 5: Minimal tool set; `disallowedTools` blocks writes for read-only agents

## Scoring Sheet — v3 baseline (13 agents scored)

| Agent | Model | Role | Workflow | Output | Error | Tools | Total | Notes |
|---|---|---|---|---|---|---|---|---|
| planner | sonnet | 5 | 5 | 5 | 4 | 5 | **24** | Battle-tested, exemplary |
| debugger | sonnet | 5 | 5 | 5 | 4 | 5 | **24** | Battle-tested, exemplary |
| code-reviewer | haiku | 5 | 4 | 5 | 3 | 5 | **22** | Haiku-optimized, efficient |
| security | sonnet | 5 | 5 | 5 | 4 | 4 | **23** | Comprehensive OWASP coverage |
| commit | haiku | 5 | 4 | 5 | 3 | 4 | **21** | Simple and effective |
| push | haiku | 4 | 4 | 4 | 3 | 4 | **19** | Safety checks, upstream detection |
| test-runner | haiku | 4 | 4 | 4 | 3 | 4 | **19** | Runs jest, vitest, bats |
| researcher | sonnet | 4 | 4 | 4 | 3 | 4 | **19** | Consolidated: explorer + data + db-reader |
| docs | haiku | 4 | 4 | 4 | 3 | 4 | **19** | Consolidated: readme + doc-updater + report |
| bash-specialist | haiku | 5 | 5 | 4 | 4 | 4 | **22** | Shell scripts and BATS tests |
| merge | haiku | 4 | 4 | 4 | 3 | 4 | **19** | Git merges, rebases, conflicts |
| morning-briefing | haiku | 4 | 4 | 4 | 4 | 4 | **20** | Daily git activity briefing |
| devops | haiku | 4 | 4 | 4 | 3 | 4 | **19** | CI/CD, Docker, infrastructure |

## Scoring Sheet — current-roster additions (13 agents scored)

Scored 2026-08-04 against the same 5 dimensions. Model and Tool Discipline are read from each agent's actual frontmatter (`tools:` / `disallowedTools:`). `db-reader` is scored against its **current** tool set — its `Write` grant was dropped in PR #353 (commit `da4d43d`), closing the file-write surface, though its SELECT-only SQL discipline remains a prompt-level contract (no PreToolUse guard enforces it).

| Agent | Model | Role | Workflow | Output | Error | Tools | Total | Notes |
|---|---|---|---|---|---|---|---|---|
| backend-writer | sonnet | 5 | 5 | 5 | 5 | 4 | **24** | Extensive failure-mode guards (hallucination, truncation, dispatch-at-depth) |
| frontend-writer | sonnet | 5 | 5 | 5 | 5 | 4 | **24** | Mirror of backend-writer; same guards |
| migration-reviewer | opus | 5 | 5 | 5 | 4 | 5 | **24** | Gold-standard tool discipline (`disallowedTools: [Write, Edit]`) |
| api-contract | haiku | 5 | 5 | 5 | 4 | 5 | **24** | Read-only guardian; breaking-change taxonomy + report template |
| dep-auditor | haiku | 5 | 5 | 5 | 4 | 5 | **24** | Per-ecosystem audit commands w/ graceful-degrade; `MAL-` hard gate |
| eval-writer | sonnet | 5 | 5 | 5 | 4 | 4 | **23** | Full YAML schema + canonical exemplar; `on_error` three-outcome model |
| frontend-qa | haiku | 5 | 4 | 5 | 4 | 5 | **23** | Read-only (`disallowedTools`); per-file template + screenshot fallback |
| email-drafter | haiku | 4 | 5 | 5 | 3 | 4 | **21** | Dual role (email + portfolio sync); numbered workflows, concrete MCP tool names |
| release-notes | haiku | 4 | 5 | 5 | 3 | 4 | **21** | Conventional-commit mapping + changelog template |
| db-reader | sonnet | 5 | 4 | 4 | 3 | 4 | **20** | Read-only by tool omission (Write dropped); SELECT-discipline still prompt-level |
| report-writer | haiku | 4 | 4 | 5 | 3 | 4 | **20** | Multiple report templates; "generate from code, never invent" |
| pr-reviewer | sonnet | 5 | 5 | 4 | 2 | 4 | **20** | Strong role/workflow; thin on failure-case handling |
| infra-writer | haiku | 4 | 3 | 4 | 3 | 4 | **18** | Thinnest def — responsibility list, not a numbered workflow; one failure case |

## Notes

- **v3 consolidation:** 42 agents reduced to a 15-agent v3 target (registry has since grown to 27). Former agents (data-scientist, doc-updater, readme-writer, refactor-cleaner, etc.) were folded into the specialists. Note: test-writer was NOT folded — it remains a standalone agent (`agents/core/test-writer.md`).
- **The baseline table is 13 rows, not 15.** The v3 target of 15 counted `orchestrator` (since removed — orchestration is now the `/orchestrate` skill run from the main session, not a dispatched agent) and `test-writer` (standalone, still unscored). The 13 baseline rows are the v3 agents that both survived and were scored.
- **Scoring carried forward** where the agent existed in v2. New/consolidated agents scored against their current definitions.
- **Roster coverage (2026-08-04):** 26 of the 27 current agents are now scored — the 13 baseline rows above plus the 13 current-roster additions. Only `test-writer` remains unscored.
- **Honest distribution — do NOT assert a blanket "all agents score 19+".** 25 of the 26 scored agents score ≥19. The sole exception is `infra-writer` at **18**: its definition is a responsibility list rather than a numbered workflow (Workflow = 3) and documents only one failure case (Error = 3). Closing the gap to ≥19 would mean giving it a numbered workflow with decision points and a second named failure-mode fallback.
