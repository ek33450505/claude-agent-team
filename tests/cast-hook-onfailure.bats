#!/usr/bin/env bats
# tests/cast-hook-onfailure.bats
# U1: native hook field "onFailure": "block" (Claude Code >= 2.1.295) on the
# three fail-closed CAST guards ONLY, plus the install-time version-floor WARN.
#
# Brick guard: UserPromptSubmit/SessionStart/telemetry/async hooks must stay
# fail-open — a broken memory router must never block prompts.

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO="${BATS_TEST_DIRNAME}/.."
FRAGMENT="${REPO}/managed-settings.d/25-hooks-security.json"
FRAGMENTS_DIR="${REPO}/managed-settings.d"
SETTINGS="${REPO}/settings.json"
PLUGIN_HOOKS="${REPO}/plugin/hooks/hooks.json"
FLOOR_SCRIPT="${REPO}/scripts/cast-cc-version-floor.sh"

# Prints "<event>|<id>|<command>|<onFailure>|<async>" for every inner hook in $1.
_hooks() {
  python3 - "$1" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
for ev, groups in (d.get("hooks") or {}).items():
    for g in groups:
        for h in g.get("hooks", []):
            print("|".join([ev, str(g.get("id", "")), h.get("command", ""),
                            str(h.get("onFailure", "")), str(h.get("async", ""))]))
PY
}

# Asserts exactly the three guard hooks carry onFailure == block in file $1.
_assert_three_guards() {
  local out
  out="$(_hooks "$1")"
  echo "$out" | grep -F 'ConfigChange|' | grep -F 'cast-config-change-guard.sh' | grep -q '|block|' || return 1
  echo "$out" | grep -F 'PreToolUse|cast-pretool-dispatch|' | grep -q '|block|' || return 1
  echo "$out" | grep -F 'PreToolUse|cast-write-guards|' | grep -q '|block|' || return 1
}

# --- (a) fragment ---------------------------------------------------------

@test "fragment: the three guard hooks carry onFailure block" {
  run _assert_three_guards "$FRAGMENT"
  assert_success
}

@test "fragment: cast-audit-hook.sh hooks do NOT carry onFailure" {
  run bash -c "$(declare -f _hooks); _hooks '$FRAGMENT' | grep -F 'cast-audit-hook.sh'"
  assert_success
  assert_output --partial 'cast-audit-hook.sh --mode pre'
  assert_output --partial 'cast-audit-hook.sh --mode post'
  refute_output --partial '|block|'
}

# --- (b) brick guard ------------------------------------------------------

@test "brick guard: onFailure block appears only under PreToolUse or ConfigChange (allowlist)" {
  run python3 - "$FRAGMENTS_DIR" <<'PY'
import glob, json, os, sys
ALLOWED = {"PreToolUse", "ConfigChange"}
bad = []
for f in sorted(glob.glob(os.path.join(sys.argv[1], "*.json"))):
    d = json.load(open(f))
    for ev, groups in (d.get("hooks") or {}).items():
        for g in groups:
            for h in g.get("hooks", []):
                if h.get("onFailure") == "block" and ev not in ALLOWED:
                    bad.append(f"{os.path.basename(f)}:{ev}")
print("\n".join(bad))
sys.exit(1 if bad else 0)
PY
  assert_success
  assert_output ""
}

@test "brick guard: no async hook carries onFailure in any fragment" {
  run python3 - "$FRAGMENTS_DIR" <<'PY'
import glob, json, os, sys
bad = []
for f in sorted(glob.glob(os.path.join(sys.argv[1], "*.json"))):
    d = json.load(open(f))
    for ev, groups in (d.get("hooks") or {}).items():
        for g in groups:
            for h in g.get("hooks", []):
                if h.get("async") is True and "onFailure" in h:
                    bad.append(f"{os.path.basename(f)}:{ev}")
print("\n".join(bad))
sys.exit(1 if bad else 0)
PY
  assert_success
  assert_output ""
}

