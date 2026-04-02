# CAST Agent Protocol Specification

**Version:** 2.1.0
**Status:** Active
**Last Updated:** 2026-04-01

---

## Overview

CAST (Claude Agent Specialist Team) defines a protocol for multi-agent Claude Code systems. A CAST-compatible system routes user prompts to specialist agents, enforces quality gates, and propagates structured status signals across agent boundaries — all without requiring the user to manually orchestrate each step.

This specification covers the five protocol layers that make CAST agents interoperable:

1. **Status Blocks** — structured output format every agent must emit
2. **Escape Hatches** — env-var guards that allow trusted bypasses of hook enforcement
3. **Agent Dispatch Manifests** — declarative batch execution plans embedded in plan files
4. **Dispatch Directives** — hook-injected instructions Claude must obey
5. **Hook Event Model** — stdin/stdout contract for UserPromptSubmit, PreToolUse, PostToolUse

Supporting infrastructure documented separately:

6. **Shared Task Board** — cross-agent progress tracking at `~/.claude/task-board.json`
7. **Fan-out Dispatch** — parallel multi-agent execution patterns

---

## Section 1 — Status Block Format

Every CAST agent MUST output a Status block as the final content of its response. The Status block is the machine-readable contract between an agent and the session that dispatched it. It drives automatic routing, review triggers, and halt conditions.

### 1.1 Text Format (human-readable, always required)

The text format appears at the end of the agent's Markdown response. It MUST use the exact field names shown below. Field order is fixed within each status variant.

#### DONE

Used when the agent completed its task with no issues warranting follow-up.

```
Status: DONE
Summary: [one sentence describing what was accomplished]
```

Required fields: `Status`, `Summary`
Optional fields: none

#### DONE_WITH_CONCERNS

Used when the agent completed its task but identified issues that may need follow-up. This status triggers automatic `code-reviewer` dispatch via the `agent-status-reader.sh` PostToolUse hook.

```
Status: DONE_WITH_CONCERNS
Summary: [one sentence describing what was accomplished]
Concerns: [specific issues found — file/line references where possible]
Recommended agents:
  - <agent-name>: [specific reason referencing file/line]
  - <agent-name>: [specific reason referencing file/line]
```

Required fields: `Status`, `Summary`, `Concerns`
Optional fields: `Recommended agents` — include only when actionable follow-up is warranted

The `Recommended agents:` subsection lists the exact agent names (matching entries in the agent registry) and a specific reason for each. The orchestrator or main session decides whether to dispatch — the recommending agent MUST NOT auto-dispatch. See Section 1.3 for how `Recommended agents` are processed.

#### BLOCKED

Used when the agent cannot complete its task due to an unresolvable dependency, missing file, ambiguous requirement, or tool failure. A BLOCKED status causes `agent-status-reader.sh` to emit a `[CAST-HALT]` directive and exit with code 2, hard-blocking the parent session.

```
Status: BLOCKED
Summary: [one sentence describing what was attempted]
Blocker: [precise description of what is missing or failed — be specific enough to resolve]
```

Required fields: `Status`, `Summary`, `Blocker`
Optional fields: none

A BLOCKED agent MUST NOT silently fail or partially complete work. It MUST roll back any partial changes before emitting BLOCKED, or explicitly list changes made so the operator can clean up.

#### NEEDS_CONTEXT

Used when the agent needs additional information from the user or calling context before it can proceed. Unlike BLOCKED, the agent has not attempted the work — it paused to request clarification.

```
Status: NEEDS_CONTEXT
Summary: [one sentence describing what was attempted]
Missing: [specific questions or data needed to proceed]
```

Required fields: `Status`, `Summary`, `Missing`
Optional fields: none

The orchestrator handles NEEDS_CONTEXT by pausing batch execution, surfacing the `Missing` field to the user, and re-dispatching the same agent with the updated context prepended to its prompt.

### 1.2 JSON File Format (machine-readable, required for code-modifying agents)

Agents that modify code MUST also write a JSON status file via `cast_write_status` (sourced from `~/.claude/scripts/status-writer.sh`). Agents that only read or report MAY skip this.

**File path:** `~/.claude/agent-status/<agent-name>-<timestamp>.json`

**Timestamp format:** `YYYYMMDDTHHMMSSz` (UTC, e.g., `20260324T153042Z`)

**Schema:**

```json
{
  "agent": "string — agent name matching its frontmatter name field",
  "status": "DONE | DONE_WITH_CONCERNS | BLOCKED | NEEDS_CONTEXT",
  "summary": "string — mirrors the text Status Block Summary field",
  "concerns": "string | null — mirrors Concerns field; null when not applicable",
  "recommended_agents": "string | null — mirrors Recommended agents as comma-separated list or null",
  "timestamp": "string — YYYYMMDDTHHMMSSz UTC"
}
```

