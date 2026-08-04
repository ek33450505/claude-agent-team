# Good First Issue Drafts — CAST
**Date:** 2026-05-04
**Scope:** 8 issues to seed a contribution backlog and lower the bar for first-time contributors.
**Status:** DRAFT — review before running `gh issue create`.

---

## Issue 1: Add 13 missing agents to the CHEATSHEET agents table

**Labels:** `good first issue`, `documentation`
**Estimated time:** 20 min

The `CHEATSHEET.md` agents table lists 16 agents but `agents/core/` ships 29. Thirteen newer agents — `adr-writer`, `api-contract`, `dep-auditor`, `email-drafter`, `knowledge-curator`, `learning-scout`, `meeting-prep`, `migration-reviewer`, `perf-sentinel`, `pr-narrator`, `release-notes`, `standup-writer`, and `task-triage` — were added after the table was written and never backfilled. This means anyone reading the cheatsheet as a quick reference has no idea these agents exist.

**What to change:** Open `CHEATSHEET.md` and add one row per missing agent to the `## Agents` table. The table columns are `Agent | Model | Effort | Key Tools | Description`. Populate each column from the corresponding agent file in `agents/core/<name>.md` — the frontmatter fields `model`, `effort`, and `tools` map directly, and the `description` field gives you the one-liner. Keep rows in alphabetical order.

**Where to look:**
- `CHEATSHEET.md` — the table to update (line ~34)
- `agents/core/<name>.md` — source of truth for each agent's metadata

**Acceptance criteria:**
- All 29 agents in `agents/core/` appear as rows in the `## Agents` table.
- Each new row follows the existing column format exactly (no extra columns, same pipe style).
- `make docs` (or a quick manual diff) shows no other changes — this PR touches only `CHEATSHEET.md`.
- No row is duplicated.
- Rows are sorted alphabetically by agent name.

---

## Issue 2: Fix stale cross-reference to `docs/agent-quality-rubric.md` in CONTRIBUTING.md

**Labels:** `good first issue`, `documentation`
**Estimated time:** 10 min

`CONTRIBUTING.md` (line 69) tells contributors to see `docs/agent-quality-rubric.md` for how agents are evaluated, but that file lives at `docs/agents/agent-quality-rubric.md`. Anyone who clicks the path or tries to open it directly gets a 404. It is a small but confidence-destroying mistake for a first-time contributor who is trying to follow the guide.

**What to change:** In `CONTRIBUTING.md`, update the single reference from `docs/agent-quality-rubric.md` to `docs/agents/agent-quality-rubric.md`. Optionally add it as a Markdown link so it is clickable on GitHub: `[docs/agents/agent-quality-rubric.md](docs/agents/agent-quality-rubric.md)`.

**Where to look:**
- `CONTRIBUTING.md` line 69 — the stale reference
- `docs/agents/agent-quality-rubric.md` — the actual file (verify it exists before submitting)

**Acceptance criteria:**
- The corrected path resolves to a real file when browsed on GitHub.
- `CONTRIBUTING.md` has no other path references to the old location.
- No other files are changed.
- The fix passes `make test` (pre-commit hook re-stages README if needed; no test failures expected for a doc-only change).

---

## Issue 3: Add BATS tests for `cast-agent-color.sh`

**Labels:** `good first issue`, `tests`, `bash`
**Estimated time:** 25 min

`scripts/cast-agent-color.sh` is a pure case-statement lookup (agent name → ANSI color code) that is sourced by `cast-statusline.sh` and other display scripts. It has zero test coverage. Because it has no I/O or side effects, it is one of the easiest scripts in the repo to test — you source it and assert on the output of `get_agent_color`.

**What to change:** Create `tests/cast-agent-color.bats` with at least four `@test` cases:
1. A known agent (`code-writer`) returns the expected ANSI sequence (`\033[38;5;208m`).
2. A second known agent (`debugger`) returns the correct sequence.
3. An unknown agent name returns the reset sequence (`\033[0m`).
4. `get_agent_color_reset` returns the reset sequence regardless of input.

Look at `tests/cast-stats.bats` for the BATS test header pattern (`load 'test_helper/bats-support/load'`, `REPO_DIR` resolution, `setup`/`teardown`). No mocked HOME or temp dirs are needed — the script is stateless.

