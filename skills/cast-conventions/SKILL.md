---
name: cast-conventions
description: Shared CAST conventions for all agents. Loaded automatically via agent frontmatter.
user-invocable: false
---

# CAST Agent Conventions

These conventions apply to every CAST agent. They are loaded automatically via the `skills: [cast-conventions]` frontmatter field.

## Agent Protocol

Every agent MUST follow this protocol:

1. **Start:** Emit a task_claimed event:
   ```bash
   source ~/.claude/scripts/cast-events.sh && cast_emit_event 'task_claimed' '<agent-name>' "${TASK_ID:-manual}" '' 'Starting'
   ```
2. **Memory:** Read `~/.claude/agent-memory-local/<agent-name>/MEMORY.md` before starting. Update when you discover reusable patterns.
3. **Context limit:** If running low on turns, finish current unit, write a Status block, list remaining work. Never exit without a Status block.
4. **End with Status:** One of `DONE` | `DONE_WITH_CONCERNS` | `BLOCKED` | `NEEDS_CONTEXT` — followed by one-line Summary and `## Work Log` bullets.

## Status Block Format

Every agent response MUST end with a structured Status block:

```
Status: DONE | DONE_WITH_CONCERNS | BLOCKED | NEEDS_CONTEXT
Summary: [one-line description of what was accomplished]
Files changed: [explicit list of modified files, if applicable]
Concerns: [required if DONE_WITH_CONCERNS]
Context needed: [required if NEEDS_CONTEXT]
```

## Key Principles

- **YAGNI:** Build only what was asked. No extra features or nice-to-haves.
- **DRY:** Find existing patterns before inventing new ones. Read similar files first.
- **Small units:** Each logical unit should be 15-30 minutes of work maximum.

## Commit Convention

- Never run `git commit` directly — always use the `commit` agent.
- Never use `--no-verify` or bypass hooks.

## Error Routing

- Route any error/failure to the `debugger` agent rather than inline triage.
- Agents that modify code (`test-writer`, `debugger`, `code-writer`) self-dispatch `code-reviewer` internally — do not double-dispatch from the main session.

## Code Review Requirement

- MANDATORY: Invoke `code-reviewer` (haiku) after every logical unit of changes.
- Do NOT proceed to the next logical unit until code-reviewer returns `Status: DONE` or `Status: DONE_WITH_CONCERNS`.

## Status File

Write a machine-readable status file at `~/.claude/agent-status/<agent-name>-<timestamp>.json` with keys: `agent`, `status`, `summary`, `concerns` (if DONE_WITH_CONCERNS), `timestamp` (format: `YYYY-MM-DDTHH:MM:SSZ`). Source `~/.claude/scripts/status-writer.sh` and call `cast_write_status` if available, otherwise write the JSON directly.

## Facts Emission

When you discover a stable, cross-agent-useful fact during your run, emit a `## Facts` block at the end of your response. This block is parsed by the SubagentStop hook and persisted to `agent_memories`.

**Format** — one fact per line, pipe-delimited:
```
## Facts
name: <slug-no-spaces> | type: <user|feedback|project|reference|procedural> | content: <text>
name: <slug-no-spaces> | type: <feedback> | content: <text> | description: <optional> | confidence: <0.0..1.0>
```

**When to emit:**
- Stable patterns discovered that other agents would benefit from knowing
- User preferences or constraints that recur across sessions
- Non-obvious project decisions with lasting impact

**When NOT to emit:**
- Ephemeral state (current task status, in-progress work)
- File paths or code snippets (read the file instead)
- Anything already in CLAUDE.md or agent memory files
- Session-only context that won't outlive this conversation

**Constraints:** Max 5 facts per run. `name` must be a slug (no whitespace, ≤80 chars). `content` is truncated to 500 chars by the parser. `type` must be one of the five enumerated values. Malformed lines are skipped silently.

## Response Budget

Keep your final response under **2,000 tokens** (300 for lightweight agents). Summarize findings rather than reproducing raw tool output. Write verbose results to disk and reference the file path instead.

## Output Discipline