@test "brick guard: exactly three onFailure block hooks exist across all fragments" {
  run python3 - "$FRAGMENTS_DIR" <<'PY'
import glob, json, os, sys
n = 0
for f in sorted(glob.glob(os.path.join(sys.argv[1], "*.json"))):
    d = json.load(open(f))
    for ev, groups in (d.get("hooks") or {}).items():
        for g in groups:
            for h in g.get("hooks", []):
                if "onFailure" in h:
                    n += 1
print(n)
PY
  assert_success
  assert_output "3"
}

# --- (c) committed build artifacts ---------------------------------------

@test "committed settings.json carries onFailure block on the three guards" {
  run _assert_three_guards "$SETTINGS"
  assert_success
}

@test "committed plugin/hooks/hooks.json carries onFailure block on the three guards" {
  run _assert_three_guards "$PLUGIN_HOOKS"
  assert_success
}

# --- (d) version floor script --------------------------------------------

setup() {
  STUB_DIR="${BATS_TEST_TMPDIR}/bin"
  mkdir -p "$STUB_DIR"
  # PATH with only coreutils-ish dirs and NO claude, for the absent case.
  NOCLAUDE_PATH="/usr/bin:/bin"
}

# $1 = text the stub `claude --version` prints
_stub_claude() {
  printf '#!/bin/sh\necho "%s"\n' "$1" > "${STUB_DIR}/claude"
  chmod +x "${STUB_DIR}/claude"
}

_run_floor() {
  run env PATH="${STUB_DIR}:${NOCLAUDE_PATH}" CLAUDE_SUBPROCESS=0 /bin/bash "$FLOOR_SCRIPT"
}

@test "floor: 2.1.294 warns and names the version" {
  _stub_claude "2.1.294 (Claude Code)"
  _run_floor
  assert_success
  assert_output --partial "WARNING"
  assert_output --partial "2.1.294"
}

@test "floor: 2.1.295 is silent" {
  _stub_claude "2.1.295 (Claude Code)"
  _run_floor
  assert_success
  assert_output ""
}

@test "floor: 2.1.300 is silent" {
  _stub_claude "2.1.300"
  _run_floor
  assert_success
  assert_output ""
}

@test "floor: 2.2.0 is silent" {
  _stub_claude "2.2.0"
  _run_floor
  assert_success
  assert_output ""
}

@test "floor: 3.0.0 is silent" {
  _stub_claude "3.0.0"
  _run_floor
  assert_success
  assert_output ""
}

@test "floor: 2.1.29 warns (numeric compare, not string)" {
  _stub_claude "2.1.29 (Claude Code)"
  _run_floor
  assert_success
  assert_output --partial "WARNING"
  assert_output --partial "2.1.29"
}

@test "floor: 2.1.80 warns (a string compare would stay silent)" {
  _stub_claude "2.1.80 (Claude Code)"
  _run_floor
  assert_success
  assert_output --partial "WARNING"
  assert_output --partial "2.1.80"
}

@test "floor: 2.1.1000 is silent (a string compare would warn)" {
  _stub_claude "2.1.1000 (Claude Code)"
  _run_floor
  assert_success
  assert_output ""
}

@test "floor: claude --version exiting 1 says could not determine and exits 0" {
  printf '#!/bin/sh\nexit 1\n' > "${STUB_DIR}/claude"
  chmod +x "${STUB_DIR}/claude"
  _run_floor
  assert_success
  assert_output --partial "could not determine"
}

@test "floor: garbage version says could not determine" {
  _stub_claude "not a version"
  _run_floor
  assert_success
  assert_output --partial "could not determine"
}

@test "floor: claude absent from PATH says could not determine" {
  run env PATH="$NOCLAUDE_PATH" CLAUDE_SUBPROCESS=0 /bin/bash "$FLOOR_SCRIPT"
  assert_success
  assert_output --partial "could not determine"
}