**Writing the file (bash helper):**

```bash
source ~/.claude/scripts/status-writer.sh
cast_write_status "DONE" "Implemented auth module" "code-writer" "" ""
cast_write_status "DONE_WITH_CONCERNS" "Implemented auth module" "code-writer" \
  "dead code remains in src/utils.js lines 45-67" "code-reviewer"
cast_write_status "BLOCKED" "Could not complete implementation" "code-writer" \
  "Missing test coverage — cannot verify behavior preservation" ""
```

**How `agent-status-reader.sh` processes the file:**

The `agent-status-reader.sh` PostToolUse hook runs inside subagent context (`CLAUDE_SUBPROCESS=1`). It locates the latest JSON file in `~/.claude/agent-status/` by lexicographic sort of filenames (which encode UTC timestamp). It then:

| Status | Hook action | Exit code |
|---|---|---|
| `DONE` | Exit silently | 0 |
| `DONE_WITH_CONCERNS` | Output `[CAST-REVIEW]` directive via `hookSpecificOutput` | 0 |
| `BLOCKED` | Output `[CAST-HALT]` directive and block message | 2 |
| `NEEDS_CONTEXT` | Exit silently (orchestrator reads text block) | 0 |
| File missing | Exit silently | 0 |

Path canonicalization: before reading any status file, `agent-status-reader.sh` calls `realpath` and verifies the result starts with `$HOME/`. Files outside `$HOME` are silently skipped.

### 1.3 code-reviewer Recommendations

When `code-reviewer` emits `DONE_WITH_CONCERNS`, the `Recommended agents:` subsection lists follow-up agents. Format:

```
Recommended agents:
  - code-writer: dead code in src/utils.js lines 45-67
  - security: potential auth bypass in src/auth/login.js line 112
  - docs: public API signature changed in src/api/routes.js
```

Rules:
- Each entry names one agent from the CAST registry
- Reason MUST reference a specific file and line number where possible
- `code-reviewer` MUST NOT dispatch these agents — it only recommends
- The main session or orchestrator reads the `Recommended agents:` section and decides whether to dispatch
- `code-reviewer` MUST NOT recommend another `code-reviewer` — this creates infinite loops
- Maximum 3 recommended agents per review pass

---

## Section 2 — Escape Hatch Pattern

The CAST PreToolUse hook (`pre-tool-guard.sh`) hard-blocks certain Bash operations that must go through designated agents. Escape hatches allow trusted contexts (such as agent internals) to bypass these blocks.

### 2.1 Defined Escape Hatches

| Escape hatch | Unblocked operation | Who uses it |
|---|---|---|
| `CAST_COMMIT_AGENT=1` | `git commit` | `commit` agent exclusively |
| `CAST_PUSH_OK=1` | `git push` | Post-review push workflows |

### 2.2 Syntax Requirements

The escape hatch MUST appear as a **leading environment variable assignment** immediately before the git command on the same command string. No other tokens may precede it.

**Valid:**
```bash
CAST_COMMIT_AGENT=1 git commit -m "feat(auth): add token refresh"
CAST_PUSH_OK=1 git push origin main
```

**Invalid — blocked:**
```bash
git commit -m "CAST_COMMIT_AGENT=1"          # message injection
echo "CAST_COMMIT_AGENT=1" && git commit     # chained echo
export CAST_COMMIT_AGENT=1; git commit       # separate export statement
```

### 2.3 Security Model

The hook uses the regex `^CAST_COMMIT_AGENT=1[[:space:]]+git[[:space:]]+commit` anchored at position 0 of the full command string. The anchor at `^` is not a performance optimization — it is the security boundary. A check using `grep -q "CAST_COMMIT_AGENT=1"` anywhere in the command would allow message injection attacks (e.g., a commit message that contains the bypass string to trick a future audit).

The same positional-anchor model applies to `CAST_PUSH_OK=1`.

### 2.4 Adding New Escape Hatches

To add a new escape hatch for a blocked operation:

1. Define the env var name in the format `CAST_<OPERATION>_<ACTOR>=1`
2. Add an allow-block in `pre-tool-guard.sh` anchored at `^` before the corresponding block rule
3. Document it in this table (Section 2.1)
4. The escape hatch MUST only be used by the designated agent — document that constraint in the agent's definition

Exit code semantics: exit 0 = allow, exit 2 = hard-block. Never use exit 1 in pre-tool-guard.sh.

