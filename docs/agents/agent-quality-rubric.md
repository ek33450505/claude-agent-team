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

## Scoring Sheet (CAST v3 — 15 agents)

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
| docs | sonnet | 4 | 4 | 4 | 3 | 4 | **19** | Consolidated: readme + doc-updater + report |
| bash-specialist | sonnet | 5 | 5 | 4 | 4 | 4 | **22** | Shell scripts and BATS tests |
| merge | sonnet | 4 | 4 | 4 | 3 | 4 | **19** | Git merges, rebases, conflicts |
| orchestrator | sonnet | 4 | 5 | 4 | 4 | 4 | **21** | Plan manifest execution |
| morning-briefing | sonnet | 4 | 4 | 4 | 4 | 4 | **20** | Daily git activity briefing |
| devops | sonnet | 4 | 4 | 4 | 3 | 4 | **19** | CI/CD, Docker, infrastructure |

## Notes

- **v3 consolidation:** 42 agents reduced to 15. Many former agents (test-writer, data-scientist, db-reader, doc-updater, readme-writer, refactor-cleaner, etc.) were folded into the 15 specialists.
- **Scoring carried forward** where the agent existed in v2. New/consolidated agents scored based on their v3 definitions.
- All agents score 19+ — no priority fixes needed.
