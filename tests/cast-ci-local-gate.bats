#!/usr/bin/env bats
# Regression ratchet for LF-9 (2026-08-16): `make ci-local`'s preserved
# hook-contract-validation gate used to sit AFTER the act loop. python-unit
# was the loop's LAST job and could fail (it does, permanently, on this
# machine — PyYAML is absent from the act image catthehacker/ubuntu:act-latest
# but present on GitHub's ubuntu-latest), which meant the loop's `exit 1`
# aborted `make` before hook-contract-validation ever ran — silently. It was
# the only coverage for hook contracts in ci-local.
#
# The fix moves BOTH hook-contract-validation and python-unit out of the act
# loop to run directly, BEFORE the loop, each with its own unconditional
# failure path (no `|| true`, no `@` suppression of exit status).
#
# This harness is hermetic: it copies the repo's Makefile into a temp work
# dir, puts controllable `act`/`docker` stubs on PATH ahead of the real
# binaries, and stubs `scripts/cast-validate-all-hooks.sh` with a sentinel +
# controllable exit code. Nothing here invokes the real act, Docker, or the
# real hook validator, and nothing escapes the temp work dir.
#
# Mutation test (case 1, done by hand — see dispatch report for the exact
# output): a copy of the Makefile with the OLD ordering restored (hook gate
# echo + `bash scripts/cast-validate-all-hooks.sh --source` moved back to
# AFTER the `for j in ...; do ... done` loop, matching the pre-fix recipe)
# was run through the identical case-1 harness below. With that OLD copy,
# the case-1 assertion (target fails AND the HOOK_GATE_RAN sentinel is
# present in the output) FAILS: the target still fails (python-unit / a
# failing act stub aborts the loop) but HOOK_GATE_RAN is absent from the
# output, because `make` stopped at the loop's `exit 1` before ever reaching
# the hook-gate line. Restoring the fixed Makefile makes the assertion pass
# again. This proves the test discriminates the fixed ordering from the bug
# it is named for, rather than passing unconditionally.

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'
load 'helpers/setup'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

setup() {
  setup_temp_home
  WORK="$(mktemp -d)"
  if [[ "$WORK" != "$BATS_TMPDIR"/* && "$WORK" != /tmp/* && "$WORK" != /private/tmp/* && "$WORK" != /var/folders/* && "$WORK" != /private/var/folders/* ]]; then
    echo "refusing to use non-tmp work dir: $WORK" >&2
    return 1
  fi

  cp "$REPO_DIR/Makefile" "$WORK/Makefile"
  mkdir -p "$WORK/scripts" "$WORK/tests" "$WORK/stubbin"

  # Trivially-passing python test so the direct python-unit run has a real
  # (empty-ish) suite to discover instead of depending on this repo's suite.
  cat > "$WORK/tests/test_ok.py" <<'PYEOF'
import unittest


class OkTest(unittest.TestCase):
    def test_ok(self):
        self.assertTrue(True)
PYEOF

  # Controllable stub validator: sentinel line + exit code from env var.
  cat > "$WORK/scripts/cast-validate-all-hooks.sh" <<'HOOKEOF'
#!/usr/bin/env bash
echo "HOOK_GATE_RAN"
exit "${STUB_HOOK_EXIT:-0}"
HOOKEOF
  chmod +x "$WORK/scripts/cast-validate-all-hooks.sh"

  # Controllable stub bash32-parse-lint: sentinel line + exit code from env
  # var, mirroring the cast-validate-all-hooks.sh stub above. Added when
  # bash32-parse-lint became a direct (pre-loop) ci-local job — without this
  # stub the sandboxed $WORK dir has no such script and `make ci-local` dies
  # with "No such file or directory" before ever reaching the act loop.
  cat > "$WORK/scripts/cast-lint-bash32-parse.sh" <<'BASH32EOF'
#!/usr/bin/env bash
echo "BASH32_LINT_RAN"
exit "${STUB_BASH32_EXIT:-0}"
BASH32EOF
  chmod +x "$WORK/scripts/cast-lint-bash32-parse.sh"

  # Controllable stub act/docker, placed on PATH ahead of the real binaries.
  cat > "$WORK/stubbin/act" <<'ACTEOF'
#!/usr/bin/env bash
echo "ACT_STUB_RAN $*"
exit "${STUB_ACT_EXIT:-0}"
ACTEOF
  chmod +x "$WORK/stubbin/act"

  cat > "$WORK/stubbin/docker" <<'DOCKEREOF'
#!/usr/bin/env bash
exit 0
DOCKEREOF
  chmod +x "$WORK/stubbin/docker"
}

teardown() {
  if [[ -n "${WORK:-}" ]] && [[ "$WORK" == "$BATS_TMPDIR"/* || "$WORK" == /tmp/* || "$WORK" == /private/tmp/* || "$WORK" == /var/folders/* || "$WORK" == /private/var/folders/* ]]; then
    rm -rf "$WORK"
  fi
  teardown_temp_home
}

run_ci_local() {
  PATH="$WORK/stubbin:$PATH" STUB_HOOK_EXIT="${STUB_HOOK_EXIT:-0}" STUB_ACT_EXIT="${STUB_ACT_EXIT:-0}" STUB_BASH32_EXIT="${STUB_BASH32_EXIT:-0}" \
    bash -c 'cd "$1" && make -f "$1/Makefile" ci-local' _ "$WORK"
}

@test "case 1: an act-job failure does not silently skip the hook gate" {
  STUB_ACT_EXIT=1 run run_ci_local
  assert_failure
  assert_output --partial "HOOK_GATE_RAN"
}

@test "case 2: a failing hook validator fails the target even when act is green" {
  STUB_ACT_EXIT=0 STUB_HOOK_EXIT=1 run run_ci_local
  assert_failure
}

@test "case 3: green path succeeds and the summary names bash32-parse-lint and 8 act jobs" {
  # Act-job count is unchanged by the bash32-parse-lint addition: it runs as
  # a direct (pre-loop) job, not an act job, so the loop is still exactly
  # bats/stats-guard/rules-drift/readme-structure/pii-scan/shellcheck/
  # db-contract/self-lints (8). "8 act jobs" stays accurate; this only
  # broadens the assertion to also cover the new direct job's presence in
  # the closing summary line.
  STUB_ACT_EXIT=0 STUB_HOOK_EXIT=0 STUB_BASH32_EXIT=0 run run_ci_local
  assert_success
  # Sentinel FIRST, mirroring case 1's HOOK_GATE_RAN: this is the only
  # assertion that proves the stub was actually INVOKED. The two --partial
  # checks below match the Makefile's closing summary line, which prints
  # whether or not the job ran, so on their own they would pass against a
  # target that skipped it entirely.
  assert_output --partial "BASH32_LINT_RAN"
  assert_output --partial "bash32-parse-lint"
  assert_output --partial "8 act jobs"
}
