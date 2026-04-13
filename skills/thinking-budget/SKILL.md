---
name: thinking-budget
description: Reference for per-agent extended thinking budget configuration. Load when adjusting agent thinking budgets.
user-invocable: false
allowed-tools: []
---

# Thinking Budget Configuration

Config file: `~/.claude/config/thinking-budgets.json`

## Tiers
- **0** — disabled (haiku reviewers, commit/push/merge agents)
- **1,024** — minimal default (all unspecified agents)
- **2,048** — light reasoning (code-writer)
- **4,096** — moderate (debugger, security, api-contract, learning-scout, perf-sentinel)
- **8,192** — deep reasoning (orchestrator, planner, researcher)

## To override for a session
Set the budget in the agent's frontmatter `thinking_budget` field, or override in `config/thinking-budgets.json`.

## Rationale
Haiku agents doing mechanical tasks (commit, push, review formatting) get 0 — they do not benefit from chain-of-thought. Sonnet agents doing planning, security, or multi-file analysis get higher budgets. Default 1,024 prevents zero-budget errors on unspecified agents.
