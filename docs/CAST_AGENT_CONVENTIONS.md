# CAST Agent Conventions

Shared conventions for all CAST agent definitions. Read this before authoring or editing any agent in `agents/core/`.

---

## Status Block Placement: Status FIRST, Work Log SECOND

Every agent response MUST emit Status before the Work Log. This is a truncation-survival contract — Claude Code subagents have a hardcoded 32K output ceiling (upstream issue #25569). When an agent's output is long, truncation cuts from the bottom. If Status is at the bottom (after the Work Log), truncation eats it and the orchestrator loses routing signal.

### Correct ordering

```
Status: DONE | DONE_WITH_CONCERNS | BLOCKED | NEEDS_CONTEXT
Summary: One-line summary of what was accomplished.
Files changed: [list]
Concerns: [required if DONE_WITH_CONCERNS]

## Work Log

- Reads: [1-line summary of what was reviewed]
- Edits: [bullet per file, change in ≤1 sentence]
- Tests: [pass/fail count + framework]
- Decisions: [≤3 bullets on non-obvious choices]
```

### Wrong ordering (do not do this)

```
## Work Log
- Read: src/auth.ts (142 lines)
- Read: src/utils.ts (88 lines)
...many lines...

Status: DONE   ← GETS EATEN BY TRUNCATION
Summary: ...
```

### Rationale

- Truncation drops from the bottom of the output buffer.
- Status is the orchestrator's routing contract — without it, the next batch can't be dispatched.
- Work Log is diagnostic for humans; useful but non-blocking if truncated.
- All 23 core agent definitions enforce this order.

---

## Work Log Verbosity Budget

Keep Work Log sections to ~30 lines maximum. Templates:

| Field | Budget |
|---|---|
| Reads | 1-line summary total — not a per-file list |
| Edits | 1 bullet per file, ≤1 sentence per bullet |
| Tests | pass/fail count + framework name only |
| Decisions | ≤3 bullets, non-obvious choices only |

Verbose per-file enumeration (e.g., "src/auth.ts (142 lines)", "src/utils.ts (88 lines)") bloats output and accelerates truncation. Summarize instead.

---

## Model naming convention for haiku agents

> All haiku agents use `model: haiku` in frontmatter (bare form — 13 agents verified in `agents/core/`). When authoring or editing agent frontmatter, use `model: haiku` — never `haiku-3`, `claude-haiku-3`, or `claude-haiku-4-5`. If a fully-qualified string is required by the API, use `claude-haiku-4.5` (dotted, matching CLAUDE.md registry), but the bare `model: haiku` is the established repo convention.

Note: `thinking_budget:` frontmatter was removed in CAST v8 as dead code — Claude Code does not read this field. Use native `effort:` instead for compute control.

---

## Response Budget by Agent Class

| Agent class | Budget |
|---|---|
| Lightweight (haiku, review-only) | 300 tokens |
| Standard (haiku, code-generating) | 800 tokens |
| Heavy (sonnet, implementation/research) | 2,000 tokens |

---

## Status Values

| Value | When to use |
|---|---|
| `DONE` | Task complete, no concerns |
| `DONE_WITH_CONCERNS` | Task complete but reviewer should note issues |
| `BLOCKED` | Cannot proceed — missing info or hard failure |
| `NEEDS_CONTEXT` | Insufficient information to start — describe what's missing |

---

## Commit Convention

- Never run `git commit` directly — always use the `commit` agent.
- Never use `--no-verify` or bypass hooks.
- When code-writer returns `DONE`, a separate `commit` batch dispatches the commit agent.

---

## Code Review Requirement

- MANDATORY: Invoke `code-reviewer` (haiku) after every logical unit of changes.
- Do NOT proceed to the next logical unit until code-reviewer returns `Status: DONE` or `Status: DONE_WITH_CONCERNS`.
- Self-dispatch applies in direct-dispatch mode only. Plan-based dispatch delegates review to the orchestrator.
