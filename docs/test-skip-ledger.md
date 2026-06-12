# BATS Test Skip Ledger

This ledger makes every intentional test skip explicit, recording why it exists and the condition under which it would be un-skipped. The CAST test suite runs against an isolated temp HOME (see `tests/run.sh`), never the real `~/.claude` — that isolation is mandatory to prevent destructive operations from touching the live runtime.

A skip without a recorded rationale is indistinguishable from lost coverage — the same "absence-of-a-check masquerading as a pass" failure mode that the honesty principle targets. This document ensures every gap in coverage is intentional and auditable.

---

## Resolved This Session (2026-06-08 batch)

| File | Issue | Resolution |
|------|-------|-----------|
| `cast-keychain.bats` | `security add-generic-password` probe could hang ~9 min on macOS Keychain GUI auth prompt | Wrapped probe in 5-second timeout via `_kc_run_with_timeout()` (line 15–39); degrades to clean skip in non-interactive/CI contexts; runs normally when Keychain is available and authorized |
| `cast-swarm-bootstrap.bats` / `cast-swarm-teardown.bats` | Skipped in GitHub CI job when `python3 -c "import yaml"` failed (pyyaml missing) | Added `python3-yaml` to the CI job's apt install; both test suites now run (8/8 pass, 0 skips) |
| `pre-commit.bats` | 4 tests had dead `\|\| skip "Hook output mismatch"` guard that would silently skip on regression | Converted to real `assert_output --partial` assertions (15/15 pass, 0 skips) |

### 2026-06-11 batch (Phase 8 test-suite lean)

