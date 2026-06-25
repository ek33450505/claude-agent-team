---
paths:
  - "tests/**"
  - "**/*.bats"
---

# Test File Conventions

- All shell tests use BATS (Bash Automated Testing System)
- Test assertions on `wc -l` output: use `$(wc -l < file)` (redirected form) to avoid macOS whitespace issues
- Numeric comparisons: strip whitespace with `| tr -d ' '` before comparing
- Each test file maps to one script in `scripts/` or `bin/`
- Use `@test "description" { ... }` blocks — one assertion focus per block
- Load helpers from `tests/test_helper.bash` when available
- Do NOT mock external dependencies in tests that must catch real integration failures
- HARD RULE (added 2026-06-02): any test touching $HOME or ~/.claude MUST isolate via temp HOME (`setup_temp_home`/`teardown_temp_home` from tests/helpers/setup.bash). Tests operating on the real $HOME wiped the live runtime on 2026-06-02 and cause the recurring CI tests/hooks failures.
- HARD RULE: any test invoking a script that may emit a desktop notification, play a sound, or open a URL/app (osascript, notify-send, terminal-notifier, open) MUST PATH-shim that surface with a no-op stub in setup(). Tests must produce zero real GUI side effects — the GUI analogue of the temp-HOME isolation rule.
