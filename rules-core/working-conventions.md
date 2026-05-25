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

## Accessibility (UI projects)
- Every icon-only button/link gets `aria-label`; decorative icons get `aria-hidden="true"`
- Visible `:focus-visible` state on every interactive element — never rely on browser default rings on dark themes
- Color contrast ≥ 4.5:1 for text and meaningful icons
- Hit target ≥ 44×44 px on touch surfaces
- Form inputs have `<label>`, `autoComplete`, and `aria-describedby` for errors
- Animation respects `prefers-reduced-motion` via `useReducedMotion()` or CSS media query
- Semantic HTML first (`<button>`, `<a>`, `<nav>`, `<main>`); ARIA only when semantic HTML is insufficient
- Keyboard navigation works end-to-end — logical tab order, modal focus trap, Escape closes overlays
- Applies on first pass, not as a later sweep. Dispatch `frontend-qa` for a dedicated a11y review before commit on UI-heavy changes.

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

## Memory Verification

- Auto-memory entries that name a wired hook, registered route, or flag-gated feature must be verified on disk before being relied on for new work. Memory records intent and snapshots; reality is the file system and live config.
- When recommending action based on a memory entry that names a specific function/path/script, grep or stat the target first. "The memory says X exists" is not the same as "X exists now."
- Bug class context: 2026-05-05 — a 3-week-old auto-memory said `SessionStart read hook added 2026-04-26` but the hook had never been wired. The intent was recorded; the wiring step never happened. The memory was honest about what it observed.

## Branch & Worktree Hygiene

- **Grooming policy:**
  - `cast-swarm-*` branches older than 7 days with no open PR are candidates for deletion.
  - `worktree-agent-*` branches older than 7 days are candidates for deletion.
  - `feature/*` and `fix/*` branches that are merged into `main` AND whose remote tracking ref is `[gone]` are candidates for deletion.
- **Hard whitelist (never deleted):** `main`, `feat/*`, `feature/cast-v7-*`, any branch currently checked out in a worktree.
- **Manual usage:**
  - `cast clean` — dry-run preview (default, no changes made)
  - `cast clean --apply` — delete stale branches
  - `cast clean --apply --worktrees` — delete stale branches and prune dead worktree directories
- **Weekly automated dry-run report:** `scripts/cast-branch-groomer-schedule.sh` writes a dated report to `~/.claude/reports/branch-grooming-<date>.md`. Review the report, then run `cast clean --apply` when ready.
- **Hard rule:** Any agent or skill that creates a branch or worktree MUST clean up on success. The groomer is a safety net, not the primary cleanup mechanism. Orphaned branches from failed or abandoned agent runs must be cleaned manually.
- **CI contract validation:** The `hook-contract-validation` job in `.github/workflows/bats-ci.yml` validates `hookSpecificOutput` format. Non-spec output is a hard CI fail — fix before pushing.

## Phase 5b — Workflow Closures

- **Auto mode:** `defaultMode: "auto"` is set but has a session-start bug — use `--permission-mode auto` until upstream fixes it.
- **Routines:** Prefer `/schedule` over local cron for scheduled CAST jobs.
- **Forked subagents:** Use `scripts/cast-managed-agent.sh <agent> <prompt> --fork` to spawn agents on Anthropic infrastructure with `CLAUDE_CODE_FORK_SUBAGENT=1` set. This replaces worktree isolation for parallel work — Managed Agents isolate execution on cloud infrastructure, eliminating filesystem contention. Cannot spawn sub-subagents — no nested orchestration.
- **Task Budgets:** Opus 4.7 API beta only — no Claude Code surface yet; revisit when GA.