---

## Section 3 — Agent Dispatch Manifest Format

An Agent Dispatch Manifest is a declarative execution plan embedded in a plan `.md` file under `~/.claude/plans/`. It tells the `orchestrator` agent which specialist agents to run, in what order, and whether they can run in parallel.

### 3.1 Location and Detection

A manifest lives inside a `## Agent Dispatch Manifest` section in a plan file. The manifest itself is a fenced code block tagged `json dispatch`:

````markdown
## Agent Dispatch Manifest

```json dispatch
{ ... }
```
````

When `post-tool-hook.sh` sees a `Write` tool call to a `.md` file under a `/plans/` path that contains a `json dispatch` block, it injects a `[CAST-ORCHESTRATE]` directive telling Claude to dispatch the `orchestrator` agent.

### 3.2 Full Field Reference

```json
{
  "batches": [
    {
      "id": 1,
      "description": "Human-readable label shown in the dispatch queue",
      "parallel": true,
      "type": "fan-out",
      "agents": [
        {
          "subagent_type": "planner",
          "prompt": "Create a detailed implementation plan for X. Plan file: ~/.claude/plans/2026-03-24-X.md"
        },
        {
          "subagent_type": "security",
          "prompt": "Audit the security surface of X before implementation."
        }
      ]
    },
    {
      "id": 2,
      "description": "Implementation",
      "parallel": false,
      "agents": [
        {
          "subagent_type": "main",
          "prompt": "Implement X per the plan at ~/.claude/plans/2026-03-24-X.md"
        }
      ]
    },
    {
      "id": 3,
      "description": "Quality gates",
      "parallel": true,
      "agents": [
        {
          "subagent_type": "code-reviewer",
          "prompt": "Review the changes just made for X"
        },
        {
          "subagent_type": "test-runner",
          "prompt": "Run tests to verify the new logic added in X"
        }
      ]
    },
    {
      "id": 4,
      "description": "Commit",
      "parallel": false,
      "agents": [
        {
          "subagent_type": "commit",
          "prompt": "Create a semantic commit for the completed X work."
        }
      ]
    }
  ]
}
```

### 3.3 Field Definitions

| Field | Type | Required | Description |
|---|---|---|---|
| `batches` | array | yes | Ordered list of execution batches |
| `id` | integer | yes | Monotonically increasing batch number; used in task board keys |
| `description` | string | yes | Human-readable label for the dispatch queue display |
| `parallel` | boolean | yes | `true` = dispatch all agents in batch simultaneously; `false` = dispatch one agent, wait for completion |
| `type` | string | no | `"fan-out"` enables Fan-out Dispatch behavior (see Section 7); `"sequential"` is the default when omitted |
| `agents` | array | yes | One or more agent dispatch entries |
| `subagent_type` | string | yes | Name of the agent to dispatch, matching the `name` field in the agent's frontmatter; or `"main"` for orchestrator self-execution |
| `prompt` | string | yes | Task description passed to the agent; MUST be specific and include relevant context (feature name, file paths, plan path) |

### 3.4 `"parallel": true` Fan-out Behavior

When `"parallel": true`, the orchestrator dispatches all agents in the batch in a single response using simultaneous Agent tool calls. Agents in a parallel batch MUST NOT depend on each other's outputs. Maximum 4 agents per parallel batch.

### 3.5 `"type": "sequential"` vs `"type": "fan-out"`

- `"type": "sequential"` (default): agents run one at a time regardless of `parallel` flag; the `parallel` flag takes precedence if set to `true`
- `"type": "fan-out"`: all agents dispatch simultaneously AND the orchestrator synthesizes their outputs before passing context to the next batch (see Section 7)

### 3.6 `"subagent_type": "main"` Semantics

When `subagent_type` is `"main"`, the orchestrator does not spawn a subagent via the Agent tool. Instead, the orchestrator (or main Claude session) executes the implementation instructions directly. This is used for batches where the work cannot be effectively delegated, such as complex multi-file implementation steps that require the full reasoning context of the session.

### 3.7 Retry Protocol

When a batch returns `Status: BLOCKED`, the orchestrator applies the following retry protocol:

1. Log the BLOCKED status to the task board with the blocker description
2. Re-dispatch the same batch a second time, prepending: `"Previous attempt BLOCKED: <blocker>. Resolve and retry."` to the agent prompt
3. If the second attempt also returns BLOCKED: re-dispatch one final time with the full accumulated context from both prior attempts
4. If the third attempt returns BLOCKED: halt execution and surface to the user: `"Batch <id> blocked after 3 attempts. Human intervention required. Blocker: <blocker>"` — do not proceed to subsequent batches
5. If any retry succeeds (DONE or DONE_WITH_CONCERNS): resume normal execution from the next batch

