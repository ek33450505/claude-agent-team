# Working Conventions

## Planning
- Run `planner` before any non-trivial change
- Tasks should be 15-30 min of work max; break larger work into smaller chunks
- Each logical unit gets its own commit

## Code quality
- YAGNI: build only what was asked
- DRY: find existing patterns before inventing new ones
- TDD: write failing tests before implementation for logic-heavy tasks
- Run `code-reviewer` after every meaningful code change

## Testing
- Tests live alongside source: `src/components/Foo.jsx` → `src/components/Foo.test.jsx`
- Test behavior, not implementation — prefer `getByRole`/`getByText` over `getByTestId`
- Cover: happy path, edge cases, error states

## SQL / Data
- Always use `db-reader` for read-only exploration
- Write optimized queries with filters and comments for complex logic
- For BigQuery: use `bq query` CLI

## Commits
- Commit message format: imperative mood, concise (`Add feature X`, `Fix bug in Y`)
- Never amend published commits

## Context Management
- Watch for the "dumb zone" — quality degrades when context reaches ~50% compaction
- Use `/compact` manually before hitting the zone, or `/clear` and start fresh
- For large tasks: break into sub-sessions, use `/rename` + `/resume`
- Use Esc Esc or `/rewind` to undo mistakes instead of fixing in same context
- Commit at least hourly during implementation sessions
