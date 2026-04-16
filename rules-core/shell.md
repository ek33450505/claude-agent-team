---
globs:
  - "**/*.sh"
  - "**/*.bats"
---

# Shell Script Conventions

- All scripts: `set -euo pipefail` after guards
- CAST hooks: check `CLAUDE_SUBPROCESS` guard first, exit 0 for subprocesses
- Error logging: `_log_error()` function writing to `~/.claude/logs/hook-errors.log`
- Read stdin: `INPUT="$(cat 2>/dev/null || true)"` — never fail on empty stdin
- Hook output: use `hookSpecificOutput` JSON format for structured feedback
- Exit codes: 0 = pass/continue, 2 = block (PreToolUse hooks only)
- BATS tests: use `@test` annotations, `setup()` and `teardown()` for fixtures
- BATS assertions: prefer `assert_output`, `assert_success`, `assert_failure`
- ShellCheck clean: no warnings in CI
- Quote all variables: `"$var"` not `$var`
- Use `[[ ]]` for conditionals, not `[ ]`
