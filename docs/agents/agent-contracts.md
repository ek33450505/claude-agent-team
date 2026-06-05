# Agent Contracts — Structured Status Blocks

## Purpose

Every CAST agent ends its work with a Status block. Historically this was free-text, which created two problems:

1. **Fragile orchestration.** The `agent-status-reader.sh` hook parses raw JSON files written by agents — any structural variation causes silent failures or missed BLOCKED signals.
2. **No dashboard consumption.** The dashboard cannot query structured outcomes without a stable schema.

The agent-status schema (`schemas/agent-status.json`) formalizes the contract. Every agent now emits a JSON block alongside the human-readable Status line. Both coexist: humans read the text, machines read the JSON.

---

## Schema Reference

Source: [`schemas/agent-status.json`](../../schemas/agent-status.json)

Draft: JSON Schema 2020-12

---

## Field Reference

| Field | Type | Required | Notes |
|---|---|---|---|
| `status` | string enum | **Yes** | `DONE`, `DONE_WITH_CONCERNS`, `BLOCKED`, `NEEDS_CONTEXT` |
| `summary` | string | **Yes** | 1–300 chars. One-line description of outcome. |
| `agent` | string | **Yes** | Agent name, e.g. `code-writer`, `debugger`. |
| `concerns` | string[] | Conditional | Required (non-empty) when `status` is `DONE_WITH_CONCERNS`. |
| `blockers` | string[] | Conditional | Required (non-empty) when `status` is `BLOCKED`. |
| `context_needed` | string[] | Conditional | Required (non-empty) when `status` is `NEEDS_CONTEXT`. |
| `files_changed` | string[] | No | Absolute paths of created/modified files. |
| `next_actions` | string[] | No | Suggested follow-up steps for orchestrator or user. |
| `schema_version` | string | No | Must be `"1.0"` if present. |

---

## How Agents Should Emit Status

Agents continue to emit the human-readable Status block first. Immediately after, they emit a fenced JSON block that passes the validator.

### Pattern

```
Status: DONE
Summary: Implemented three new routes and wrote 12 tests.
Files changed: src/routes/auth.ts, src/routes/auth.test.ts
```

```json
{
  "status": "DONE",
  "summary": "Implemented three new routes and wrote 12 tests.",
  "agent": "code-writer",
  "files_changed": [
    "/Users/yourname/Projects/personal/my-project/src/routes/auth.ts",
    "/Users/yourname/Projects/personal/my-project/src/routes/auth.test.ts"
  ],
  "schema_version": "1.0"
}
```

The JSON block is the machine-readable contract. The human-readable block above it remains for readability.

---

## Example: Passing Status Block (code-writer)

```json
{
  "status": "DONE",
  "summary": "Added cast-validate-status.py with stdin/file input, --schema override, and structured error messages.",
  "agent": "code-writer",
  "files_changed": [
    "/Users/yourname/Projects/personal/claude-agent-team/schemas/agent-status.json",
    "/Users/yourname/Projects/personal/claude-agent-team/scripts/cast-validate-status.py",
    "/Users/yourname/Projects/personal/claude-agent-team/tests/cast-validate-status.bats",
    "/Users/yourname/Projects/personal/claude-agent-team/docs/agent-contracts.md"
  ],
  "next_actions": [
    "Dispatch code-reviewer to review all four new files",
    "Dispatch commit agent with semantic message"
  ],
  "schema_version": "1.0"
}
```

---

## Example: Failing Status Block (debugger — blocker hit)

```json
{
  "status": "BLOCKED",
  "summary": "Cannot resolve TypeScript compilation errors in auth module — missing @types/express.",
  "agent": "debugger",
  "blockers": [
    "TS2307: Cannot find module 'express' or its corresponding type declarations",
    "npm install @types/express failed with EACCES permission denied"
  ],
  "context_needed": [],
  "schema_version": "1.0"
}
```

---

## Validation

Run the validator against any status JSON:

```bash
# From stdin
echo '{"status":"DONE","summary":"ok","agent":"commit"}' | python3 scripts/cast-validate-status.py

# From file
python3 scripts/cast-validate-status.py /path/to/status.json

# With custom schema path
python3 scripts/cast-validate-status.py --schema schemas/agent-status.json /path/to/status.json
```

Exit 0 + `VALID` on success. Exit 1 + `INVALID: <reason>` on stderr on failure.

---

## Integration Points

**`agent-status-reader.sh` hook (current):** Reads JSON files from `$CAST_STATUS_DIR`. The validator can be wired into this hook to reject malformed status files before they are processed, preventing silent failures when a BLOCKED file has no `blockers` field.

**`/orchestrate` skill (planned):** Wave-level fan-out summaries will be derived from the `summary` fields of all agents in a wave. Reliable parsing requires this schema.

**Dashboard `/agents` page (planned):** The `concerns`, `blockers`, and `next_actions` arrays map directly to UI affordances — concern badges, blocker alerts, suggested next steps.

**Changelog generation (planned):** The `files_changed` array and `summary` field feed the `release-notes` agent with structured per-commit metadata, eliminating the need to parse free-text commit messages for file lists.
