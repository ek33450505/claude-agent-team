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