**Where to look:**
- `scripts/cast-agent-color.sh` — the script under test (39 lines, pure functions)
- `tests/cast-stats.bats` — reference test for BATS header/structure
- `tests/test_helper/` — shared BATS helpers already present

**Acceptance criteria:**
- `tests/cast-agent-color.bats` is a new file containing at least 4 `@test` cases.
- All tests pass when run with `bats tests/cast-agent-color.bats`.
- The test file loads `bats-support` and `bats-assert` from `test_helper/`.
- `make test` remains green (no regressions).

---

## Issue 4: Add BATS tests for `cast-budget-alert.sh` (no-db path)

**Labels:** `good first issue`, `tests`, `bash`, `python`
**Estimated time:** 30 min

`scripts/cast-budget-alert.sh` has no test coverage despite being a hook that fires after every cost-tracking event. The script has a well-defined fast exit: if `$CAST_DB_PATH` points to a non-existent file, it exits 0 silently. This makes two edge cases straightforward to test without needing a real SQLite database: the missing-db path and the no-budget-configured path.

**What to change:** Create `tests/cast-budget-alert.bats` with at least three `@test` cases:
1. When `CAST_DB_PATH` points to a file that does not exist, the script exits 0 and produces no output.
2. When a SQLite DB exists but has no `budgets` table row, the script exits 0 and produces no output.
3. When a DB exists with a daily budget row and today's spend exceeds 80% of the limit, the script prints a string containing `[CAST-BUDGET-WARN]`.

For cases 2 and 3, use `python3 -c "import sqlite3, os; ..."` in the `setup()` to create a minimal in-memory SQLite file. Export `CAST_DB_PATH` to point at the temp file. Pattern follows `tests/cast-db.bats`.

**Where to look:**
- `scripts/cast-budget-alert.sh` — script under test (114 lines)
- `tests/cast-db.bats` — reference for SQLite fixture setup in BATS
- `tests/cast-stats.bats` — reference for `setup`/`teardown` with temp `$HOME`

**Acceptance criteria:**
- `tests/cast-budget-alert.bats` contains at least 3 `@test` cases covering the three scenarios above.
- All tests pass with `bats tests/cast-budget-alert.bats`.
- Test fixture creates and cleans up a real SQLite file (no mocks of the DB library).
- `make test` remains green.

---

## Issue 5: Add `--help` flag to `cast-validate.sh`

**Labels:** `good first issue`, `bash`, `help wanted`
**Estimated time:** 20 min

`scripts/cast-validate.sh` is one of the first scripts a new user runs (`cast validate` calls it) and it has 11 named checks, but there is no `--help` flag. Running it with an unexpected argument produces an unrelated error. A brief `--help` output describing what each of the 11 checks does would let contributors understand the tool without reading the source.

**What to change:** Add a `--help` / `-h` branch near the top of `cast-validate.sh`, before the check logic runs. It should print a short usage block to stdout and exit 0. Model the style after the comment block already at the top of the file (lines 2–9). The text should name all 11 checks, note exit codes (0=all green, 1=warnings, 2=errors), and show `Usage: cast validate [--help]`.

**Where to look:**
- `scripts/cast-validate.sh` — the script to edit (check lines 1–25 for argument handling)
- `scripts/cast-notify.sh` lines 29–33 — example of existing `--help`-style message in a peer script

**Acceptance criteria:**
- `bash scripts/cast-validate.sh --help` exits 0 and prints usage text to stdout.
- `bash scripts/cast-validate.sh -h` produces the same output.
- The normal `cast validate` flow (no flags) is unchanged — all 11 checks still run.
- Usage text lists all 11 checks by name.
- `make test` remains green.

---

## Issue 6: Add `--help` flag to `cast-notify.sh`

**Labels:** `good first issue`, `bash`
**Estimated time:** 15 min

`scripts/cast-notify.sh` already prints a usage hint when called with no arguments (lines 32–33), but it does not handle `--help` or `-h` as explicit flags. Running `cast-notify.sh --help` currently falls through to the event-type dispatch and prints a confusing error. The four event types (`blocked`, `queue_complete`, `budget_alert`, `briefing_ready`) and the three positional args deserve a proper help screen.

**What to change:** Add a guard near the top of `cast-notify.sh` (after the subprocess guard, before line 27) that checks if `$1` is `--help` or `-h`. If so, print the usage block from the existing comment header (lines 8–15) and exit 0. The usage text already exists in the file header — just echo it.

