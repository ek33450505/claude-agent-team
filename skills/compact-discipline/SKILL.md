---
name: compact-discipline
description: Compact discipline rules — when and how to use /compact to prevent context degradation. Auto-loaded by CAST working conventions.
user-invocable: false
allowed-tools: []
---

# Compact Discipline

## When to compact
- At ~60% context usage (before the "dumb zone" at ~70%)
- Before starting a new logical unit after a large exploration
- After reading 5+ large files in a row
- Whenever output quality feels degraded

## How to compact
1. Run `/compact` — Claude Code summarizes context and continues
2. If starting fresh: `/clear` + `/resume` to reload last session summary
3. Use `/rename` to checkpoint before compacting a long session

## Signs you waited too long
- Repeating yourself
- Missing obvious patterns you saw earlier
- Contradicting earlier decisions

## Rule: commit before compact
Always commit the current work unit before compacting. Compact discards tool output history.