@test "floor: install.sh runs the floor check after the settings merge and warns" {
  merge=$(grep -n 'cast-merge-settings.sh" "\$CLAUDE_DIR/settings.json"' "${REPO}/install.sh" | head -1 | cut -d: -f1)
  floor=$(grep -n 'CC_FLOOR_MSG="\$(bash .*cast-cc-version-floor.sh.*|| true)"' "${REPO}/install.sh" | cut -d: -f1)
  warnl=$(grep -n 'warn "  \$CC_FLOOR_MSG"' "${REPO}/install.sh" | cut -d: -f1)
  [ -n "$merge" ]
  [ -n "$floor" ]
  [ -n "$warnl" ]
  [ "$floor" -gt "$merge" ]
  [ "$warnl" -gt "$floor" ]
}

# U3a: install.sh must refuse to deploy while the root-owned managed file is stale
# (a managed copy without onFailure cancels the user copy's block).
_gate_lines() {
  gate=$(grep -n 'cast-managed-settings-verify.py" --check-onfailure' "${REPO}/install.sh" | head -1 | cut -d: -f1)
  firstwrite=$(grep -nE '^[[:space:]]*(mkdir|cp|rm|chmod)[^#]*"\$CLAUDE_DIR/scripts' "${REPO}/install.sh" | head -1 | cut -d: -f1)
}

@test "managed gate: install.sh calls the verifier with --check-onfailure" {
  _gate_lines
  [ -n "$gate" ]
}

@test "managed gate: runs BEFORE the first write into CLAUDE_DIR/scripts" {
  _gate_lines
  [ -n "$gate" ]
  [ -n "$firstwrite" ]
  [ "$gate" -lt "$firstwrite" ]
}

@test "managed gate: runs before the backup/mkdir section too" {
  _gate_lines
  backup=$(grep -n '^backup_if_needed "\$CLAUDE_DIR/agents"' "${REPO}/install.sh" | head -1 | cut -d: -f1)
  [ -n "$gate" ]
  [ -n "$backup" ]
  [ "$gate" -lt "$backup" ]
}

@test "managed gate: failure branch prints the sudo commands and exits 1" {
  _gate_lines
  [ -n "$gate" ]
  printins=$(grep -n 'cast-managed-settings-verify.py" --print-install' "${REPO}/install.sh" | head -1 | cut -d: -f1)
  [ -n "$printins" ]
  [ "$printins" -gt "$gate" ]
  exitl=$(awk -v s="$gate" 'NR>s && /^[[:space:]]*exit 1[[:space:]]*$/ {print NR; exit}' "${REPO}/install.sh")
  [ -n "$exitl" ]
  [ "$exitl" -gt "$printins" ]
  # the exit 1 must be the gate's own: no `fi` at gate-block indent between call and exit
  [ $((exitl - gate)) -le 12 ]
}

@test "managed gate: skipped ONLY via _cast_is_test_home (sentinel + temp prefix), defined before the gate" {
  _gate_lines
  [ -n "$gate" ]
  pred=$(grep -n '^_cast_is_test_home()' "${REPO}/install.sh" | head -1 | cut -d: -f1)
  skipl=$(grep -n '^if _cast_is_test_home; then' "${REPO}/install.sh" | head -1 | cut -d: -f1)
  [ -n "$pred" ]
  [ -n "$skipl" ]
  [ "$pred" -lt "$skipl" ]
  [ "$skipl" -lt "$gate" ]
  end=$(awk -v s="$pred" 'NR>s && /^}/ {print NR; exit}' "${REPO}/install.sh")
  [ -n "$end" ]
  body=$(sed -n "${pred},${end}p" "${REPO}/install.sh")
  # the predicate honors the BATS temp-HOME sentinel AND a temp-prefix HOME ...
  printf '%s\n' "$body" | grep -q '\.cast-test-home'
  printf '%s\n' "$body" | grep -q 'cd -P'
  printf '%s\n' "$body" | grep -q '/var/folders/\*'
  printf '%s\n' "$body" | grep -q '/tmp/\*'
  # ... and nothing else: no CI / CLAUDE_SUBPROCESS / CAST_INSTALL_NO_LAUNCHCTL escape
  run grep -E 'CI|CLAUDE_SUBPROCESS|CAST_INSTALL_NO_LAUNCHCTL' <<<"$body"
  [ "$status" -ne 0 ]
}

