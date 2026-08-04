# Hook Types Evaluation for CAST

**Date:** 2026-04-10
**Author:** CAST Researcher Agent
**Status:** Research Complete

---

## Overview

Claude Code supports four hook types. CAST currently uses only `command` hooks (bash scripts). This evaluation assesses the three newer types: HTTP hooks, Prompt hooks, and Agent hooks.

## Hook Type Comparison

### 1. Command Hooks (Current CAST Standard)

```json
{
  "type": "command",
  "command": "bash ~/.claude/scripts/cast-audit-hook.sh",
  "timeout": 5
}
```

**How it works:** Spawns a bash subprocess. Receives event JSON on stdin. Stdout is parsed for hookSpecificOutput.

**Pros:** Full control, any logic, access to filesystem and cast.db, no API cost.
**Cons:** Process spawn overhead (~50-100ms per hook), error-prone (exit codes, JSON parsing), no Claude intelligence.

### 2. HTTP Hooks

```json
{
  "type": "http",
  "url": "http://localhost:3001/api/hook-events",
  "timeout": 3,
  "async": true
}
```

**How it works:** Sends a POST request with the hook event JSON as the body. Response is parsed for hookSpecificOutput.

**Pros:** Lightweight, no subprocess, works with any HTTP service, great for dashboards.
**Cons:** Requires a running server, network latency, no complex logic at the hook layer.

**CAST Use Cases:**
| Use Case | Fit | Notes |
|---|---|---|
| Dashboard real-time updates | Excellent | Already have `http://localhost:3001/api/hook-events` in PostCompact |
| External alerting (Slack, PagerDuty) | Good | Could POST to webhook URLs |
| Metrics collection (Prometheus) | Good | Push metrics to pushgateway |
| cast.db writes | Poor | Overkill — command hook is simpler |

### 3. Prompt Hooks

```json
{
  "type": "prompt",
  "prompt": "Evaluate whether this tool call could delete production data. If yes, respond with BLOCK and explain why."
}
```

**How it works:** Sends a single-turn Claude evaluation. The prompt includes the hook context. Claude's response is used as the hook output.

**Pros:** Natural language policy enforcement, can understand intent, no code to maintain.
**Cons:** API token cost per invocation, latency (~1-3 seconds), non-deterministic.

**CAST Use Cases:**
| Use Case | Fit | Notes |
|---|---|---|
| PostCompact context recovery | Excellent | Already used in 30-hooks-session.json |
| Security policy enforcement | Good | "Does this bash command access credentials?" |
| Code quality gates | Moderate | Could evaluate code changes, but slower than command hooks |
| Routine logging | Poor | Too expensive for high-frequency events |

**Cost estimate:** ~$0.001-0.005 per invocation (single turn, small context). At 50 invocations/session: ~$0.05-0.25/session.

### 4. Agent Hooks

```json
{
  "type": "agent",
  "agent": "Verify that the proposed file changes don't break any existing tests. Run the relevant test suite and report results.",
  "timeout": 60
}
```

**How it works:** Spawns a Claude subagent with tool access. The agent can read files, run commands, and make decisions. Its final response is the hook output.

**Pros:** Full Claude intelligence + tool access, can investigate complex scenarios, self-verifying.
**Cons:** Highest cost (multi-turn agent), highest latency (10-60+ seconds), unpredictable execution time.

**CAST Use Cases:**
| Use Case | Fit | Notes |
|---|---|---|
| Pre-commit verification | Good | Run tests, check for secrets, validate schema |
| Security review on sensitive files | Good | Full analysis before allowing writes to auth/env files |
| Architecture enforcement | Moderate | Verify import patterns, dependency rules |
| Routine telemetry | Poor | Way too expensive and slow |

**Cost estimate:** ~$0.05-0.50 per invocation (multi-turn agent). Use sparingly.

## Decision Matrix

| Use Case | Command | HTTP | Prompt | Agent |
|---|---|---|---|---|
| Telemetry/logging | Best | Good | - | - |
| cast.db writes | Best | - | - | - |
| Dashboard updates | Good | Best | - | - |
| Policy enforcement | Good | - | Best | - |
| Security gates | Good | - | Good | Best |
| Pre-commit checks | Good | - | - | Good |
| Context recovery | - | - | Best | - |
| External webhooks | - | Best | - | - |
| Complex verification | - | - | - | Best |

## Recommendations for CAST

### Convert to HTTP Hooks
1. **PostToolUse dashboard notification** — already partially done in PostCompact. Extend to send all PostToolUse events to `localhost:3001/api/hook-events` for real-time dashboard updates.
2. **External alerting** — add HTTP hooks for critical events (BLOCKED status, permission denials) to Slack/Discord webhooks.

### Add Prompt Hooks
1. **Security-sensitive PreToolUse** — for Write/Edit to files matching `**/auth/**`, `**/.env*`, `**/credentials*`, add a prompt hook: "Evaluate whether this file change could expose secrets or weaken authentication."
2. **PostCompact context recovery** — already in place, keep it.

### Add Agent Hooks (Sparingly)
1. **Pre-push verification** — before pushing to main, run an agent hook that executes the test suite and verifies no regressions. Only for direct pushes to main (not feature branches).

### Keep as Command Hooks
- All telemetry and logging hooks (cast-audit, cast-session-start, cast-db-log)
- All cost tracking hooks (cast-cost-tracker, cast-budget-alert)
- All task lifecycle hooks (cast-task-created, cast-task-completed)
- The teammate-idle hook (needs filesystem access and fast response)

## Implementation Priority

1. **HTTP hooks for dashboard** (low cost, immediate value)
2. **Prompt hook for security-sensitive files** (moderate cost, high value)
3. **Agent hook for pre-push** (high cost, use only on main branch pushes)

## Cost Summary

Assuming a typical session (100 tool calls, 5 security-relevant, 1 push):
- Current (all command): ~$0 additional cost
- With HTTP hooks: ~$0 additional (network only)
- With 5 prompt hooks: ~$0.01-0.025 per session
- With 1 agent hook: ~$0.05-0.50 per push
- **Total incremental:** ~$0.06-0.53 per session (worst case)