Maximum retries: 3 total attempts (1 original + 2 retries). The retry limit exists to prevent runaway loops in cases where the blocker is systemic.

### 3.8 Minimum Valid Manifest

The minimum CAST-compatible manifest is:

```json
{
  "batches": [
    {"id": 1, "description": "Implementation", "parallel": false, "agents": [{"subagent_type": "main", "prompt": "..."}]},
    {"id": 2, "description": "Review", "parallel": false, "agents": [{"subagent_type": "code-reviewer", "prompt": "..."}]},
    {"id": 3, "description": "Commit", "parallel": false, "agents": [{"subagent_type": "commit", "prompt": "..."}]}
  ]
}
```

---

## Section 4 — Dispatch Directive Protocol

Dispatch directives are injected into Claude's context by hook scripts via `hookSpecificOutput`. They are MANDATORY instructions — not suggestions. Claude MUST act on them immediately.

### 4.1 `[CAST-DISPATCH]`

**Format injected by hook:**
```
[CAST-DISPATCH] Route: <agent> (confidence: hard|soft)
MANDATORY|RECOMMENDED: Dispatch the `<agent>` agent via the Agent tool (model: <model>).
Pass the user's full prompt as the agent task. Do NOT handle this inline.
```

**Trigger:** In CAST v3, `[CAST-DISPATCH]` is no longer injected by a hook. The model reads the dispatch table in `CLAUDE.md` and dispatches agents directly via the Agent tool. This directive is documented here for protocol reference but is now handled by model-driven dispatch rather than hook injection.

**What Claude must do:** Dispatch the named agent via the Agent tool immediately. Do not answer the user's question inline. Do not ask for confirmation when confidence is `hard`.

**Confidence levels:**
- `hard` — dispatch is MANDATORY; Claude may not handle inline
- `soft` — dispatch is RECOMMENDED; Claude may use judgment but should prefer the agent

**Consequences if ignored:** The work bypasses the specialist agent's quality checks, producing lower-quality output and breaking chain/review guarantees.

### 4.2 `[CAST-REVIEW]`

**Format injected by hook:**
```
[CAST-REVIEW] Code was modified. After completing your current logical unit of changes,
dispatch `code-reviewer` agent (haiku) to review. Do not skip this step.
```

**Trigger:** `post-tool-hook.sh` (PostToolUse hook) fires after any Write or Edit tool call in the main session

**What Claude must do:** After completing the current logical unit of changes (not after every single file edit), dispatch `code-reviewer` (haiku model) via the Agent tool.

**CLAUDE_SUBPROCESS guard:** This directive is only injected in the main session (`CLAUDE_SUBPROCESS != 1`). Subagents do not receive it — they have their own internal review logic or report status to the main session.

**Agents that self-dispatch code-reviewer:** `code-writer` and `debugger` self-dispatch `code-reviewer` internally. The main session MUST NOT re-dispatch `code-reviewer` after these agents complete — the review already happened internally.

### 4.3 `[CAST-CHAIN]`

**Format injected by hook:**
```
[CAST-CHAIN] After <agent> completes: dispatch `agent-a` -> `agent-b` in sequence.
```

**Trigger:** In CAST v3, post-chain behavior is defined in `CLAUDE.md` (not injected by hooks). After code-writer or debugger completes: `code-reviewer → commit → push`. The model reads this protocol and dispatches accordingly.

**What Claude must do:** After the primary agent's task is complete, dispatch the listed agents in order. Do not ask for confirmation. Each agent in the chain receives the output of the previous agent as context.

**Consequences if ignored:** Quality gates (code-reviewer) and commit steps (commit agent) are skipped, leaving code unreviewed and uncommitted.

### 4.4 `[CAST-ORCHESTRATE]`

**Format injected by hook:**
```
[CAST-ORCHESTRATE] Plan file at <path> contains an Agent Dispatch Manifest.
Dispatch the `orchestrator` agent via the Agent tool with this plan file path.
Present the queue to the user for approval before executing any batches.
```

**Trigger:** `post-tool-hook.sh` detects a `json dispatch` block in a newly written `.md` file under a `/plans/` path

**What Claude must do:** Dispatch the `orchestrator` agent with the plan file path. The orchestrator presents the queue to the user for approval before executing any batches. Do not execute the manifest directly.

### 4.5 `[CAST-HALT]`

