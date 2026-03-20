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

## Scoring Sheet

| Agent | Role | Workflow | Output | Error | Tools | Total | Notes |
|---|---|---|---|---|---|---|---|
| planner | 5 | 5 | 5 | 4 | 5 | **24** | Battle-tested, exemplary |
| debugger | 5 | 5 | 5 | 4 | 5 | **24** | Battle-tested, exemplary |
| test-writer | 5 | 4 | 4 | 3 | 4 | **20** | Solid, minor output gaps |
| code-reviewer | 5 | 4 | 5 | 3 | 5 | **22** | Haiku-optimized, efficient |
| security | 5 | 5 | 5 | 4 | 4 | **23** | Comprehensive OWASP coverage |
| commit | 5 | 4 | 5 | 3 | 4 | **21** | Simple and effective |
| data-scientist | 4 | 4 | 4 | 3 | 4 | **19** | Good, could add error handling |
| db-reader | 5 | 4 | 4 | 3 | 5 | **21** | Read-only enforced well |
| architect | 5 | 4 | 4 | 3 | 4 | **20** | Good ADR workflow |
| tdd-guide | 5 | 5 | 4 | 3 | 4 | **21** | Strong red-green-refactor |
| qa-reviewer | 4 | 4 | 4 | 3 | 5 | **20** | Decent, read-only tools |
| morning-briefing | 4 | 4 | 4 | 4 | 4 | **20** | Cross-platform update pending |
| email-manager | 4 | 4 | 4 | 3 | 4 | **19** | macOS-dependent |
| researcher | 4 | 4 | 4 | 3 | 4 | **19** | Good comparison format |
| report-writer | 4 | 4 | 4 | 3 | 4 | **19** | Adequate |
| meeting-notes | 4 | 4 | 4 | 3 | 4 | **19** | Adequate |
| doc-updater | 4 | 3 | 3 | 2 | 4 | **16** | Needs output template |
| refactor-cleaner | 4 | 4 | 3 | 3 | 4 | **18** | Adequate |
| build-error-resolver | 4 | 4 | 4 | 3 | 4 | **19** | Haiku, minimal diffs |
| e2e-runner | 3 | 4 | 3 | 2 | 4 | **16** | Needs error handling, stack discovery |
| browser | 4 | 4 | 3 | 2 | 3 | **16** | Needs error handling, output format |
| presenter | 3 | 3 | 3 | 2 | 3 | **14** | Weakest — needs full hardening |

## Priority Fix Order (lowest score first)
1. **presenter** (14) — needs output location, error handling, non-goals, example
2. **browser** (16) — needs error handling, output format, write discipline
3. **e2e-runner** (16) — needs stack discovery, error handling, non-goals
4. doc-updater (16) — future pass
