# Managed Agent Shim Audit

Audited: `scripts/cast-managed-agent.sh`
Date: 2026-05-06

## Implemented

- **Agent define (Step 1):** `POST /v1/agents` — sends agent name, model, system prompt, tool spec. Extracts `id` from response.
- **Environment create (Step 2):** `POST /v1/environments` — sends `agent_id`, `type: "default"`. Extracts `id`.
- **Session create (Step 3):** `POST /v1/sessions` — sends `agent_id`, `environment_id`, `title`. Emits response to stdout.
- **cast.db telemetry:** `_write_telemetry()` writes to `managed_agent_invocations` table via `scripts/cast_db.py`. Uses single-quoted heredoc (PYTELEMETRY) — correct.
- **Auth error handling:** HTTP 401/403 always fail-closed even when `--local-fallback` is set.
- **Logging:** Per-invocation log at `~/.claude/logs/managed-agent-invocations.log`.
- **`--define-only` flag:** Stops after Step 1, emits raw response.
- **`--fork` flag:** Sets `CLAUDE_CODE_FORK_SUBAGENT=1` in environment.

## Missing

- **SSE Streaming:** Session response is collected synchronously with `--silent --fail-with-body`. No `Accept: text/event-stream` header. Output arrives only after the entire session completes (or fails), not progressively. The `--no-stream` counterpart flag doesn't exist because streaming isn't implemented at all.
- **`agent_runs` table write:** Only `managed_agent_invocations` is written. The `agent_runs` table (which `cast status` and `cast budget` read for cost/run counts) is never populated for managed dispatches. This means managed runs are invisible to the main cost/activity views.
- **Error classification:** All non-auth errors are treated identically. No distinction between transient network failures (worth retrying) vs. API-level errors (4xx non-auth). No retry logic.
- **Task summary capture:** No mechanism to parse agent output and extract a summary for telemetry.
- **Model field in telemetry:** `managed_agent_invocations` records the http_status and exit_code but not which model was used.

## Keychain Fallback

Works. The script checks `security find-generic-password -s anthropic-api-key -w` before failing on missing `ANTHROPIC_API_KEY`. The mock `security` binary in BATS tests correctly overrides this. The keychain path is guarded with `|| true` so a missing keychain entry doesn't abort the script.

## `--local-fallback` Path

When any `_curl_step` call returns exit code 2 (set by the fallback branch in `_curl_step`), the caller exits 0 after writing telemetry. This means: if the Managed Agents API is unreachable, the script silently succeeds without dispatching the task locally. The name is misleading — it doesn't actually dispatch the agent locally; it just swallows the error and exits 0. A true local fallback would call the Claude Code agent tool or another local dispatch mechanism, which doesn't exist yet.