**Format injected by hook:**
```
**[CAST-HALT]** Agent `<agent>` is BLOCKED and cannot proceed.
Summary: <summary>
Concerns: <concerns>
Resolve the blocker before continuing. Do not retry the blocked operation.
```

**Trigger:** `agent-status-reader.sh` reads a status JSON file with `"status": "BLOCKED"` and exits with code 2

**What Claude must do:** Surface the blocker description to the user immediately. Do not retry the blocked operation. Do not proceed to any subsequent steps. Wait for the user to resolve the blocker or provide missing context.

**Exit code 2 semantics:** Claude Code treats exit 2 from a hook as a hard block — Claude cannot proceed with the current operation. This is the only CAST directive enforced at the tool level rather than the instruction level.

---

### 4.6 `[CAST-DISPATCH-GROUP]`

> **Historical (CAST v2):** This directive was removed in CAST v3. Agent groups and the routing table were eliminated in favor of model-driven dispatch.

`[CAST-DISPATCH-GROUP]` is injected by `route.sh` when the user's prompt matches a pattern in `~/.claude/config/agent-groups.json`. It instructs Claude to dispatch the `orchestrator` agent with the matched group's wave plan rather than routing to a single agent. The group payload — including `group_id`, `description`, `waves`, and optional `post_chain` — is written to a temporary JSON file whose path is embedded in the directive. Claude must pass this file path to the orchestrator as task context and must not attempt to execute the waves inline. Wave-based dispatch follows the same fan-out semantics defined in Section 3.4, with agents in each wave running in parallel before the next wave begins.

---

## Section 5 — Hook Event Model

CAST uses three Claude Code hook events. Each hook script reads a JSON payload from stdin and outputs either nothing (allow silently) or a JSON response to stdout.

### 5.1 Hook Overview

| Event | Hook script | Fires when |
|---|---|---|
| `PreToolUse:Bash` | `pre-tool-guard.sh` | Claude is about to run a bash command |
| `PostToolUse:Write\|Edit` | `post-tool-hook.sh` | Claude just wrote or edited a file |
| `PostToolUse:Agent` | `cast-cost-tracker.sh` | Claude just dispatched an agent |
| `Stop` | `cast-session-end.sh` | Session ends |

### 5.2 `UserPromptSubmit` — `route.sh`

> **Historical (CAST v2):** The `UserPromptSubmit` hook (`route.sh`) was removed in CAST v3. Dispatch is now model-driven — the model reads the CLAUDE.md dispatch table and decides which agent to call. This section is preserved for protocol documentation.

**Stdin JSON schema:**
```json
{
  "prompt": "string — the user's raw input",
  "session_id": "string — current session identifier"
}
```

**Processing:** Extracts and lowercases the prompt. Skips if `CLAUDE_SUBPROCESS=1`. Matches against `~/.claude/config/routing-table.json` using regex patterns. Patterns longer than 200 characters are skipped (ReDoS prevention).

**Stdout on match:**
```json
{
  "hookSpecificOutput": {
    "hookEventName": "UserPromptSubmit",
    "additionalContext": "[CAST-DISPATCH] Route: <agent> ..."
  }
}
```

**Stdout on no match:** empty (no output)

**Exit codes:**
- `0` — allow prompt to proceed (with or without injected context)
- `1` — warn (shown to Claude as context, but Claude can proceed)
- `2` — hard-block (Claude cannot proceed; not used by route.sh)

**Observability:** Every match and non-match is logged to `~/.claude/routing-log.jsonl`. Log is rotated at 5MB, keeping up to 2 rotated copies.

**CLAUDE_SUBPROCESS guard:** `route.sh` exits 0 immediately when `CLAUDE_SUBPROCESS=1`. Subagent prompts MUST NOT trigger re-routing — they are focused work delegations, not new user requests.

### 5.3 `PreToolUse` — `pre-tool-guard.sh`

**Stdin JSON schema:**
```json
{
  "tool_name": "string — name of the tool Claude is about to call",
  "tool_input": {
    "command": "string — the bash command (for Bash tool only)"
  }
}
```

**Processing:** Acts on Bash tool calls only — checks `command` against blocked operation patterns (git commit, git push). Validates escape hatches at position 0.

**Stdout on block:**
```
**[CAST]** Raw `git commit` blocked. Dispatch the `commit` agent instead.
```
(plain text — displayed to Claude as the block reason)

**Stdout on allow:** empty

**Exit codes:**
- `0` — allow the tool call
- `2` — hard-block; Claude cannot execute the command

Note: `pre-tool-guard.sh` does not output `hookSpecificOutput` JSON — it outputs plain text when blocking, which Claude Code displays as the block reason.

