## Summary

-
-

## Type of Change

- [ ] New agent
- [ ] New route
- [ ] Hook change
- [ ] Bug fix
- [ ] Docs only
- [ ] Refactor

## Pre-Merge Checklist

- [ ] `make test` passes
- [ ] `make docs` run and README.md committed with updated counts
- [ ] New agent: frontmatter complete (`name`, `description`, `tools`, `model`)
- [ ] New agent: emits `task_claimed` event in Step 0
- [ ] New agent: outputs structured `Status:` block as final response
- [ ] New routing pattern: test case added to `tests/route.bats`
- [ ] No hardcoded paths (use `$HOME` or `~/`)
- [ ] `CHANGELOG.md` updated for user-visible changes
