---
name: orchestrate
description: Execute a CAST plan by dispatching the orchestrator. Pass a plan file path, 'next' for the most recent plan, or 'resume' to continue from a checkpoint.
user-invocable: true
allowed-tools: [Read, Glob, Bash, Agent]
---

# Orchestrate

This is the `/orchestrate` skill. It dispatches the CAST orchestrator to execute a plan.

## Arguments

$ARGUMENTS

## Step 1 — Resolve the plan path

**If a file path was provided as an argument:** use it directly.

**If argument is `next` or no argument:** find the most recent plan file:
```bash
ls -t ~/.claude/plans/*.md | head -1
```

**If argument is `resume`:** find any checkpoint log in `~/.claude/cast/orchestrator-checkpoint-*.log`. Read the most recent one to extract the plan path and last completed batch.

If no plan file can be found, output: "No plan file found in ~/.claude/plans/. Run /plan first to write one."

## Step 2 — Dispatch the orchestrator

Dispatch via the Agent tool with these exact parameters:
- `subagent_type: "general-purpose"`
- `name: "orchestrator"` — makes it show as "orchestrator" in the UI instead of a UUID
- prompt: `"You are the CAST orchestrator. Read your full instructions at ~/.claude/agents/orchestrator.md first. Then execute the plan at [RESOLVED_PLAN_PATH]. Follow the orchestrator instructions exactly: present the batch queue for approval, then execute all batches in order. If resuming, the last completed batch was [LAST_BATCH] — skip batches with id <= that number."`

**Important:** Always use `subagent_type: "general-purpose"` — never `subagent_type: "orchestrator"`. The orchestrator is a custom CAST agent and not a valid built-in subagent type. The `name` field is what makes it appear labeled in the UI.
