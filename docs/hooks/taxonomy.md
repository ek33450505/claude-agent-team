# CAST Hook Taxonomy

## Gate vs Observability vs Routing

- **(a) GATE** — Fires on PreToolUse or PreCompact; may block the operation. Exit code 2 (PreToolUse) or `{"decision":"block"}` JSON body (PreCompact) stops execution. These are hard safety rails. Do NOT add `async: true` to gate hooks.
- **(b) OBS (Observability)** — Always exits 0; logs, records metrics, or emits warnings to cast.db or the event stream. Never blocks. May use `async: true` when latency matters.
- **(c) ROUTING** — Rewrites or intercepts the operation (e.g., injects a default answer, delegates to another script). Exits 0 but changes what Claude does next.

---

## Classification Table

| Script | Event | Exit-2 gate? | Class | Wired? |
|---|---|---|---|---|
| `pre-tool-guard.sh` | PreToolUse (Bash) | YES — blocks git commit/push/stash + policy violations | **(a) GATE** | YES |
| `cast-audit-hook.sh` | PreToolUse (Write/Edit) | Conditional — exits 2 only when PII redact=on + cloud-bound | **(a) GATE** (conditional) + **(b) OBS** | YES |
| `cast-headless-guard.sh` | PreToolUse (AskUserQuestion) | NO — exit 0, injects safe default answer | **(c) ROUTING** | YES |
| `cast-stat-claim-guard.sh` | PreToolUse (Write/Edit) | YES — blocks README badges with wrong test counts | **(a) GATE** | YES |
| `cast-tilde-write-guard.sh` | PreToolUse (Write/Edit) | YES — blocks literal-tilde path writes | **(a) GATE** | YES |
| `cast-no-fake-success-guard.sh` | PreToolUse (Write/Edit) | NO — exit 0, emits warn only | **(b) OBS** | YES (async) |
| `cast-precompact-guard.sh` | PreCompact | NO exit 2 — returns `{"decision":"block"}` JSON | **(a) GATE** (native PreCompact protocol) | YES |
| `cast-precompact-memory-save.sh` | PreCompact | exit 0 | **(b) OBS** | YES |
| `cast-response-completeness-hook.sh` | SubagentStop | exit 0 | **(b) OBS** | YES |
| `cast-subagent-stop-hook.sh` | SubagentStop | exit 0 | **(b) OBS** | YES |
| `cast-code-ref-guard.sh` | (CLI only — see below) | exit 0 | **(b) OBS** | NOT WIRED |
| `post-tool-hook.sh` | PostToolUse (Write/Edit/Agent/Bash) | exit 0 (delegates to cast-post-tool.py) | **(c) ROUTING** | YES |
| `cast-budget-alert.sh` | PostToolUse | exit 0 | **(b) OBS** | YES |
| `cast-tool-failure-hook.sh` | PostToolUseFailure | exit 0 | **(b) OBS** | YES |
| `cast-session-start-hook.sh` | SessionStart | exit 0 | **(b) OBS** | YES |
| `cast-session-start-journal.sh` | SessionStart | exit 0 | **(b) OBS** | YES |
| `cast-time-context-hook.sh` | SessionStart | exit 0 | **(b) OBS** | YES |
| `cast-user-prompt-hook.sh` | UserPromptSubmit | exit 0 | **(b) OBS** | YES |
| `cast-journal-session-end.sh` | Stop | exit 0 | **(b) OBS** | YES |
| `cast-session-end.sh` | Stop + SessionEnd | exit 0 | **(b) OBS** | YES |
| `cast-stop-failure-hook.sh` | StopFailure | exit 0 | **(b) OBS** | YES |
| `cast-subagent-start-hook.sh` | SubagentStart | exit 0 | **(b) OBS** | YES |
| `cast-cwdchanged-hook.sh` | CwdChanged | exit 0 | **(b) OBS** | YES |
| `cast-filechanged-hook.sh` | FileChanged | exit 0 | **(b) OBS** | YES |
| `cast-post-compact-hook.sh` | PostCompact | exit 0 | **(b) OBS** | YES |
| `cast-instructions-loaded-hook.sh` | InstructionsLoaded | exit 0 | **(b) OBS** | YES |
| `cast-task-created-hook.sh` | TaskCreated | exit 0 | **(b) OBS** | YES |

---

## Deferred / Experimental

`TaskCompleted` and `TeammateIdle` events require the experimental **Agent Teams** flag. No quality gates depend on these events today. All gate work against these events is deferred until Agent Teams reaches GA. Do not add hooks targeting these events to the live runtime.

---

## No-op Findings

- **`bin/cast` has no hook runner.** The roadmap item "remove custom hook runner from bin/cast" is a confirmed no-op. All hooks are wired natively via `managed-settings.d/*.json` fragments.
- **No gates to retire.** All wired gates are correct and non-overlapping. The roadmap item "retire 5-8 quality gates" found no candidates.
- **`cast-code-ref-guard.sh` is CLI-only.** Called as `echo "$output" | bash scripts/cast-code-ref-guard.sh`. Not a hook; intentionally not wired. The header comment in the script documents this explicitly.
