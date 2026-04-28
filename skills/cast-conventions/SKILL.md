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