**Where to look:**
- `scripts/cast-notify.sh` — the script to edit (lines 27–35 for the argument section)
- The comment block at lines 7–15 is the canonical usage text to print

**Acceptance criteria:**
- `bash scripts/cast-notify.sh --help` exits 0 and prints usage to stdout.
- `bash scripts/cast-notify.sh -h` produces the same output.
- `bash scripts/cast-notify.sh` (no args) still prints the short usage hint to stderr and exits 0 (existing behavior unchanged).
- All existing `cast-notify.bats` tests (if present) continue to pass.
- `make test` remains green.

---

## Issue 7: Add color entries for the 13 agents missing from `cast-agent-color.sh`

**Labels:** `good first issue`, `bash`, `agent`
**Estimated time:** 20 min

`scripts/cast-agent-color.sh` maps agent names to ANSI 256-color codes for terminal display. It covers 16 of the 29 core agents. The 13 newer agents — `adr-writer`, `api-contract`, `dep-auditor`, `email-drafter`, `knowledge-curator`, `learning-scout`, `meeting-prep`, `migration-reviewer`, `perf-sentinel`, `pr-narrator`, `release-notes`, `standup-writer`, `task-triage` — all fall through to the `*)` reset case, which means they display as plain white in the status line and any color-aware output. Fixing this makes the terminal experience consistent for all agents.

**What to change:** In `scripts/cast-agent-color.sh`, add one `<agent-name>)  code="38;5;NNN" ;;` line per missing agent inside the `case "$agent" in` block (lines 11–31). Pick visually distinct ANSI 256-color codes that don't clash with the 16 already assigned. A reference chart: https://en.wikipedia.org/wiki/ANSI_escape_code#8-bit. Keep alphabetical order within the block is not required, but grouping by role (communication agents together, quality agents together) is appreciated.

**Where to look:**
- `scripts/cast-agent-color.sh` — the case block at lines 11–31
- `agents/core/<name>.md` — each agent's `color:` frontmatter field (e.g., `dep-auditor` has `color: yellow`) can guide your choice

**Acceptance criteria:**
- All 29 agents in `agents/core/` have an explicit entry in the case block (the `*)` catch-all should no longer match any known agent name).
- Running `source scripts/cast-agent-color.sh && get_agent_color adr-writer` prints a non-empty, non-reset escape sequence.
- No two agents share the same color code.
- The existing BATS test `tests/cast-agent-color.bats` passes (file created in Issue 3 — if that issue hasn't landed yet, manually source and spot-check three of the new entries).
- `make test` remains green.

---

## Issue 8: Add empty-state copy to the dashboard Sessions page when no data exists

**Labels:** `good first issue`, `documentation`, `help wanted`
**Estimated time:** 25 min

> **Note:** This issue targets the sister repo `ek33450505/claude-code-dashboard`, not `claude-agent-team`. File it there.

The Sessions page (`src/views/SessionsView.tsx`) currently shows the text "No sessions found" when the database has no rows. This is technically correct but gives new users no guidance on what to do next — they don't know if CAST is misconfigured, if they need to run a session first, or if the dashboard is pointing at the wrong database. A short contextual message with a next-step hint would meaningfully reduce confusion.

**What to change:** In `src/views/SessionsView.tsx`, locate the two places where `'No sessions found'` is rendered (lines ~314 and ~400). For the non-search case (no `searchQuery` and no `projectFilter`), replace the plain text with a two-line message: the existing "No sessions found" heading, plus a subtitle such as "Run `claude` to start a session — it will appear here automatically." Keep the search/filter case as-is ("No matching sessions") since that already explains the situation.

**Where to look:**
- `src/views/SessionsView.tsx` lines ~310–320 and ~396–404 — the two empty-state render paths
- Existing `"No agents running"` text in `src/views/AgentsView.tsx` line ~310 — reference for the component pattern already in use

**Acceptance criteria:**
- When Sessions has no rows and no active filter, the page displays a subtitle hint about running `claude`.
- The search/filter empty state ("No matching sessions") is unchanged.
- The change is purely presentational — no API calls, no state changes.
- The page renders without TypeScript errors (`npm run build` clean).
- Visual inspection: subtitle text is smaller/muted compared to the heading (use an existing muted text class from the file).
