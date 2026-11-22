---
name: python-conventions
description: Python and shell-script conventions for CAST projects. Load when writing, reviewing, or debugging Python scripts, hook scripts, or files under scripts/ or bin/. Covers stdlib-only policy, DB access patterns, exit codes, idempotency, stdin parsing, and hook script conventions.
user-invocable: false
allowed-tools: []
---

# Python Conventions

- Stdlib only unless task spec allows pip installs
- DB access: use `scripts/cast_db.py` abstraction (`db_write`, `db_query`, `db_execute`)
- DB path: `os.environ.get('CAST_DB_PATH', os.path.expanduser('~/.claude/cast.db'))`
- Error handling: catch specific exceptions, log to `~/.claude/logs/`, never crash the hook pipeline
- Schema changes: use `CREATE TABLE IF NOT EXISTS` and `ALTER TABLE ... ADD COLUMN` with try/except for idempotency
- Hook payload: read it from stdin (`json.loads(sys.stdin.read())`), or from fd 3 when a heredoc owns stdin (bash `3< <(printf '%s' "$INPUT")`, Python `os.fdopen(3)`), with try/except. Never pass it in an env var: Linux caps one env string at 128 KiB, so large payloads fail with E2BIG and are silently dropped.
- Use f-strings for string formatting
- Type hints on function signatures where practical
- No global state — each script execution is independent

## Script File Conventions

- Python scripts: use stdlib only unless the task spec explicitly allows pip installs
- DB access: always use `os.environ.get('CAST_DB_PATH', os.path.expanduser('~/.claude/cast.db'))` for path resolution
- Exit codes: 0 = success, 1 = error; print errors to stderr, results to stdout
- Idempotency: migration scripts must be safe to run multiple times (check before CREATE/ALTER)
- All new scripts written here must ALSO be committed to the repo `scripts/` directory — never write only to `~/.claude/scripts/`
- Hook scripts that emit events: use `cast_emit_event` from `~/.claude/scripts/cast-events.sh`
- JSON output scripts: always emit valid JSON even on error (`{"error": "..."}`)
