# claude-agent-team (CAST)

## Install

```bash
bash install.sh
```

Requires clean working tree in `agents/`, `scripts/`, `bin/`, `rules-core/` — install aborts on uncommitted changes. Bypass with `CAST_INSTALL_FORCE=1` (CI only).

## Test

```bash
bash tests/run.sh                 # Run the full BATS suite (isolated temp HOME)
make ci-local                     # Run real GitHub Actions CI locally via act
```

**HARD RULE:** Run only against an isolated temp HOME, never against real `~/.claude`. The suite's teardown deletes its HOME-scoped fixtures, so it must run only against an isolated temp HOME — never your real `~/.claude`. Use the `setup_temp_home` / `teardown_temp_home` helpers in `tests/helpers/setup.bash`.

`tests/test_helper/bats-support` and `tests/test_helper/bats-assert` are git submodules — on a fresh clone, run `git submodule update --init --recursive` first or `tests/run.sh` will refuse to start.

The `make ci-local` target (also: `cast ci-local`) runs `hook-contract-validation` (`scripts/cast-validate-all-hooks.sh --source`) and `python-unit` (`python3 -m unittest discover -s tests -p 'test_*.py' -v`) directly, BEFORE the act loop, then runs the remaining 8 PR-gating workflows (bats, stats-guard, rules-drift, readme-structure, pii-scan, shellcheck, db-contract, self-lints) via `act`. Requires `act` and Docker. Dropped from the act loop: `contract-test` (advisory-only by construction — `|| true` + `continue-on-error: true` in bats-ci.yml, provides no enforcement signal); `hook-contract-validation` (real gate, run directly and BEFORE the loop so a later act-job failure can't silently skip it — it declares `needs: bats`, so under act it re-ran the full BATS suite as a dependency); and `python-unit` (PyYAML is absent from the act image `catthehacker/ubuntu:act-latest` but present on GitHub's `ubuntu-latest`, so it fails under act for a reason unrelated to real regressions — run directly as the workflow's exact command instead). Excluded from act: gitleaks (needs live GITHUB_TOKEN), bats-macos (no macOS runner in act), bats-ubuntu (duplicates bats).

## Run

```bash
cast status   # health check after install
```

## Non-obvious

- `agents/core/` holds the 27 canonical agent definitions — edit there, then reinstall.
- `.claude/` at repo root is a runtime install artifact (output of `install.sh`), not a config location for development.
- `CAST_DB_PATH` overrides the default SQLite path (`~/.claude/cast.db`).
- `CAST_COMMIT_AGENT=1` escape-hatch prefix allows raw `git commit` when the commit agent is unavailable.
- `tools/justfile` is the canonical source for the `just -g <recipe>` cost/trend recipes; `install.sh` delivers it to `~/.config/just/justfile`. Unlike every other install step this one **overwrites** (backing up first, and aborting if the backup fails) — skip-if-exists is what previously meant a merged fix never reached the live file. Cost/trend recipes read the `agent_runs_daily` rollup, so the CURRENT day is partial until the nightly rollup runs; each prints a `rollup_age`.