### 5.4 `PostToolUse` — `post-tool-hook.sh`

**Stdin JSON schema:**
```json
{
  "tool_name": "string — name of the tool that just completed",
  "tool_input": {
    "file_path": "string — for Write/Edit tools"
  }
}
```

**Processing (three parts, in order):**

1. **Auto-format** (all sessions including subagents): if `tool_name` is Write or Edit and `file_path` matches `.(js|jsx|ts|tsx|css|json)`, search for a `.prettierrc` config walking up the directory tree and run `npx prettier --write` if found.

2. **CAST-REVIEW injection** (main session only): if `CLAUDE_SUBPROCESS != 1` and `tool_name` is Write or Edit, output the `[CAST-REVIEW]` directive.

3. **CAST-ORCHESTRATE detection** (main session only): if `tool_name` is Write, `file_path` contains `/plans/`, and the file contains a `json dispatch` block, output the `[CAST-ORCHESTRATE]` directive.

**Stdout format for directive injection:**
```json
{
  "hookSpecificOutput": {
    "hookEventName": "PostToolUse",
    "additionalContext": "[CAST-REVIEW] ..."
  }
}
```

**Exit codes:** Always 0 (no hard-blocking in post-tool-hook.sh).

### 5.5 `PostToolUse` — `agent-status-reader.sh`

> **Note:** In CAST v3, `agent-status-reader.sh` is no longer registered as a hook. Status propagation is handled by the model reading agent Status blocks directly. This section is preserved for protocol reference.

This hook runs only in subagent context. It inverts the standard CLAUDE_SUBPROCESS guard:

```bash
if [ "${CLAUDE_SUBPROCESS:-0}" != "1" ]; then exit 0; fi
```

**Purpose:** After a subagent writes a status file via `cast_write_status`, this hook reads the latest status file and propagates the signal to the parent session.

**Stdin:** same PostToolUse schema as `post-tool-hook.sh`

**BLOCKED stdout:**
```
**[CAST-HALT]** Agent `<agent>` is BLOCKED and cannot proceed.
Summary: <summary>
Concerns: <concerns>
Resolve the blocker before continuing. Do not retry the blocked operation.
```
Exit code: `2` (hard-block)

**DONE_WITH_CONCERNS stdout:**
```json
{
  "hookSpecificOutput": {
    "hookEventName": "PostToolUse",
    "additionalContext": "[CAST-REVIEW] Agent `<agent>` completed with concerns.\nSummary: ...\nConcerns: ...\nDispatch `code-reviewer` (haiku) to review before proceeding."
  }
}
```
Exit code: `0`

**DONE / NEEDS_CONTEXT / missing file:** exit 0 silently.

### 5.6 `hookSpecificOutput` Format

The `hookSpecificOutput` object is the standard envelope for injecting context into Claude's session:

```json
{
  "hookSpecificOutput": {
    "hookEventName": "UserPromptSubmit | PreToolUse | PostToolUse",
    "additionalContext": "string — the directive or context text"
  }
}
```

The `additionalContext` string appears in Claude's context window as if it were part of the conversation. Claude MUST treat directives in `additionalContext` as mandatory instructions.

---

## Section 6 — Event-Sourcing Protocol

CAST uses append-only event files instead of shared mutable state. Agents never share a
mutable file — each agent writes its own immutable event to the events/ directory.

### Directory Layout

All under `~/.claude/cast/`:

| Directory | Contents | Mutable? |
|---|---|---|
| `events/` | `{timestamp}-{agent}-{task_id}.json` — one file per agent action | Never (append-only) |
| `state/` | `{task_id}.json` — derived from events by orchestrator | Derived (can be re-derived) |
| `reviews/` | `{artifact_id}-{reviewer}-{timestamp}.json` — review decisions | Never |
| `artifacts/` | Plans, patches, test files produced by agents | Never |

### Event File Schema

File: `{timestamp}-{agent}-{task_id}.json`

| Field | Type | Description |
|---|---|---|
| event_id | string | `{timestamp}-{agent}-{task_id}` |
| timestamp | ISO8601 | UTC timestamp |
| agent | string | Which agent emitted this event |
| task_id | string | Task being acted on (e.g., "batch-2") |
| parent_task_id | string\|null | Parent task for sub-tasks |
| event_type | string | See event types below |
| status | string\|null | DONE\|BLOCKED\|DONE_WITH_CONCERNS\|IN_PROGRESS |
| summary | string\|null | Human-readable description |
| artifact_id | string\|null | ID of artifact produced |
| concerns | string\|null | Details for DONE_WITH_CONCERNS |

