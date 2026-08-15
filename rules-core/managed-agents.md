# Managed Agents Preference

> Shim usage, keychain setup, convergence status, and roadmap moved to `claude-agent-team/docs/managed-agents-reference.md` (v7.5 Phase 1, 2026-06-09). Behavioral rule kept below.

Managed Agents are Anthropic-hosted autonomous agents (beta `managed-agents-2026-04-01`) that run on Anthropic infrastructure rather than the local machine — parallel work without the filesystem-isolation complexity of git worktrees.

## Rule
**Prefer Managed Agents over local git worktrees for parallel work.** Worktree-based parallel dispatches have repeatedly lost changes, overwritten good files with stale versions, and required manual recovery; Managed Agents isolate execution on Anthropic infrastructure, eliminating that cross-worktree interference.

## When
- Parallel agent work that would previously have used worktrees
- Long-running autonomous jobs that don't need real-time user feedback
- RemoteTrigger / scheduled jobs where local execution is unnecessary
- Multi-agent chains that benefit from independent execution contexts

## When NOT
- Work needing local filesystem state the Managed Agent can't reach (uncommitted changes, local-only tools, unpushed branches)
- Work needing private SSH keys or local credentials outside the agent's authenticated scope
- Interactive debugging or real-time user feedback loops
