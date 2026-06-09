# Managed Agents — Reference

> Shim usage, keychain setup, convergence status, and roadmap moved off the always-on
> `rules/managed-agents.md` surface (v7.5 Phase 1, 2026-06-09). The behavioral rule
> (prefer Managed Agents over worktrees; the When / When-NOT decision lists) stays in
> `rules/managed-agents.md`.

Managed Agents are Anthropic-hosted autonomous agents (beta header `managed-agents-2026-04-01`) that run on Anthropic infrastructure rather than the local machine. They enable parallel work without the filesystem isolation complexity of git worktrees.

## Migration Candidate

`code-reviewer` (5/5 score: parallel by design, no local-only state, read-only output, bounded duration, low-stakes failure — see `~/.claude/research/2026-04-25-managed-agents-candidate.md` [NOTE: this research file was lost in the wipe]).

## Adapter Shim

`scripts/cast-managed-agent.sh <agent-name> <prompt> [--local-fallback] [--define-only]`. Requires `ANTHROPIC_API_KEY` (or keychain). Beta header `managed-agents-2026-04-01`. Auth errors (401/403) fail-closed even with `--local-fallback`. Default: full 3-step flow (agents → environments → sessions); `--define-only` stops after agent creation.

## Keychain Setup

If `ANTHROPIC_API_KEY` is unset, the shim falls back to macOS Keychain under service `anthropic-api-key`. Register once:

```bash
security add-generic-password -s anthropic-api-key -a "$USER" -w '<your-key>'
```

The shim reads it automatically — no env var export needed.

## Phase 11 Convergence — Shim as Native API Target

The shim (`scripts/cast-managed-agent.sh`) is the convergence target toward Anthropic's native Managed Agents API. As of 2026-06-03 the shim is approximately two API generations behind: Multiagent Orchestration, Outcomes, webhooks, and self-hosted sandboxes shipped Apr–May 2026 under the same `managed-agents-*` beta-header family. Full native adoption is deferred until the current request schema is verifiable in a headless session.

### Beta header override

Operators who have verified a newer header generation can override the default without editing the script:

```bash
CAST_MANAGED_AGENT_BETA_HEADER=managed-agents-2026-XX-YY \
  scripts/cast-managed-agent.sh <agent> <prompt>
```

The script resolves: `BETA_HEADER="${CAST_MANAGED_AGENT_BETA_HEADER:-managed-agents-2026-04-01}"`. When unset, the original default applies and behavior is unchanged.

## Status

Phase 6b complete — full session flow, BATS coverage, cast.db telemetry, keychain fallback. Last seen: 2026-04-25. Phase 11 (convergence baseline + header override) added 2026-06-03.

## Roadmap notes (from the 2026-06-01 audit)

- R2: the shim is 2 API generations behind (multiagent sessions, Outcomes, webhooks, self-hosted sandboxes shipped Apr-May 2026 under the same beta header) — upgrade in audit Phase 7.
- R5: Task Budgets now support Opus 4.8 (`task-budgets-2026-03-13`) but still NOT available in Claude Code (Messages API only).
