---
name: plan
description: Activate the heavy planner→/orchestrate chain — write a structured plan file with Agent Dispatch Manifest, then invoke the /orchestrate skill to execute it in waves. Reserve for genuinely multi-file / multi-hour / multi-agent work (large refactors, migrations, features spanning many files). For single-session-sized work (one or a few files), use built-in plan mode (shift-tab) instead — not this skill.
user-invocable: true
allowed-tools: [Write, Read, Glob, Grep, Agent]
---

# Plan Mode

This is the `/plan` skill — the heavy `planner`→`/orchestrate` chain, reserved for genuinely multi-file / multi-hour / multi-agent work. For single-session-sized tasks (one or a few files, finishable in one session), use built-in plan mode (shift-tab) with a single agent instead of this skill. You are entering plan mode to write a structured implementation plan.

## Step 1 — Write the plan file

Write a plan file under `~/.claude/plans/` using the Write tool:

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

## Step 2 — Show plan summary and ask for approval

After writing the plan file, display a concise summary:
- Plan file path
- Number of batches and agents
- A table: Batch | Mode | What it does

Then ask the user: **"Execute this plan with /orchestrate? [yes/no]"**

Wait for explicit confirmation before proceeding.

## Step 3 — Execute via /orchestrate skill

Once the user confirms, invoke the `/orchestrate` skill with the plan file path:

```
/orchestrate [ABSOLUTE_PLAN_PATH]
```

The `/orchestrate` skill reads the plan's Agent Dispatch Manifest and executes all batches directly from the main session — presenting the batch queue, running the interrupt window, then dispatching agents in order.
