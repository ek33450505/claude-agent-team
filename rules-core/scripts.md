---
paths:
  - "scripts/**"
  - "bin/**"
---

# Script File Conventions

- Python scripts: use stdlib only unless the task spec explicitly allows pip installs
- DB access: always use `os.environ.get('CAST_DB_PATH', os.path.expanduser('~/.claude/cast.db'))` for path resolution
- Exit codes: 0 = success, 1 = error; print errors to stderr, results to stdout
- Idempotency: migration scripts must be safe to run multiple times (check before CREATE/ALTER)
- All new scripts written here must ALSO be committed to the repo `scripts/` directory — never write only to `~/.claude/scripts/`
- Hook scripts that emit events: use `cast_emit_event` from `~/.claude/scripts/cast-events.sh`
- JSON output scripts: always emit valid JSON even on error (`{"error": "..."}`)
