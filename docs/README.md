# CAST Documentation Index

All CAST documentation with one-line descriptions. Start with the Tutorial if you're new.

---

## Getting Started

| Document | Description |
|---|---|
| [Tutorial: Getting Started](tutorial/getting-started.md) | Install CAST via Homebrew and verify `cast status` loads <!-- CAST_AGENT_COUNT -->23<!-- /CAST_AGENT_COUNT --> agents |
| [Tutorial: First Agent Dispatch](tutorial/first-agent-dispatch.md) | Dispatch `code-reviewer` on a file and read the Work Log output |
| [Tutorial: How Hooks Work](tutorial/first-hook.md) | Conceptual intro to hook events, the CLAUDE_SUBPROCESS guard, and cast.db verification |

---

## Reference

| Document | Description |
|---|---|
| [Compatibility Matrix](compatibility.md) | Claude Code version requirements for each CAST feature and known breakages |
| [Hook Authoring Guide](hooks/authoring-guide.md) | Write, test, and install custom hook scripts end-to-end |
| [Known Limitations](known-limitations.md) | Documented constraints and workarounds |
| [Native Tools Reference](native-tools-reference.md) | Claude Code built-in tools that CAST hooks interact with |
| [Token Optimization](TOKEN-OPTIMIZATION.md) | Model tiering, response budgets, and Ollama local routing to reduce token spend |

---

## Architecture

| Document | Description |
|---|---|
| [Architecture Overview](architecture/ARCHITECTURE.md) | Full system architecture: enforcement gates, data-integrity stack, agent contracts, worktrees |
| [Observability Guide](observability/OBSERVABILITY.md) | cast.db schema, observability dashboard, hook event coverage |
| [CAST Protocol Spec](architecture/cast-protocol-spec.md) | Agent dispatch protocol, ADM format, and SubagentStop payload contract |
| [Dispatch DAG Decision](dispatch-dag-decision.md) | ADR: why CAST uses a manifest-driven DAG over a centralized orchestrator |
| [Attest DONE-Gate](attest-donegate.md) | SubagentStop completion-gate plugin: what it is, status (OFF by default), opt-in steps, scope (`code-writer,bash-specialist`), cast.db `attestations` table |

---

## Agent Documentation

| Document | Description |
|---|---|
| [Agent Roster](agents/AGENT-ROSTER.md) | All <!-- CAST_AGENT_COUNT -->23<!-- /CAST_AGENT_COUNT --> agents with model tiers and scopes |
| [Agent Contracts — Status-block schema](agents/agent-contracts.md) | Structured Status Block JSON schema and input/output contracts for each agent type |
| [Agent Contract Testing](agent-contracts.md) | Contract testing framework: YAML-driven assertion specs for agent contracts |
| [Agent Quality Rubric](agents/agent-quality-rubric.md) | How `code-reviewer` scores agent output quality |
| [CAST Agent Conventions](CAST_AGENT_CONVENTIONS.md) | Protocol every agent must follow: Status blocks, Work Logs, Facts emission |

---

## Hook Examples

| File | Description |
|---|---|
| [log-every-tool-call.sh](hooks/examples/log-every-tool-call.sh) | PostToolUse hook that logs tool name + input to cast.db |
| [block-on-dirty-worktree.sh](hooks/examples/block-on-dirty-worktree.sh) | PreToolUse hook that exits 2 when the git working tree has uncommitted changes |
| [notify-on-agent-stop.sh](hooks/examples/notify-on-agent-stop.sh) | SubagentStop hook that appends agent name and stop reason to a log file |

---

## Specs and Design Notes

| Document | Description |
|---|---|
| [Parallel Agent Groups Design](specs/2026-03-24-parallel-agent-groups-design.md) | Design spec for parallel batch dispatch in Agent Dispatch Manifests |
| [Work Log Audit](work-log-audit.md) | Audit of Work Log quality across agent responses |
| [Agent Response Capture Decision](agent-response-capture-decision.md) | ADR: how SubagentStop captures agent output across dispatch paths |
