---
globs:
  - "**/*.py"
---

# Python Conventions

- Stdlib only unless task spec allows pip installs
- DB access: use `scripts/cast_db.py` abstraction (`db_write`, `db_query`, `db_execute`)
- DB path: `os.environ.get('CAST_DB_PATH', os.path.expanduser('~/.claude/cast.db'))`
- Error handling: catch specific exceptions, log to `~/.claude/logs/`, never crash the hook pipeline
- Schema changes: use `CREATE TABLE IF NOT EXISTS` and `ALTER TABLE ... ADD COLUMN` with try/except for idempotency
- Stdin parsing: `json.loads(os.environ.get("CAST_INPUT", ""))` pattern with try/except
- Use f-strings for string formatting
- Type hints on function signatures where practical
- No global state — each script execution is independent
