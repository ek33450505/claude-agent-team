---
name: merge
description: >
  Git merge, rebase, and conflict resolution specialist. Use when merging feature branches,
  rebasing onto main, resolving merge conflicts, merging PRs via gh CLI, or cleaning up
  merged worktrees and branches. Hard-blocks force-merges to main/master without explicit approval.
user-invocable: true
allowed-tools: [Agent, Bash, Read, Glob, Grep]
---

# Merge

This is the `/merge` skill. Dispatch the `merge` agent to handle the operation.

## How to use

```
/merge                        # detect scenario from current git state
/merge feature/my-branch      # merge a specific branch into main
/merge --pr 42                # merge PR #42 via gh CLI
/merge --rebase               # rebase current branch onto main
/merge --cleanup              # remove stale local branches + worktrees
/merge --squash feature/xyz   # squash-merge a noisy feature branch
```

## Dispatch rules

Parse the user's arguments, then dispatch the `merge` agent with a clear task prompt. Include:

1. **Source branch** — from args, or detect with `git branch --show-current`
2. **Target branch** — default `main`, or from args
3. **Strategy** — ff-rebase (default), squash, merge-commit, or PR merge
4. **Scope** — full merge vs. cleanup-only vs. conflict resolution only

### Scenario detection (when no args given)

Run `git status` and `git branch -vv` to detect the situation:

| State | Action |
|-------|--------|
| On a feature branch with commits ahead of main | Rebase + fast-forward merge |
| Unmerged paths in working tree | Conflict resolution mode |
| Local branches marked `[gone]` | Stale branch + worktree cleanup |
| Clean working tree on main | Report "nothing to merge" cleanly |

## Safety reminders (pass to agent)

- Hard-block force-merge to main/master — require `approve force-merge` in writing
- Always show `git diff --stat` before executing
- Verify merge before any branch deletion
- Never delete the currently checked-out branch

## Dispatch

Use the Agent tool to dispatch `merge` with the full context assembled above.

Do not execute git commands inline — hand off to the agent.
