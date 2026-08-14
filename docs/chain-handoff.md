# Chain Handoff Block — Specification

Every agent in a multi-agent chain MUST emit a `## Handoff` block in its response. This block is the machine-readable contract between sequential agents in an orchestrated chain.

## Format

```markdown
## Handoff
agent: <agent-name>
status: DONE
files_changed: scripts/foo.sh, scripts/bar.py
key_decisions: used FTS5 for retrieval, not embeddings
next_agent_needs: run bats tests/ to verify
blockers: none
```

## Required Fields

| Field | Values | Description |
|---|---|---|
| `files_changed` | comma-separated paths, or `none` | Every file the agent wrote, edited, or deleted |
| `status` | `DONE` \| `DONE_WITH_CONCERNS` \| `BLOCKED` \| `NEEDS_CONTEXT` | Mirrors the agent's Status line |
| `blockers` | text or `none` | Anything that must be resolved before the chain continues |

## Optional Fields

| Field | Description |
|---|---|
| `agent` | Which agent emitted this block |
| `key_decisions` | Non-obvious choices the next agent should know (max 3) |
| `next_agent_needs` | Specific commands or checks the downstream agent should run |
| Any other field | Anything else the next agent needs to know — free-form key: value |

## Placement

The `## Handoff` block MUST appear **before** `## Work Log` and **after** the final code/prose of the response.

```
[agent body]

## Handoff
...

## Work Log
...

Status: DONE
```

## Why key-value, not prose

LLM summarization introduces errors. When the orchestrator passes an agent's response summary to the next agent, paraphrasing changes meaning: "4 tests added, all passing" becomes "tests were added" — the count and pass/fail status are lost. Key-value pairs survive injection verbatim. The orchestrator extracts the `## Handoff` block using a regex match and prepends it to the next agent's prompt without any transformation.

This is the same reason structured formats outperform prose in chain-of-thought pipelines: **each field is a discrete, independently verifiable claim**.

## How the orchestrator uses it

After each agent completes in a wave, the orchestrator:

1. Extracts the `## Handoff` block from the agent's response using:
   ```
   ## Handoff\n([\s\S]+?)(?=\n## |\Z)
   ```
2. Prepends it verbatim to the next wave's agent prompts as:
   ```
   ## Context from previous agent
   [handoff block content]
   ```
3. The injected context appears at the TOP of the next agent's prompt, before the task description.

The orchestrator never paraphrases the Handoff block. It injects it word-for-word. The next agent reads structured facts, not a summary of facts.

## What happens if the block is missing

If the orchestrator does not find a `## Handoff` block in an agent's output:

1. It logs: `[WARN] No ## Handoff block found in <agent-name> output — using Work Log as fallback`
2. It extracts the `## Work Log` section instead (human-readable prose)
3. It prepends that under `## Context from previous agent (Work Log fallback)`

The Work Log fallback is lossy — prose summaries are more likely to lose specific details (file paths, test counts, exact error messages). Agents that omit `## Handoff` degrade chain reliability.

## Example — complete agent response

```markdown
The hook script has been updated with the new extraction step.

## Handoff
agent: code-writer
status: DONE
files_changed: scripts/cast-subagent-stop-hook.sh, tests/cast-subagent-stop-hook.bats
key_decisions: used awk for Handoff block extraction to avoid Python subprocess overhead
next_agent_needs: run bats tests/cast-subagent-stop-hook.bats to confirm new test cases pass
blockers: none

## Work Log
- Reads: existing SubagentStop hook (Step 2 db mirror pattern)
- Edits: cast-subagent-stop-hook.sh — added Handoff extraction after Step 2
- Edits: cast-subagent-stop-hook.bats — added 3 test cases for Handoff extraction
- code-reviewer result: DONE
- Tests: 3 new / 0 fail (bats)
- Decisions: awk over Python — no interpreter startup cost in the hook pipeline

Status: DONE
Summary: Added Handoff block extraction to SubagentStop hook — 2 files changed
Files changed: scripts/cast-subagent-stop-hook.sh, tests/cast-subagent-stop-hook.bats
```

## Enforcement

The `## Handoff` block is validated by `cast-subagent-stop-hook.sh` at **WARN level** (Step 2.4). Violations are logged to the `agent_protocol_violations` table in `cast.db` and emitted to stderr — the hook never blocks.

### Validation rules (Step 2.4)

| Condition | Violation logged |
|---|---|
| Block absent + agent was **chained** (`batch_id` present in SubagentStop payload) | `missing_handoff` |
| Block absent + agent was a **solo dispatch** (`batch_id` absent) | nothing — solo agents legitimately omit the block |
| Block present but unparseable / no `key: value` lines found | `invalid_handoff_format` |
| Block present + required field missing (`files_changed`, `status`, `blockers`) | `handoff_schema_violation` with `pattern=missing_field:<name>` |
| Block present + `status` value not in allowed set | `handoff_schema_violation` with `pattern=invalid_value:status=<value>` |

The typed schema that the validator mirrors is in `schemas/agent-handoff.json`. The runtime validator is `scripts/cast_handoff_parser.py` (importable as a module; also runnable as a CLI for smoke-testing).

### What is NOT enforced

- Agents that are exempt from the Status block contract (`STATUS_CONTRACT_EXEMPT=1` — Claude Code built-ins, workflow subagents) are also skipped by the Handoff validator.
- Optional fields (`agent`, `key_decisions`, `next_agent_needs`) are never flagged as violations.
- Content quality of field values is not checked — any non-empty string satisfies `files_changed` and `blockers`.

### Incident-record integration

The incident-record stage in `cast_subagent_stop.py` parses the Handoff block's `files_changed` field to populate `related_files` on incident records. Absent a Handoff block, that field is omitted from the incident record (unchanged from prior behavior).