| File | Issue | Resolution |
|------|-------|-----------|
| `tests/scripts/cast-memory-backup.bats` | Row removed — file was deleted in v7.5 Phase 6 when the stub was removed (prerequisite for un-skip satisfied; tests archived with the feature) | Ledger entry removed; test file no longer exists |
| `tests/skills/deep-research.bats` | New conditional skip added for the network-free deep-research regression harness (PR #133 honesty fix) | Requires `node` for harness execution; skip at line 19 degrades gracefully in non-Node environments; runs in GitHub CI (node included) and on development machines with Node installed |

### 2026-06-12 batch (foundation-tail audit)

| File | Issue | Resolution |
|------|-------|-----------|
| `tests/cast-db-contract.bats:58` | `\|\| skip "db-contract --update-baseline failed"` masked contract-script regressions (if `--update-baseline` broke, tests silently skipped instead of failing) | Converted to hard `if ! …; then false; fi` — `--update-baseline` failure is now a test failure |
| `tests/cast-db-contract.bats:100` | Same regression-masking skip in test 4 (desktop-absent baseline path) | Same hard-failure conversion |

---

## Remaining Intentional Skips

**Total call sites: 18** across 12 files (as of 2026-06-12 post-foundation-tail fix).

Note: a single `setup()`-level skip gates every `@test` in a file with one call. Those are marked **[setup-level]** and the gated test count is noted — a single ledger line represents multiple suppressed tests.

| File | Line | # Tests Gated | Reason | Category | Un-skip Condition |
|------|------|--------------|--------|----------|------------------|
| `tests/cast-swarm-bootstrap.bats` | 12 | ~8 **[setup-level]** | `pyyaml` not available — setup() bails before any test can run | Environment (optional dependency) | pyyaml available in environment; `python3 -c "import yaml"` succeeds |
| `tests/cast-swarm-teardown.bats` | 13 | ~8 **[setup-level]** | Same pyyaml guard in setup() | Environment (optional dependency) | Same as above |
| `tests/cast-session-start-journal.bats` | 15 | ~all **[setup-level]** | Requires actual journal entries in `~/Documents/Claude/`; setup() skips if absent | Environment (real vault) | Could be un-skipped by seeding a fixture vault under the temp HOME (not yet implemented) |
| `tests/cast-encrypt.bats` | 46 | 1 | `age` binary not installed | Environment (optional dependency) | Install `age` in CI and confirm test passes |
| `tests/cast-encrypt.bats` | 63 | 1 | `age` binary not installed | Environment (optional dependency) | Same as above |
| `tests/cast-keychain.bats` | 48 | 1 | macOS Keychain is macOS-only; skips on non-Darwin | Environment (platform) | Runs automatically on macOS |
| `tests/cast-keychain.bats` | 62 | 1 | Keychain writes unavailable (headless/CI or auth-prompt timed out) | Environment (platform) | Runs on interactive macOS with Keychain access granted |
| `tests/teardown-guard.bats` | 58 | 1 | Sentinel `.cast-test-home` not created by `setup_temp_home` — guards a positive-path teardown test | Conditional (harness state) | Fires automatically when `setup_temp_home` creates the sentinel correctly |
| `tests/teardown-guard.bats` | 61 | 1 | HOME not under a recognized temp prefix (`/tmp/`, `/private/tmp/`, `/var/folders/`, `/private/var/folders/`) — guards prefix validation test | Conditional (harness state) | Fires when HOME is correctly set to a temp path by the harness |
| `tests/teardown-guard.bats` | 64 | 1 | Temp HOME directory not created — guards existence check | Conditional (harness state) | Fires when temp HOME is created successfully |
| `tests/teardown-guard.bats` | 123 | 1 | Cannot create a non-temp test directory (helper `_make_non_temp_home` failed) | Environment (runtime) | Passes when the helper can create a directory outside recognized temp prefixes |
| `tests/test_cast_memory_persistence.bats` | 27 | 1 | SQLite FTS5 module not available | Environment (sqlite build) | Runs where sqlite3 has FTS5 (macOS system sqlite, Ubuntu apt sqlite both include it); older CI sqlite versions may lack FTS5 |
| `tests/cast-session-end.bats` | 301 | 1 | `read -t 0` unavailable on bash <4; open-pipe guard not active on this runtime | Environment (interpreter version) | Runs on bash 4+ (most Linux CI runners; macOS ships bash 3.2) |
| `tests/cast-precompact-guard.bats` | 125 | 1 | Guards bash 3.2 compat code path; skips if `/bin/bash` unavailable | Environment (interpreter) | Runs wherever `/bin/bash` exists (virtually all macOS and Linux systems) |
| `tests/install-personal.bats` | 60 | 1 | `agents/personal/` archived in v7 Phase 4.5 (portfolio-sync agent removed); directory does not exist | Conditional (archived feature) | Un-skip when a personal-overlay agent is re-added to the codebase |
| `tests/install-personal.bats` | 86 | 1 | Same — `agents/personal/` absent | Conditional (archived feature) | Same as above |
| `tests/agents/effort-frontmatter.bats` | 147 | 1 | `agents/personal/` absent (same Phase 4.5 archive) | Conditional (archived feature) | Same as above |
| `tests/skills/deep-research.bats` | 19 | 1 | Network-free regression harness requires `node` binary | Environment (optional dependency) | Runs where `node` is installed (GitHub CI runners include it; development machines with Node) |

---

## Principle

A skip is acceptable only when its reason is recorded and its un-skip condition is clearly stated. A skip with no rationale is indistinguishable from silent coverage loss — the same "absence-of-a-check masquerading as a pass" failure mode the honesty principle targets.

Three categories of skips exist:

1. **Permanent (deprecated feature):** The skip codifies that a feature is intentionally removed. The tests remain as documentation of prior behavior. Un-skipping requires resurrecting the feature itself.
2. **Conditional (archived path):** The skip gates a feature on a path that may be re-created. The tests are live documentation of expected behavior when the path returns. Un-skipping happens when the path re-appears.
3. **Environment (platform, build, or external tool):** The skip documents a capability gap in the test harness — a tool is missing, a platform is unsupported, or a build configuration lacks a feature. Un-skipping requires closing that gap.

For each skip in this ledger, check the category: if it's "Environment," the skip is a signal that the test harness could be hardened. If it's "Permanent" or "Conditional," the skip is documentation of intentional product decisions.

See also: `docs/honesty-feature.md` for the broader principle.
