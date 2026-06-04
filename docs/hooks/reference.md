# CAST Hook Reference

One row per hook that ships in `settings.json`. See `authoring-guide.md` for the protocol if you want to write your own.

## SessionStart hooks (3)

| Script | Matcher | What it does |
|---|---|---|
| `cast-session-start-hook.sh` | `*` | Writes CAST env vars to `$CLAUDE_ENV_FILE` and logs session start to `session-starts.jsonl`. |
| `cast-time-context-hook.sh` | `*` | Injects local date/time/timezone context into Claude's context window via `hookSpecificOutput`. |
| `cast-session-start-journal.sh` | `*` | Injects the most recent dated journal entry from the Obsidian vault at session start. |

## UserPromptSubmit hooks (1)

| Script | Matcher | What it does |
|---|---|---|
| `cast-user-prompt-hook.sh` | `*` | Logs prompt metadata (never full text) to `user-prompts.jsonl` and `cast.db routing_events`. |

## PostToolUseFailure hooks (1)

| Script | Matcher | What it does |
|---|---|---|
| `cast-tool-failure-hook.sh` | `*` | Logs tool failure metadata to `tool-failures.jsonl` and `cast.db routing_events`. |

## PostToolUse hooks (2)

| Script | Matcher | What it does |
|---|---|---|
| `post-tool-hook.sh` | `Write\|Edit\|Agent\|Bash` | Delegates to `cast-post-tool.py` — logs file modifications to cast.db and emits HTTP events to the dashboard. |
| `cast-budget-alert.sh` | `*` | Reads today's total spend from `sessions` and emits `[CAST-BUDGET-WARN]` or `[CAST-BUDGET-HARD-LIMIT]` when thresholds are crossed. |

## InstructionsLoaded hooks (1)

| Script | Matcher | What it does |
|---|---|---|
| `cast-instructions-loaded-hook.sh` | `*` | Logs active `CLAUDE.md` files at session start to `instructions-loaded.jsonl`. |

## PreToolUse hooks (6)

| Script | Matcher | What it does |
|---|---|---|
| `cast-audit-hook.sh` | `Write\|Edit` | Appends an audit record (tool name, file path, command hash) to `audit.jsonl`; when PII redaction is enabled, conditionally blocks cloud-bound writes containing PII (exit 2). |
| `cast-headless-guard.sh` | `AskUserQuestion` | Auto-responds to `AskUserQuestion` with a safe default to prevent pipeline stalls in headless runs. |
| `cast-stat-claim-guard.sh` | `Write\|Edit` | Blocks `README.md` writes when the badge test count differs from the actual `git ls-files` count. |
| `cast-no-fake-success-guard.sh` | `Write\|Edit` | Warns (never blocks) when try/catch blocks return sample/fake/mock data that could mask integration failures. |
| `pre-tool-guard.sh` | `Bash` | Blocks `git commit`, `git push`, and `git stash` calls (and other policy violations) in agent sessions (exit 2). |
| `cast-tilde-write-guard.sh` | `Write\|Edit` | Blocks writes to literal-tilde paths (e.g. `~/foo`) that would resolve incorrectly in non-interactive contexts (exit 2). |

## CwdChanged hooks (1)

| Script | Matcher | What it does |
|---|---|---|
| `cast-cwdchanged-hook.sh` | `*` | Logs cwd changes to `cast.db` and exports `CAST_REPO_CLASS` from the new directory's `cast.json`. |

## FileChanged hooks (1)

| Script | Matcher | What it does |
|---|---|---|
| `cast-filechanged-hook.sh` | `.envrc\|.env\|.cast\|cast.json` | Logs changes to environment and CAST config files to `cast.db` via `cast-events.sh`. |

## PreCompact hooks (2)

| Script | Matcher | What it does |
|---|---|---|
| `cast-precompact-guard.sh` | `*` | Blocks auto-compaction if any tracked repo is dirty; manual `/compact` always passes through. |
| `cast-precompact-memory-save.sh` | `*` | Saves a snapshot of the conversation summary before compaction (owner-only permissions). |

## Stop hooks (2)

| Script | Matcher | What it does |
|---|---|---|
| `cast-journal-session-end.sh` | `*` | Prompts for a per-date journal note in the Obsidian vault on session close. |
| `cast-session-end.sh` | `*` | Runs all CAST session-end cleanup: hook-health marker, blocked-response escalation, memory auto-init, and project board refresh. |

## SessionEnd hooks (1)

| Script | Matcher | What it does |
|---|---|---|
| `cast-session-end.sh` | `*` | Same consolidated cleanup script as the `Stop` entry above; registered for both events. |

## SubagentStart hooks (1)

| Script | Matcher | What it does |
|---|---|---|
| `cast-subagent-start-hook.sh` | `*` | Emits a `task_claimed` event and inserts a running row into `cast.db agent_runs` when a subagent starts. |

## SubagentStop hooks (2)

| Script | Matcher | What it does |
|---|---|---|
| `cast-subagent-stop-hook.sh` | `*` | Emits `task_completed` or `task_blocked` and updates `cast.db agent_runs`; logs turn-ceiling events when detected. |
| `cast-response-completeness-hook.sh` | `*` | Checks every subagent response for a valid `Status:` block and logs missing ones as truncation warnings. |

## StopFailure hooks (1)

| Script | Matcher | What it does |
|---|---|---|
| `cast-stop-failure-hook.sh` | `*` | Logs stop-failure events to `cast.db` and fires a macOS desktop notification when a subagent fails due to API errors or rate limits. |

## PostCompact hooks (1)

| Script | Matcher | What it does |
|---|---|---|
| `cast-post-compact-hook.sh` | `*` | Logs context compaction events to `cast/events/` and `compact-log.jsonl` (observability only). |

## TaskCreated hooks (1)

| Script | Matcher | What it does |
|---|---|---|
| `cast-task-created-hook.sh` | `*` | Logs background agent task creation events to `cast/events/` and `cast.db`. |

## How hooks get installed

Running `install.sh` at the repo root copies all scripts in `scripts/` to `~/.claude/scripts/`, installs the `managed-settings.d/*.json` fragments, and regenerates `~/.claude/settings.json` from those fragments via `cast-merge-settings.sh`. To add or remove a hook, edit (or add) a fragment in `managed-settings.d/` and re-run `install.sh` — do not hand-edit `settings.json` directly, as it is a generated artifact and will be overwritten on the next install.
