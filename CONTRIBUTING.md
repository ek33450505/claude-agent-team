# Contributing to CAST

Thank you for your interest in contributing to CAST — Claude Agent Specialist Team.

## Prerequisites

- [Bats-core](https://github.com/bats-core/bats-core) (included as a submodule at `tests/bats/`)
- `jq` 1.6+
- Bash 4.0+
- [Claude Code CLI](https://claude.ai/code) installed and configured

## Quick Start

```bash
git clone https://github.com/ek33450505/claude-agent-team.git
cd claude-agent-team
./install.sh
make test
```

`./install.sh` automatically wires the pre-commit hook, which runs `make docs` before every commit and re-stages `README.md` if counts changed. If you skip `install.sh`, run `make hooks` once to activate the hook manually.

---

## Adding a New Agent

### File location

Agents live under `agents/<tier>/<name>.md`, where tier is one of:

| Tier | Path | Purpose |
|------|------|---------|
| core | `agents/core/` | Always installed, essential to CAST |
| extended | `agents/extended/` | Opt-in at install time |
| productivity | `agents/productivity/` | Scheduling, writing, briefings |
| professional | `agents/professional/` | Browser, QA, presentations |
| orchestration | `agents/orchestration/` | Orchestrators, verifiers, auto-stagers |
| specialist | `agents/specialist/` | DevOps, performance, SEO, linting |

### Required frontmatter

Every agent file must begin with YAML frontmatter:

```yaml
---
name: <agent-name>
description: <one-line description used by Claude Code to select this agent>
tools: Read, Write, Edit, Bash   # list only tools the agent needs
model: claude-haiku-4-5          # or claude-sonnet-4-5
---
```

See `docs/agent-quality-rubric.md` for how agents are evaluated. Aim for score 4-5 on all dimensions.

### Mandatory Step 0 — task_claimed event

Every agent must emit a `task_claimed` event as its **first action**:

```bash
source ~/.claude/scripts/cast-events.sh
cast_emit_event 'task_claimed' '<agent-name>' 'task-<id>' '' 'Starting <description>'
```

This populates the CAST event log and the dashboard session view.

### Mandatory Status block

Every agent must end its response with a structured Status block:

```
Status: DONE
Summary: <one sentence>
```

Valid status values: `DONE` | `DONE_WITH_CONCERNS` | `BLOCKED` | `NEEDS_CONTEXT`

If `DONE_WITH_CONCERNS`, add a `Concerns:` line immediately after Status.
If `BLOCKED`, add a `Blocker:` line describing what is preventing completion.

---

## Adding a Routing Rule

Routing rules live in `config/routing-table.json`. Each rule has this shape:

```json
{
  "pattern": "(?i)\\bwrite.*test\\b",
  "agent": "test-writer",
  "confidence": "hard",
  "description": "Explicit test-writing request"
}
```

**Confidence levels:**
- `hard` — unambiguous match; always dispatches
- `soft` — heuristic match; may fall through to NLU router if score is low

**Pattern safety rules:**
- Max 200 characters
- Must not contain catastrophic backtracking patterns (avoid `(a+)+`, nested quantifiers)
- Test your regex with `python3 -c "import re; re.compile('<your_pattern>')"`

**Required:** add a corresponding test case to `tests/route.bats`:

```bash
@test "routes 'write a test for foo' to test-writer" {
  result=$(echo "write a test for foo" | bash scripts/route.sh)
  [[ "$result" == *"test-writer"* ]]
}
```

---

## Adding an Agent Group

Agent groups live in `config/agent-groups.json`. Each group dispatches multiple agents in waves:

```json
{
  "name": "my-feature",
  "pattern": "(?i)my trigger phrase",
  "waves": [
    { "agents": ["architect"], "parallel": false },
    { "agents": ["code-writer", "test-writer"], "parallel": true }
  ],
  "post_chain": ["code-reviewer", "commit"]
}
```

Waves run in order. Agents within a wave with `"parallel": true` run simultaneously.
`post_chain` agents run after all waves complete.

---

## Running Tests

```bash
# Full suite
make test

# Single file
tests/bats/bin/bats tests/route.bats
```

---

## Keeping Docs in Sync

README badge counts (agents, routes, commands, etc.) are maintained by `scripts/gen-stats.sh`.
**Always run `make docs` before committing** if you added or removed any agent, command, skill, route, or test.
CI will fail the PR if README counts are stale.

```bash
make docs
git add README.md
```

---

## PR Checklist

Before opening a pull request:

- [ ] `make test` passes locally
- [ ] `make docs` run and `README.md` committed with updated counts
- [ ] New agent: frontmatter is complete (`name`, `description`, `tools`, `model`)
- [ ] New agent: emits `task_claimed` event in Step 0
- [ ] New agent: outputs structured `Status:` block as the final line of every response
- [ ] New routing pattern: test case added to `tests/route.bats`
- [ ] No hardcoded paths — use `$HOME` or `~/` for user-relative paths
- [ ] `CHANGELOG.md` updated for any user-visible change
