# Your First Agent Dispatch

This is Part 2 of the CAST tutorial. You'll dispatch `code-reviewer` on a sample file
and read the Work Log output it returns.

**Prerequisite:** Complete [Part 1 — Getting Started](./getting-started.md) first.

---

## Step 1: Create a sample file to review

In any project directory, create a simple script:

```bash
cat > /tmp/sample.sh << 'EOF'
#!/bin/bash
name=$1
echo Hello $name
EOF
```

---

## Step 2: Open Claude Code and dispatch the agent

Start a Claude Code session in your terminal:

```bash
claude
```

Then ask Claude to dispatch `code-reviewer`:

```
Review /tmp/sample.sh using the code-reviewer agent. Focus on shell safety issues.
```

Claude Code will invoke the agent via the Agent tool. You'll see output similar to:

```
[code-reviewer dispatched]

Reviewing /tmp/sample.sh...
```

---

## Step 3: Read the Work Log

When the agent finishes, it returns a structured response ending with a **Status block**
and a **Work Log**. Look for this section in the output:

```
Status: DONE_WITH_CONCERNS
Summary: Reviewed /tmp/sample.sh — 2 shell safety issues found

## Work Log

- Reads: sample.sh — 3 lines, bash script greeting
- Findings:
  - Line 2: `name=$1` — unquoted variable; use `name="${1}"` to handle spaces
  - Line 3: `echo Hello $name` — unquoted expansion; use `echo "Hello ${name}"`
- Tests: skipped — review task, no code changes
- Concerns: SC2086 (unquoted variables) would fail ShellCheck; fix before committing
```

---

## Step 4: Understand the Status block

Every CAST agent ends with one of four statuses:

| Status | Meaning |
|---|---|
| `DONE` | Task complete, no issues |
| `DONE_WITH_CONCERNS` | Complete, but concerns worth addressing |
| `BLOCKED` | Cannot proceed — needs human input |
| `NEEDS_CONTEXT` | Needs more information to continue |

The **Summary** line is a one-sentence description of what happened. The **Work Log**
breaks down reads, edits, test results, and decisions made during the run.

---

## Step 5: Verify the dispatch was logged

CAST logs every agent dispatch to `cast.db`. Check it:

```bash
sqlite3 ~/.claude/cast.db \
  "SELECT agent, status, ended_at FROM agent_runs ORDER BY ended_at DESC LIMIT 3;"
```

Expected output:

```
code-reviewer|DONE_WITH_CONCERNS|2026-05-06T14:23:01Z

```

---

## What just happened

When you asked Claude to use `code-reviewer`, Claude Code:
1. Loaded the agent definition from `~/.claude/agents/code-reviewer.md`
2. Invoked the agent via the Agent tool with your file path as context
3. The agent read the file, applied its review criteria, and returned a structured response
4. The SubagentStop hook fired, logging the dispatch to `cast.db`

The agent ran as a **subagent** — a separate Claude instance with its own context window,
specialized system prompt, and bounded task scope. It cannot commit code or modify files
on its own; it only reads and reports.

---

## Next step

Part 3: [How hooks work](./first-hook.md) — understand what a hook event is, how CAST
wires them, and how to verify a hook fired by checking `cast.db`.
