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

## Scoring Sheet (23 agents)

| Agent | Model | Role | Workflow | Output | Error | Tools | Total | Notes |
|---|---|---|---|---|---|---|---|---|
| planner | sonnet | 5 | 5 | 5 | 4 | 5 | **24** | Battle-tested, exemplary |
| debugger | sonnet | 5 | 5 | 5 | 4 | 5 | **24** | Battle-tested, exemplary |
| code-writer | sonnet | 5 | 5 | 4 | 4 | 4 | **22** | Self-dispatches code-reviewer + commit |
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

## Notes

- **v3 consolidation:** 42 agents reduced to 15 at the v3 consolidation point (registry has since grown to 23). Former agents (data-scientist, db-reader, doc-updater, readme-writer, refactor-cleaner, etc.) were folded into the specialists. Note: test-writer was NOT folded — it remains a standalone agent (`agents/core/test-writer.md`).
- **Scoring carried forward** where the agent existed in v2. New/consolidated agents scored based on their v3 definitions.
- **Scoring above covers the original 15-agent set.** The 8 additional agents (dev-workflow, productivity, knowledge/career tier) in the current 23-agent roster are unscored — re-score the full roster before asserting all agents score 19+. Orchestration is handled by the `/orchestrate` skill (main session), not a dispatched `orchestrator` agent.
