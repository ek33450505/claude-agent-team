## Description

<!-- What does this PR do? Why? Link the issue it closes if applicable. -->

## Type of Change

- [ ] New agent
- [ ] New hook script
- [ ] CLI change (`bin/cast`)
- [ ] Bug fix
- [ ] Docs only
- [ ] Refactor
- [ ] CI / workflow

## Pre-Merge Checklist

- [ ] `bats tests/` passes locally (run `make test-ubuntu` for cross-platform Ubuntu parity check)
- [ ] New shell scripts have BATS test coverage in `tests/`
- [ ] If adding a new agent: frontmatter complete (`name`, `description`, `tools`, `model`, `effort`), added to `CLAUDE.md` registry and `CHEATSHEET.md`
- [ ] If adding a new hook script: wired in `settings.json`, script exists in `scripts/`, CI setup step in `bats-ci.yml` copies it
- [ ] README badge NOT manually edited — auto-syncs on merge to `main`
- [ ] No `find tests/ -name "*.bats"` — use `git ls-files tests/*.bats` for test counts
- [ ] No hardcoded absolute paths — use `$HOME` or `~/`
- [ ] `CHANGELOG.md` updated for any user-visible change
