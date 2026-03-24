---
name: plan
description: Activate plan mode — write a structured plan file with Agent Dispatch Manifest, then dispatch the orchestrator agent to execute it. Use for any non-trivial feature, refactor, or multi-step task.
user-invocable: true
allowed-tools: [Write, Read, Glob, Grep, ExitPlanMode, Agent]
---

# Plan Mode

This is the `/plan` skill. You are entering plan mode to write a structured implementation plan.

## Step 1 — Write the plan file

Use ExitPlanMode to enter the native plan editor. Write a plan file under `~/.claude/plans/` following the planner.md format:

- Filename: `~/.claude/plans/<YYYY-MM-DD>-<slug>.md` where slug is a short kebab-case description
- Include all of these sections:
  - Title and context
  - Fix strategy / implementation approach (one subsection per logical change)
  - Files to modify table
  - Implementation order
  - Verification steps
  - `## Agent Dispatch Manifest` — **mandatory** — a `json dispatch` code block with batches, agent types, prompts, and parallel flags

The ADM block must follow this schema:
```json dispatch
{
  "batches": [
    {
      "id": 1,
      "description": "short description",
      "parallel": true,
      "agents": [
        { "subagent_type": "agent-name", "prompt": "specific task prompt" }
      ]
    }
  ]
}
```

Use `"subagent_type": "main"` for tasks the orchestrator handles inline. Use named agents (e.g. `"code-reviewer"`, `"commit"`) for delegated tasks. Group independent tasks into parallel batches.

## Step 2 — After ExitPlanMode approval

Once the plan file is written and the user approves ExitPlanMode:

Dispatch the `orchestrator` agent via the Agent tool, passing the absolute path to the plan file you just wrote. Example:

> Dispatch orchestrator with task: "Execute plan at /Users/<you>/.claude/plans/<filename>.md"

The orchestrator will read the Agent Dispatch Manifest, present the batch queue for user approval, and execute the batches in order.

Do not execute the plan yourself — hand it off to the orchestrator.
