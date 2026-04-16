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

## Worktree Workflow
- DO NOT use git worktrees for parallel agent work unless explicitly requested. Worktree-based agent dispatches have repeatedly lost changes, overwritten good files with stale versions, and required manual recovery.
- If parallelization is needed, prefer sequential edits on the main branch or explicitly confirm the worktree strategy with the user first.
- Always verify agent-reported file changes by reading the files after the agent completes.

## Branch Naming
- Before starting any phase/feature work, verify the current branch matches the phase name (e.g., Phase C3 work must land on feature/c3-*, not feature/c2-*).
- When orchestrating a new phase, explicitly create and checkout the correctly-named branch FIRST before any edits or agent dispatches.

## Post-Push CI Verification
- After pushing commits that could affect CI, check for hardcoded absolute paths, platform-specific modules (e.g., FTS5 on macOS runners), and stale version lookups after package renames.
- Run the test suite locally with CI-equivalent paths before pushing when possible.

## Stat/Fact Verification
- Before writing any public-facing content (LinkedIn, README, dev.to articles, announcements) that cites project stats (agent counts, test counts, line counts), verify numbers against the actual repo state — do not rely on memory or prior session context.
