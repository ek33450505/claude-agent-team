# Working Conventions

> Operational/recovery procedures (worktree recovery, multi-terminal coordination, post-push CI checks, branch grooming, workflow closures) live in `docs/operational-playbook.md`.

## Planning
- Run `planner` before any non-trivial change
- Tasks: 15-30 min max; break larger work into chunks
- Each logical unit gets its own commit

## Code Quality
- YAGNI: build only what was asked
- DRY: find existing patterns before inventing new ones
- TDD: write failing tests before implementation for logic-heavy tasks
- Scope discipline: every change traces to the request. Fix a trivial bug only in a file you are ALREADY editing for the task — never open another file to "tidy" it; no "while I'm here" edits.
- Out-of-scope or non-trivial findings: SURFACE, do not fix without an OK. Agents flag via `DONE_WITH_CONCERNS` (the Status `Concerns` field); the main session raises it to the user. (Surgical HARD RULES in `bash-specialist`/`commit` stay stricter — this does not loosen them.)
- MANDATORY: `code-reviewer` after every logical unit of changes
- MANDATORY: Never `git commit` directly — use the `commit` agent
- MANDATORY: Route errors to `debugger` agent, not inline triage
- MANDATORY: Code-modifying agents attempt to self-dispatch `code-reviewer` via the Agent tool; when nesting depth prevents it, they emit DONE_WITH_CONCERNS and the orchestrator dispatches code-reviewer instead
- MANDATORY: All agents end with Status: `DONE` | `DONE_WITH_CONCERNS` | `BLOCKED` | `NEEDS_CONTEXT`

## Agent Selection
- `researcher` (sonnet): deep investigation, external sources, recommendations
- `Explore` subagent: fast codebase navigation, file/grep searches

## Agent Turn Limits (maxTurns)
- Every CAST agent has a `maxTurns` frontmatter cap (natively enforced by Claude Code). Hitting it stops the agent SILENTLY mid-task: no Status/Handoff block, no SubagentStop hook fire, and the `agent_runs` row stays stuck in `running` (discovered 2026-06-10, crosscheck_2.0 help-docs migration).
- A SendMessage resume grants a fresh turn budget — but scope dispatch prompts to fit the cap instead of relying on resumes. Implementation class: code-writer 80, test-writer 50, debugger 50; most others 15–25.
- Symptom of a hit cap: agent's final message ends mid-sentence (e.g. "Now let me run the tests:") with no Status line. Treat as truncation, not completion — never relay it as done.
- For tasks that legitimately need more turns (large migrations, multi-file sweeps), split into smaller dispatches rather than raising caps further — the cap is a runaway-loop guard.

## Parallel Dispatch
- `test-runner` (and any process-killing / test-executing agent) MUST run in its OWN sequential batch. It MUST NEVER share a `"parallel": true` batch or a dispatch-group wave with any other agent — most critically the review agents (`code-reviewer`, `security`, `frontend-qa`).
- Reason: `test-runner`'s suite-timeout/kill path can reap co-scheduled sibling processes — a co-scheduled `code-reviewer` was killed this way on 2026-06-14. Isolating `test-runner` in its own batch keeps the kill blast radius to itself.

## Testing
- Tests alongside source: `Foo.jsx` -> `Foo.test.jsx`
- Test behavior (`getByRole`/`getByText`), not implementation
- Cover: happy path, edge cases, error states
- A new gate (lint, hook, CI check) isn't done until probed on its REAL default path: plant a violation, run with no env overrides, watch it bite. Passing only via the test/override path is false green (blast-radius lint scanned 0 files and exited 0, 2026-06-12).
- New BATS files using `date`/`stat`/`sed` get a Docker Ubuntu pass before push, not just macOS — BSD/GNU flag divergence (e.g. BSD-only `date -v`) breaks CI (2026-06-12).

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

## Branch Naming
- Before starting any phase/feature work, verify the current branch matches the phase name (e.g., Phase C3 work must land on feature/c3-*, not feature/c2-*).
- When orchestrating a new phase, explicitly create and checkout the correctly-named branch FIRST before any edits or agent dispatches.

## Stat/Fact Verification
- Before writing any public-facing content (LinkedIn, README, dev.to articles, announcements) that cites project stats (agent counts, test counts, line counts), verify numbers against the actual repo state — do not rely on memory or prior session context.

## Memory Verification

- Auto-memory entries that name a wired hook, registered route, or flag-gated feature must be verified on disk before being relied on for new work. Memory records intent and snapshots; reality is the file system and live config.
- When recommending action based on a memory entry that names a specific function/path/script, grep or stat the target first. "The memory says X exists" is not the same as "X exists now."
- Bug class context: 2026-05-05 — a 3-week-old auto-memory said `SessionStart read hook added 2026-04-26` but the hook had never been wired. The intent was recorded; the wiring step never happened. The memory was honest about what it observed.