@test "managed gate: the gate does not use _cast_skip_launchctl" {
  _gate_lines
  skipl=$(grep -n '^if _cast_is_test_home; then' "${REPO}/install.sh" | head -1 | cut -d: -f1)
  [ -n "$skipl" ]
  # the line opening the gate's block is the sentinel-only predicate, not the launchctl one
  ! sed -n "${skipl},${gate}p" "${REPO}/install.sh" | grep -q '_cast_skip_launchctl'
}

@test "managed gate: _cast_skip_launchctl is still defined exactly once" {
  n=$(grep -c '^[[:space:]]*_cast_skip_launchctl()' "${REPO}/install.sh")
  [ "$n" -eq 1 ]
}

# --- Behavioural: run the marked gate block from install.sh in isolation (install.sh itself is never run) ---
# The block is extracted between its marker comments and run with stub warn/error, a stub
# verifier file under a scratch SCRIPT_DIR, and a PATH-shimmed python3 whose behaviour each
# test controls through STUB_CHECK_RC. STUB_LOG records every python3 invocation.
_gate_setup() {
  GS="${BATS_TEST_TMPDIR}/gs"
  mkdir -p "$GS/bin" "$GS/sd/scripts"
  : > "$GS/sd/scripts/cast-managed-settings-verify.py"
  cat > "$GS/bin/python3" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$STUB_LOG"
case "$*" in
  *--check-onfailure*) echo "FAIL: stub says stale"; exit "${STUB_CHECK_RC:-0}" ;;
  *--print-install*) echo "FAKE-SUDO-COMMAND"; [ -n "${STUB_EMIT_ESC:-}" ] && printf '\033[31mEVIL\n'; exit 0 ;;
esac
exit 0
STUB
  chmod +x "$GS/bin/python3"
  {
    echo 'set -euo pipefail'
    echo 'warn() { printf "WARN: %s\n" "$1"; }'
    echo 'error() { printf "%s\n" "$1"; }'
    echo "SCRIPT_DIR=\"$GS/sd\""
    sed -n '/^# >>> cast-managed-onfailure-gate$/,/^# <<< cast-managed-onfailure-gate$/p' "${REPO}/install.sh"
    echo 'echo GATE-PASSED'
  } > "$GS/gate.sh"
  # the extraction must have found the block (not an empty/vacuous script)
  grep -q '_cast_is_test_home' "$GS/gate.sh"
  STUB_LOG="$GS/calls.log"
}

_gate_run() { # _gate_run <HOME> <check-rc>
  run env HOME="$1" PATH="$GS/bin:$PATH" STUB_LOG="$STUB_LOG" STUB_CHECK_RC="$2" /bin/bash "$GS/gate.sh"
}

@test "managed gate (behaviour): stale verdict + non-test HOME aborts with exit 1 and the abort text" {
  _gate_setup
  _gate_run "/nonexistent-home-$$" 1
  assert_failure 1
  assert_output --partial "install.sh aborted"
  assert_output --partial "FAKE-SUDO-COMMAND"
  refute_output --partial "GATE-PASSED"
}

@test "managed gate (behaviour): passing verdict + non-test HOME continues" {
  _gate_setup
  _gate_run "/nonexistent-home-$$" 0
  assert_success
  assert_output --partial "GATE-PASSED"
  refute_output --partial "skipped"
}

