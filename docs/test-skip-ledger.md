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

---

## Remaining Intentional Skips

| File | # Skips | Reason | Category | Un-skip Condition |
|------|---------|--------|----------|------------------|
| `tests/cast-keychain.bats` | 2 | macOS Keychain is macOS-only; write tests skip on non-Darwin or when Keychain writes are unavailable/headless (timed out) | Environment (platform) | Runs automatically on an interactive macOS with Keychain access |
| `tests/install-personal.bats` | 2 | `agents/personal/` archived in v7 Phase 4.5 (portfolio-sync agent removed); directory does not exist | Conditional (archived feature) | Un-skip when a personal-overlay agent is re-added to the codebase |
| `tests/agents/effort-frontmatter.bats` | 1 | Same as above — `agents/personal/` absent | Conditional (archived feature) | Same as above |
| `tests/cast-encrypt.bats` | 2 | `age` binary not installed in CI environment | Environment (optional dependency) | Install `age` in CI and confirm 2 tests pass (not yet verified); or leave as honest optional-dep skip |
| `tests/test_cast_memory_persistence.bats` | 1 | SQLite FTS5 module not available | Environment (sqlite build) | Runs where sqlite3 has FTS5 (macOS system sqlite, Ubuntu apt sqlite both include it); CI runners may lack FTS5 in older sqlite versions |
| `tests/cast-session-start-journal.bats` | 1 | Requires actual journal entries in `~/Documents/Claude/` directory | Environment (real vault) | Could be un-skipped by seeding a fixture vault under the temp HOME (not yet implemented) |
| `tests/cast-precompact-guard.bats` | 1 | Guards bash 3.2 compat code path; skips if `/bin/bash` unavailable | Environment (interpreter) | Runs wherever `/bin/bash` exists (virtually all macOS and Linux systems) |
| `tests/skills/deep-research.bats` | 1 | Network-free regression harness for deep-research skill (PR #133); requires `node` binary | Environment (optional dependency) | Runs where `node` is installed (GitHub CI runners include it; development machines with Node) |

---

## Principle

A skip is acceptable only when its reason is recorded and its un-skip condition is clearly stated. A skip with no rationale is indistinguishable from silent coverage loss — the same "absence-of-a-check masquerading as a pass" failure mode the honesty principle targets.

Three categories of skips exist:

1. **Permanent (deprecated feature):** The skip codifies that a feature is intentionally removed. The tests remain as documentation of prior behavior. Un-skipping requires resurrecting the feature itself.
2. **Conditional (archived path):** The skip gates a feature on a path that may be re-created. The tests are live documentation of expected behavior when the path returns. Un-skipping happens when the path re-appears.
3. **Environment (platform, build, or external tool):** The skip documents a capability gap in the test harness — a tool is missing, a platform is unsupported, or a build configuration lacks a feature. Un-skipping requires closing that gap.

For each skip in this ledger, check the category: if it's "Environment," the skip is a signal that the test harness could be hardened. If it's "Permanent" or "Conditional," the skip is documentation of intentional product decisions.

See also: `docs/honesty-feature.md` for the broader principle.