### Event Types

| event_type | When emitted |
|---|---|
| task_created | planner creates a new task |
| task_claimed | agent begins working on a task |
| task_completed | agent finishes (with status field) |
| task_blocked | agent cannot proceed |
| task_rejected | reviewer rejects an artifact |
| artifact_written | agent produces a code/doc artifact |
| review_submitted | reviewer submits a decision |

### Review File Schema

File: `{artifact_id}-{reviewer}-{timestamp}.json`

| Field | Type | Description |
|---|---|---|
| review_id | string | `{artifact_id}-{reviewer}-{timestamp}` |
| artifact_id | string | Which artifact is being reviewed |
| reviewer | string | Agent that reviewed |
| decision | string | `approved` or `rejected` |
| timestamp | ISO8601 | UTC |
| feedback | string\|null | Specific review notes |
| recommended_agents | array | Follow-up agents recommended |

### Approval Gating

Before commit, the commit agent calls `cast_check_approvals <task_id> <required_reviewer...>`.

- Exit 0: all required approvals present — proceed
- Exit 1: missing approvals — block commit, request review
- Exit 2: unanswered rejections — block commit, rejection must be addressed first

Required approvals for a code commit: `code-reviewer` (mandatory) + `test-runner` (if tests exist).

### Why Not Shared State

Shared mutable JSON files create race conditions when agents run in parallel. The event-sourcing approach:
- Each agent writes only to its own timestamped file (no conflicts)
- State is always re-derivable from events (no corruption risk)
- Full causal history preserved for the dashboard
- Reviews are attached to specific artifact IDs (not to vague global task state)

---

## Section 7 — Fan-out Dispatch

Fan-out dispatch enables multiple specialist agents to work on a problem simultaneously, then synthesizes their independent findings before passing context to the next stage.

### 7.1 Manifest-Level Fan-out

Triggered by `"type": "fan-out"` in a manifest batch. The orchestrator:

1. Dispatches all agents in the batch simultaneously (single response, multiple Agent tool calls)
2. Collects all agent responses
3. Synthesizes outputs into a **Fan-out Summary** paragraph
4. Prepends the Fan-out Summary to the prompt of every agent in the immediately following batch

**Fan-out Summary format:**
```
Fan-out Summary (Batch <id>):
- <agent-a>: <main finding in one sentence>
- <agent-b>: <main finding in one sentence>
[Conflicts: <describe any contradictory findings between agents>]
```

### 7.2 Agent-Level Fan-out

An agent may itself dispatch multiple sub-specialists simultaneously. This is agent-level fan-out. The agent:

1. Identifies independent sub-tasks that can run in parallel
2. Dispatches all sub-specialist agents in a single response
3. Synthesizes outputs before reporting its own Status block

### 7.3 Constraints

- Maximum 4 agents per fan-out batch (orchestrator enforces this; planner MUST respect it when building manifests)
- Agents in a fan-out batch MUST NOT depend on each other's outputs
- The synthesizing agent (orchestrator or dispatching agent) MUST produce a Fan-out Summary before passing context forward
- Fan-out does not imply fan-in review is skipped — quality gates still apply to the synthesized output

---

## Implementing CAST Compatibility

### Checklist: CAST-compatible agent

A CAST-compatible agent MUST:

- [ ] Include a YAML frontmatter block at the top of the `.md` file with fields: `name`, `description`, `tools`, `model`
- [ ] Output a Status block (`Status: DONE | DONE_WITH_CONCERNS | BLOCKED | NEEDS_CONTEXT`) as the last content in every response
- [ ] Include `Summary:` in every Status block
- [ ] Include `Blocker:` when status is BLOCKED
- [ ] Include `Concerns:` when status is DONE_WITH_CONCERNS
- [ ] If code-modifying: source `status-writer.sh` and call `cast_write_status` with matching values
- [ ] Never dispatch another instance of itself (prevents infinite loops)
- [ ] Not re-dispatch `code-reviewer` if it self-dispatches internally (self-dispatching agents: `code-writer`, `debugger`)
- [ ] Use `CAST_COMMIT_AGENT=1 git commit` (not raw `git commit`) if it needs to commit directly

A CAST-compatible agent SHOULD:

- [ ] Declare `memory: local` and consult `MEMORY.md` in `~/.claude/agent-memory-local/<name>/` before starting
- [ ] Use `disallowedTools` to prevent unintended side effects (e.g., `code-reviewer` disallows Write and Edit)
- [ ] Include a `maxTurns` limit appropriate for the task scope
- [ ] Keep prompts specific — include feature names, file paths, and plan paths when available

