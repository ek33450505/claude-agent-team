---
name: cast-audit
description: Comprehensive CAST codebase audit — bugs, security, performance, test coverage. Dispatches parallel researchers to scan the codebase and collates findings into a dated report. Manual invocation only.
user-invocable: true
allowed-tools: [Agent, Read, Glob, Grep]
---

# CAST Audit Skill

## Overview

The `/cast-audit` skill automates the CAST codebase audit, surfacing accumulating drift and regressions before they compound. It dispatches parallel researchers, one per section (bugs/dead code, security, performance, test coverage), collates findings, and writes a report to `~/.claude/reports/cast-audit-YYYY-MM-DD.md`.

**Does NOT auto-fix.** This skill surfaces findings only. Remediation happens via follow-up agent dispatch (`debugger`, `security`, `test-writer`).

## Usage

### Manual invocation

```bash
/cast-audit
```

Runs full audit and writes report to `~/.claude/reports/cast-audit-YYYY-MM-DD.md`.

### Options

- `/cast-audit --since 2026-03-01` — Only flag regressions (increases, new findings) since the date. Compares against the most recent prior audit before that date.
- `/cast-audit --section security` — Run one section only (security, bugs, performance, or coverage). Output still goes to the full report.
- `/cast-audit --no-collate` — Run the parallel researchers but do NOT collate into a single report. Useful for debugging individual sections.

## Report Format

Each audit produces a collated report with this structure:

```
# CAST Audit — YYYY-MM-DD

## Executive Summary

- 🔴 HIGH: [top 1-2 findings by severity]
- 🟡 MED: [secondary findings]
- 🟢 LOW: [informational findings]

Comparison to prior audit (YYYY-MM-DD):
- +3 HIGH / -1 MED / +2 LOW severity

## Findings by Category

### Bugs & Dead Code

[Bulleted findings with severity tags, file paths, line numbers]

### Security

[Bulleted findings]

### Performance

[Bulleted findings]

### Test Coverage

[Bulleted findings]

## Recommended Actions

| Finding | Severity | Recommended Agent | Effort |
|---|---|---|---|
| ... | HIGH | debugger | ~30 min |

```

Example finding:
```
- 🔴 HIGH (SECURITY): `scripts/cast-session-end.sh:42` — SQL injection via unquoted SESSION_ID in sqlite3 insert. Use parameterization or add validation guard.
```

Each section report (written to `~/.claude/reports/cast-audit-YYYY-MM-DD-<section>.md`) contains raw findings for that category.

## Audit Scope per Section

### 1. Bugs & Dead Code

Scan for:
- Orphan scripts (referenced in `settings.json` but missing from `scripts/`)
- Orphan agent definitions (in `~/.claude/agents/` but not referenced anywhere)
- Orphan skills (in `~/.claude/skills/` but not wired)
- Unreachable code paths (dead conditionals, TODO/FIXME comments with no issue tracker)
- Cold imports (unused imports in Python scripts)
- Pattern regressions (new instances of 13-python-cold-start, etc.)

### 2. Security

Scan for:
- SQL injection patterns (env-var interpolation in sqlite3 without parameterization)
- Shell injection in hook scripts (unquoted variable expansion in backticks or $(...))
- Secrets leaking to config files (API keys, tokens, credentials in version-controlled files)
- File permissions issues (world-readable secrets, mismatched owner)
- Subagent write bypass (agents attempting to modify files outside their `owns_files` spec)
- Python eval/exec usage (dangerous dynamic code execution)

### 3. Performance

Scan for:
- Python cold-start counts per hook (inline `python3 -c` > 2 per script)
- Slow database queries (N+1 patterns, missing indices, unbounded result sets)
- Unbounded loops or recursive calls
- Hook execution time > 500ms (inferred from `~/.claude/logs/` if available)
- Large file reads into memory
- Repeated network calls without caching

### 4. Test Coverage

Scan for:
- BATS gaps — shell scripts in `scripts/` without corresponding `tests/<name>.bats`
- Vitest gaps — frontend React components in `src/components/` without `.test.tsx`
- TypeScript files without colocated tests
- Test files with zero assertions (stubs)
- Skipped tests (@test.skip, .only overrides)

## Implementation

When invoked, the main session:

1. **Dispatches researchers in parallel**, one per section, each limited to at most 4 of that section's checks (split a section into two dispatches when it has more), per the cast-conventions refusal trigger:
   ```
   Researcher 1 (bugs): Scan scripts/, agents/, skills/ for orphan, unreachable, and cold-start patterns
   Researcher 2 (security): Scan all code for SQL injection, shell injection, secrets, file perms
   Researcher 3 (performance): Scan for cold-starts, slow queries, unbounded work
   Researcher 4 (coverage): Compare test files against source files in scripts/, src/
   ```

2. **Each researcher writes findings to**:
   ```
   ~/.claude/reports/cast-audit-YYYY-MM-DD-bugs.md
   ~/.claude/reports/cast-audit-YYYY-MM-DD-security.md
   ~/.claude/reports/cast-audit-YYYY-MM-DD-performance.md
   ~/.claude/reports/cast-audit-YYYY-MM-DD-coverage.md
   ```

3. **Main session collates the section reports into**:
   ```
   ~/.claude/reports/cast-audit-YYYY-MM-DD.md
   ```
   With executive summary, side-by-side comparison to prior audit (if available), action items, and recommended agents.

4. **Idempotency**: Running `/cast-audit` twice on 2026-04-16 overwrites `cast-audit-2026-04-16.md` and the section files.

## Integration with CAST Ecosystem

- **Findings are diagnostic only** — remediation requires explicit follow-up dispatch of debugger, security, test-writer.
- **Report location** — Always `~/.claude/reports/cast-audit-YYYY-MM-DD.md`. Updated README documents this path.
- **Comparison logic** — If prior audit exists in `~/.claude/reports/cast-audit-YYYY-MM-*.md`, collation step compares finding counts by severity and flags regressions (e.g., "+3 HIGH since last month").
- **No auto-fix** — This is a discovery tool. Prevents "invisible" drift from accumulating.
