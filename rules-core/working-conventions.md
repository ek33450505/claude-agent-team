# Working Conventions

## Planning
- Run `planner` before any non-trivial change
- Tasks: 15-30 min max; break larger work into chunks
- Each logical unit gets its own commit

## Code Quality
- YAGNI: build only what was asked
- DRY: find existing patterns before inventing new ones
- TDD: write failing tests before implementation for logic-heavy tasks
- MANDATORY: `code-reviewer` after every logical unit of changes
- MANDATORY: Never `git commit` directly — use the `commit` agent
- MANDATORY: Route errors to `debugger` agent, not inline triage
- MANDATORY: Code-modifying agents self-dispatch `code-reviewer` internally
- MANDATORY: All agents end with Status: `DONE` | `DONE_WITH_CONCERNS` | `BLOCKED` | `NEEDS_CONTEXT`

## Agent Selection
- `researcher` (sonnet): deep investigation, external sources, recommendations
- `Explore` subagent: fast codebase navigation, file/grep searches

## Testing
- Tests alongside source: `Foo.jsx` -> `Foo.test.jsx`
- Test behavior (`getByRole`/`getByText`), not implementation
- Cover: happy path, edge cases, error states

## SQL / Data
- `db-reader` for read-only exploration
- Optimized queries with filters; BigQuery via `bq query` CLI

## Commits
- MANDATORY: Use `commit` agent — never raw `git commit`
- Imperative mood, concise (`Add feature X`, `Fix bug in Y`)

## Context Management
- Compact at ~60% context (before "dumb zone" at ~70%)
- `/compact` to summarize; `/clear` + `/resume` for fresh start
- Commit before compacting — compact discards tool output history
- Commit at least hourly during implementation sessions
- Run `/usage` periodically to monitor token spend; cost data feeds the monthly review process
- Run `/cost` after long sessions for per-model + cache-hit breakdown (complements `/usage`).
- `CLAUDE_CODE_SCRIPT_CAPS=100` is set in settings.json — caps per-session script invocations to prevent runaway agent loops.

## MCP + Cost

- `mcpServers` wired in `settings.json` — github MCP available in all sessions
- `/cost` after long sessions for per-model + cache-hit breakdown
- `/usage` periodically for token spend monitoring
- All three feed the monthly cost re-evaluation cadence

## Worktree Recovery
- `code-writer`, `debugger`, `test-writer`, `security`, and `frontend-qa` no longer auto-isolate into git worktrees (`isolation: worktree` removed from frontmatter). The agent runs in the orchestrator's working tree.
- A `SubagentStop` detection hook (`cast-subagent-worktree-check.sh`) fires after every dispatch of these agents. If the harness still spawns a worktree as a side effect, the hook auto-removes it when clean (banner: `✓ AGENT-WORKTREE CLEANUP`) and escalates when dirty (banner: `⚠ AGENT-WORKTREE DETECTED (DIRTY)`). All anomalies log to `cast.db worktree_anomalies`.
- If the dirty banner appears, copy the listed files from the worktree path to the active branch, then `git worktree remove --force --force <path>`.
- Always verify agent-reported file changes by reading the files after the agent completes.

## Multi-Terminal Coordination

When running more than one terminal on the same repo simultaneously:

- **Explicit stage lists:** Never use `git add -A` or `git add .` — always stage by explicit file path. This prevents Terminal B from committing files that Terminal A is mid-edit on.
- **Pull before push:** `git pull --rebase origin <branch>` before every push. If the rebase fails, resolve; never force-push shared history.
- **Pre-commit status check:** Run `git status` immediately before staging to surface any cross-stream artifacts (unexpected modifications or untracked files from the other terminal's agent work).
- **Sequential push order is the proven safe pattern:** Finish Terminal A's entire commit chain, push it, then Terminal B rebases and pushes. Parallel pushes to the same branch cause race-condition overwrites.
- **Parallel research dispatches are safe:** Read-only agent work (researcher, code-reviewer) can run in parallel across terminals without coordination. Writes must be sequential.
- **No cross-terminal agent scope overlap:** If Terminal A owns a file, Terminal B agents must not touch it, even to "fix" adjacent issues. Scope creep from one terminal's agents is the primary cause of mid-session reverts.

## Branch Naming
- Before starting any phase/feature work, verify the current branch matches the phase name (e.g., Phase C3 work must land on feature/c3-*, not feature/c2-*).
- When orchestrating a new phase, explicitly create and checkout the correctly-named branch FIRST before any edits or agent dispatches.

## Post-Push CI Verification
- After pushing commits that could affect CI, check for hardcoded absolute paths, platform-specific modules (e.g., FTS5 on macOS runners), and stale version lookups after package renames.
- Run the test suite locally with CI-equivalent paths before pushing when possible.

## Stat/Fact Verification
- Before writing any public-facing content (LinkedIn, README, dev.to articles, announcements) that cites project stats (agent counts, test counts, line counts), verify numbers against the actual repo state — do not rely on memory or prior session context.

## Phase 5b — Workflow Closures

- **Auto mode:** `defaultMode: "auto"` is set but has a session-start bug — use `--permission-mode auto` until upstream fixes it.
- **Routines:** Prefer `/schedule` over local cron for scheduled CAST jobs.
- **Forked subagents:** Cannot spawn sub-subagents — no nested orchestration.
- **Task Budgets:** Opus 4.7 API beta only — no Claude Code surface yet; revisit when GA.
