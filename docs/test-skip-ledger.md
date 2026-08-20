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

**Total call sites: 76** across 30 files (as of 2026-07-04 full re-enumeration; prior count of 23 across 14 files was under-counted — missed `cast-ask.bats` FTS5/JSON cluster, `cast-doctor-ask.bats`, `cast-doctor-honesty.bats`, `cast-doctor-litestream.bats`, `cast-commit-reconcile.bats`, `run-sh-count-gate.bats`, `install.bats`, and the two extra `install-personal.bats` sites. +2 same-day: `cast-pretool-dispatch-guardfail.bats` interpreter guards, added with the py3.9 hook-compat fixes; +1 2026-07-05: `cast-incident-record.bats` subprocess-guard skip, W2-1 consolidation; +3 2026-07-09: `cast-record-review.bats` (new file, B5) — 2 real-cast.db-required guards + 1 eval-case-fixture-not-found guard; +6 2026-07-10: `cast-otel-collector.bats` (3 HTTP-daemon-start guards) + `cast-overlay-sync.bats` (3 empty-clone-identity guards, incl. the GH007-regression test found in the follow-up pass) — GH macOS runner incompatibilities, v9.5.2; +6 2026-07-30: `cast-encrypt.bats` grew 2→8 `age`-guard skips with the Secure Enclave lockout fix (#348) — encrypt/decrypt round-trip, SE-stub, software/SE overwrite-guard, and 600/700 permission tests; +1 2026-08-04: `status-writer.bats` (new file) — 1 `zsh`-guard skip on the zsh read-only-`status` regression test, which runs on macOS/local where zsh ships and skips on ubuntu CI runners lacking zsh; +1 2026-08-14: `bash32-source-guard.bats` (new file) — 1 interpreter-version guard on the negative-control test that proves the bash 3.2 `source`-under-`set -e` fatality is real, which must skip on bash 4+ (Linux CI's `/bin/bash` is 5.x and correctly lacks the bug). Also corrected the *file* count, which had drifted 25→29 unnoticed because `skip-ledger-drift.bats` only enforces the call-site number, not the file number; +2 2026-08-20: `cast-rules-sync.bats` (new file, v10 Session F) — 2 root-guard skips on the fail-closed backup tests, which chmod a directory/file unwritable and must skip when running as root because chmod cannot block root. File count 29→30 for the same new file).

**Enumeration command** (run from repo root; catches all 4 skip forms: `|| skip "`, `&& skip "`, line-leading `skip "`, if-then inline `skip "`; excludes comment lines and the self-referential guard file):

```
grep -rEn '(\|\| skip "|&& skip "|[[:space:]]skip ")' tests/ --include="*.bats" \
  | grep -vF 'skip-ledger-drift.bats' \
  | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#'
```

A companion BATS guard (`tests/skip-ledger-drift.bats`) re-runs this command and fails if the actual count diverges from the number recorded in this document.

Note: a single `setup()`-level skip gates every `@test` in a file with one call. Those are marked **[setup-level]** and the gated test count is noted — a single ledger line represents multiple suppressed tests.

| File | Line | # Tests Gated | Reason | Category | Un-skip Condition |
|------|------|--------------|--------|----------|------------------|
| `tests/cast-session-start-journal.bats` | 15 | 6 **[setup-level]** | Requires actual journal entries in `~/Documents/Claude/`; setup() skips if absent | Environment (real vault) | Could be un-skipped by seeding a fixture vault under the temp HOME (not yet implemented) |
| `tests/test_cast_memory_persistence.bats` | 22 | 3 **[setup-level]** | SQLite FTS5 module not available; checked in setup() | Environment (sqlite build) | Runs where sqlite3 has FTS5 (macOS system sqlite, Ubuntu apt sqlite both include it); older CI sqlite versions may lack FTS5 |
| `tests/cast-ask.bats` | 67 | 1 | SQLite FTS5 module not available in this build | Environment (sqlite build) | Runs where sqlite3 has FTS5 |
| `tests/cast-ask.bats` | 92 | 1 | SQLite FTS5 module not available in this build | Environment (sqlite build) | Runs where sqlite3 has FTS5 |
| `tests/cast-ask.bats` | 121 | 1 | SQLite FTS5 module not available in this build | Environment (sqlite build) | Runs where sqlite3 has FTS5 |
| `tests/cast-ask.bats` | 142 | 1 | SQLite FTS5 module not available in this build | Environment (sqlite build) | Runs where sqlite3 has FTS5 |
| `tests/cast-ask.bats` | 167 | 1 | SQLite FTS5 module not available in this build | Environment (sqlite build) | Runs where sqlite3 has FTS5 |
| `tests/cast-ask.bats` | 203 | 1 | SQLite FTS5 module not available in this build | Environment (sqlite build) | Runs where sqlite3 has FTS5 |
| `tests/cast-ask.bats` | 227 | 1 | SQLite FTS5 module not available in this build | Environment (sqlite build) | Runs where sqlite3 has FTS5 |
| `tests/cast-ask.bats` | 249 | 1 | SQLite FTS5 module not available in this build | Environment (sqlite build) | Runs where sqlite3 has FTS5 |
| `tests/cast-ask.bats` | 270 | 1 | SQLite FTS5 module not available in this build | Environment (sqlite build) | Runs where sqlite3 has FTS5 |
| `tests/cast-ask.bats` | 284 | 1 | JSON structure check: `"name"` key absent in `cast memory search --json` output (earlier step failed to populate DB) | Conditional (prior step outcome) | Fires when DB population and `cast ask` command succeed; the skip guards against a confusing failure cascade when earlier assertions would already have caught the root issue |
| `tests/cast-ask.bats` | 285 | 1 | JSON structure check: `"content"` key absent | Conditional (prior step outcome) | Same as line 284 |
| `tests/cast-ask.bats` | 286 | 1 | JSON structure check: `"created_at"` key absent | Conditional (prior step outcome) | Same as line 284 |
| `tests/cast-ask.bats` | 303 | 1 | SQLite FTS5 module not available in this build | Environment (sqlite build) | Runs where sqlite3 has FTS5 |
| `tests/cast-ask.bats` | 324 | 1 | SQLite FTS5 module not available in this build | Environment (sqlite build) | Runs where sqlite3 has FTS5 |
| `tests/cast-ask.bats` | 335 | 1 | SQLite FTS5 module not available in this build | Environment (sqlite build) | Runs where sqlite3 has FTS5 |
| `tests/cast-ask.bats` | 348 | 1 | SQLite FTS5 module not available in this build | Environment (sqlite build) | Runs where sqlite3 has FTS5 |
| `tests/cast-ask.bats` | 363 | 1 | SQLite FTS5 module not available in this build | Environment (sqlite build) | Runs where sqlite3 has FTS5 |
| `tests/cast-doctor-ask.bats` | 74 | 1 | SQLite FTS5 module not available in this build | Environment (sqlite build) | Runs where sqlite3 has FTS5 |
| `tests/cast-doctor-ask.bats` | 88 | 1 | SQLite FTS5 module not available in this build | Environment (sqlite build) | Runs where sqlite3 has FTS5 |
| `tests/cast-doctor-ask.bats` | 111 | 1 | SQLite FTS5 module not available in this build | Environment (sqlite build) | Runs where sqlite3 has FTS5 |
| `tests/cast-encrypt.bats` | 60 | 1 | `age` binary not installed (encrypt-without-setup) | Environment (optional dependency) | Install `age` in CI and confirm test passes |
| `tests/cast-encrypt.bats` | 72 | 1 | `age` binary not installed (setup keypair) | Environment (optional dependency) | Same as above |
| `tests/cast-encrypt.bats` | 97 | 1 | `age` binary not installed (software-key overwrite guard) | Environment (optional dependency) | Same as above |
| `tests/cast-encrypt.bats` | 125 | 1 | `age` binary not installed (software-key 600/700 perms) | Environment (optional dependency) | Same as above |
| `tests/cast-encrypt.bats` | 153 | 1 | `age` binary not installed (SE overwrite guard) | Environment (optional dependency) | Same as above |
| `tests/cast-encrypt.bats` | 188 | 1 | `age` binary not installed (SE identity 600/700 perms) | Environment (optional dependency) | Same as above |
| `tests/cast-encrypt.bats` | 223 | 1 | `age` binary not installed (encrypt/decrypt round-trip) | Environment (optional dependency) | Same as above |
| `tests/cast-encrypt.bats` | 261 | 1 | `age` binary not installed (SE identity outside ~/.claude + `-i`) | Environment (optional dependency) | Same as above |
| `tests/cast-keychain.bats` | 48 | 1 | macOS Keychain is macOS-only; skips on non-Darwin | Environment (platform) | Runs automatically on macOS |
| `tests/cast-keychain.bats` | 62 | 1 | Keychain writes unavailable (headless/CI or auth-prompt timed out) | Environment (platform) | Runs on interactive macOS with Keychain access granted |
| `tests/teardown-guard.bats` | 58 | 1 | Sentinel `.cast-test-home` not created by `setup_temp_home` — guards a positive-path teardown test | Conditional (harness state) | Fires automatically when `setup_temp_home` creates the sentinel correctly |
| `tests/teardown-guard.bats` | 61 | 1 | HOME not under a recognized temp prefix (`/tmp/`, `/private/tmp/`, `/var/folders/`, `/private/var/folders/`) — guards prefix validation test | Conditional (harness state) | Fires when HOME is correctly set to a temp path by the harness |
| `tests/teardown-guard.bats` | 64 | 1 | Temp HOME directory not created — guards existence check | Conditional (harness state) | Fires when temp HOME is created successfully |
| `tests/teardown-guard.bats` | 123 | 1 | Cannot create a non-temp test directory (helper `_make_non_temp_home` failed) | Environment (runtime) | Passes when the helper can create a directory outside recognized temp prefixes |
| `tests/cast-session-end.bats` | 295 | 1 | `read -t 0` unavailable on bash <4; open-pipe guard not active on this runtime | Environment (interpreter version) | Runs on bash 4+ (most Linux CI runners; macOS ships bash 3.2) |
| `tests/cast-precompact-guard.bats` | 124 | 1 | Guards bash 3.2 compat code path; skips if `/bin/bash` unavailable | Environment (interpreter) | Runs wherever `/bin/bash` exists (virtually all macOS and Linux systems) |
| `tests/cast-integrity.bats` | 350 | 1 | `launchctl` command available on macOS; skip gates a Linux/CI-only test path that verifies INFO-skip behavior when launchctl is absent | Environment (platform) | Runs automatically on Linux systems without launchctl; manually testable on CI runners |
| `tests/cast-integrity.bats` | 366 | 1 | Same as above — `launchctl` present on macOS, test only meaningful on systems without it | Environment (platform) | Same as above |
| `tests/cast-doctor-litestream.bats` | 257 | 1 | `launchctl` present on macOS; this rung (daemon check skipped with INFO) is only reachable when launchctl is absent from PATH | Environment (platform) | Runs on Linux/CI runners where launchctl is not installed |
| `tests/install-launchctl-isolation.bats` | 23 | 1 | `launchd` is macOS-only; test requires Darwin to be meaningful | Environment (platform) | Runs automatically on macOS |
| `tests/install.bats` | 289 | 1 | macOS-only: launchd plist installation; test requires `uname == Darwin` | Environment (platform) | Runs automatically on macOS |
| `tests/install.bats` | 432 | 1 | `managed-settings-personal/12-otel.json` not present in repo (personal overlay not committed) | Conditional (optional file) | Fires when `managed-settings-personal/12-otel.json` is added to the repo |
| `tests/install-personal.bats` | 60 | 1 | `portfolio-sync` agent archived in v7 Phase 4.5; `agents/personal/` directory is empty | Conditional (archived feature) | Un-skip when a personal-overlay agent is re-added to the codebase |
| `tests/install-personal.bats` | 86 | 1 | Same — `agents/personal/` absent after Phase 4.5 archive | Conditional (archived feature) | Same as above |
| `tests/install-personal.bats` | 117 | 1 | `managed-settings-personal/12-otel.json` not present in repo | Conditional (optional file) | Fires when `managed-settings-personal/12-otel.json` is added to the repo |
| `tests/install-personal.bats` | 140 | 1 | `managed-settings-personal/12-otel.json` not present in repo | Conditional (optional file) | Same as above |
| `tests/cast-litestream-setup.bats` | 190 | 1 | plist source file (`macos/cast-litestream.plist`) not present in checkout — test validates plist structure but fixture is in version control | Conditional (fixture path) | Fires when `macos/cast-litestream.plist` exists in the repo (standard in all releases) |
| `tests/cast-litestream-verify.bats` | 173 | 1 | `litestream` binary not installed in environment | Environment (optional dependency) | Runs on systems with litestream installed; included in GitHub CI runners |
| `tests/cast-litestream-verify.bats` | 174 | 1 | `sqlite3` binary not installed in environment | Environment (optional dependency) | Runs on systems with sqlite3 installed (virtually all macOS and Linux systems) |
| `tests/cast-litestream-verify.bats` | 204 | 1 | Litestream did not create replica files within 3 seconds (environment timing/I/O slow) — test allows replica creation delay, skips if deadline not met | Conditional (environment timing) | Fires when litestream can create replica files within 3s on the test harness |
| `tests/cast-plugin-smoke.bats` | 185 | 1 | `claude` CLI command not available in environment | Environment (optional dependency) | Runs on systems with Claude CLI installed |
| `tests/cast-doctor-honesty.bats` | 342 | 1 | `chmod 000` unreadable simulation requires non-root; root bypasses file permission checks | Environment (privilege) | Runs as non-root (standard in CI and developer machines) |
| `tests/cast-doctor-honesty.bats` | 368 | 1 | Same — `chmod 000` unreadable simulation requires non-root | Environment (privilege) | Same as above |
| `tests/cast-doctor-honesty.bats` | 395 | 1 | Same — `chmod 000` unreadable simulation requires non-root | Environment (privilege) | Same as above |
| `tests/cast-commit-reconcile.bats` | 238 | 1 | `chmod 000` has no effect as root; test verifies permission-denied path | Environment (privilege) | Runs as non-root |
| `tests/run-sh-count-gate.bats` | 53 | 1 | `chmod 000` does not restrict root; unreadable-file scenario is untestable as root (if-then inline form) | Environment (privilege) | Runs as non-root |
| `tests/agents/effort-frontmatter.bats` | 147 | 1 | `agents/personal/` not present — archived in Phase 4.5.3 | Conditional (archived feature) | Un-skip when a personal-overlay agent is re-added |
| `tests/skills/deep-research.bats` | 19 | 1 | Network-free regression harness requires `node` binary | Environment (optional dependency) | Runs where `node` is installed (GitHub CI runners include it) |
| `tests/cast-pretool-dispatch-guardfail.bats` | 211 | 1 | py3.9-compat smoke test requires `/usr/bin/python3` (system interpreter); absent on Homebrew/nix-only runners | Environment (interpreter) | Runs where the macOS/Linux system python3 exists at `/usr/bin/python3` |
| `tests/cast-pretool-dispatch-guardfail.bats` | 220 | 1 | Same smoke test: `/usr/bin/python3` >= 3.10 makes PEP-604 natively valid — the annotation-crash regression is unobservable on that interpreter | Environment (interpreter) | Runs where `/usr/bin/python3` is < 3.10 (e.g. macOS system python 3.9.6, the environment that broke the guards on 2026-07-04) |
| `tests/cast-incident-record.bats` | (subprocess guard test) | 1 | `cast-incident-record.sh` had a `CLAUDE_SUBPROCESS=1` guard that exited early; the consolidated `cast-subagent-stop-hook.sh` has no such guard — SubagentStop fires in the parent session where `CLAUDE_SUBPROCESS` is never set (W2-1 consolidation, 2026-07-05) | Permanent (retired behavior) | Un-skip only if the SubagentStop hook re-gains a subprocess guard |
| `tests/cast-otel-collector.bats` | 330 | 1 | HTTP collector daemon never accepts connections on the GH macOS runner (start-poll timeout in `_start_collector_http`); attempt-first — only skips if the real start fails AND the GH-macOS env guard matches, so genuine regressions elsewhere still fail | Environment (CI runner) | Un-skip when the GH macOS runner's daemon-start timing is fixed or the runner is upgraded |
| `tests/cast-otel-collector.bats` | 367 | 1 | Same daemon-start failure, second HTTP test (malformed chunk-size) | Environment (CI runner) | Same as above |
| `tests/cast-otel-collector.bats` | 394 | 1 | Same daemon-start failure, third HTTP test (non-chunked Content-Length) | Environment (CI runner) | Same as above |
| `tests/cast-overlay-sync.bats` | 60 | 1 | Overlay-sync script exits non-zero after an empty-repo clone on the GH macOS runner (git 2.54 behavior difference) — "sets correct local git identity (dry-run)" | Environment (CI runner / git version) | Un-skip when GH macOS runner's git version matches local/ubuntu behavior for empty-clone |
| `tests/cast-overlay-sync.bats` | 75 | 1 | Same empty-clone git-version difference — "does not touch global git config" | Environment (CI runner / git version) | Same as above |
| `tests/cast-overlay-sync.bats` | 93 | 1 | Same empty-clone git-version difference — "corrects a pre-existing real-email local config (regression for GH007)" | Environment (CI runner / git version) | Same as above |
| `tests/status-writer.bats` | 23 | 1 | `zsh` binary not installed — gates the regression test that reproduces the zsh read-only-`status` bug under a real zsh subshell (a bash-only test cannot catch it) | Environment (interpreter) | Runs automatically where `zsh` is installed (macOS ships zsh as the default shell; local dev machines) — skips on ubuntu CI runners without zsh |
| `tests/bash32-source-guard.bats` | 50 | 1 | `/bin/bash` is 4+ — gates the **negative control** that proves the bash 3.2 `source`-of-a-missing-file-under-`set -e` fatality actually reproduces on this interpreter. Bash 4+ correctly does not have the bug, so on those hosts the assertion would be false rather than merely untested | Environment (interpreter version) | Never un-skipped on bash 4+; this is intentionally permanent. It runs for real on macOS, where `/bin/bash` is Apple's frozen 3.2.57, and skips on Linux CI (`/bin/bash` 5.x). The four positive tests in the same file assert the guarded idiom SURVIVES and run unconditionally on every interpreter |

---

## Principle

A skip is acceptable only when its reason is recorded and its un-skip condition is clearly stated. A skip with no rationale is indistinguishable from silent coverage loss — the same "absence-of-a-check masquerading as a pass" failure mode the honesty principle targets.

Three categories of skips exist:

1. **Permanent (deprecated feature):** The skip codifies that a feature is intentionally removed. The tests remain as documentation of prior behavior. Un-skipping requires resurrecting the feature itself.
2. **Conditional (archived path):** The skip gates a feature on a path that may be re-created. The tests are live documentation of expected behavior when the path returns. Un-skipping happens when the path re-appears.
3. **Environment (platform, build, or external tool):** The skip documents a capability gap in the test harness — a tool is missing, a platform is unsupported, or a build configuration lacks a feature. Un-skipping requires closing that gap.

For each skip in this ledger, check the category: if it's "Environment," the skip is a signal that the test harness could be hardened. If it's "Permanent" or "Conditional," the skip is documentation of intentional product decisions.

See also: `docs/honesty-feature.md` for the broader principle.
