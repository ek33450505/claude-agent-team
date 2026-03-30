## Summary

-
-

## Type of Change

- [ ] New agent
- [ ] New hook change
- [ ] CLI subcommand added/changed
- [ ] Bug fix
- [ ] Docs only
- [ ] Refactor

## Pre-Merge Checklist

- [ ] `tests/bats/bin/bats tests/` runs without new failures (excluding known-skip list)
- [ ] `cast validate` passes
- [ ] `cast doctor` shows no new ERRORs
- [ ] New agent: frontmatter complete (`name`, `description`, `tools`, `model`)
- [ ] New agent: emits `task_claimed` event in Step 0
- [ ] New agent: outputs structured `Status:` block as final response
- [ ] New agent: added to `install.sh` copy list
- [ ] New hook: wired in `~/.claude/settings.json` template and `install.sh`
- [ ] `CHANGELOG.md` updated for user-visible changes
- [ ] No hardcoded paths (use `$HOME` or `~/`)