### Checklist: CAST-compatible hook script

A CAST-compatible hook script MUST:

- [ ] Read the full stdin payload before processing
- [ ] Guard against subagent re-entry using `CLAUDE_SUBPROCESS`: exit 0 for hooks that should only run in the main session; invert the guard for hooks that only run inside subagents
- [ ] Use `realpath` + `$HOME/` prefix check before reading or writing any file path derived from input
- [ ] Use exit code 0 (allow), 1 (warn), or 2 (hard-block) — never exit with other codes for protocol responses
- [ ] Output `hookSpecificOutput` JSON for directive injection; output plain text for block messages
- [ ] Limit regex pattern length to 200 characters maximum (ReDoS prevention)
- [ ] Log dispatch events to `cast.db` via `cast-cost-tracker.sh` (for PostToolUse:Agent hooks)
- [ ] Use `python3` stdlib only — no pip packages

A CAST-compatible hook script SHOULD:

- [ ] Use `set -euo pipefail` for fail-fast behavior
- [ ] Scope sensitive values as env-prefix subprocess invocations rather than `export` (prevents leaking to unrelated subprocesses)
- [ ] Emit nothing to stdout when taking no action (silence = allow)

---

## Appendix A — Directory Layout

```
~/.claude/
├── CLAUDE.md                        # Dispatch table + post-chain protocol (loaded every session)
├── agents/                          # Agent definition files (.md with YAML frontmatter)
├── scripts/
│   ├── pre-tool-guard.sh            # PreToolUse:Bash hook: git commit/push guard
│   ├── post-tool-hook.sh            # PostToolUse:Write|Edit hook (review injection)
│   ├── cast-cost-tracker.sh         # PostToolUse:Agent hook (logs to cast.db)
│   ├── cast-session-end.sh          # Stop hook: archival, pruning, memory sync
│   ├── status-writer.sh             # Sourced helper: cast_write_status
│   ├── cast-events.sh               # Sourced helper: cast_emit_event
│   ├── cast-validate.sh             # System integrity checker
│   ├── cast-stats.sh                # Usage analytics from cast.db
│   ├── cast-cron-setup.sh           # Cron installer for scheduled tasks
│   └── cast-db-init.sh              # Initialize cast.db schema
├── rules/                           # Stack context, project catalog, conventions
├── plans/                           # Plan files with Agent Dispatch Manifests
├── agent-status/                    # Per-agent JSON status files
├── agent-memory-local/              # Per-agent persistent memory
│   └── <agent-name>/MEMORY.md
├── cast.db                          # SQLite: sessions, agent_runs, budgets, agent_memories
├── cast/
│   ├── events/                      # Immutable event files
│   └── orchestrator-checkpoint.log  # Orchestrator batch progress
├── briefings/                       # Morning briefing outputs
├── meetings/                        # Meeting notes outputs
└── reports/                         # Report outputs
```

## Appendix B — Routing Table Schema

> **Historical (CAST v2):** The routing table was removed in CAST v3. This section is preserved for protocol documentation.

Each entry in `routing-table.json` under the `routes` array:

```json
{
  "patterns": ["regex1", "regex2"],
  "agent": "agent-name",
  "model": "haiku | sonnet | opus",
  "command": "/slash-command",
  "confidence": "hard | soft",
  "post_chain": ["agent-a", "agent-b"] | null | ["auto-dispatch-from-manifest"]
}
```

`post_chain: ["auto-dispatch-from-manifest"]` is a special sentinel used for the `planner` route. It tells route.sh not to append a `[CAST-CHAIN]` directive — the manifest itself drives the post-chain via `[CAST-ORCHESTRATE]`.

## Appendix C — Version History

| Version | Changes |
|---|---|
| 2.1.0 | CAST v3.3 (Phase 11): WAL mode, structured error logging, SQL injection fix, PII advisory mode, orchestrator checkpoints + policy gate, TRUNCATED/BLOCKED classification split, approval gate removed. |
| 2.0.0 | CAST v3: Removed routing table and route.sh. Model-driven dispatch via CLAUDE.md. Consolidated 42→15 agents. 4 hooks (pre-tool-guard, post-tool-hook, cast-cost-tracker, cast-session-end). Added cast.db observability. Replaced castd daemon with cron. |
| 1.5.0 | Added orchestrator, fan-out dispatch, task board, agent-status-reader, CAST-ORCHESTRATE and CAST-HALT directives |
| 1.0.0 | Initial protocol: Status Blocks, escape hatches, route.sh, pre-tool-guard.sh, post-tool-hook.sh |
