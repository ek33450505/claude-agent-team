# Managed Agents Preference

Managed Agents are Anthropic-hosted autonomous agents (beta header `managed-agents-2026-04-01`) that run on Anthropic infrastructure rather than the local machine. They enable parallel work without the filesystem isolation complexity of git worktrees.

## Rule
**Prefer Managed Agents over local git worktrees for parallel work.**

## Why
The existing worktree workflow rule in `working-conventions.md` documents a footgun: worktree-based parallel agent dispatches have repeatedly lost changes, overwritten good files with stale versions, and required manual recovery. Managed Agents isolate execution on Anthropic infrastructure, eliminating the cross-worktree interference and checkout conflicts that plague local parallelization.

## When
- Parallel agent work that would previously have used worktrees
- Long-running autonomous jobs that don't need real-time user feedback
- RemoteTrigger / scheduled jobs where local execution is unnecessary
- Multi-agent chains that would benefit from independent execution contexts

## When NOT
- Work that requires local filesystem state the Managed Agent can't reach (uncommitted changes, local-only tools, unpushed branches)
- Work requiring access to private SSH keys or local credentials outside the agent's authenticated scope
- Interactive debugging or real-time user feedback loops

## Migration Candidate
`code-reviewer` (5/5 score: parallel by design, no local-only state, read-only output, bounded duration, low-stakes failure — see `~/.claude/research/2026-04-25-managed-agents-candidate.md`).

## Adapter Shim
`scripts/cast-managed-agent.sh <agent-name> <prompt> [--local-fallback] [--define-only]`. Requires `ANTHROPIC_API_KEY` (or keychain). Beta header `managed-agents-2026-04-01`. Auth errors (401/403) fail-closed even with `--local-fallback`. Default: full 3-step flow (agents → environments → sessions); `--define-only` stops after agent creation.

## Keychain Setup

If `ANTHROPIC_API_KEY` is unset, the shim falls back to macOS Keychain under service `anthropic-api-key`. Register once:

```bash
security add-generic-password -s anthropic-api-key -a "$USER" -w '<your-key>'
```

The shim reads it automatically — no env var export needed.

## Status
Phase 6b complete — full session flow, BATS coverage, cast.db telemetry, keychain fallback. Last seen: 2026-04-25.