@test "managed gate (behaviour): sentinel + temp-prefix HOME skips, prints the notice, never calls the verifier" {
  _gate_setup
  th=$(mktemp -d "${BATS_TEST_TMPDIR}/th.XXXXXX")   # under the bats temp root (/tmp or /var/folders)
  [[ "$th" == /tmp/* || "$th" == /private/tmp/* || "$th" == /var/folders/* || "$th" == /private/var/folders/* ]]
  touch "$th/.cast-test-home"
  _gate_run "$th" 1
  rm -rf "$th"
  assert_success
  assert_output --partial "managed-settings onFailure gate skipped (test HOME)"
  assert_output --partial "GATE-PASSED"
  [ ! -s "$STUB_LOG" ]
}

@test "managed gate (behaviour): THE canonicalisation discriminator - a relative HOME resolving into a temp dir with the sentinel skips" {
  _gate_setup
  # Raw HOME "relhome" matches no temp prefix; its canonical path (under the bats temp root)
  # does and carries the sentinel. Only an implementation that canonicalises BEFORE both the
  # sentinel and the prefix check skips here.
  cd "$BATS_TEST_TMPDIR"
  mkdir -p relhome
  touch relhome/.cast-test-home
  _gate_run "relhome" 1
  assert_success
  assert_output --partial "gate skipped (test HOME)"
  [ ! -s "$STUB_LOG" ]
}

@test "managed gate (behaviour): positive path only - skip still works through a symlinked HOME (does NOT discriminate canonicalisation)" {
  _gate_setup
  th=$(mktemp -d "${BATS_TEST_TMPDIR}/th.XXXXXX")
  touch "$th/.cast-test-home"
  ln -s "$th" "${BATS_TEST_TMPDIR}/homelink"
  _gate_run "${BATS_TEST_TMPDIR}/homelink" 1
  rm -rf "$th"
  assert_success
  assert_output --partial "gate skipped (test HOME)"
}

@test "managed gate (behaviour): gate runs for a HOME that resolves to a non-temp dir with no sentinel (does NOT discriminate canonicalisation)" {
  _gate_setup
  # No sentinel can exist at the canonical (non-temp) location without writing outside the
  # temp roots, so this only shows the gate RUNS for such a HOME; it does not exercise the
  # prefix check or canonicalisation (the relative-HOME test above is THE discriminator).
  _gate_run "/tmp/../usr" 1
  assert_failure 1
  assert_output --partial "install.sh aborted"
  refute_output --partial "skipped"
}

@test "managed gate (behaviour): no sentinel under a temp-prefix HOME does NOT skip" {
  _gate_setup
  th=$(mktemp -d "${BATS_TEST_TMPDIR}/th.XXXXXX")
  [[ "$th" == /tmp/* || "$th" == /private/tmp/* || "$th" == /var/folders/* || "$th" == /private/var/folders/* ]]
  _gate_run "$th" 1
  rm -rf "$th"
  assert_failure 1
  assert_output --partial "install.sh aborted"
}

@test "managed gate (behaviour): CI / CLAUDE_SUBPROCESS / CAST_INSTALL_NO_LAUNCHCTL do not skip" {
  _gate_setup
  run env HOME="/nonexistent-home-$$" PATH="$GS/bin:$PATH" STUB_LOG="$STUB_LOG" STUB_CHECK_RC=1 \
    CI=1 CLAUDE_SUBPROCESS=1 CAST_INSTALL_NO_LAUNCHCTL=1 /bin/bash "$GS/gate.sh"
  assert_failure 1
  assert_output --partial "install.sh aborted"
}

@test "managed gate (behaviour): control characters in the printed install commands are sanitised" {
  _gate_setup
  run env HOME="/nonexistent-home-$$" PATH="$GS/bin:$PATH" STUB_LOG="$STUB_LOG" STUB_CHECK_RC=1 \
    STUB_EMIT_ESC=1 /bin/bash "$GS/gate.sh"
  assert_failure 1
  assert_output --partial "EVIL"
  [[ "$output" != *$'\033'* ]]
}