Truncate all Bash command output to the last 50 lines using `| tail -50` unless the result is in the final lines. Never let raw command output fill your context.

## Truncation Prevention

The Response Budget exists to keep the prose tail intact through the model's output limit. These structural rules make the budget reachable.

**Findings format for audit/research dispatches:**
- Lead with a one-line headline per finding. One bullet per finding, no narration of the search path.
- Cap findings at the top N requested (default 5). If more exist, write the full list to disk at `~/.claude/reports/<agent>-<task>-full.md` and reference the path.
- "Top N findings, one bullet each" beats "I looked at X, then Y, then Z, and found..."

**Multi-target scope rule:**
- A single agent dispatched to audit/sync/review more than one repo is a truncation risk. Split into one dispatch per target.
- If you receive a multi-target prompt and the union of expected output exceeds your response budget, return `Status: NEEDS_CONTEXT` with: "Multi-target scope — request a separate dispatch per target."

**Reference, don't reproduce:**
- File contents → write a diff, not the new file body.
- Test output → counts + failing-test names, never the raw TAP stream.
- Search results → match counts + 3-5 representative hits, never the full grep.

## Destructive Path Discipline

Tests and scripts MUST NOT issue destructive operations (`rm -rf`, `git checkout -- <path>`, `git restore`, `git reset --hard`, file overwrites without backup) against tracked directories or files identified by repo-relative names from a non-isolated working directory.

**Rules:**
- Destructive operations in BATS tests are bound to `$BATS_TMPDIR`, `$BATS_TEST_TMPDIR`, or a `mktemp -d` directory the test itself created. Never to a path resolved against the test's cwd (which is usually the repo root).
- Before any `rm -rf "$DIR"`, assert that `$DIR` is under `$BATS_TMPDIR` or an equivalent isolated root: `[[ "$DIR" == "$BATS_TMPDIR"/* ]] || { echo "refusing to rm outside tmpdir: $DIR" >&2; return 1; }`.
- If a test needs to verify "the routines/ directory exists," it `stat`s the path read-only. It does NOT `rm` and recreate.
- Outside tests: agents do not run `git checkout`, `git restore`, `git reset`, `git clean`, or `rm -rf` against tracked paths to "clean up" state they didn't create. If the working tree is dirty in a way that blocks the task, report `Status: BLOCKED` with the blocker and let the orchestrator decide.

Why: a CAST routines deletion on 2026-05-11 traced to a BATS test that ran `rm -rf "routines"` from the repo root, deleting every tracked YAML in `routines/`. The destructive op had no isolation guard and no cwd assertion. Recovery was via `git checkout HEAD -- routines/`, but the pattern is the danger — the framework cannot catch every destructive sequence at lint time.

## Pre-existing Failure Evidence Rule

An agent MAY NOT classify a test failure as "pre-existing," "unrelated to my change," or "already broken" without producing baseline evidence.

**The contract:**
- Baseline evidence = running the same test command at the prior commit (`git stash && <run tests> && git stash pop`) and showing the same failures.
- Without baseline evidence, the only valid classifications are `BLOCKED` (the failure is real and you cannot resolve it) or `DONE_WITH_CONCERNS` (you fixed what you could, but flag the residual).
- "I assume these were already failing" is not a classification. It's a guess. Guesses are not valid in a Status block.

**Practical application:**
- test-runner: if the test framework reports failures, the Status is `BLOCKED` with the failing-test list. test-runner does not classify pre-existing.
- Sync/migration agents (anyone moving code between repos): if you encounter post-sync test failures, you MUST run baseline on the pre-sync commit before reporting pre-existing. If you can't or won't run baseline, the Status is `BLOCKED`.
- debugger: may dismiss a failure as pre-existing only after producing baseline evidence in the Work Log.

Why: a cast-hooks 17-script bulk-sync on 2026-05-11 reported 5 contract-test failures as "pre-existing failures unrelated to the sync." They were not — every failure was caused by the sync. The agent's confident classification cost ~40 minutes of triage before the revert. The structural fix is to refuse the classification absent evidence.
