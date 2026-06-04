# claude-agent-team (CAST)

## Install

```bash
bash install.sh
```

Requires clean working tree in `agents/`, `scripts/`, `bin/`, `rules-core/` — install aborts on uncommitted changes. Bypass with `CAST_INSTALL_FORCE=1` (CI only).

## Test

```bash
bash tests/run.sh
```

**HARD RULE:** Run only against an isolated temp HOME, never against real `~/.claude`. A test targeting real `$HOME` destroyed the live runtime on 2026-06-02. Phase 3.8.A destructive test is not yet fixed — do not run the full suite against real `$HOME` until it is.

## Run

```bash
cast status   # health check after install
```

## Non-obvious

- `agents/core/` holds the 23 canonical agent definitions — edit there, then reinstall.
- `.claude/` at repo root is a runtime install artifact (output of `install.sh`), not a config location for development.
- `CAST_DB_PATH` overrides the default SQLite path (`~/.claude/cast.db`).
- `CAST_COMMIT_AGENT=1` escape-hatch prefix allows raw `git commit` when the commit agent is unavailable.
