---
description: Show all installed CAST agents, commands, and how the routing system works
---

Read `~/.claude/agents/` and list every installed agent. For each, extract the frontmatter fields: name, model, description (first line). Also read `~/.claude/commands/` and list every installed command file name (without .md).

Then read `~/.claude/config/routing-table.json` and extract: for each route, the agent name and its command.

Format the full output as:

---

## CAST — Claude Agent System & Team

### Installed Agents

| Agent | Model | Command | When to Use |
|---|---|---|---|
[one row per agent: name | model | slash command if in routing table else — | first line of description]

### How Routing Works

The `UserPromptSubmit` hook runs `route.sh` on every message. When your prompt matches a known pattern, CAST dispatches the right agent automatically — you don't need to type a command.

**Patterns that trigger routing:**
[list each route: "Prompts matching: [patterns]" → dispatches `/command`]

**Opus escalation:** Prefix any message with `opus:` to use Opus for that message.
Example: `opus: design the entire authentication system from scratch`

### Quick Examples

| What you type | What CAST does |
|---|---|
| "write tests for my new component" | Dispatches `test-writer` (Sonnet) |
| "commit my changes" | Dispatches `commit` agent (Haiku — ~$0.001) |
| "debug why my build is failing" | Dispatches `debugger` (Sonnet) |
| "run playwright e2e tests" | Dispatches `e2e-runner` (Sonnet) |
| "typescript error in my file" | Dispatches `build-error-resolver` (Haiku) |

### Check Routing History

```bash
tail -20 ~/.claude/routing-log.jsonl | python3 -m json.tool
```

---
