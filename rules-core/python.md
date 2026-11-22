---
globs:
  - "**/*.py"
---
<!-- DUAL-KEEP v8-A1 -> python-conventions skill (see docs/v8-a1-rules-migration.md) -->

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
