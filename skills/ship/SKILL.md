# Ship Skill

Codifies the test → CI-safety-check → commit → push → journal loop.

## Steps

1. **Run full test suite** — for CAST repos: `bash tests/run.sh` (isolated temp HOME — NEVER `bats tests/` on real $HOME). For Node repos: `npm test`. Abort if any test fails. Do NOT proceed to commit if tests are red.

2. **Pre-push CI sanity check** — run `bash ~/.claude/scripts/pre-push-ci-check.sh` and review output. Fix any findings before pushing. The script checks for:
   - Hardcoded `/Users/` absolute paths in test files
   - Platform-specific imports that won't work on Linux CI (FTS5, macOS-only modules)
   - Stale `version()` or package name references after renames

3. **Stage and commit** — dispatch `commit` agent. Do not use raw `git commit`.

4. **Push** — dispatch `push` agent.

5. **Write journal entry** — reflect on what shipped, any surprises, and what the next session should pick up. Write to `~/Documents/Claude/YYYY-MM/YYYY-MM-DD.md` — create today's per-date note inside this month's folder (Write tool; mkdir -p the month folder if missing). Start with a `# <Month Day, Year>` heading.

## Usage

Invoke with: `/ship` or include "run the ship workflow" in your prompt.

## Guard Rails

- Never skip the test step, even for "trivial" changes
- Never skip the CI sanity check before push
- If push agent returns sandbox errors, re-run with `dangerouslyDisableSandbox: true` per known limitation
