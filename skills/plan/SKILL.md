---
name: plan
description: Activate plan mode — write a structured plan file with Agent Dispatch Manifest, then dispatch the orchestrator agent to execute it. Use for any non-trivial feature, refactor, or multi-step task.
user-invocable: true
allowed-tools: [Write, Read, Glob, Grep, Agent]
---

# Plan Mode

This is the `/plan` skill. You are entering plan mode to write a structured implementation plan.

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

Then ask the user: **"Dispatch orchestrator to execute this plan? [yes/no]"**

Wait for explicit confirmation before proceeding.

## Step 3 — Dispatch the orchestrator

Once the user confirms, dispatch via the Agent tool using `subagent_type: "general-purpose"`. Pass this prompt:

> "You are the CAST orchestrator. Read your full instructions at ~/.claude/agents/orchestrator.md first, then execute the plan at [ABSOLUTE_PLAN_PATH]. Follow the orchestrator instructions exactly — present the batch queue for approval, then execute all batches in order."

**Important:** Always use `subagent_type: "general-purpose"` — never `subagent_type: "orchestrator"`. That name is a custom CAST agent, not a valid built-in subagent type.

Do not execute the plan yourself — hand it off to the agent.
